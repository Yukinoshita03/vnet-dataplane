#include "dns_monitor.hpp"

#include <algorithm>
#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

const char *direction_name_local(__u32 direction)
{
    switch (direction) {
    case DNS_DIR_INGRESS:
        return "ingress";
    case DNS_DIR_EGRESS:
        return "egress";
    case DNS_DIR_XDP_INGRESS:
        return "xdp-ingress";
    default:
        return "unknown";
    }
}

uint64_t counter_delta(uint64_t total, uint64_t *last)
{
    uint64_t delta = total >= *last ? total - *last : 0;
    *last = total;
    return delta;
}

} // namespace

const char *direction_name(__u32 direction)
{
    return direction_name_local(direction);
}

const char *rcode_name(int rcode)
{
    switch (rcode) {
    case 0:
        return "noerror";
    case 1:
        return "formerr";
    case 2:
        return "servfail";
    case 3:
        return "nxdomain";
    case 4:
        return "notimp";
    case 5:
        return "refused";
    default:
        return nullptr;
    }
}

std::string ipv4_to_string(__u32 addr)
{
    char buf[INET_ADDRSTRLEN] = {};
    if (!inet_ntop(AF_INET, &addr, buf, sizeof(buf)))
        return "<invalid>";
    return std::string(buf);
}

dns_flow_key build_user_flow_key(const dns_event *event)
{
    dns_flow_key key = {};
    key.dns_id = event->dns_id;

    if (event->is_response) {
        key.client_ip = event->dst_ip;
        key.server_ip = event->src_ip;
        key.client_port = event->dst_port;
        key.server_port = event->src_port;
    } else {
        key.client_ip = event->src_ip;
        key.server_ip = event->dst_ip;
        key.client_port = event->src_port;
        key.server_port = event->dst_port;
    }

    return key;
}

void print_verbose_event(const dns_event *event)
{
    std::cout << "[" << direction_name(event->direction) << "] "
              << ipv4_to_string(event->src_ip) << ":" << event->src_port
              << " -> "
              << ipv4_to_string(event->dst_ip) << ":" << event->dst_port
              << " id=" << event->dns_id << " "
              << (event->is_response ? "response" : "query")
              << " rcode=" << static_cast<int>(event->rcode)
              << " matched=" << static_cast<int>(event->matched)
              << " latency_ms="
              << std::fixed << std::setprecision(3)
              << static_cast<double>(event->latency_ns) / 1000000.0
              << " len=" << event->packet_len
              << " ifindex=" << event->ifindex
              << " ts=" << event->timestamp_ns << "\n";
}

int handle_dns_event(void *ctx, void *data, size_t data_sz)
{
    auto *state = static_cast<ReaderState *>(ctx);
    if (data_sz < sizeof(dns_event))
        return 0;

    const auto *event = static_cast<const dns_event *>(data);
    dns_flow_key key = build_user_flow_key(event);

    if (event->is_response) {
        state->current.response_count++;
        if (event->rcode < kRcodeCount)
            state->current.rcode[event->rcode]++;
        if (event->matched && event->latency_ns > 0)
            state->current.latency_samples_ns.push_back(event->latency_ns);
        else
            state->current.unmatched_response_count++;
        state->pending.erase(key);
    } else {
        state->current.query_count++;
        state->pending[key] = monotonic_now_ns();
    }

    if (state->options->verbose_events)
        print_verbose_event(event);

    return 0;
}

double ns_to_ms(uint64_t ns)
{
    return static_cast<double>(ns) / 1000000.0;
}

double percentile_ms(std::vector<uint64_t> samples, double percentile)
{
    if (samples.empty())
        return 0.0;

    std::sort(samples.begin(), samples.end());
    size_t index = static_cast<size_t>((percentile / 100.0) *
                                       static_cast<double>(samples.size() - 1));
    return ns_to_ms(samples[index]);
}

double average_ms(const std::vector<uint64_t> &samples)
{
    if (samples.empty())
        return 0.0;

    long double total = 0.0;
    for (uint64_t sample : samples)
        total += sample;
    return ns_to_ms(static_cast<uint64_t>(total / static_cast<long double>(samples.size())));
}

double average_history_packets(const std::deque<HistoryWindow> &history)
{
    if (history.empty())
        return 0.0;

    uint64_t total = 0;
    for (const auto &window : history)
        total += window.packet_count;
    return static_cast<double>(total) / static_cast<double>(history.size());
}

double average_history_p95(const std::deque<HistoryWindow> &history)
{
    double total = 0.0;
    int count = 0;
    for (const auto &window : history) {
        if (window.p95_ms > 0.0) {
            total += window.p95_ms;
            count++;
        }
    }
    return count ? total / static_cast<double>(count) : 0.0;
}

void collect_timeouts(ReaderState *state)
{
    uint64_t now_ns = monotonic_now_ns();
    uint64_t timeout_ns =
        static_cast<uint64_t>(state->options->timeout_ms) * 1000000ull;

    for (auto it = state->pending.begin(); it != state->pending.end();) {
        if (now_ns > it->second && now_ns - it->second > timeout_ns) {
            state->current.timeout_count++;
            it = state->pending.erase(it);
        } else {
            ++it;
        }
    }
}

uint64_t read_percpu_counter_total(int map_fd, __u32 key)
{
    if (map_fd < 0)
        return 0;

    int cpu_count = libbpf_num_possible_cpus();
    if (cpu_count <= 0)
        return 0;

    std::vector<__u64> values(cpu_count);
    if (bpf_map_lookup_elem(map_fd, &key, values.data()) != 0)
        return 0;

    uint64_t total = 0;
    for (__u64 value : values)
        total += value;
    return total;
}

uint64_t read_dropped_events_total(int map_fd)
{
    __u32 key = 0;
    return read_percpu_counter_total(map_fd, key);
}

std::string build_alerts(const WindowMetrics &metrics,
                         const std::deque<HistoryWindow> &history,
                         double qps_spike_factor,
                         double latency_spike_factor,
                         double p95_ms)
{
    std::vector<std::string> alerts;
    uint64_t packets = metrics.query_count + metrics.response_count;
    double avg_packets = average_history_packets(history);
    double avg_p95 = average_history_p95(history);

    if (avg_packets > 0.0 &&
        packets >= static_cast<uint64_t>(kTrafficSpikeMinPackets) &&
        static_cast<double>(packets) > avg_packets * qps_spike_factor) {
        alerts.emplace_back("traffic_spike");
    }

    if (avg_p95 > 0.0 &&
        p95_ms >= kLatencySpikeMinP95Ms &&
        p95_ms > avg_p95 * latency_spike_factor) {
        alerts.emplace_back("latency_spike");
    }

    if (metrics.ringbuf_drop_delta > 0)
        alerts.emplace_back("ringbuf_drop");

    if (alerts.empty())
        return "none";

    std::ostringstream out;
    for (size_t i = 0; i < alerts.size(); ++i) {
        if (i)
            out << ",";
        out << alerts[i];
    }
    return out.str();
}

void print_metrics(ReaderState *state)
{
    collect_timeouts(state);

    uint64_t drop_total = read_dropped_events_total(state->dropped_events_fd);
    state->current.ringbuf_drop_delta =
        drop_total >= state->last_drop_total ? drop_total - state->last_drop_total : 0;
    state->last_drop_total = drop_total;

    uint64_t cache_hits = read_percpu_counter_total(
        state->cache_stats_fd, DNS_CACHE_STAT_HIT);
    uint64_t cache_misses = read_percpu_counter_total(
        state->cache_stats_fd, DNS_CACHE_STAT_MISS);
    uint64_t cache_expired = read_percpu_counter_total(
        state->cache_stats_fd, DNS_CACHE_STAT_EXPIRED);
    uint64_t cache_tx = read_percpu_counter_total(
        state->cache_stats_fd, DNS_CACHE_STAT_TX);

    uint64_t cache_hit_delta = counter_delta(cache_hits, &state->last_cache_hits);
    uint64_t cache_miss_delta = counter_delta(cache_misses, &state->last_cache_misses);
    uint64_t cache_expired_delta =
        counter_delta(cache_expired, &state->last_cache_expired);
    uint64_t cache_tx_delta = counter_delta(cache_tx, &state->last_cache_tx);

    double avg_ms = average_ms(state->current.latency_samples_ns);
    double p95_ms = percentile_ms(state->current.latency_samples_ns, 95.0);
    double p99_ms = percentile_ms(state->current.latency_samples_ns, 99.0);
    std::string alerts = build_alerts(state->current, state->history,
                                      state->options->qps_spike_factor,
                                      state->options->latency_spike_factor,
                                      p95_ms);

    std::cout << "dns_metrics dev=" << state->options->ifname
              << " qps=" << state->current.query_count
              << " rps=" << state->current.response_count
              << " pending=" << state->pending.size()
              << " timeout=" << state->current.timeout_count
              << " unmatched=" << state->current.unmatched_response_count
              << " avg=" << std::fixed << std::setprecision(3) << avg_ms << "ms"
              << " p95=" << p95_ms << "ms"
              << " p99=" << p99_ms << "ms";

    for (int i = 0; i < kRcodeCount; ++i) {
        if (!state->current.rcode[i])
            continue;
        const char *name = rcode_name(i);
        if (name)
            std::cout << " rcode_" << name << "=" << state->current.rcode[i];
        else
            std::cout << " rcode_" << i << "=" << state->current.rcode[i];
    }

    std::cout << " ringbuf_drop=" << state->current.ringbuf_drop_delta
              << " cache_hit=" << cache_hit_delta
              << " cache_miss=" << cache_miss_delta
              << " cache_expired=" << cache_expired_delta
              << " cache_tx=" << cache_tx_delta
              << " alerts=" << alerts << "\n";

    state->history.push_back(
        {state->current.query_count + state->current.response_count, p95_ms});
    if (state->history.size() > kHistoryWindows)
        state->history.pop_front();

    state->current = WindowMetrics{};
}
