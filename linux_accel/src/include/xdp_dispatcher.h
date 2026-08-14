#ifndef YUKINONET_XDP_DISPATCHER_ABI_H
#define YUKINONET_XDP_DISPATCHER_ABI_H

#include <linux/types.h>

/* Keep the slots stable so a dispatcher map can be inspected while running. */
#define XDP_DISPATCH_DNS_SLOT 0u
#define XDP_DISPATCH_UDP_SLOT 1u
#define XDP_DISPATCH_SLOT_COUNT 2u
#define XDP_DISPATCH_SLOT_DISABLED ((__u32)-1)

enum xdp_dispatch_role {
    XDP_DISPATCH_ROLE_SERVER = 1,
    XDP_DISPATCH_ROLE_CLIENT = 2,
};

struct xdp_dispatch_config {
    __u32 dns_slot;
    __u32 udp_slot;
    __u32 role;
    __u32 reserved;
};

#endif
