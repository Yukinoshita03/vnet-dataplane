#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/udp.h>

#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

#include "dns_xdp_cache_helpers.h"

#define NATIVE_XDP_ECHO_PORT 45954

/*
 * Deliberately small driver probe:
 *   - every unrelated packet takes the ordinary XDP_PASS path;
 *   - an IPv4/UDP packet addressed to NATIVE_XDP_ECHO_PORT is reflected
 *     directly by XDP_TX after swapping L2/L3/L4 addresses.
 *
 * It is intentionally independent of dns_monitor and its maps.  A peer can
 * therefore distinguish native-driver plumbing from DNS-cache logic.
 */
SEC("xdp")
int native_xdp_echo_probe(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;
    struct ethhdr *eth = data;
    struct iphdr *ip;
    struct udphdr *udp;
    __be32 tmp_addr;
    __be16 tmp_port;

    if ((void *)(eth + 1) > data_end)
        return XDP_ABORTED;
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return XDP_PASS;

    ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_ABORTED;
    if (ip->version != 4 || ip->ihl != 5 || ip->protocol != IPPROTO_UDP)
        return XDP_PASS;

    udp = (void *)(ip + 1);
    if ((void *)(udp + 1) > data_end)
        return XDP_ABORTED;
    if (udp->dest != bpf_htons(NATIVE_XDP_ECHO_PORT))
        return XDP_PASS;

    dns_swap_eth_addrs(eth);

    tmp_addr = ip->saddr;
    ip->saddr = ip->daddr;
    ip->daddr = tmp_addr;
    ip->check = 0;
    ip->check = dns_ipv4_header_checksum(ip);

    tmp_port = udp->source;
    udp->source = udp->dest;
    udp->dest = tmp_port;
    /* IPv4 permits a zero UDP checksum; this avoids a second checksum pass. */
    udp->check = 0;

    return XDP_TX;
}

char LICENSE[] SEC("license") = "GPL";
