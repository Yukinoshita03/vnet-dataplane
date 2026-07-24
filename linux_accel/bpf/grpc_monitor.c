#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/pkt_cls.h>
#include <linux/tcp.h>

#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

#include "grpc_event.h"

#define GRPC_DEFAULT_PORT 50051
#define IP_FRAGMENT_MASK 0x3fff
#define RINGBUF_SIZE (1 << 24)
#define GRPC_FLOW_MAX_ENTRIES 65536
#define GRPC_RESPONSE_CACHE_MAX_ENTRIES 4096

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, RINGBUF_SIZE);
} grpc_events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, GRPC_FLOW_MAX_ENTRIES);
    __type(key, struct grpc_flow_key);
    __type(value, __u64);
} grpc_request_start SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u64);
} grpc_dropped_events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct grpc_config);
} grpc_config_map SEC(".maps");
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, struct grpc_policy_key);
    __type(value, struct grpc_policy_value);
} grpc_policy_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, GRPC_RESPONSE_CACHE_MAX_ENTRIES);
    __type(key, struct grpc_response_cache_key);
    __type(value, struct grpc_response_cache_value);
} grpc_resp_cache SEC(".maps");

static __always_inline int read_packet(void *dst, const struct __sk_buff *skb,
                                       __u32 offset, __u32 len)
{
    return bpf_skb_load_bytes(skb, offset, dst, len);
}

static __always_inline __u16 configured_port(void)
{
    __u32 key = 0;
    struct grpc_config *config = bpf_map_lookup_elem(&grpc_config_map, &key);

    if (config && config->port)
        return config->port;
    return GRPC_DEFAULT_PORT;
}

static __always_inline void increment_dropped_events(void)
{
    __u32 key = 0;
    __u64 *value = bpf_map_lookup_elem(&grpc_dropped_events, &key);

    if (value)
        *value += 1;
}

static __always_inline void build_grpc_flow_key(struct grpc_flow_key *key,
                                                const struct iphdr *ip,
                                                __u16 src_port,
                                                __u16 dst_port,
                                                __u8 is_response)
{
    if (is_response) {
        key->client_ip = ip->daddr;
        key->server_ip = ip->saddr;
        key->client_port = dst_port;
        key->server_port = src_port;
    } else {
        key->client_ip = ip->saddr;
        key->server_ip = ip->daddr;
        key->client_port = src_port;
        key->server_port = dst_port;
    }
}

static __always_inline __u8 detect_h2_flags(const struct __sk_buff *skb,
                                            __u32 payload_offset,
                                            __u32 payload_len)
{
    char preface[24] = {};
    __u8 frame_type = 0;
    __u8 flags = 0;

    if (payload_len >= 24 &&
        read_packet(preface, skb, payload_offset, sizeof(preface)) == 0) {
        if (preface[0] == 'P' && preface[1] == 'R' && preface[2] == 'I' &&
            preface[3] == ' ' && preface[4] == '*' && preface[5] == ' ' &&
            preface[6] == 'H' && preface[7] == 'T' && preface[8] == 'T' &&
            preface[9] == 'P' && preface[10] == '/' && preface[11] == '2') {
            flags |= GRPC_FLAG_H2_PREFACE;
        }
    }

    if (payload_len >= 9 &&
        read_packet(&frame_type, skb, payload_offset + 3, sizeof(frame_type)) == 0 &&
        frame_type == 0x1) {
        flags |= GRPC_FLAG_H2_HEADERS;
    }

    return flags;
}

static __always_inline int handle_grpc_packet(struct __sk_buff *skb,
                                              __u32 direction)
{
    struct ethhdr eth = {};
    struct iphdr ip = {};
    struct tcphdr tcp = {};
    __u32 offset = 0;
    __u32 ip_header_len;
    __u32 tcp_header_len;
    __u32 ip_total_len;
    __u32 payload_len;
    __u32 payload_offset;
    __u16 src_port;
    __u16 dst_port;
    __u16 port = configured_port();
    __u8 is_response;
    __u8 matched = 0;
    __u8 flags = 0;
    __u64 now;
    __u64 latency_ns = 0;
    __u64 *start_ns;
    struct grpc_flow_key flow_key = {};
    struct grpc_event *event;

    if (read_packet(&eth, skb, offset, sizeof(eth)) < 0)
        return TC_ACT_OK;
    if (bpf_ntohs(eth.h_proto) != ETH_P_IP)
        return TC_ACT_OK;

    offset += sizeof(eth);
    if (read_packet(&ip, skb, offset, sizeof(ip)) < 0)
        return TC_ACT_OK;
    if (ip.version != 4 || ip.protocol != IPPROTO_TCP)
        return TC_ACT_OK;
    if (bpf_ntohs(ip.frag_off) & IP_FRAGMENT_MASK)
        return TC_ACT_OK;

    ip_header_len = ip.ihl * 4;
    if (ip_header_len < sizeof(ip))
        return TC_ACT_OK;

    offset += ip_header_len;
    if (read_packet(&tcp, skb, offset, sizeof(tcp)) < 0)
        return TC_ACT_OK;

    src_port = bpf_ntohs(tcp.source);
    dst_port = bpf_ntohs(tcp.dest);
    if (src_port != port && dst_port != port)
        return TC_ACT_OK;

    tcp_header_len = tcp.doff * 4;
    if (tcp_header_len < sizeof(tcp))
        return TC_ACT_OK;

    ip_total_len = bpf_ntohs(ip.tot_len);
    if (ip_total_len < ip_header_len + tcp_header_len)
        return TC_ACT_OK;

    payload_len = ip_total_len - ip_header_len - tcp_header_len;
    if (payload_len == 0)
        return TC_ACT_OK;

    payload_offset = offset + tcp_header_len;
    now = bpf_ktime_get_ns();
    is_response = src_port == port;
    flags = detect_h2_flags(skb, payload_offset, payload_len);
    build_grpc_flow_key(&flow_key, &ip, src_port, dst_port, is_response);

    if (is_response) {
        start_ns = bpf_map_lookup_elem(&grpc_request_start, &flow_key);
        if (start_ns) {
            matched = 1;
            latency_ns = now - *start_ns;
            bpf_map_delete_elem(&grpc_request_start, &flow_key);
        }
    } else {
        start_ns = bpf_map_lookup_elem(&grpc_request_start, &flow_key);
        if (!start_ns)
            bpf_map_update_elem(&grpc_request_start, &flow_key, &now, BPF_ANY);
    }

    event = bpf_ringbuf_reserve(&grpc_events, sizeof(*event), 0);
    if (!event) {
        increment_dropped_events();
        return TC_ACT_OK;
    }

    __builtin_memset(event, 0, sizeof(*event));
    event->timestamp_ns = now;
    event->latency_ns = latency_ns;
    event->direction = direction;
    event->ifindex = skb->ifindex;
    event->packet_len = skb->len;
    event->payload_len = payload_len;
    event->src_ip = ip.saddr;
    event->dst_ip = ip.daddr;
    event->src_port = src_port;
    event->dst_port = dst_port;
    event->is_response = is_response;
    event->matched = matched;
    event->flags = flags;
    bpf_ringbuf_submit(event, 0);
    return TC_ACT_OK;
}

SEC("tc/ingress")
int grpc_ingress(struct __sk_buff *skb)
{
    return handle_grpc_packet(skb, GRPC_DIR_INGRESS);
}

SEC("tc/egress")
int grpc_egress(struct __sk_buff *skb)
{
    return handle_grpc_packet(skb, GRPC_DIR_EGRESS);
}

char LICENSE[] SEC("license") = "GPL";

