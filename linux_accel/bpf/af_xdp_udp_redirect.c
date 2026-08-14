#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/udp.h>

#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

#define AF_XDP_UDP_PORT 9000
#define AF_XDP_REQUEST_LEN 4

struct {
    __uint(type, BPF_MAP_TYPE_XSKMAP);
    __uint(max_entries, 64);
    __type(key, __u32);
    __type(value, __u32);
} af_xdp_sockets SEC(".maps");

enum af_xdp_redirect_stat {
    AF_XDP_REDIRECT_REQUEST = 0,
    AF_XDP_REDIRECT_MATCH,
    AF_XDP_REDIRECT_SUCCESS,
    AF_XDP_REDIRECT_FALLBACK,
    AF_XDP_REDIRECT_STAT_COUNT,
};

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, AF_XDP_REDIRECT_STAT_COUNT);
    __type(key, __u32);
    __type(value, __u64);
} af_xdp_redirect_stats SEC(".maps");

static __always_inline void stat_inc(__u32 key)
{
    __u64 *value = bpf_map_lookup_elem(&af_xdp_redirect_stats, &key);

    if (value)
        *value += 1;
}

SEC("xdp")
int af_xdp_udp_redirect(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;
    struct ethhdr *eth = data;
    struct iphdr *ip;
    struct udphdr *udp;
    __u8 *payload;
    __u32 udp_len;
    int action;

    if ((void *)(eth + 1) > data_end ||
        bpf_ntohs(eth->h_proto) != ETH_P_IP)
        return XDP_PASS;
    ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end || ip->version != 4 ||
        ip->ihl != sizeof(*ip) / 4 || ip->protocol != IPPROTO_UDP ||
        (bpf_ntohs(ip->frag_off) & 0x3fff))
        return XDP_PASS;
    udp = (void *)(ip + 1);
    if ((void *)(udp + 1) > data_end ||
        udp->dest != bpf_htons(AF_XDP_UDP_PORT))
        return XDP_PASS;
    udp_len = bpf_ntohs(udp->len);
    if (udp_len != sizeof(*udp) + AF_XDP_REQUEST_LEN)
        return XDP_PASS;
    payload = (void *)(udp + 1);
    if ((void *)(payload + AF_XDP_REQUEST_LEN) > data_end)
        return XDP_PASS;

    stat_inc(AF_XDP_REDIRECT_REQUEST);
    if (payload[0] != 'p' || payload[1] != 'i' ||
        payload[2] != 'n' || payload[3] != 'g')
        return XDP_PASS;

    stat_inc(AF_XDP_REDIRECT_MATCH);
    action = bpf_redirect_map(&af_xdp_sockets, ctx->rx_queue_index, XDP_PASS);
    if (action == XDP_REDIRECT)
        stat_inc(AF_XDP_REDIRECT_SUCCESS);
    else
        stat_inc(AF_XDP_REDIRECT_FALLBACK);
    return action;
}

char LICENSE[] SEC("license") = "GPL";
