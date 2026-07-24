#pragma once

#include <linux/types.h>

enum grpc_direction {
    GRPC_DIR_INGRESS = 1,
    GRPC_DIR_EGRESS = 2,
};

enum grpc_event_flags {
    GRPC_FLAG_H2_PREFACE = 1 << 0,
    GRPC_FLAG_H2_HEADERS = 1 << 1,
};

struct grpc_config {
    __u16 port;
    __u16 _pad[3];
};

struct grpc_policy_key {
    __u64 method_hash;
};

struct grpc_policy_value {
    __u32 ttl;
    __u8 idempotent;
    __u8 _pad[3];
};

struct grpc_response_cache_key {
    __u64 method_hash;
    __u64 payload_hash;
};

enum grpc_response_status {
    GRPC_RESPONSE_SERVING = 1,
    GRPC_RESPONSE_NOT_SERVING = 2,
};

struct grpc_response_cache_value {
    __u32 status;
    __u32 _pad;
    __u64 expires_ns;
};

struct grpc_flow_key {
    __u32 client_ip;
    __u32 server_ip;
    __u16 client_port;
    __u16 server_port;
};

struct grpc_event {
    __u64 timestamp_ns;
    __u64 latency_ns;
    __u32 direction;
    __u32 ifindex;
    __u32 packet_len;
    __u32 payload_len;
    __u32 src_ip;
    __u32 dst_ip;
    __u16 src_port;
    __u16 dst_port;
    __u8 is_response;
    __u8 matched;
    __u8 flags;
    __u8 _pad;
};

