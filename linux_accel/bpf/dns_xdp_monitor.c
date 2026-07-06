#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/udp.h>

#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

#include "dns_event.h"

#define DNS_PORT 53
#define DNS_FLAG_RESPONSE 0x8000
#define DNS_RCODE_MASK 0x000f
#define DNS_QTYPE_A 1
#define DNS_QCLASS_IN 1
#define DNS_RESPONSE_NOERROR 0x8180
#define DNS_A_ANSWER_LEN 16
#define DNS_CACHE_ANSWER_OFFSET_MAX 511
#define DNS_XDP_QNAME_SCAN_MAX 64
#define DNS_FIXED_ANSWER_WRITER(offset)                                      \
    if (answer_offset == offset) {                                           \
        answer = data + offset;                                              \
        if ((void *)(answer + DNS_A_ANSWER_LEN) > data_end)                  \
            return -1;                                                       \
        goto write_answer;                                                   \
    }
#define ETH_ALEN 6
#define IP_FRAGMENT_MASK 0x3fff
#define RINGBUF_SIZE (1 << 24)
#define DNS_QUERY_START_MAX_ENTRIES 65536
#define DNS_CACHE_MAX_ENTRIES 1024

struct dns_hdr {
    __be16 id;
    __be16 flags;
    __be16 qdcount;
    __be16 ancount;
    __be16 nscount;
    __be16 arcount;
};

struct dns_a_answer {
    __be16 name;
    __be16 type;
    __be16 class;
    __be32 ttl;
    __be16 rdlength;
    __be32 addr;
} __attribute__((packed));

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

struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, DNS_CACHE_MAX_ENTRIES);
    __type(key, struct dns_cache_key);
    __type(value, struct dns_cache_value);
} dns_cache SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, DNS_CACHE_STAT_COUNT);
    __type(key, __u32);
    __type(value, __u64);
} dns_cache_stats SEC(".maps");

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

static __always_inline __u16 ipv4_header_checksum(struct iphdr *ip)
{
    __u8 *p = (__u8 *)ip;
    __u32 sum = 0;

    sum += ((__u16)p[0] << 8) | p[1];
    sum += ((__u16)p[2] << 8) | p[3];
    sum += ((__u16)p[4] << 8) | p[5];
    sum += ((__u16)p[6] << 8) | p[7];
    sum += ((__u16)p[8] << 8) | p[9];
    sum += ((__u16)p[10] << 8) | p[11];
    sum += ((__u16)p[12] << 8) | p[13];
    sum += ((__u16)p[14] << 8) | p[15];
    sum += ((__u16)p[16] << 8) | p[17];
    sum += ((__u16)p[18] << 8) | p[19];

    sum = (sum & 0xffff) + (sum >> 16);
    sum = (sum & 0xffff) + (sum >> 16);
    return bpf_htons((__u16)(~sum));
}

static __always_inline void swap_eth_addrs(struct ethhdr *eth)
{
    __u8 tmp;

    tmp = eth->h_source[0];
    eth->h_source[0] = eth->h_dest[0];
    eth->h_dest[0] = tmp;
    tmp = eth->h_source[1];
    eth->h_source[1] = eth->h_dest[1];
    eth->h_dest[1] = tmp;
    tmp = eth->h_source[2];
    eth->h_source[2] = eth->h_dest[2];
    eth->h_dest[2] = tmp;
    tmp = eth->h_source[3];
    eth->h_source[3] = eth->h_dest[3];
    eth->h_dest[3] = tmp;
    tmp = eth->h_source[4];
    eth->h_source[4] = eth->h_dest[4];
    eth->h_dest[4] = tmp;
    tmp = eth->h_source[5];
    eth->h_source[5] = eth->h_dest[5];
    eth->h_dest[5] = tmp;
}

static __always_inline int write_dns_a_answer(void *data, void *data_end,
                                              __u32 answer_offset,
                                              __u32 answer_ttl,
                                              __u32 answer_ipv4)
{
    __u8 *answer;

    DNS_FIXED_ANSWER_WRITER(60)
    DNS_FIXED_ANSWER_WRITER(61)
    DNS_FIXED_ANSWER_WRITER(62)
    DNS_FIXED_ANSWER_WRITER(63)
    DNS_FIXED_ANSWER_WRITER(64)
    DNS_FIXED_ANSWER_WRITER(65)
    DNS_FIXED_ANSWER_WRITER(66)
    DNS_FIXED_ANSWER_WRITER(67)
    DNS_FIXED_ANSWER_WRITER(68)
    DNS_FIXED_ANSWER_WRITER(69)
    DNS_FIXED_ANSWER_WRITER(70)
    DNS_FIXED_ANSWER_WRITER(71)
    DNS_FIXED_ANSWER_WRITER(72)
    DNS_FIXED_ANSWER_WRITER(73)
    DNS_FIXED_ANSWER_WRITER(74)
    DNS_FIXED_ANSWER_WRITER(75)
    DNS_FIXED_ANSWER_WRITER(76)
    DNS_FIXED_ANSWER_WRITER(77)
    DNS_FIXED_ANSWER_WRITER(78)
    DNS_FIXED_ANSWER_WRITER(79)
    DNS_FIXED_ANSWER_WRITER(80)
    DNS_FIXED_ANSWER_WRITER(81)
    DNS_FIXED_ANSWER_WRITER(82)
    DNS_FIXED_ANSWER_WRITER(83)
    DNS_FIXED_ANSWER_WRITER(84)
    DNS_FIXED_ANSWER_WRITER(85)
    DNS_FIXED_ANSWER_WRITER(86)
    DNS_FIXED_ANSWER_WRITER(87)
    DNS_FIXED_ANSWER_WRITER(88)
    DNS_FIXED_ANSWER_WRITER(89)
    DNS_FIXED_ANSWER_WRITER(90)
    DNS_FIXED_ANSWER_WRITER(91)
    DNS_FIXED_ANSWER_WRITER(92)
    DNS_FIXED_ANSWER_WRITER(93)
    DNS_FIXED_ANSWER_WRITER(94)
    DNS_FIXED_ANSWER_WRITER(95)
    DNS_FIXED_ANSWER_WRITER(96)
    DNS_FIXED_ANSWER_WRITER(97)
    DNS_FIXED_ANSWER_WRITER(98)
    DNS_FIXED_ANSWER_WRITER(99)
    DNS_FIXED_ANSWER_WRITER(100)
    DNS_FIXED_ANSWER_WRITER(101)
    DNS_FIXED_ANSWER_WRITER(102)
    DNS_FIXED_ANSWER_WRITER(103)
    DNS_FIXED_ANSWER_WRITER(104)
    DNS_FIXED_ANSWER_WRITER(105)
    DNS_FIXED_ANSWER_WRITER(106)
    DNS_FIXED_ANSWER_WRITER(107)
    DNS_FIXED_ANSWER_WRITER(108)
    DNS_FIXED_ANSWER_WRITER(109)
    DNS_FIXED_ANSWER_WRITER(110)
    DNS_FIXED_ANSWER_WRITER(111)
    DNS_FIXED_ANSWER_WRITER(112)
    DNS_FIXED_ANSWER_WRITER(113)
    DNS_FIXED_ANSWER_WRITER(114)
    DNS_FIXED_ANSWER_WRITER(115)
    DNS_FIXED_ANSWER_WRITER(116)
    DNS_FIXED_ANSWER_WRITER(117)
    DNS_FIXED_ANSWER_WRITER(118)
    DNS_FIXED_ANSWER_WRITER(119)
    DNS_FIXED_ANSWER_WRITER(120)
    DNS_FIXED_ANSWER_WRITER(121)
    DNS_FIXED_ANSWER_WRITER(122)
    return -1;

write_answer:
    answer[0] = 0xc0;
    answer[1] = 0x0c;
    answer[2] = 0x00;
    answer[3] = DNS_QTYPE_A;
    answer[4] = 0x00;
    answer[5] = DNS_QCLASS_IN;
    answer[6] = (__u8)(answer_ttl >> 24);
    answer[7] = (__u8)(answer_ttl >> 16);
    answer[8] = (__u8)(answer_ttl >> 8);
    answer[9] = (__u8)answer_ttl;
    answer[10] = 0x00;
    answer[11] = 0x04;
    answer[12] = (__u8)answer_ipv4;
    answer[13] = (__u8)(answer_ipv4 >> 8);
    answer[14] = (__u8)(answer_ipv4 >> 16);
    answer[15] = (__u8)(answer_ipv4 >> 24);
    return 0;
}

static __always_inline int parse_dns_question(void *data, void *data_end,
                                              const struct dns_hdr *dns,
                                              struct dns_cache_key *key,
                                              __u32 *question_end_offset)
{
    int done = 0;
    __u32 qname_len = 0;
    __u8 *field;
    __u8 *question = (__u8 *)(dns + 1);

    __builtin_memset(key, 0, sizeof(*key));

    for (int i = 0; i < DNS_XDP_QNAME_SCAN_MAX; i++) {
        __u8 value;

        if ((void *)(question + i + 1) > data_end)
            return -1;

        value = question[i];
        key->qname[i] = value;

        if (value == 0) {
            done = 1;
            qname_len = i + 1;
            break;
        }
    }

    if (!done)
        return -1;

    field = question + qname_len;
    if ((void *)(field + 4) > data_end)
        return -1;

    key->qtype = ((__u16)field[0] << 8) | field[1];
    key->qclass = ((__u16)field[2] << 8) | field[3];
    *question_end_offset = (__u32)((long)field + 4 - (long)data);
    return 0;
}

static __always_inline int try_dns_cache_response(struct xdp_md *ctx,
                                                  void *data,
                                                  void *data_end,
                                                  struct ethhdr *eth,
                                                  struct iphdr *ip,
                                                  struct udphdr *udp,
                                                  struct dns_hdr *dns,
                                                  __u32 ip_header_len,
                                                  __u8 is_response,
                                                  __u64 now)
{
    struct dns_cache_key cache_key = {};
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

    if (is_response)
        return XDP_PASS;
    if (bpf_ntohs(dns->qdcount) != 1)
        return XDP_PASS;
    if (bpf_ntohs(dns->ancount) != 0 || bpf_ntohs(dns->nscount) != 0 ||
        bpf_ntohs(dns->arcount) != 0)
        return XDP_PASS;
    if (ip_header_len != sizeof(*ip))
        return XDP_PASS;

    if (parse_dns_question(data, data_end, dns, &cache_key,
                           &question_end_offset) < 0)
        return XDP_PASS;
    if (cache_key.qtype != DNS_QTYPE_A || cache_key.qclass != DNS_QCLASS_IN)
        return XDP_PASS;

    cache_value = bpf_map_lookup_elem(&dns_cache, &cache_key);
    if (!cache_value) {
        increment_cache_stat(DNS_CACHE_STAT_MISS);
        return XDP_PASS;
    }

    if (cache_value->expires_ns && now > cache_value->expires_ns) {
        bpf_map_delete_elem(&dns_cache, &cache_key);
        increment_cache_stat(DNS_CACHE_STAT_EXPIRED);
        return XDP_PASS;
    }

    increment_cache_stat(DNS_CACHE_STAT_HIT);
    answer_ipv4 = cache_value->answer_ipv4;
    answer_ttl = cache_value->ttl;

    old_ip_len = bpf_ntohs(ip->tot_len);
    old_udp_len = bpf_ntohs(udp->len);
    logical_packet_end_offset =
        (__u32)((long)ip - (long)data) + old_ip_len;
    if (question_end_offset != logical_packet_end_offset)
        return XDP_PASS;

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

    if (write_dns_a_answer(data, data_end, answer_offset, answer_ttl,
                           answer_ipv4) < 0)
        return XDP_ABORTED;

    swap_eth_addrs(eth);

    __be32 tmp_ip = ip->saddr;
    ip->saddr = ip->daddr;
    ip->daddr = tmp_ip;
    ip->tot_len = bpf_htons(new_ip_len);
    ip->check = 0;
    ip->check = ipv4_header_checksum(ip);

    __be16 tmp_port = udp->source;
    udp->source = udp->dest;
    udp->dest = tmp_port;
    udp->len = bpf_htons(new_udp_len);
    udp->check = 0;

    dns->flags = bpf_htons(DNS_RESPONSE_NOERROR);
    dns->ancount = bpf_htons(1);
    dns->nscount = 0;
    dns->arcount = 0;

    increment_cache_stat(DNS_CACHE_STAT_TX);
    return XDP_TX;
}

SEC("xdp")
int dns_xdp_monitor(struct xdp_md *ctx)
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
    __u8 matched = 0;
    __u8 rcode = 0;
    __u64 now;
    __u64 latency_ns = 0;
    __u64 *start_ns;
    struct dns_flow_key flow_key = {};
    struct dns_event *event;

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

    int cache_action = try_dns_cache_response(ctx, data, data_end, eth, ip, udp,
                                              dns, ip_header_len, is_response,
                                              now);
    if (cache_action != XDP_PASS)
        return cache_action;

    build_dns_flow_key(&flow_key, ip, src_port, dst_port, dns_id, is_response);
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
        return XDP_PASS;
    }

    __builtin_memset(event, 0, sizeof(*event));
    event->timestamp_ns = now;
    event->latency_ns = latency_ns;
    event->direction = DNS_DIR_XDP_INGRESS;
    event->ifindex = ctx->ingress_ifindex;
    event->packet_len = (__u32)((long)data_end - (long)data);
    event->src_ip = ip->saddr;
    event->dst_ip = ip->daddr;
    event->src_port = src_port;
    event->dst_port = dst_port;
    event->dns_id = dns_id;
    event->is_response = is_response;
    event->rcode = rcode;
    event->matched = matched;
    bpf_ringbuf_submit(event, 0);
    return XDP_PASS;
}

char LICENSE[] SEC("license") = "GPL";
