#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/pkt_cls.h>
#include <linux/udp.h>

#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

#include "dns_event.h"

#define DNS_PORT 53
#define DNS_FLAG_RESPONSE 0x8000
#define DNS_RCODE_MASK 0x000f
#define IP_FRAGMENT_MASK 0x3fff
#define RINGBUF_SIZE (1 << 24)
#define DNS_QUERY_START_MAX_ENTRIES 65536

struct dns_hdr {
    __be16 id;
    __be16 flags;
    __be16 qdcount;
    __be16 ancount;
    __be16 nscount;
    __be16 arcount;
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, RINGBUF_SIZE);
} dns_events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, DNS_QUERY_START_MAX_ENTRIES);
    __type(key, struct dns_flow_key);
    __type(value, __u64);
} dns_query_start SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u64);
} dropped_events SEC(".maps");

static __always_inline int read_packet(void *dst, const struct __sk_buff *skb,
                                       __u32 offset, __u32 len)
{
    return bpf_skb_load_bytes(skb, offset, dst, len);
}

static __always_inline void increment_dropped_events(void)
{
    __u32 key = 0;
    __u64 *value = bpf_map_lookup_elem(&dropped_events, &key);

    if (value)
        *value += 1;
}

static __always_inline void build_dns_flow_key(struct dns_flow_key *key,
                                               const struct iphdr *ip,
                                               __u16 src_port,
                                               __u16 dst_port,
                                               __u16 dns_id,
                                               __u8 is_response)
{
    key->_pad = 0;
    key->dns_id = dns_id;
    // Normalize both query and response packets into a client-to-server key.
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

static __always_inline int handle_dns_packet(struct __sk_buff *skb,
                                             __u32 direction)
{
    struct ethhdr eth = {};
    struct iphdr ip = {};
    struct udphdr udp = {};
    struct dns_hdr dns = {};
    __u32 offset = 0;
    __u32 ip_header_len;
    __u16 src_port;
    __u16 dst_port;
    __u16 dns_id;
    __u16 dns_flags;
    __u8 is_response;
    __u8 matched = 0;
    __u8 rcode = 0;
    __u64 now;
    __u64 latency_ns = 0;
    __u64 *start_ns;
    struct dns_flow_key flow_key = {};
    struct dns_event *event;

    if (read_packet(&eth, skb, offset, sizeof(eth)) < 0)
        return TC_ACT_OK;

    if (bpf_ntohs(eth.h_proto) != ETH_P_IP)
        return TC_ACT_OK;

    offset += sizeof(eth);
    if (read_packet(&ip, skb, offset, sizeof(ip)) < 0)
        return TC_ACT_OK;

    if (ip.version != 4 || ip.protocol != IPPROTO_UDP)
        return TC_ACT_OK;

    if (bpf_ntohs(ip.frag_off) & IP_FRAGMENT_MASK)
        return TC_ACT_OK;

    ip_header_len = ip.ihl * 4;
    if (ip_header_len < sizeof(ip))
        return TC_ACT_OK;

    offset += ip_header_len;
    if (read_packet(&udp, skb, offset, sizeof(udp)) < 0)
        return TC_ACT_OK;

    src_port = bpf_ntohs(udp.source);
    dst_port = bpf_ntohs(udp.dest);
    if (src_port != DNS_PORT && dst_port != DNS_PORT)
        return TC_ACT_OK;

    offset += sizeof(udp);
    if (read_packet(&dns, skb, offset, sizeof(dns)) < 0)
        return TC_ACT_OK;

    now = bpf_ktime_get_ns();
    dns_id = bpf_ntohs(dns.id);
    dns_flags = bpf_ntohs(dns.flags);
    is_response = !!(dns_flags & DNS_FLAG_RESPONSE);
    if (is_response)
        rcode = dns_flags & DNS_RCODE_MASK;

    build_dns_flow_key(&flow_key, &ip, src_port, dst_port, dns_id, is_response);
    // Match responses with the saved query timestamp to estimate DNS latency.
    if (is_response) {
        start_ns = bpf_map_lookup_elem(&dns_query_start, &flow_key);
        if (start_ns) {
            matched = 1;
            latency_ns = now - *start_ns;
            bpf_map_delete_elem(&dns_query_start, &flow_key);
        }
    } else {
        bpf_map_update_elem(&dns_query_start, &flow_key, &now, BPF_ANY);
    }

    event = bpf_ringbuf_reserve(&dns_events, sizeof(*event), 0);
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
    event->src_ip = ip.saddr;
    event->dst_ip = ip.daddr;
    event->src_port = src_port;
    event->dst_port = dst_port;
    event->dns_id = dns_id;
    event->is_response = is_response;
    event->rcode = rcode;
    event->matched = matched;
    bpf_ringbuf_submit(event, 0);
    return TC_ACT_OK;
}

SEC("tc/ingress")
int dns_ingress(struct __sk_buff *skb)
{
    return handle_dns_packet(skb, DNS_DIR_INGRESS);
}

SEC("tc/egress")
int dns_egress(struct __sk_buff *skb)
{
    return handle_dns_packet(skb, DNS_DIR_EGRESS);
}

char LICENSE[] SEC("license") = "GPL";
