#include "dynamic_cache_controller.hpp"

#include <algorithm>
#include <cctype>
#include <utility>

namespace {

std::string lowercase(std::string text)
{
    std::transform(text.begin(), text.end(), text.begin(),
                   [](unsigned char ch) { return std::tolower(ch); });
    return text;
}

} // namespace

const char *cache_mode_name(CacheMode mode)
{
    switch (mode) {
    case CacheMode::Bypass:
        return "BYPASS";
    case CacheMode::ServerCache:
        return "SERVER_CACHE";
    case CacheMode::ClientCache:
        return "CLIENT_CACHE";
    case CacheMode::DualCache:
        return "DUAL_CACHE";
    }
    return "BYPASS";
}

bool parse_cache_mode(const std::string &text, CacheMode *mode)
{
    if (!mode)
        return false;

    const std::string value = lowercase(text);
    if (value == "bypass") {
        *mode = CacheMode::Bypass;
        return true;
    }
    if (value == "server" || value == "server_cache" ||
        value == "server-cache") {
        *mode = CacheMode::ServerCache;
        return true;
    }
    if (value == "client" || value == "client_cache" ||
        value == "client-cache") {
        *mode = CacheMode::ClientCache;
        return true;
    }
    if (value == "dual" || value == "dual_cache" ||
        value == "dual-cache" || value == "both") {
        *mode = CacheMode::DualCache;
        return true;
    }
    return false;
}

DynamicCacheController::DynamicCacheController(
    DynamicCacheConfig config, CachePolicyPublisher *publisher)
    : config_(std::move(config)), publisher_(publisher),
      mode_(config_.initial_mode), candidate_(config_.initial_mode),
      epoch_(config_.initial_epoch)
{
    if (config_.window_size == 0)
        config_.window_size = 1;
    if (config_.required_windows == 0)
        config_.required_windows = 1;
}

DynamicCacheController::WindowSummary
DynamicCacheController::summarize() const
{
    WindowSummary summary;
    uint64_t hits = 0;
    uint64_t misses = 0;
    double p95_total = 0.0;

    for (const CacheMetricSample &sample : samples_) {
        hits += sample.dns_hits + sample.grpc_hits;
        misses += sample.dns_misses + sample.grpc_misses;
        p95_total += std::max(sample.dns_p95_us, sample.grpc_p95_us);
        summary.backend_qps += sample.backend_qps;
        summary.error_rate += sample.error_rate;
    }

    summary.requests = hits + misses;
    if (summary.requests)
        summary.hit_ratio =
            static_cast<double>(hits) / static_cast<double>(summary.requests);
    const double count = static_cast<double>(samples_.size());
    if (count > 0.0) {
        summary.p95_us = p95_total / count;
        summary.backend_qps /= count;
        summary.error_rate /= count;
    }
    return summary;
}

CacheMode DynamicCacheController::classify(
    const WindowSummary &summary, std::string *reason) const
{
    if (summary.error_rate >= config_.bypass_error_rate) {
        *reason = "error_rate";
        return CacheMode::Bypass;
    }
    if (summary.requests < config_.min_window_requests) {
        *reason = "insufficient_requests";
        return mode_;
    }

    const double hit_threshold =
        mode_ == CacheMode::Bypass ? config_.cache_enter_hit_ratio
                                   : config_.cache_exit_hit_ratio;
    if (summary.hit_ratio < hit_threshold) {
        *reason = "low_hit_ratio";
        return CacheMode::Bypass;
    }

    const double dual_threshold =
        mode_ == CacheMode::DualCache ? config_.dual_exit_backend_qps
                                      : config_.dual_enter_backend_qps;
    if (summary.backend_qps >= dual_threshold) {
        *reason = "backend_pressure";
        return CacheMode::DualCache;
    }

    const double client_threshold =
        mode_ == CacheMode::ClientCache ? config_.client_exit_p95_us
                                        : config_.client_enter_p95_us;
    if (summary.p95_us >= client_threshold) {
        *reason = "network_latency";
        return CacheMode::ClientCache;
    }

    *reason = "cache_worthwhile";
    return CacheMode::ServerCache;
}

DynamicCacheResult
DynamicCacheController::observe(const CacheMetricSample &sample)
{
    DynamicCacheResult result;
    result.mode = mode_;
    result.candidate = candidate_;
    result.epoch = epoch_;

    if (sample_seen_ && sample.timestamp_ms < last_sample_ms_) {
        result.reason = "stale_timestamp";
        return result;
    }
    last_sample_ms_ = sample.timestamp_ms;
    sample_seen_ = true;

    samples_.push_back(sample);
    while (samples_.size() > config_.window_size)
        samples_.pop_front();
    if (samples_.size() < config_.window_size) {
        result.reason = "warming_window";
        return result;
    }

    result.window_ready = true;
    const WindowSummary summary = summarize();
    result.hit_ratio = summary.hit_ratio;
    result.p95_us = summary.p95_us;
    result.backend_qps = summary.backend_qps;
    result.error_rate = summary.error_rate;

    std::string reason;
    const CacheMode target = classify(summary, &reason);
    result.reason = reason;
    if (target == mode_) {
        candidate_ = mode_;
        candidate_windows_ = 0;
        result.candidate = candidate_;
        return result;
    }

    if (target != candidate_) {
        candidate_ = target;
        candidate_windows_ = 1;
    } else {
        candidate_windows_++;
    }
    result.candidate = candidate_;
    if (candidate_windows_ < config_.required_windows) {
        result.reason += "_pending";
        return result;
    }

    if (changed_once_ &&
        sample.timestamp_ms - last_change_ms_ < config_.cooldown_ms) {
        result.reason = "cooldown";
        return result;
    }

    const uint64_t next_epoch = epoch_ + 1;
    std::string error;
    if (!publisher_ || !publisher_->publish(target, next_epoch, &error)) {
        result.publish_failed = true;
        result.reason = error.empty() ? "publish_failed" : error;
        return result;
    }

    mode_ = target;
    candidate_ = target;
    candidate_windows_ = 0;
    epoch_ = next_epoch;
    last_change_ms_ = sample.timestamp_ms;
    changed_once_ = true;
    result.mode = mode_;
    result.candidate = candidate_;
    result.epoch = epoch_;
    result.changed = true;
    return result;
}

CacheMode DynamicCacheController::mode() const
{
    return mode_;
}

uint64_t DynamicCacheController::epoch() const
{
    return epoch_;
}
