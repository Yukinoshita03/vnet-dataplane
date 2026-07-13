#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/pkt_cls.h>
#include <linux/udp.h>

#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

#include "dns_event.h"
#include "dns_xdp_cache_helpers.h"

#define IP_FRAGMENT_MASK 0x3fff
#define RINGBUF_SIZE (1 << 24)
#define DNS_CLIENT_CACHE_MAX_ENTRIES 4096
#define DNS_CLIENT_PENDING_MAX_ENTRIES 65536
#define DNS_CLIENT_TRUSTED_MAX_ENTRIES 16

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, RINGBUF_SIZE);
} dns_events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u64);
} dropped_events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, DNS_CACHE_STAT_COUNT);
    __type(key, __u32);
    __type(value, __u64);
} dns_cache_stats SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, DNS_CLIENT_CACHE_MAX_ENTRIES);
    __type(key, struct dns_client_cache_key);
    __type(value, struct dns_cache_value);
} dns_client_cache SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, DNS_CLIENT_PENDING_MAX_ENTRIES);
    __type(key, struct dns_flow_key);
    __type(value, struct dns_client_pending_value);
} dns_client_pending SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, DNS_CLIENT_TRUSTED_MAX_ENTRIES);
    __type(key, __u32);
    __type(value, __u8);
} dns_client_trusted_servers SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct dns_client_config);
} dns_client_config SEC(".maps");

static __always_inline void increment_dropped_events(void)
{
    __u32 key = 0;
    __u64 *value = bpf_map_lookup_elem(&dropped_events, &key);

    if (value)
        *value += 1;
}

static __always_inline void increment_cache_stat(__u32 key)
{
    __u64 *value = bpf_map_lookup_elem(&dns_cache_stats, &key);

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

static __always_inline int is_trusted_dns_server(__u32 address)
{
    __u8 *enabled = bpf_map_lookup_elem(&dns_client_trusted_servers, &address);

    return enabled && *enabled;
}

static __always_inline struct dns_client_config *client_config(void)
{
    __u32 key = 0;

    return bpf_map_lookup_elem(&dns_client_config, &key);
}

static __always_inline void emit_dns_event(__u32 direction, __u32 ifindex,
                                            __u32 packet_len,
                                            const struct iphdr *ip,
                                            __u16 src_port, __u16 dst_port,
                                            __u16 dns_id, __u8 is_response,
                                            __u8 rcode, __u8 matched,
                                            __u64 timestamp_ns,
                                            __u64 latency_ns)
{
    struct dns_event *event = bpf_ringbuf_reserve(&dns_events, sizeof(*event), 0);

    if (!event) {
        increment_dropped_events();
        return;
    }

    __builtin_memset(event, 0, sizeof(*event));
    event->timestamp_ns = timestamp_ns;
    event->latency_ns = latency_ns;
    event->direction = direction;
    event->ifindex = ifindex;
    event->packet_len = packet_len;
    event->src_ip = ip->saddr;
    event->dst_ip = ip->daddr;
    event->src_port = src_port;
    event->dst_port = dst_port;
    event->dns_id = dns_id;
    event->is_response = is_response;
    event->rcode = rcode;
    event->matched = matched;
    bpf_ringbuf_submit(event, 0);
}

static __always_inline int try_client_cache_response(
    struct xdp_md *ctx, void *data, void *data_end, struct ethhdr *eth,
    struct iphdr *ip, struct udphdr *udp, struct dns_hdr *dns,
    __u32 ip_header_len, __u16 src_port, __u16 dst_port, __u16 dns_id,
    __u16 dns_flags, __u64 now)
{
    struct dns_client_cache_key cache_key = {};
    struct dns_client_pending_value pending = {};
    struct dns_cache_value *cache_value;
    __u32 question_end_offset = 0;
    __u16 old_ip_len;
    __u16 old_udp_len;
    __u16 new_ip_len;
    __u16 new_udp_len;
    __u32 logical_packet_end_offset;
    __u32 answer_offset;
    __u32 answer_ipv4;
    __u32 answer_ttl;
    __u64 remaining_ns;
    struct dns_flow_key flow_key = {};

    if (dns_flags & DNS_FLAG_RESPONSE)
        return XDP_PASS;
    if (dns_flags & DNS_OPCODE_MASK)
        return XDP_PASS;
    if (dst_port != DNS_PORT || bpf_ntohs(dns->qdcount) != 1)
        return XDP_PASS;
    if (bpf_ntohs(dns->ancount) != 0 || bpf_ntohs(dns->nscount) != 0 ||
        bpf_ntohs(dns->arcount) != 0)
        return XDP_PASS;
    if (ip_header_len != sizeof(*ip) || !is_trusted_dns_server(ip->daddr))
        return XDP_PASS;

    cache_key.resolver_ipv4 = ip->daddr;
    if (dns_parse_question(data, data_end, dns, cache_key.qname,
                           &cache_key.qtype, &cache_key.qclass,
                           &question_end_offset) < 0)
        return XDP_PASS;
    if (cache_key.qtype != DNS_QTYPE_A || cache_key.qclass != DNS_QCLASS_IN)
        return XDP_PASS;

    cache_value = bpf_map_lookup_elem(&dns_client_cache, &cache_key);
    if (cache_value && cache_value->expires_ns && now > cache_value->expires_ns) {
        bpf_map_delete_elem(&dns_client_cache, &cache_key);
        increment_cache_stat(DNS_CACHE_STAT_EXPIRED);
        cache_value = 0;
    }

    if (!cache_value) {
        build_dns_flow_key(&flow_key, ip, src_port, dst_port, dns_id, 0);
        pending.cache_key = cache_key;
        pending.started_ns = now;
        bpf_map_update_elem(&dns_client_pending, &flow_key, &pending, BPF_ANY);
        increment_cache_stat(DNS_CACHE_STAT_MISS);
        return XDP_PASS;
    }

    old_ip_len = bpf_ntohs(ip->tot_len);
    old_udp_len = bpf_ntohs(udp->len);
    logical_packet_end_offset = (__u32)((long)ip - (long)data) + old_ip_len;
    if (question_end_offset != logical_packet_end_offset)
        return XDP_PASS;

    answer_ipv4 = cache_value->answer_ipv4;
    answer_ttl = cache_value->ttl;
    if (cache_value->expires_ns) {
        remaining_ns = cache_value->expires_ns - now;
        answer_ttl = (__u32)(remaining_ns / 1000000000ull);
        if (!answer_ttl)
            answer_ttl = 1;
    }
    new_ip_len = old_ip_len + DNS_A_ANSWER_LEN;
    new_udp_len = old_udp_len + DNS_A_ANSWER_LEN;
    answer_offset = question_end_offset;

    if (bpf_xdp_adjust_tail(ctx, DNS_A_ANSWER_LEN) < 0)
        return XDP_ABORTED;

    data = (void *)(long)ctx->data;
    data_end = (void *)(long)ctx->data_end;
    eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_ABORTED;
    ip = data + sizeof(*eth);
    if ((void *)(ip + 1) > data_end)
        return XDP_ABORTED;
    udp = (void *)ip + sizeof(*ip);
    if ((void *)(udp + 1) > data_end)
        return XDP_ABORTED;
    dns = (void *)udp + sizeof(*udp);
    if ((void *)(dns + 1) > data_end)
        return XDP_ABORTED;

    if (dns_write_a_answer(data, data_end, answer_offset, answer_ttl,
                           answer_ipv4) < 0)
        return XDP_ABORTED;

    dns_swap_eth_addrs(eth);

    __be32 tmp_ip = ip->saddr;
    ip->saddr = ip->daddr;
    ip->daddr = tmp_ip;
    ip->tot_len = bpf_htons(new_ip_len);
    ip->check = 0;
    ip->check = dns_ipv4_header_checksum(ip);

    __be16 tmp_port = udp->source;
    udp->source = udp->dest;
    udp->dest = tmp_port;
    udp->len = bpf_htons(new_udp_len);
    udp->check = 0;

    dns->flags = bpf_htons(DNS_RESPONSE_NOERROR);
    dns->ancount = bpf_htons(1);
    dns->nscount = 0;
    dns->arcount = 0;

    increment_cache_stat(DNS_CACHE_STAT_HIT);
    increment_cache_stat(DNS_CACHE_STAT_TX);
    return XDP_TX;
}

SEC("xdp")
int dns_client_cache_xdp(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;
    struct ethhdr *eth = data;
    struct iphdr *ip;
    struct udphdr *udp;
    struct dns_hdr *dns;
    __u32 ip_header_len;
    __u16 src_port;
    __u16 dst_port;
    __u16 dns_id;
    __u16 dns_flags;
    __u8 is_response;
    __u8 rcode = 0;
    __u64 now;
    int cache_action;

    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;
    if (bpf_ntohs(eth->h_proto) != ETH_P_IP)
        return XDP_PASS;

    ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;
    if (ip->version != 4 || ip->protocol != IPPROTO_UDP)
        return XDP_PASS;
    if (bpf_ntohs(ip->frag_off) & IP_FRAGMENT_MASK)
        return XDP_PASS;

    ip_header_len = ip->ihl * 4;
    if (ip_header_len < sizeof(*ip))
        return XDP_PASS;
    udp = (void *)ip + ip_header_len;
    if ((void *)(udp + 1) > data_end)
        return XDP_PASS;

    src_port = bpf_ntohs(udp->source);
    dst_port = bpf_ntohs(udp->dest);
    if (src_port != DNS_PORT && dst_port != DNS_PORT)
        return XDP_PASS;

    dns = (void *)(udp + 1);
    if ((void *)(dns + 1) > data_end)
        return XDP_PASS;

    now = bpf_ktime_get_ns();
    dns_id = bpf_ntohs(dns->id);
    dns_flags = bpf_ntohs(dns->flags);
    is_response = !!(dns_flags & DNS_FLAG_RESPONSE);
    if (is_response)
        rcode = dns_flags & DNS_RCODE_MASK;

    cache_action = try_client_cache_response(
        ctx, data, data_end, eth, ip, udp, dns, ip_header_len, src_port,
        dst_port, dns_id, dns_flags, now);
    if (cache_action != XDP_PASS)
        return cache_action;

    emit_dns_event(DNS_DIR_CLIENT_XDP_INGRESS, ctx->ingress_ifindex,
                   (__u32)((long)data_end - (long)data), ip, src_port,
                   dst_port, dns_id, is_response, rcode, 0, now, 0);
    return XDP_PASS;
}

static __always_inline int read_packet(void *dst, const struct __sk_buff *skb,
                                       __u32 offset, __u32 len)
{
    return bpf_skb_load_bytes(skb, offset, dst, len);
}

static __always_inline int parse_skb_question(
    const struct __sk_buff *skb, __u32 dns_offset,
    struct dns_client_cache_key *cache_key, __u32 *answer_offset)
{
    __u32 qname_offset = dns_offset + sizeof(struct dns_hdr);
    __u32 qname_len = 0;
    __u8 label_remaining = 0;
    __u8 field[4] = {};

    __builtin_memset(cache_key, 0, sizeof(*cache_key));
    for (int i = 0; i < DNS_CLIENT_QNAME_MAX; i++) {
        __u8 value;

        if (read_packet(&value, skb, qname_offset + i, sizeof(value)) < 0)
            return -1;
        if (!label_remaining) {
            if (value == 0) {
                cache_key->qname[i] = value;
                qname_len = i + 1;
                break;
            }
            if (value > 63)
                return -1;
            label_remaining = value;
        } else {
            if (value >= 'A' && value <= 'Z')
                value += 'a' - 'A';
            label_remaining--;
        }
        cache_key->qname[i] = value;
    }

    if (!qname_len)
        return -1;
    if (read_packet(field, skb, qname_offset + qname_len, sizeof(field)) < 0)
        return -1;

    cache_key->qtype = ((__u16)field[0] << 8) | field[1];
    cache_key->qclass = ((__u16)field[2] << 8) | field[3];
    *answer_offset = qname_offset + qname_len + sizeof(field);
    return 0;
}

static __always_inline int cache_keys_equal(
    const struct dns_client_cache_key *lhs,
    const struct dns_client_cache_key *rhs)
{
    if (lhs->resolver_ipv4 != rhs->resolver_ipv4 || lhs->qtype != rhs->qtype ||
        lhs->qclass != rhs->qclass)
        return 0;

    for (int i = 0; i < DNS_CLIENT_QNAME_MAX; i++) {
        if (lhs->qname[i] != rhs->qname[i])
            return 0;
    }
    return 1;
}

static __always_inline void reject_pending(const struct dns_flow_key *flow_key)
{
    bpf_map_delete_elem(&dns_client_pending, flow_key);
    increment_cache_stat(DNS_CACHE_STAT_LEARN_REJECTED);
}

SEC("tc/egress")
int dns_client_cache_egress(struct __sk_buff *skb)
{
    struct ethhdr eth = {};
    struct iphdr ip = {};
    struct udphdr udp = {};
    struct dns_hdr dns = {};
    struct dns_flow_key flow_key = {};
    struct dns_client_pending_value *pending;
    struct dns_client_config *config;
    struct dns_client_cache_key response_key = {};
    struct dns_a_answer answer = {};
    struct dns_cache_value cache_value = {};
    __u32 offset = 0;
    __u32 ip_header_len;
    __u32 answer_offset = 0;
    __u16 src_port;
    __u16 dst_port;
    __u16 dns_id;
    __u16 dns_flags;
    __u8 rcode;
    __u8 matched = 0;
    __u64 now;
    __u64 latency_ns = 0;
    __u32 ttl;

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
    if (ip_header_len != sizeof(ip))
        return TC_ACT_OK;
    offset += ip_header_len;
    if (read_packet(&udp, skb, offset, sizeof(udp)) < 0)
        return TC_ACT_OK;

    src_port = bpf_ntohs(udp.source);
    dst_port = bpf_ntohs(udp.dest);
    if (src_port != DNS_PORT)
        return TC_ACT_OK;

    offset += sizeof(udp);
    if (read_packet(&dns, skb, offset, sizeof(dns)) < 0)
        return TC_ACT_OK;

    dns_flags = bpf_ntohs(dns.flags);
    if (!(dns_flags & DNS_FLAG_RESPONSE))
        return TC_ACT_OK;

    now = bpf_ktime_get_ns();
    dns_id = bpf_ntohs(dns.id);
    rcode = dns_flags & DNS_RCODE_MASK;
    build_dns_flow_key(&flow_key, &ip, src_port, dst_port, dns_id, 1);
    pending = bpf_map_lookup_elem(&dns_client_pending, &flow_key);
    if (pending) {
        matched = 1;
        latency_ns = now - pending->started_ns;
        config = client_config();
        if (!config || now - pending->started_ns > config->learn_window_ns) {
            bpf_map_delete_elem(&dns_client_pending, &flow_key);
            increment_cache_stat(DNS_CACHE_STAT_PENDING_EXPIRED);
        } else if (!is_trusted_dns_server(ip.saddr) ||
                   (dns_flags & DNS_OPCODE_MASK) ||
                   (dns_flags & DNS_FLAG_TRUNCATED) || rcode != 0 ||
                   bpf_ntohs(dns.qdcount) != 1 ||
                   bpf_ntohs(dns.ancount) != 1 ||
                   parse_skb_question(skb, offset, &response_key,
                                      &answer_offset) < 0) {
            reject_pending(&flow_key);
        } else {
            response_key.resolver_ipv4 = ip.saddr;
            if (!cache_keys_equal(&pending->cache_key, &response_key) ||
                read_packet(&answer, skb, answer_offset, sizeof(answer)) < 0 ||
                bpf_ntohs(answer.name) != 0xc00c ||
                bpf_ntohs(answer.type) != DNS_QTYPE_A ||
                bpf_ntohs(answer.class) != DNS_QCLASS_IN ||
                bpf_ntohs(answer.rdlength) != 4 ||
                bpf_ntohs(dns.nscount) != 0 ||
                bpf_ntohs(dns.arcount) != 0) {
                reject_pending(&flow_key);
            } else {
                ttl = bpf_ntohl(answer.ttl);
                if (!ttl) {
                    reject_pending(&flow_key);
                } else {
                    if (!config->max_ttl) {
                        reject_pending(&flow_key);
                    } else {
                        if (ttl > config->max_ttl)
                        ttl = config->max_ttl;
                        cache_value.answer_ipv4 = answer.addr;
                        cache_value.ttl = ttl;
                        cache_value.expires_ns =
                            now + (__u64)ttl * 1000000000ull;
                        bpf_map_update_elem(&dns_client_cache, &response_key,
                                            &cache_value, BPF_ANY);
                        bpf_map_delete_elem(&dns_client_pending, &flow_key);
                        increment_cache_stat(DNS_CACHE_STAT_LEARNED);
                    }
                }
            }
        }
    }

    emit_dns_event(DNS_DIR_CLIENT_TC_EGRESS, skb->ifindex, skb->len, &ip,
                   src_port, dst_port, dns_id, 1, rcode, matched, now,
                   latency_ns);
    return TC_ACT_OK;
}

char LICENSE[] SEC("license") = "GPL";
