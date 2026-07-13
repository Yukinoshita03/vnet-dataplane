#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <string>
#include <unordered_map>
#include <vector>

#include "dns_event.h"
#include "dns_cache_config.hpp"

constexpr int kRcodeCount = 16;
constexpr int kHistoryWindows = 10;
constexpr int kTrafficSpikeMinPackets = 50;
constexpr double kLatencySpikeMinP95Ms = 20.0;

struct FlowKeyHash {
    size_t operator()(const dns_flow_key &key) const
    {
        size_t h = 1469598103934665603ull;
        auto mix = [&h](auto value) {
            using Value = decltype(value);
            const auto *bytes = reinterpret_cast<const unsigned char *>(&value);
            for (size_t i = 0; i < sizeof(Value); ++i) {
                h ^= bytes[i];
                h *= 1099511628211ull;
            }
        };

        mix(key.client_ip);
        mix(key.server_ip);
        mix(key.client_port);
        mix(key.server_port);
        mix(key.dns_id);
        return h;
    }
};

struct FlowKeyEqual {
    bool operator()(const dns_flow_key &lhs, const dns_flow_key &rhs) const
    {
        return lhs.client_ip == rhs.client_ip &&
               lhs.server_ip == rhs.server_ip &&
               lhs.client_port == rhs.client_port &&
               lhs.server_port == rhs.server_port &&
               lhs.dns_id == rhs.dns_id;
    }
};

struct Options {
    // Command-line config. hook=tc stays the default baseline.
    std::string ifname;
    std::string bpf_object;
    std::string hook = "tc";
    std::string role = "server";
    std::string xdp_mode = "native";
    std::string cache_domain;
    std::string cache_ip;
    std::string cache_file;
    std::vector<std::string> trusted_dns;
    int cache_ttl = 60;
    int max_learn_ttl = 300;
    int learn_window_ms = 2000;
    int timeout_ms = 2000;
    bool verbose_events = false;
    double qps_spike_factor = 3.0;
    double latency_spike_factor = 3.0;
};

struct WindowMetrics {
    // Metrics for the current reporting window. print_metrics resets it.
    uint64_t query_count = 0;
    uint64_t response_count = 0;
    uint64_t timeout_count = 0;
    uint64_t unmatched_response_count = 0;
    uint64_t ringbuf_drop_delta = 0;
    std::array<uint64_t, kRcodeCount> rcode = {};
    std::vector<uint64_t> latency_samples_ns;
};

struct HistoryWindow {
    uint64_t packet_count = 0;
    double p95_ms = 0.0;
};

struct ReaderState {
    // State shared by ringbuf callbacks and the once-per-second reporter.
    Options *options = nullptr;
    WindowMetrics current;
    std::unordered_map<dns_flow_key, uint64_t, FlowKeyHash, FlowKeyEqual> pending;
    std::deque<HistoryWindow> history;
    uint64_t last_drop_total = 0;
    uint64_t last_cache_hits = 0;
    uint64_t last_cache_misses = 0;
    uint64_t last_cache_expired = 0;
    uint64_t last_cache_tx = 0;
    uint64_t last_cache_learned = 0;
    uint64_t last_cache_learn_rejected = 0;
    uint64_t last_cache_pending_expired = 0;
    int dropped_events_fd = -1;
    int cache_stats_fd = -1;
};

void print_usage(const char *program);
bool parse_options(int argc, char **argv, Options *options);

const char *direction_name(__u32 direction);
const char *rcode_name(int rcode);
std::string ipv4_to_string(__u32 addr);
dns_flow_key build_user_flow_key(const dns_event *event);
void print_verbose_event(const dns_event *event);

int handle_dns_event(void *ctx, void *data, size_t data_sz);

double ns_to_ms(uint64_t ns);
double percentile_ms(std::vector<uint64_t> samples, double percentile);
double average_ms(const std::vector<uint64_t> &samples);
double average_history_packets(const std::deque<HistoryWindow> &history);
double average_history_p95(const std::deque<HistoryWindow> &history);
void collect_timeouts(ReaderState *state);
uint64_t read_dropped_events_total(int map_fd);
uint64_t read_percpu_counter_total(int map_fd, __u32 key);
std::string build_alerts(const WindowMetrics &metrics,
                         const std::deque<HistoryWindow> &history,
                         double qps_spike_factor,
                         double latency_spike_factor,
                         double p95_ms);
void print_metrics(ReaderState *state);
