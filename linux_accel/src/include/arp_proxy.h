#ifndef YUKINONET_ARP_PROXY_ABI_H
#define YUKINONET_ARP_PROXY_ABI_H

#include <linux/types.h>

#define ARP_TAP_MAX_ENTRIES 4096
#define ARP_BINDING_MAX_ENTRIES 65536

#define ARP_TAP_ENABLED (1u << 0)
#define ARP_BINDING_ENABLED (1u << 0)

enum arp_proxy_stat_key {
    ARP_PROXY_STAT_REQUEST = 0,
    ARP_PROXY_STAT_TX,
    ARP_PROXY_STAT_TAP_MISS,
    ARP_PROXY_STAT_BINDING_MISS,
    ARP_PROXY_STAT_WRONG_GENERATION,
    ARP_PROXY_STAT_EXPIRED,
    ARP_PROXY_STAT_SOURCE_INVALID,
    ARP_PROXY_STAT_FORMAT_INVALID,
    ARP_PROXY_STAT_BINDING_INVALID,
    ARP_PROXY_STAT_COUNT,
};

struct arp_tap_key {
    __u32 ifindex;
};

struct arp_tap_state {
    __u32 generation;
    __u32 flags;
    __u64 expires_ns;
};

struct arp_binding_key {
    __u32 ifindex;
    __be32 target_ipv4;
};

struct arp_binding_value {
    __u8 target_mac[6];
    __u8 reserved0[2];
    __u32 flags;
    __u32 generation;
    __u64 expires_ns;
};

#endif
