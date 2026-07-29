#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <string>

enum class CacheMode : uint32_t {
    Bypass = 1,
    ServerCache = 2,
    ClientCache = 3,
    DualCache = 4,
};

const char *cache_mode_name(CacheMode mode);
bool parse_cache_mode(const std::string &text, CacheMode *mode);

struct CacheMetricSample {
    uint64_t timestamp_ms = 0;
    uint64_t dns_hits = 0;
    uint64_t dns_misses = 0;
    double dns_p95_us = 0.0;
    uint64_t grpc_hits = 0;
    uint64_t grpc_misses = 0;
    double grpc_p95_us = 0.0;
    double backend_qps = 0.0;
    double error_rate = 0.0;
};

struct DynamicCacheConfig {
    size_t window_size = 5;
    size_t required_windows = 2;
    uint64_t cooldown_ms = 10000;
    uint64_t min_window_requests = 100;
    double cache_enter_hit_ratio = 0.35;
    double cache_exit_hit_ratio = 0.20;
    double client_enter_p95_us = 5000.0;
    double client_exit_p95_us = 3000.0;
    double dual_enter_backend_qps = 1200.0;
    double dual_exit_backend_qps = 800.0;
    double bypass_error_rate = 0.05;
    CacheMode initial_mode = CacheMode::Bypass;
};

class CachePolicyPublisher {
public:
    virtual ~CachePolicyPublisher() = default;
    virtual bool publish(CacheMode mode, uint64_t epoch,
                         std::string *error) = 0;
};

struct DynamicCacheResult {
    CacheMode mode = CacheMode::Bypass;
    CacheMode candidate = CacheMode::Bypass;
    uint64_t epoch = 0;
    bool window_ready = false;
    bool changed = false;
    bool publish_failed = false;
    double hit_ratio = 0.0;
    double p95_us = 0.0;
    double backend_qps = 0.0;
    double error_rate = 0.0;
    std::string reason;
};

class DynamicCacheController {
public:
    DynamicCacheController(DynamicCacheConfig config,
                           CachePolicyPublisher *publisher);

    DynamicCacheResult observe(const CacheMetricSample &sample);
    CacheMode mode() const;
    uint64_t epoch() const;

private:
    struct WindowSummary {
        uint64_t requests = 0;
        double hit_ratio = 0.0;
        double p95_us = 0.0;
        double backend_qps = 0.0;
        double error_rate = 0.0;
    };

    WindowSummary summarize() const;
    CacheMode classify(const WindowSummary &summary,
                       std::string *reason) const;

    DynamicCacheConfig config_;
    CachePolicyPublisher *publisher_ = nullptr;
    std::deque<CacheMetricSample> samples_;
    CacheMode mode_ = CacheMode::Bypass;
    CacheMode candidate_ = CacheMode::Bypass;
    size_t candidate_windows_ = 0;
    uint64_t epoch_ = 0;
    uint64_t last_change_ms_ = 0;
    bool changed_once_ = false;
};
