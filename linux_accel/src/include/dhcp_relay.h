#pragma once

#include <linux/types.h>

#define DHCP_RELAY_MAX_POLICY_ENTRIES 4096
#define DHCP_RELAY_MAX_TRANSACTION_ENTRIES 65536

#define DHCP_RELAY_POLICY_ENABLED (1u << 0)
#define DHCP_RELAY_TRANSACTION_TTL_NS 30000000000ull

#define DHCP_RELAY_BOOTP_BROADCAST 0x8000u

enum dhcp_relay_stat_key {
    DHCP_RELAY_STAT_REQUEST = 0,
    DHCP_RELAY_STAT_RESPONSE,
    DHCP_RELAY_STAT_REDIRECT,
    DHCP_RELAY_STAT_POLICY_MISS,
    DHCP_RELAY_STAT_TRANSACTION_MISS,
    DHCP_RELAY_STAT_TRANSACTION_EXPIRED,
    DHCP_RELAY_STAT_TRANSACTION_UPDATE_FAIL,
    DHCP_RELAY_STAT_FORMAT_INVALID,
    DHCP_RELAY_STAT_UNSUPPORTED,
    DHCP_RELAY_STAT_POLICY_EXPIRED,
    DHCP_RELAY_STAT_COUNT,
};

struct dhcp_relay_policy_key {
    __u32 client_ifindex;
};

struct dhcp_relay_policy {
    __u32 relay_ifindex;
    __be32 relay_ipv4;
    __be32 server_ipv4;
    __u8 relay_mac[6];
    __u8 server_mac[6];
    __u32 flags;
    __u32 generation;
    __u64 expires_ns;
};

struct dhcp_relay_transaction_key {
    __u32 relay_ifindex;
    __be32 xid;
    __u8 client_mac[6];
    __u8 reserved[2];
};

struct dhcp_relay_transaction {
    __u32 client_ifindex;
    __be32 relay_ipv4;
    __be32 server_ipv4;
    __u8 relay_mac[6];
    __u8 client_mac[6];
    __u32 generation;
    __u32 reserved0;
    __u64 expires_ns;
};
