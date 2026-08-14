#ifndef YUKINONET_ARP_PROXY_H
#define YUKINONET_ARP_PROXY_H

#include <linux/bpf.h>
#include <linux/if_ether.h>

#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

#include <arp_proxy.h>

/* Keep the BPF translation unit independent of the userspace if_arp.h
 * include chain (which pulls glibc headers into the BPF target). These are
 * the stable ARP protocol values used by the kernel ABI. */
enum {
    YUKINONET_ARPHRD_ETHER = 1,
    YUKINONET_ARPOP_REQUEST = 1,
    YUKINONET_ARPOP_REPLY = 2,
};

/* ARP for Ethernet + IPv4 is always 28 bytes after the Ethernet header. */
struct arp_ipv4_eth {
    __be16 hardware_type;
    __be16 protocol_type;
    __u8 hardware_length;
    __u8 protocol_length;
    __be16 operation;
    __u8 sender_hardware[ETH_ALEN];
    __be32 sender_ipv4;
    __u8 target_hardware[ETH_ALEN];
    __be32 target_ipv4;
} __attribute__((packed));

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, ARP_TAP_MAX_ENTRIES);
    __type(key, struct arp_tap_key);
    __type(value, struct arp_tap_state);
} arp_tap_states SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, ARP_BINDING_MAX_ENTRIES);
    __type(key, struct arp_binding_key);
    __type(value, struct arp_binding_value);
} arp_bindings SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, ARP_PROXY_STAT_COUNT);
    __type(key, __u32);
    __type(value, __u64);
} arp_proxy_stats SEC(".maps");

static __always_inline void arp_proxy_stat_inc(__u32 key)
{
    __u64 *value = bpf_map_lookup_elem(&arp_proxy_stats, &key);

    if (value)
        *value += 1;
}

static __always_inline int arp_proxy_mac_is_zero_or_multicast(
    const __u8 *mac)
{
    __u8 all_zero = 1;

#pragma unroll
    for (int i = 0; i < ETH_ALEN; i++) {
        if (mac[i] != 0)
            all_zero = 0;
    }

    return all_zero || (mac[0] & 1);
}

static __always_inline int arp_proxy_mac_is_broadcast(const __u8 *mac)
{
    __u8 all_broadcast = 1;

#pragma unroll
    for (int i = 0; i < ETH_ALEN; i++) {
        if (mac[i] != 0xff)
            all_broadcast = 0;
    }

    return all_broadcast;
}

static __always_inline int arp_proxy_mac_equal(const __u8 *left,
                                               const __u8 *right)
{
#pragma unroll
    for (int i = 0; i < ETH_ALEN; i++) {
        if (left[i] != right[i])
            return 0;
    }

    return 1;
}

static __always_inline int arp_proxy_handle(struct xdp_md *ctx, void *data,
                                            void *data_end)
{
    struct ethhdr *eth = data;
    struct arp_ipv4_eth *arp;
    struct arp_tap_key tap_key = {};
    struct arp_tap_state *tap_state;
    struct arp_binding_key binding_key = {};
    struct arp_binding_value *binding;
    __u64 now;
    __u8 request_source[ETH_ALEN] = {};
    __be32 request_sender_ipv4;

    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;
    if (bpf_ntohs(eth->h_proto) != ETH_P_ARP)
        return XDP_PASS;

    arp = (void *)(eth + 1);
    if ((void *)(arp + 1) > data_end) {
        arp_proxy_stat_inc(ARP_PROXY_STAT_FORMAT_INVALID);
        return XDP_PASS;
    }

    if (arp->hardware_type != bpf_htons(YUKINONET_ARPHRD_ETHER) ||
        arp->protocol_type != bpf_htons(ETH_P_IP) ||
        arp->hardware_length != ETH_ALEN || arp->protocol_length != 4 ||
        arp->operation != bpf_htons(YUKINONET_ARPOP_REQUEST) ||
        !arp_proxy_mac_is_broadcast(eth->h_dest)) {
        arp_proxy_stat_inc(ARP_PROXY_STAT_FORMAT_INVALID);
        return XDP_PASS;
    }

    if (!arp_proxy_mac_equal(eth->h_source, arp->sender_hardware) ||
        arp_proxy_mac_is_zero_or_multicast(arp->sender_hardware) ||
        arp->sender_ipv4 == 0 || arp->sender_ipv4 == arp->target_ipv4) {
        arp_proxy_stat_inc(ARP_PROXY_STAT_SOURCE_INVALID);
        return XDP_PASS;
    }

    arp_proxy_stat_inc(ARP_PROXY_STAT_REQUEST);

    tap_key.ifindex = ctx->ingress_ifindex;
    tap_state = bpf_map_lookup_elem(&arp_tap_states, &tap_key);
    if (!tap_state || !(tap_state->flags & ARP_TAP_ENABLED)) {
        arp_proxy_stat_inc(ARP_PROXY_STAT_TAP_MISS);
        return XDP_PASS;
    }

    now = bpf_ktime_get_ns();
    if (!tap_state->expires_ns || now >= tap_state->expires_ns) {
        arp_proxy_stat_inc(ARP_PROXY_STAT_EXPIRED);
        return XDP_PASS;
    }

    binding_key.ifindex = ctx->ingress_ifindex;
    binding_key.target_ipv4 = arp->target_ipv4;
    binding = bpf_map_lookup_elem(&arp_bindings, &binding_key);
    if (!binding || !(binding->flags & ARP_BINDING_ENABLED)) {
        arp_proxy_stat_inc(ARP_PROXY_STAT_BINDING_MISS);
        return XDP_PASS;
    }
    if (binding->generation != tap_state->generation) {
        arp_proxy_stat_inc(ARP_PROXY_STAT_WRONG_GENERATION);
        return XDP_PASS;
    }
    if (!binding->expires_ns || now >= binding->expires_ns) {
        arp_proxy_stat_inc(ARP_PROXY_STAT_EXPIRED);
        return XDP_PASS;
    }
    if (arp_proxy_mac_is_zero_or_multicast(binding->target_mac)) {
        arp_proxy_stat_inc(ARP_PROXY_STAT_BINDING_INVALID);
        return XDP_PASS;
    }

    __builtin_memcpy(request_source, eth->h_source, ETH_ALEN);
    request_sender_ipv4 = arp->sender_ipv4;

    __builtin_memcpy(eth->h_dest, request_source, ETH_ALEN);
    __builtin_memcpy(eth->h_source, binding->target_mac, ETH_ALEN);
    arp->operation = bpf_htons(YUKINONET_ARPOP_REPLY);
    __builtin_memcpy(arp->sender_hardware, binding->target_mac, ETH_ALEN);
    arp->sender_ipv4 = arp->target_ipv4;
    __builtin_memcpy(arp->target_hardware, request_source, ETH_ALEN);
    arp->target_ipv4 = request_sender_ipv4;

    arp_proxy_stat_inc(ARP_PROXY_STAT_TX);
    return XDP_TX;
}

#endif
