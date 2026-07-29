#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/pkt_cls.h>
#include <linux/tcp.h>

#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

#include "cache_runtime_control.h"
#include "grpc_event.h"

#define GRPC_DEFAULT_PORT 50051
#define IP_FRAGMENT_MASK 0x3fff
#define RINGBUF_SIZE (1 << 24)
#define GRPC_FLOW_MAX_ENTRIES 65536
#define GRPC_RESPONSE_CACHE_MAX_ENTRIES 4096
#define H2_FRAME_HEADER_LEN 9
#define H2_PREFACE_LEN 24
#define H2_MAX_FRAMES_PER_PACKET 4
#define H2_FRAME_DATA 0x0
#define H2_FRAME_HEADERS 0x1
#define H2_FLAG_END_STREAM 0x1

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

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct cache_runtime_control);
} cache_rt_ctl SEC(".maps");

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
                                                __u8 is_response,
                                                __u32 stream_id)
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
    key->stream_id = stream_id;
}

struct grpc_h2_packet_info {
    __u32 stream_id;
    __u8 flags;
};

static __always_inline struct grpc_h2_packet_info
detect_h2_packet(const struct __sk_buff *skb, __u32 payload_offset,
                 __u32 payload_len)
{
    struct grpc_h2_packet_info info = {};
    char preface[H2_PREFACE_LEN] = {};
    __u32 scan_offset = payload_offset;
    __u32 remaining = payload_len;

    if (remaining >= H2_PREFACE_LEN &&
        read_packet(preface, skb, payload_offset, sizeof(preface)) == 0) {
        if (preface[0] == 'P' && preface[1] == 'R' && preface[2] == 'I' &&
            preface[3] == ' ' && preface[4] == '*' && preface[5] == ' ' &&
            preface[6] == 'H' && preface[7] == 'T' && preface[8] == 'T' &&
            preface[9] == 'P' && preface[10] == '/' && preface[11] == '2' &&
            preface[12] == '.' && preface[13] == '0' &&
            preface[14] == '\r' && preface[15] == '\n' &&
            preface[16] == '\r' && preface[17] == '\n' &&
            preface[18] == 'S' && preface[19] == 'M' &&
            preface[20] == '\r' && preface[21] == '\n' &&
            preface[22] == '\r' && preface[23] == '\n') {
            info.flags |= GRPC_FLAG_H2_PREFACE;
            scan_offset += H2_PREFACE_LEN;
            remaining -= H2_PREFACE_LEN;
        }
    }

#pragma unroll
    for (int i = 0; i < H2_MAX_FRAMES_PER_PACKET; ++i) {
        __u8 header[H2_FRAME_HEADER_LEN] = {};
        __u32 frame_len;
        __u32 stream_id;
        __u8 frame_type;
        __u8 frame_flags;

        if (remaining < H2_FRAME_HEADER_LEN)
            break;
        if (read_packet(header, skb, scan_offset, sizeof(header)) < 0)
            break;

        frame_len = ((__u32)header[0] << 16) |
                    ((__u32)header[1] << 8) |
                    (__u32)header[2];
        if (frame_len > remaining - H2_FRAME_HEADER_LEN)
            break;

        frame_type = header[3];
        frame_flags = header[4];
        stream_id = ((__u32)(header[5] & 0x7f) << 24) |
                    ((__u32)header[6] << 16) |
                    ((__u32)header[7] << 8) |
                    (__u32)header[8];

        if (stream_id != 0 &&
            (frame_type == H2_FRAME_HEADERS ||
             frame_type == H2_FRAME_DATA)) {
            info.stream_id = stream_id;
            if (frame_type == H2_FRAME_HEADERS)
                info.flags |= GRPC_FLAG_H2_HEADERS;
            else
                info.flags |= GRPC_FLAG_H2_DATA;
            if (frame_flags & H2_FLAG_END_STREAM)
                info.flags |= GRPC_FLAG_H2_END_STREAM;
            break;
        }

        scan_offset += H2_FRAME_HEADER_LEN + frame_len;
        remaining -= H2_FRAME_HEADER_LEN + frame_len;
    }

    return info;
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
    struct grpc_h2_packet_info h2 = {};
    __u64 now;
    __u64 latency_ns = 0;
    __u64 *start_ns;
    struct grpc_flow_key flow_key = {};
    struct grpc_event *event;

    if (read_packet(&eth, skb, offset, sizeof(eth)) < 0)
        return TC_ACT_PIPE;
    if (bpf_ntohs(eth.h_proto) != ETH_P_IP)
        return TC_ACT_PIPE;

    offset += sizeof(eth);
    if (read_packet(&ip, skb, offset, sizeof(ip)) < 0)
        return TC_ACT_PIPE;
    if (ip.version != 4 || ip.protocol != IPPROTO_TCP)
        return TC_ACT_PIPE;
    if (bpf_ntohs(ip.frag_off) & IP_FRAGMENT_MASK)
        return TC_ACT_PIPE;

    ip_header_len = ip.ihl * 4;
    if (ip_header_len < sizeof(ip))
        return TC_ACT_PIPE;

    offset += ip_header_len;
    if (read_packet(&tcp, skb, offset, sizeof(tcp)) < 0)
        return TC_ACT_PIPE;

    src_port = bpf_ntohs(tcp.source);
    dst_port = bpf_ntohs(tcp.dest);
    if (src_port != port && dst_port != port)
        return TC_ACT_PIPE;

    tcp_header_len = tcp.doff * 4;
    if (tcp_header_len < sizeof(tcp))
        return TC_ACT_PIPE;

    ip_total_len = bpf_ntohs(ip.tot_len);
    if (ip_total_len < ip_header_len + tcp_header_len)
        return TC_ACT_PIPE;

    payload_len = ip_total_len - ip_header_len - tcp_header_len;
    if (payload_len == 0)
        return TC_ACT_PIPE;

    payload_offset = offset + tcp_header_len;
    now = bpf_ktime_get_ns();
    is_response = src_port == port;
    h2 = detect_h2_packet(skb, payload_offset, payload_len);
    build_grpc_flow_key(&flow_key, &ip, src_port, dst_port, is_response,
                        h2.stream_id);

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
        return TC_ACT_PIPE;
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
    event->stream_id = h2.stream_id;
    event->src_port = src_port;
    event->dst_port = dst_port;
    event->is_response = is_response;
    event->matched = matched;
    event->flags = h2.flags;
    bpf_ringbuf_submit(event, 0);
    return TC_ACT_PIPE;
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

