#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/udp.h>

#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

#include "xdp_dispatcher.h"

#define XDP_DISPATCH_IP_FRAGMENT_MASK 0x3fff
#define XDP_DISPATCH_DNS_PORT 53

struct {
    __uint(type, BPF_MAP_TYPE_PROG_ARRAY);
    __uint(max_entries, XDP_DISPATCH_SLOT_COUNT);
    __type(key, __u32);
    __type(value, __u32);
} xdp_dispatch_progs SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct xdp_dispatch_config);
} xdp_dispatch_config SEC(".maps");

static __always_inline int dispatch_tail(struct xdp_md *ctx, __u32 slot)
{
    if (slot != XDP_DISPATCH_SLOT_DISABLED)
        bpf_tail_call(ctx, &xdp_dispatch_progs, slot);
    return XDP_PASS;
}

SEC("xdp")
int xdp_dispatcher(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;
    struct ethhdr *eth = data;
    struct iphdr *ip;
    struct udphdr *udp;
    struct xdp_dispatch_config *config;
    __u32 config_key = 0;
    __u32 ip_header_len;
    __u16 source_port;
    __u16 destination_port;

    config = bpf_map_lookup_elem(&xdp_dispatch_config, &config_key);
    if (!config)
        return XDP_PASS;

    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (bpf_ntohs(eth->h_proto) == ETH_P_ARP)
        return dispatch_tail(ctx, config->dns_slot);
    if (bpf_ntohs(eth->h_proto) != ETH_P_IP)
        return XDP_PASS;

    ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end || ip->version != 4 ||
        ip->protocol != IPPROTO_UDP)
        return XDP_PASS;
    if (bpf_ntohs(ip->frag_off) & XDP_DISPATCH_IP_FRAGMENT_MASK)
        return XDP_PASS;

    ip_header_len = (__u32)ip->ihl * 4;
    if (ip_header_len < sizeof(*ip) || ip_header_len > 60 ||
        (void *)ip + ip_header_len > data_end)
        return XDP_PASS;

    udp = (void *)ip + ip_header_len;
    if ((void *)(udp + 1) > data_end)
        return XDP_PASS;

    source_port = bpf_ntohs(udp->source);
    destination_port = bpf_ntohs(udp->dest);

    if (source_port == XDP_DISPATCH_DNS_PORT ||
        destination_port == XDP_DISPATCH_DNS_PORT)
        return dispatch_tail(ctx, config->dns_slot);

    if (source_port == 67 || source_port == 68 || destination_port == 67 ||
        destination_port == 68) {
        if (config->role == XDP_DISPATCH_ROLE_SERVER)
            return dispatch_tail(ctx, config->dns_slot);
        return XDP_PASS;
    }

    return dispatch_tail(ctx, config->udp_slot);
}

char LICENSE[] SEC("license") = "GPL";
