#include "grpc_event.h"

#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <net/if.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

volatile sig_atomic_t exiting = 0;

struct Options {
    std::string ifname;
    std::string bpf_object = "build/grpc_monitor.bpf.o";
    std::string pin_dir;
    int port = 50051;
    int timeout_ms = 2000;
    bool verbose_events = false;
};

struct FlowKeyHash {
    size_t operator()(const grpc_flow_key &key) const
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
        return h;
    }
};

struct FlowKeyEqual {
    bool operator()(const grpc_flow_key &lhs, const grpc_flow_key &rhs) const
    {
        return lhs.client_ip == rhs.client_ip &&
               lhs.server_ip == rhs.server_ip &&
               lhs.client_port == rhs.client_port &&
               lhs.server_port == rhs.server_port;
    }
};

struct WindowMetrics {
    uint64_t request_count = 0;
    uint64_t response_count = 0;
    uint64_t unmatched_response_count = 0;
    uint64_t timeout_count = 0;
    uint64_t h2_preface_count = 0;
    uint64_t h2_headers_count = 0;
    uint64_t ringbuf_drop_delta = 0;
    std::vector<uint64_t> latency_samples_ns;
};

struct ReaderState {
    Options *options = nullptr;
    WindowMetrics current;
    std::unordered_map<grpc_flow_key, uint64_t, FlowKeyHash, FlowKeyEqual> pending;
    uint64_t last_drop_total = 0;
    int dropped_events_fd = -1;
};

void handle_signal(int)
{
    exiting = 1;
}

void print_usage(const char *program)
{
    std::cerr << "Usage: " << program
              << " --dev <ifname> [--bpf-object <path>]"
              << " [--pin-dir <bpffs-dir>]"
              << " [--port 50051] [--timeout-ms <ms>] [--verbose-events]\n";
}

bool parse_int(const std::string &value, int *out)
{
    char *end = nullptr;
    long parsed = std::strtol(value.c_str(), &end, 10);
    if (!end || *end != '\0' || parsed <= 0 || parsed > 65535)
        return false;
    *out = static_cast<int>(parsed);
    return true;
}

bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--dev" && i + 1 < argc) {
            options->ifname = argv[++i];
        } else if (arg == "--bpf-object" && i + 1 < argc) {
            options->bpf_object = argv[++i];
        } else if (arg == "--pin-dir" && i + 1 < argc) {
            options->pin_dir = argv[++i];
        } else if (arg == "--port" && i + 1 < argc) {
            if (!parse_int(argv[++i], &options->port))
                return false;
        } else if (arg == "--timeout-ms" && i + 1 < argc) {
            if (!parse_int(argv[++i], &options->timeout_ms))
                return false;
        } else if (arg == "--verbose-events") {
            options->verbose_events = true;
        } else if (arg == "-h" || arg == "--help") {
            return false;
        } else {
            std::cerr << "Unknown or incomplete option: " << arg << "\n";
            return false;
        }
    }

    return !options->ifname.empty();
}

std::string ipv4_to_string(__u32 addr)
{
    char buf[INET_ADDRSTRLEN] = {};
    if (!inet_ntop(AF_INET, &addr, buf, sizeof(buf)))
        return "<invalid>";
    return std::string(buf);
}

const char *direction_name(__u32 direction)
{
    switch (direction) {
    case GRPC_DIR_INGRESS:
        return "ingress";
    case GRPC_DIR_EGRESS:
        return "egress";
    default:
        return "unknown";
    }
}

uint64_t monotonic_now_ns()
{
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

double ns_to_ms(uint64_t ns)
{
    return static_cast<double>(ns) / 1000000.0;
}

double average_ms(const std::vector<uint64_t> &samples)
{
    if (samples.empty())
        return 0.0;

    long double total = 0.0;
    for (uint64_t sample : samples)
        total += sample;
    return ns_to_ms(static_cast<uint64_t>(total / samples.size()));
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

uint64_t read_percpu_counter_total(int map_fd, __u32 key)
{
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

grpc_flow_key build_user_flow_key(const grpc_event *event)
{
    grpc_flow_key key = {};
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

void print_verbose_event(const grpc_event *event)
{
    std::cout << "[" << direction_name(event->direction) << "] "
              << ipv4_to_string(event->src_ip) << ":" << event->src_port
              << " -> "
              << ipv4_to_string(event->dst_ip) << ":" << event->dst_port
              << " " << (event->is_response ? "response" : "request")
              << " payload=" << event->payload_len
              << " matched=" << static_cast<int>(event->matched)
              << " h2_preface=" << !!(event->flags & GRPC_FLAG_H2_PREFACE)
              << " h2_headers=" << !!(event->flags & GRPC_FLAG_H2_HEADERS)
              << " latency_ms=" << std::fixed << std::setprecision(3)
              << ns_to_ms(event->latency_ns)
              << " len=" << event->packet_len
              << " ifindex=" << event->ifindex
              << " ts=" << event->timestamp_ns << "\n";
}

int handle_grpc_event(void *ctx, void *data, size_t data_sz)
{
    auto *state = static_cast<ReaderState *>(ctx);
    if (data_sz < sizeof(grpc_event))
        return 0;

    const auto *event = static_cast<const grpc_event *>(data);
    grpc_flow_key key = build_user_flow_key(event);

    if (event->is_response) {
        state->current.response_count++;
        if (event->matched && event->latency_ns > 0)
            state->current.latency_samples_ns.push_back(event->latency_ns);
        else
            state->current.unmatched_response_count++;
        state->pending.erase(key);
    } else {
        state->current.request_count++;
        state->pending[key] = monotonic_now_ns();
    }

    if (event->flags & GRPC_FLAG_H2_PREFACE)
        state->current.h2_preface_count++;
    if (event->flags & GRPC_FLAG_H2_HEADERS)
        state->current.h2_headers_count++;

    if (state->options->verbose_events)
        print_verbose_event(event);

    return 0;
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

void print_metrics(ReaderState *state)
{
    collect_timeouts(state);

    __u32 key = 0;
    uint64_t drop_total = read_percpu_counter_total(state->dropped_events_fd, key);
    state->current.ringbuf_drop_delta =
        drop_total >= state->last_drop_total ? drop_total - state->last_drop_total : 0;
    state->last_drop_total = drop_total;

    double avg_ms = average_ms(state->current.latency_samples_ns);
    double p50_ms = percentile_ms(state->current.latency_samples_ns, 50.0);
    double p95_ms = percentile_ms(state->current.latency_samples_ns, 95.0);
    double p99_ms = percentile_ms(state->current.latency_samples_ns, 99.0);

    std::cout << "grpc_metrics dev=" << state->options->ifname
              << " port=" << state->options->port
              << " reqps=" << state->current.request_count
              << " resps=" << state->current.response_count
              << " active_flows=" << state->pending.size()
              << " pending=" << state->pending.size()
              << " timeout=" << state->current.timeout_count
              << " unmatched=" << state->current.unmatched_response_count
              << " avg=" << std::fixed << std::setprecision(3) << avg_ms << "ms"
              << " p50=" << p50_ms << "ms"
              << " p95=" << p95_ms << "ms"
              << " p99=" << p99_ms << "ms"
              << " h2_preface=" << state->current.h2_preface_count
              << " h2_headers=" << state->current.h2_headers_count
              << " ringbuf_drop=" << state->current.ringbuf_drop_delta << "\n";

    state->current = WindowMetrics{};
}

void cleanup_tc(bpf_tc_hook *hook, bpf_tc_opts *ingress_opts,
                bpf_tc_opts *egress_opts, bool destroy_clsact)
{
    hook->attach_point = BPF_TC_INGRESS;
    bpf_tc_detach(hook, ingress_opts);
    hook->attach_point = BPF_TC_EGRESS;
    bpf_tc_detach(hook, egress_opts);

    if (destroy_clsact) {
        hook->attach_point =
            static_cast<decltype(hook->attach_point)>(BPF_TC_INGRESS | BPF_TC_EGRESS);
        bpf_tc_hook_destroy(hook);
    }
}

bool configure_port(bpf_object *obj, int port)
{
    bpf_map *config_map = bpf_object__find_map_by_name(obj, "grpc_config_map");
    if (!config_map) {
        std::cerr << "Failed to find grpc_config_map\n";
        return false;
    }

    __u32 key = 0;
    grpc_config config = {};
    config.port = static_cast<__u16>(port);
    if (bpf_map_update_elem(bpf_map__fd(config_map), &key, &config, BPF_ANY) != 0) {
        std::cerr << "Failed to configure gRPC port: " << strerror(errno) << "\n";
        return false;
    }

    return true;
}

bool ensure_dir(const std::string &path)
{
    if (path.empty())
        return true;
    if (mkdir(path.c_str(), 0755) == 0 || errno == EEXIST)
        return true;
    std::cerr << "Failed to create pin dir " << path << ": "
              << strerror(errno) << "\n";
    return false;
}

bool pin_grpc_policy_map(bpf_object *obj, const std::string &pin_dir)
{
    if (pin_dir.empty())
        return true;
    if (!ensure_dir(pin_dir))
        return false;

    bpf_map *policy_map = bpf_object__find_map_by_name(obj, "grpc_policy_map");
    if (!policy_map) {
        std::cerr << "Failed to find grpc_policy_map\n";
        return false;
    }

    std::string pin_path = pin_dir + "/grpc_policy_map";
    unlink(pin_path.c_str());
    int err = bpf_map__pin(policy_map, pin_path.c_str());
    if (err) {
        std::cerr << "Failed to pin grpc_policy_map at " << pin_path
                  << ": " << strerror(-err) << "\n";
        return false;
    }
    std::cout << "Pinned grpc_policy_map at " << pin_path << "\n";
    return true;
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) {
        print_usage(argv[0]);
        return 1;
    }

    unsigned int ifindex = if_nametoindex(options.ifname.c_str());
    if (!ifindex) {
        std::cerr << "Failed to resolve interface " << options.ifname << ": "
                  << strerror(errno) << "\n";
        return 1;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    libbpf_set_strict_mode(LIBBPF_STRICT_ALL);

    bpf_object *obj = bpf_object__open_file(options.bpf_object.c_str(), nullptr);
    if (!obj) {
        std::cerr << "Failed to open BPF object: " << options.bpf_object << "\n";
        return 1;
    }

    bpf_program *ingress_prog = bpf_object__find_program_by_name(obj, "grpc_ingress");
    bpf_program *egress_prog = bpf_object__find_program_by_name(obj, "grpc_egress");
    if (!ingress_prog || !egress_prog) {
        std::cerr << "Failed to find grpc_ingress/grpc_egress programs\n";
        bpf_object__close(obj);
        return 1;
    }

    bpf_program__set_type(ingress_prog, BPF_PROG_TYPE_SCHED_CLS);
    bpf_program__set_type(egress_prog, BPF_PROG_TYPE_SCHED_CLS);

    int err = bpf_object__load(obj);
    if (err) {
        std::cerr << "Failed to load BPF object: " << strerror(-err) << "\n";
        bpf_object__close(obj);
        return 1;
    }

    if (!configure_port(obj, options.port)) {
        bpf_object__close(obj);
        return 1;
    }
    if (!pin_grpc_policy_map(obj, options.pin_dir)) {
        bpf_object__close(obj);
        return 1;
    }

    bpf_tc_hook hook = {};
    bpf_tc_opts ingress_opts = {};
    bpf_tc_opts egress_opts = {};
    bool destroy_clsact = false;

    hook.sz = sizeof(hook);
    hook.ifindex = static_cast<int>(ifindex);
    hook.attach_point =
        static_cast<decltype(hook.attach_point)>(BPF_TC_INGRESS | BPF_TC_EGRESS);

    err = bpf_tc_hook_create(&hook);
    destroy_clsact = err == 0;
    if (err && err != -EEXIST) {
        std::cerr << "Failed to create clsact qdisc: " << strerror(-err) << "\n";
        bpf_object__close(obj);
        return 1;
    }

    ingress_opts.sz = sizeof(ingress_opts);
    ingress_opts.prog_fd = bpf_program__fd(ingress_prog);
    ingress_opts.handle = 2;
    ingress_opts.priority = 2;

    egress_opts.sz = sizeof(egress_opts);
    egress_opts.prog_fd = bpf_program__fd(egress_prog);
    egress_opts.handle = 2;
    egress_opts.priority = 2;

    hook.attach_point = BPF_TC_INGRESS;
    bpf_tc_detach(&hook, &ingress_opts);
    err = bpf_tc_attach(&hook, &ingress_opts);
    if (err) {
        std::cerr << "Failed to attach ingress program: " << strerror(-err) << "\n";
        cleanup_tc(&hook, &ingress_opts, &egress_opts, destroy_clsact);
        bpf_object__close(obj);
        return 1;
    }

    hook.attach_point = BPF_TC_EGRESS;
    bpf_tc_detach(&hook, &egress_opts);
    err = bpf_tc_attach(&hook, &egress_opts);
    if (err) {
        std::cerr << "Failed to attach egress program: " << strerror(-err) << "\n";
        cleanup_tc(&hook, &ingress_opts, &egress_opts, destroy_clsact);
        bpf_object__close(obj);
        return 1;
    }

    bpf_map *events_map = bpf_object__find_map_by_name(obj, "grpc_events");
    bpf_map *dropped_map = bpf_object__find_map_by_name(obj, "grpc_dropped_events");
    if (!events_map || !dropped_map) {
        std::cerr << "Failed to find grpc_events or grpc_dropped_events map\n";
        cleanup_tc(&hook, &ingress_opts, &egress_opts, destroy_clsact);
        bpf_object__close(obj);
        return 1;
    }

    ReaderState state = {};
    state.options = &options;
    state.dropped_events_fd = bpf_map__fd(dropped_map);
    state.last_drop_total = read_percpu_counter_total(state.dropped_events_fd, 0);

    ring_buffer *ring =
        ring_buffer__new(bpf_map__fd(events_map), handle_grpc_event, &state, nullptr);
    if (!ring) {
        std::cerr << "Failed to create ring buffer\n";
        cleanup_tc(&hook, &ingress_opts, &egress_opts, destroy_clsact);
        bpf_object__close(obj);
        return 1;
    }

    std::cout << "Listening for gRPC transport metrics on " << options.ifname
              << " port " << options.port << " with tc. Press Ctrl-C to stop.\n";

    auto next_report = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    while (!exiting) {
        err = ring_buffer__poll(ring, 100);
        if (err == -EINTR)
            break;
        if (err < 0) {
            std::cerr << "ring_buffer__poll failed: " << strerror(-err) << "\n";
            break;
        }

        auto now = std::chrono::steady_clock::now();
        if (now >= next_report) {
            print_metrics(&state);
            next_report = now + std::chrono::seconds(1);
        }
    }

    print_metrics(&state);
    ring_buffer__free(ring);
    cleanup_tc(&hook, &ingress_opts, &egress_opts, destroy_clsact);
    bpf_object__close(obj);
    return 0;
}
