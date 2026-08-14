#ifndef YUKINONET_UDP_FASTPATH_ABI_H
#define YUKINONET_UDP_FASTPATH_ABI_H

#include <linux/types.h>

#ifndef UDP_FASTPATH_MAX_ENTRIES
#define UDP_FASTPATH_MAX_ENTRIES 4096
#endif
#ifndef UDP_FASTPATH_MAX_REQUEST
#define UDP_FASTPATH_MAX_REQUEST 64
#endif
#ifndef UDP_FASTPATH_MAX_RESPONSE
#define UDP_FASTPATH_MAX_RESPONSE 64
#endif

#define UDP_FASTPATH_ENTRY_ENABLED (1u << 0)

enum udp_fastpath_stat_key {
    UDP_FASTPATH_STAT_REQUEST = 0,
    UDP_FASTPATH_STAT_HIT,
    UDP_FASTPATH_STAT_MISS,
    UDP_FASTPATH_STAT_EXPIRED,
    UDP_FASTPATH_STAT_UNSUPPORTED,
    UDP_FASTPATH_STAT_MALFORMED,
    UDP_FASTPATH_STAT_TX,
    UDP_FASTPATH_STAT_ADJUST_FAIL,
    UDP_FASTPATH_STAT_COUNT,
};

/*
 * The ingress ifindex is part of the key so the same BPF object can safely be
 * attached to several OpenStack TAPs without sharing tenant-local entries.
 * Addresses and ports use network byte order; lengths use host byte order.
 */
struct udp_fastpath_key {
    __u32 ifindex;
    __be32 server_ipv4;
    __be16 server_port;
    __u16 request_len;
    __u8 request[UDP_FASTPATH_MAX_REQUEST];
};

struct udp_fastpath_value {
    __u64 expires_ns;
    __u16 response_len;
    __u16 flags;
    __u8 response[UDP_FASTPATH_MAX_RESPONSE];
};

#endif
