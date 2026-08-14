#ifndef LINUX_ACCEL_XDP_ACTION_PROBE_H
#define LINUX_ACCEL_XDP_ACTION_PROBE_H

#include <linux/types.h>

#define XDP_ACTION_PROBE_ETHERTYPE 0x88b5
#define XDP_ACTION_PROBE_MAGIC_LEN 16
#define XDP_ACTION_PROBE_INVALID_ACTION 5
#define XDP_ACTION_PROBE_MAX_SEND_COUNT 16

#define XDP_ACTION_PROBE_MAGIC_INITIALIZER                                \
    {                                                                    \
        0x52, 0x38, 0x31, 0x36, 0x39, 0x58, 0x44, 0x50,                \
        0x5f, 0x41, 0x43, 0x54, 0x49, 0x4f, 0x4e, 0x21                 \
    }

struct xdp_action_probe_config {
    __u8 target_mac[6];
    __u8 armed;
    __u8 reserved;
};

struct xdp_action_probe_payload {
    __u8 magic[XDP_ACTION_PROBE_MAGIC_LEN];
    __be32 sequence;
} __attribute__((packed));

#endif
