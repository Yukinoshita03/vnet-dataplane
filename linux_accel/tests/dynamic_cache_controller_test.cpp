#include "dynamic_cache_controller.hpp"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

class RecordingPublisher final : public CachePolicyPublisher {
public:
    bool publish(CacheMode next_mode, uint64_t next_epoch,
                 std::string *error) override
    {
        calls++;
        if (fail) {
            if (error)
                *error = "injected_publish_failure";
            return false;
        }
        mode = next_mode;
        epoch = next_epoch;
        return true;
    }

    bool fail = false;
    int calls = 0;
    CacheMode mode = CacheMode::Bypass;
    uint64_t epoch = 0;
};

[[noreturn]] void fail(const std::string &message)
{
    std::cerr << "dynamic_cache_controller_test: " << message << "\n";
    std::exit(1);
}

CacheMetricSample sample(uint64_t timestamp_ms, uint64_t hits,
                         uint64_t misses, double p95_us,
                         double backend_qps, double error_rate = 0.0)
{
    CacheMetricSample value;
    value.timestamp_ms = timestamp_ms;
    value.dns_hits = hits;
    value.dns_misses = misses;
    value.dns_p95_us = p95_us;
    value.backend_qps = backend_qps;
    value.error_rate = error_rate;
    return value;
}

DynamicCacheConfig test_config()
{
    DynamicCacheConfig config;
    config.window_size = 2;
    config.required_windows = 2;
    config.cooldown_ms = 1000;
    config.min_window_requests = 100;
    return config;
}

void expect_mode_after_stable_windows()
{
    RecordingPublisher publisher;
    DynamicCacheController controller(test_config(), &publisher);
    controller.observe(sample(100, 70, 30, 1000.0, 100.0));
    DynamicCacheResult pending =
        controller.observe(sample(200, 70, 30, 1000.0, 100.0));
    if (pending.changed)
        fail("changed before candidate stability requirement");
    DynamicCacheResult changed =
        controller.observe(sample(300, 70, 30, 1000.0, 100.0));
    if (!changed.changed || changed.mode != CacheMode::ServerCache ||
        changed.epoch != 1 || publisher.calls != 1)
        fail("did not enter SERVER_CACHE after stable windows");
}

void expect_hysteresis()
{
    RecordingPublisher publisher;
    DynamicCacheConfig config = test_config();
    config.initial_mode = CacheMode::ServerCache;
    DynamicCacheController controller(config, &publisher);
    for (uint64_t timestamp : {100ull, 200ull, 300ull, 400ull})
        controller.observe(sample(timestamp, 25, 75, 1000.0, 100.0));
    if (controller.mode() != CacheMode::ServerCache || publisher.calls != 0)
        fail("hit-ratio hysteresis did not retain SERVER_CACHE");
}

void expect_cooldown()
{
    RecordingPublisher publisher;
    DynamicCacheController controller(test_config(), &publisher);
    controller.observe(sample(100, 70, 30, 1000.0, 100.0));
    controller.observe(sample(200, 70, 30, 1000.0, 100.0));
    controller.observe(sample(300, 70, 30, 1000.0, 100.0));

    controller.observe(sample(400, 90, 10, 1000.0, 3000.0));
    DynamicCacheResult blocked =
        controller.observe(sample(500, 90, 10, 1000.0, 3000.0));
    if (blocked.changed || blocked.reason != "cooldown")
        fail("cooldown did not block a rapid policy change");

    DynamicCacheResult changed =
        controller.observe(sample(1400, 90, 10, 1000.0, 3000.0));
    if (!changed.changed || changed.mode != CacheMode::DualCache ||
        changed.epoch != 2)
        fail("DUAL_CACHE did not publish after cooldown");
}

void expect_publish_failure_keeps_epoch()
{
    RecordingPublisher publisher;
    publisher.fail = true;
    DynamicCacheController controller(test_config(), &publisher);
    controller.observe(sample(100, 80, 20, 7000.0, 100.0));
    controller.observe(sample(200, 80, 20, 7000.0, 100.0));
    DynamicCacheResult failed =
        controller.observe(sample(300, 80, 20, 7000.0, 100.0));
    if (!failed.publish_failed || controller.mode() != CacheMode::Bypass ||
        controller.epoch() != 0)
        fail("publish failure changed committed state");

    publisher.fail = false;
    DynamicCacheResult retried =
        controller.observe(sample(400, 80, 20, 7000.0, 100.0));
    if (!retried.changed || retried.mode != CacheMode::ClientCache ||
        retried.epoch != 1)
        fail("failed publication was not retried");
}

void expect_error_rate_forces_bypass()
{
    RecordingPublisher publisher;
    DynamicCacheConfig config = test_config();
    config.initial_mode = CacheMode::DualCache;
    DynamicCacheController controller(config, &publisher);
    controller.observe(sample(100, 90, 10, 1000.0, 2000.0, 0.10));
    controller.observe(sample(200, 90, 10, 1000.0, 2000.0, 0.10));
    DynamicCacheResult changed =
        controller.observe(sample(300, 90, 10, 1000.0, 2000.0, 0.10));
    if (!changed.changed || changed.mode != CacheMode::Bypass)
        fail("high error rate did not force BYPASS");
}

void expect_initial_epoch_is_preserved()
{
    RecordingPublisher publisher;
    DynamicCacheConfig config = test_config();
    config.initial_epoch = 41;
    DynamicCacheController controller(config, &publisher);
    controller.observe(sample(100, 70, 30, 1000.0, 100.0));
    controller.observe(sample(200, 70, 30, 1000.0, 100.0));
    DynamicCacheResult changed =
        controller.observe(sample(300, 70, 30, 1000.0, 100.0));
    if (!changed.changed || changed.epoch != 42 || publisher.epoch != 42)
        fail("initial epoch was not carried into the next publication");
}

void expect_stale_sample_is_ignored()
{
    RecordingPublisher publisher;
    DynamicCacheController controller(test_config(), &publisher);
    controller.observe(sample(200, 70, 30, 1000.0, 100.0));
    DynamicCacheResult stale =
        controller.observe(sample(100, 70, 30, 1000.0, 100.0));
    if (stale.window_ready || stale.changed ||
        stale.reason != "stale_timestamp" || publisher.calls != 0)
        fail("stale metrics sample affected controller state");
}

} // namespace

int main()
{
    expect_mode_after_stable_windows();
    expect_hysteresis();
    expect_cooldown();
    expect_publish_failure_keeps_epoch();
    expect_error_rate_forces_bypass();
    expect_initial_epoch_is_preserved();
    expect_stale_sample_is_ignored();
    std::cout << "dynamic_cache_controller_test: PASS\n";
    return 0;
}
