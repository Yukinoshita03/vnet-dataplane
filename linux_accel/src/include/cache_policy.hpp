#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "dns_cache_config.hpp"

struct GrpcPolicyEntry {
    std::string method;
    uint64_t method_hash = 0;
    int ttl = 0;
    bool idempotent = false;
};

struct GrpcResponseCacheEntry {
    std::string method;
    uint64_t method_hash = 0;
    std::string payload;
    uint64_t payload_hash = 0;
    std::string status;
    int ttl = 0;
};

struct CachePolicy {
    std::vector<DnsCacheEntry> dns_entries;
    std::vector<GrpcPolicyEntry> grpc_entries;
    std::vector<GrpcResponseCacheEntry> grpc_cache_entries;
};

bool parse_cache_policy_file(const std::string &path,
                             CachePolicy *policy,
                             std::string *error);

uint64_t hash_grpc_method(const std::string &method);
uint64_t hash_grpc_payload(const std::string &payload);

