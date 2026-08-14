#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/udp.h>

#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

#include "udp_fastpath.h"

#define IP_FRAGMENT_MASK 0x3fff

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, UDP_FASTPATH_MAX_ENTRIES);
    __type(key, struct udp_fastpath_key);
    __type(value, struct udp_fastpath_value);
} udp_fastpath_entries SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, UDP_FASTPATH_STAT_COUNT);
    __type(key, __u32);
    __type(value, __u64);
} udp_fastpath_stats SEC(".maps");

static __always_inline void udp_fastpath_stat_inc(__u32 key)
{
    __u64 *value = bpf_map_lookup_elem(&udp_fastpath_stats, &key);

    if (value)
        *value += 1;
}

static __always_inline void udp_fastpath_swap_mac(struct ethhdr *eth)
{
    __u8 source[ETH_ALEN];

    __builtin_memcpy(source, eth->h_source, sizeof(source));
    __builtin_memcpy(eth->h_source, eth->h_dest, ETH_ALEN);
    __builtin_memcpy(eth->h_dest, source, ETH_ALEN);
}

static __always_inline __u16 udp_fastpath_ipv4_checksum(struct iphdr *ip)
{
    __u32 sum = 0;
    __u16 *words = (__u16 *)ip;

#pragma unroll
    for (int i = 0; i < (int)(sizeof(*ip) / sizeof(__u16)); i++)
        sum += words[i];

    sum = (sum & 0xffff) + (sum >> 16);
    sum = (sum & 0xffff) + (sum >> 16);
    return (__u16)~sum;
}

SEC("xdp")
int udp_fastpath_xdp(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;
    struct ethhdr *eth = data;
    struct iphdr *ip;
    struct udphdr *udp;
    struct udp_fastpath_key key = {};
    struct udp_fastpath_value *entry;
    __u8 *payload;
    __u32 ip_len;
    __u32 udp_len;
    __u32 request_len;
    __u32 response_len;
    __u32 target_frame_len;
    __u32 frame_len;
    __u64 now;
    int tail_delta;

    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;
    if (bpf_ntohs(eth->h_proto) != ETH_P_IP)
        return XDP_PASS;

    ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end) {
        udp_fastpath_stat_inc(UDP_FASTPATH_STAT_MALFORMED);
        return XDP_PASS;
    }
    if (ip->version != 4 || ip->protocol != IPPROTO_UDP)
        return XDP_PASS;
    if (ip->ihl != sizeof(*ip) / 4 ||
        (bpf_ntohs(ip->frag_off) & IP_FRAGMENT_MASK)) {
        udp_fastpath_stat_inc(UDP_FASTPATH_STAT_UNSUPPORTED);
        return XDP_PASS;
    }

    udp = (void *)(ip + 1);
    if ((void *)(udp + 1) > data_end) {
        udp_fastpath_stat_inc(UDP_FASTPATH_STAT_MALFORMED);
        return XDP_PASS;
    }
    ip_len = bpf_ntohs(ip->tot_len);
    if (ip_len < sizeof(*ip) + sizeof(*udp) ||
        (void *)ip + ip_len > data_end) {
        udp_fastpath_stat_inc(UDP_FASTPATH_STAT_MALFORMED);
        return XDP_PASS;
    }
    udp_len = bpf_ntohs(udp->len);
    if (udp_len < sizeof(*udp) || udp_len != ip_len - sizeof(*ip)) {
        udp_fastpath_stat_inc(UDP_FASTPATH_STAT_MALFORMED);
        return XDP_PASS;
    }

    request_len = udp_len - sizeof(*udp);
    if (request_len > UDP_FASTPATH_MAX_REQUEST) {
        udp_fastpath_stat_inc(UDP_FASTPATH_STAT_UNSUPPORTED);
        return XDP_PASS;
    }
    payload = (void *)(udp + 1);
    if ((void *)payload + request_len > data_end) {
        udp_fastpath_stat_inc(UDP_FASTPATH_STAT_MALFORMED);
        return XDP_PASS;
    }

    udp_fastpath_stat_inc(UDP_FASTPATH_STAT_REQUEST);
    key.ifindex = ctx->ingress_ifindex;
    key.server_ipv4 = ip->daddr;
    key.server_port = udp->dest;
    key.request_len = (__u16)request_len;
#pragma unroll
    for (int i = 0; i < UDP_FASTPATH_MAX_REQUEST; i++) {
        if ((__u32)i < request_len) {
            if ((void *)(payload + i + 1) > data_end)
                return XDP_PASS;
            key.request[i] = payload[i];
        }
    }

    entry = bpf_map_lookup_elem(&udp_fastpath_entries, &key);
    if (!entry || !(entry->flags & UDP_FASTPATH_ENTRY_ENABLED)) {
        udp_fastpath_stat_inc(UDP_FASTPATH_STAT_MISS);
        return XDP_PASS;
    }

    now = bpf_ktime_get_ns();
    if (!entry->expires_ns || now >= entry->expires_ns) {
        bpf_map_delete_elem(&udp_fastpath_entries, &key);
        udp_fastpath_stat_inc(UDP_FASTPATH_STAT_EXPIRED);
        return XDP_PASS;
    }

    response_len = entry->response_len;
    if (response_len > UDP_FASTPATH_MAX_RESPONSE) {
        udp_fastpath_stat_inc(UDP_FASTPATH_STAT_UNSUPPORTED);
        return XDP_PASS;
    }
    frame_len = (__u32)((long)data_end - (long)data);
    target_frame_len = sizeof(*eth) + sizeof(*ip) + sizeof(*udp) + response_len;
    tail_delta = (int)target_frame_len - (int)frame_len;
    if (tail_delta && bpf_xdp_adjust_tail(ctx, tail_delta) < 0) {
        udp_fastpath_stat_inc(UDP_FASTPATH_STAT_ADJUST_FAIL);
        return XDP_ABORTED;
    }

    data = (void *)(long)ctx->data;
    data_end = (void *)(long)ctx->data_end;
    eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_ABORTED;
    ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_ABORTED;
    udp = (void *)(ip + 1);
    if ((void *)(udp + 1) > data_end)
        return XDP_ABORTED;
    payload = (void *)(udp + 1);
    if ((void *)payload + response_len > data_end)
        return XDP_ABORTED;

#pragma unroll
    for (int i = 0; i < UDP_FASTPATH_MAX_RESPONSE; i++) {
        if ((__u32)i < response_len) {
            if ((void *)(payload + i + 1) > data_end)
                return XDP_ABORTED;
            payload[i] = entry->response[i];
        }
    }

    udp_fastpath_swap_mac(eth);
    __be32 old_source = ip->saddr;
    ip->saddr = ip->daddr;
    ip->daddr = old_source;
    ip->tot_len = bpf_htons(sizeof(*ip) + sizeof(*udp) + response_len);
    ip->check = 0;
    ip->check = udp_fastpath_ipv4_checksum(ip);

    __be16 old_port = udp->source;
    udp->source = udp->dest;
    udp->dest = old_port;
    udp->len = bpf_htons(sizeof(*udp) + response_len);
    /* A zero UDP checksum is valid for IPv4 and avoids protocol-specific data. */
    udp->check = 0;

    udp_fastpath_stat_inc(UDP_FASTPATH_STAT_HIT);
    udp_fastpath_stat_inc(UDP_FASTPATH_STAT_TX);
    return XDP_TX;
}

char LICENSE[] SEC("license") = "GPL";
