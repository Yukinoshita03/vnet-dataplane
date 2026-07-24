#pragma once

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

enum class HealthStatus : uint8_t {
    Serving = 1,
    NotServing = 2,
};

struct GrpcCacheKey {
    uint64_t method_hash = 0;
    uint64_t payload_hash = 0;
};

struct GrpcCacheKeyHash {
    size_t operator()(const GrpcCacheKey &key) const
    {
        return static_cast<size_t>(key.method_hash ^
                                   (key.payload_hash + 0x9e3779b97f4a7c15ull +
                                    (key.method_hash << 6) +
                                    (key.method_hash >> 2)));
    }
};

struct GrpcCacheKeyEqual {
    bool operator()(const GrpcCacheKey &lhs, const GrpcCacheKey &rhs) const
    {
        return lhs.method_hash == rhs.method_hash &&
               lhs.payload_hash == rhs.payload_hash;
    }
};

struct CacheEntry {
    HealthStatus status = HealthStatus::Serving;
};

using ResponseCache =
    std::unordered_map<GrpcCacheKey, CacheEntry, GrpcCacheKeyHash,
                       GrpcCacheKeyEqual>;

struct Options {
    std::string listen_host = "0.0.0.0";
    int listen_port = 50051;
    std::string backend_host;
    int backend_port = 0;
    std::string grpc_map_path;
    std::string grpc_response_map_path;
    std::string cache_file;
    std::string method = "/grpc.health.v1.Health/Check";
    std::vector<std::string> cache_entries;
    bool verbose = false;
};

struct CacheStats {
    uint64_t accepted = 0;
    uint64_t policy_miss = 0;
    uint64_t parse_error = 0;
    uint64_t cache_hit = 0;
    uint64_t serving_cache_hit = 0;
    uint64_t not_serving_cache_hit = 0;
    uint64_t response_cache_miss = 0;
    uint64_t fallback = 0;
    uint64_t fallback_error = 0;
    uint64_t tx_error = 0;
};

struct RequestInfo {
    uint32_t stream_id = 1;
    std::string method;
    uint64_t payload_hash = 1469598103934665603ull;
    bool saw_headers = false;
    bool saw_data = false;
};
