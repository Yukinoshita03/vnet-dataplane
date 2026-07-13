#pragma once

#include <linux/types.h>

#define DNS_CACHE_QNAME_MAX 256
#define DNS_XDP_QNAME_SCAN_MAX 64
#define DNS_CLIENT_QNAME_MAX DNS_XDP_QNAME_SCAN_MAX

enum dns_direction {
    DNS_DIR_INGRESS = 1,
    DNS_DIR_EGRESS = 2,
    DNS_DIR_XDP_INGRESS = 3,
    DNS_DIR_CLIENT_XDP_INGRESS = 4,
    DNS_DIR_CLIENT_TC_EGRESS = 5,
};

enum dns_cache_stat_key {
    DNS_CACHE_STAT_HIT = 0,
    DNS_CACHE_STAT_MISS = 1,
    DNS_CACHE_STAT_EXPIRED = 2,
    DNS_CACHE_STAT_TX = 3,
    DNS_CACHE_STAT_LEARNED = 4,
    DNS_CACHE_STAT_LEARN_REJECTED = 5,
    DNS_CACHE_STAT_PENDING_EXPIRED = 6,
    DNS_CACHE_STAT_COUNT = 7,
};

struct dns_flow_key {
    __u32 client_ip;
    __u32 server_ip;
    __u16 client_port;
    __u16 server_port;
    __u16 dns_id;
    __u16 _pad;
};

struct dns_event {
    __u64 timestamp_ns;
    __u64 latency_ns;
    __u32 direction;
    __u32 ifindex;
    __u32 packet_len;
    __u32 src_ip;
    __u32 dst_ip;
    __u16 src_port;
    __u16 dst_port;
    __u16 dns_id;
    __u8 is_response;
    __u8 rcode;
    __u8 matched;
    __u8 _pad[3];
};

struct dns_cache_key {
    __u8 qname[DNS_CACHE_QNAME_MAX];
    __u16 qtype;
    __u16 qclass;
};

struct dns_cache_value {
    __u32 answer_ipv4;
    __u32 ttl;
    __u64 expires_ns;
};

struct dns_client_cache_key {
    __u32 resolver_ipv4;
    __u8 qname[DNS_CLIENT_QNAME_MAX];
    __u16 qtype;
    __u16 qclass;
};

struct dns_client_pending_value {
    struct dns_client_cache_key cache_key;
    __u64 started_ns;
};

struct dns_client_config {
    __u64 learn_window_ns;
    __u32 max_ttl;
    __u32 _pad;
};
