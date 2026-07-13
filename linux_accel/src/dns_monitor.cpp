#include "dns_monitor.hpp"

#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <linux/if_link.h>
#include <net/if.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <chrono>
#include <iostream>
#include <string>
#include <vector>

namespace {

volatile sig_atomic_t exiting = 0;

struct Attachments {
    bpf_tc_hook hook = {};
    bpf_tc_opts ingress_opts = {};
    bpf_tc_opts egress_opts = {};
    bool xdp_attached = false;
    bool tc_ingress_attached = false;
    bool tc_egress_attached = false;
    bool destroy_clsact = false;
};

void handle_signal(int)
{
    exiting = 1;
}

int xdp_mode_flags(const std::string &mode)
{
    if (mode == "generic")
        return XDP_FLAGS_SKB_MODE;
    return XDP_FLAGS_DRV_MODE;
}

void cleanup_tc(Attachments *attachments)
{
    if (attachments->tc_ingress_attached) {
        attachments->hook.attach_point = BPF_TC_INGRESS;
        bpf_tc_detach(&attachments->hook, &attachments->ingress_opts);
        attachments->tc_ingress_attached = false;
    }
    if (attachments->tc_egress_attached) {
        attachments->hook.attach_point = BPF_TC_EGRESS;
        bpf_tc_detach(&attachments->hook, &attachments->egress_opts);
        attachments->tc_egress_attached = false;
    }
    if (attachments->destroy_clsact) {
        attachments->hook.attach_point =
            static_cast<decltype(attachments->hook.attach_point)>(
                BPF_TC_INGRESS | BPF_TC_EGRESS);
        bpf_tc_hook_destroy(&attachments->hook);
        attachments->destroy_clsact = false;
    }
}

void cleanup_attachments(Attachments *attachments, unsigned int ifindex,
                         int xdp_mode)
{
    if (attachments->xdp_attached) {
        bpf_xdp_detach(static_cast<int>(ifindex), xdp_mode, nullptr);
        attachments->xdp_attached = false;
    }
    cleanup_tc(attachments);
}

bool ensure_tc_hook(Attachments *attachments, unsigned int ifindex)
{
    attachments->hook.sz = sizeof(attachments->hook);
    attachments->hook.ifindex = static_cast<int>(ifindex);
    attachments->hook.attach_point =
        static_cast<decltype(attachments->hook.attach_point)>(
            BPF_TC_INGRESS | BPF_TC_EGRESS);

    int err = bpf_tc_hook_create(&attachments->hook);
    attachments->destroy_clsact = err == 0;
    if (err && err != -EEXIST) {
        std::cerr << "Failed to create clsact qdisc: " << strerror(-err)
                  << "\n";
        return false;
    }
    return true;
}

bool attach_tc_filter(Attachments *attachments, bpf_program *program,
                      enum bpf_tc_attach_point attach_point, __u32 handle,
                      __u32 priority, bool *attached)
{
    bpf_tc_opts *opts = attach_point == BPF_TC_INGRESS
                            ? &attachments->ingress_opts
                            : &attachments->egress_opts;
    *opts = {};
    opts->sz = sizeof(*opts);
    opts->prog_fd = bpf_program__fd(program);
    opts->handle = handle;
    opts->priority = priority;
    attachments->hook.attach_point = attach_point;

    int err = bpf_tc_attach(&attachments->hook, opts);
    if (err) {
        std::cerr << "Failed to attach "
                  << (attach_point == BPF_TC_INGRESS ? "ingress" : "egress")
                  << " tc program: " << strerror(-err) << "\n";
        return false;
    }
    *attached = true;
    return true;
}

bool install_dns_cache(bpf_object *obj, const Options &options)
{
    std::vector<DnsCacheEntry> entries;
    std::string error;

    if (!options.cache_file.empty() &&
        !parse_dns_cache_file(options.cache_file, &entries, &error)) {
        std::cerr << error << "\n";
        return false;
    }
    if (!options.cache_domain.empty())
        entries.push_back({options.cache_domain, options.cache_ip, options.cache_ttl});
    if (entries.empty())
        return true;

    bpf_map *cache_map = bpf_object__find_map_by_name(obj, "dns_cache");
    if (!cache_map) {
        std::cerr << "Failed to find dns_cache map\n";
        return false;
    }

    int cache_fd = bpf_map__fd(cache_map);
    for (const DnsCacheEntry &entry : entries) {
        if (!install_dns_cache_entry(cache_fd, entry, &error)) {
            std::cerr << error << "\n";
            return false;
        }
        std::cout << "Installed DNS cache entry " << entry.domain
                  << " A " << entry.ip << " ttl=" << entry.ttl << "\n";
    }
    return true;
}

bool install_client_config(bpf_object *obj, const Options &options)
{
    bpf_map *trusted_map =
        bpf_object__find_map_by_name(obj, "dns_client_trusted_servers");
    bpf_map *config_map =
        bpf_object__find_map_by_name(obj, "dns_client_config");
    if (!trusted_map || !config_map) {
        std::cerr << "Failed to find client DNS cache maps\n";
        return false;
    }

    int trusted_fd = bpf_map__fd(trusted_map);
    for (const std::string &address_text : options.trusted_dns) {
        __u32 address = 0;
        __u8 enabled = 1;
        if (inet_pton(AF_INET, address_text.c_str(), &address) != 1) {
            std::cerr << "Invalid trusted DNS IPv4 address: " << address_text
                      << "\n";
            return false;
        }
        if (bpf_map_update_elem(trusted_fd, &address, &enabled, BPF_ANY) != 0) {
            std::cerr << "Failed to install trusted DNS server " << address_text
                      << ": " << strerror(errno) << "\n";
            return false;
        }
    }

    __u32 key = 0;
    dns_client_config config = {};
    config.learn_window_ns =
        static_cast<__u64>(options.learn_window_ms) * 1000000ull;
    config.max_ttl = static_cast<__u32>(options.max_learn_ttl);
    if (bpf_map_update_elem(bpf_map__fd(config_map), &key, &config, BPF_ANY) !=
        0) {
        std::cerr << "Failed to install client DNS cache config: "
                  << strerror(errno) << "\n";
        return false;
    }
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

    bpf_program *ingress_prog = nullptr;
    bpf_program *egress_prog = nullptr;
    bpf_program *xdp_prog = nullptr;
    if (options.hook == "tc") {
        ingress_prog = bpf_object__find_program_by_name(obj, "dns_ingress");
        egress_prog = bpf_object__find_program_by_name(obj, "dns_egress");
        if (!ingress_prog || !egress_prog) {
            std::cerr << "Failed to find dns_ingress/dns_egress programs\n";
            bpf_object__close(obj);
            return 1;
        }
        bpf_program__set_type(ingress_prog, BPF_PROG_TYPE_SCHED_CLS);
        bpf_program__set_type(egress_prog, BPF_PROG_TYPE_SCHED_CLS);
    } else if (options.role == "client") {
        xdp_prog = bpf_object__find_program_by_name(obj, "dns_client_cache_xdp");
        egress_prog =
            bpf_object__find_program_by_name(obj, "dns_client_cache_egress");
        if (!xdp_prog || !egress_prog) {
            std::cerr << "Failed to find client DNS cache programs\n";
            bpf_object__close(obj);
            return 1;
        }
        bpf_program__set_type(xdp_prog, BPF_PROG_TYPE_XDP);
        bpf_program__set_type(egress_prog, BPF_PROG_TYPE_SCHED_CLS);
    } else {
        xdp_prog = bpf_object__find_program_by_name(obj, "dns_xdp_monitor");
        if (!xdp_prog) {
            std::cerr << "Failed to find dns_xdp_monitor program\n";
            bpf_object__close(obj);
            return 1;
        }
        bpf_program__set_type(xdp_prog, BPF_PROG_TYPE_XDP);
    }

    int err = bpf_object__load(obj);
    if (err) {
        std::cerr << "Failed to load BPF object: " << strerror(-err) << "\n";
        bpf_object__close(obj);
        return 1;
    }

    if (options.hook == "xdp" && options.role == "server" &&
        !install_dns_cache(obj, options)) {
        bpf_object__close(obj);
        return 1;
    }
    if (options.hook == "xdp" && options.role == "client" &&
        !install_client_config(obj, options)) {
        bpf_object__close(obj);
        return 1;
    }

    const int xdp_mode = xdp_mode_flags(options.xdp_mode);
    Attachments attachments;
    if (options.hook == "tc") {
        if (!ensure_tc_hook(&attachments, ifindex) ||
            !attach_tc_filter(&attachments, ingress_prog, BPF_TC_INGRESS, 1, 1,
                              &attachments.tc_ingress_attached) ||
            !attach_tc_filter(&attachments, egress_prog, BPF_TC_EGRESS, 1, 1,
                              &attachments.tc_egress_attached)) {
            cleanup_attachments(&attachments, ifindex, xdp_mode);
            bpf_object__close(obj);
            return 1;
        }
    } else if (options.role == "client") {
        if (!ensure_tc_hook(&attachments, ifindex) ||
            !attach_tc_filter(&attachments, egress_prog, BPF_TC_EGRESS, 100,
                              100, &attachments.tc_egress_attached)) {
            cleanup_attachments(&attachments, ifindex, xdp_mode);
            bpf_object__close(obj);
            return 1;
        }
        err = bpf_xdp_attach(static_cast<int>(ifindex), bpf_program__fd(xdp_prog),
                             xdp_mode | XDP_FLAGS_UPDATE_IF_NOEXIST, nullptr);
        if (err) {
            std::cerr << "Failed to attach client XDP program in "
                      << options.xdp_mode << " mode: " << strerror(-err) << "\n";
            cleanup_attachments(&attachments, ifindex, xdp_mode);
            bpf_object__close(obj);
            return 1;
        }
        attachments.xdp_attached = true;
    } else {
        err = bpf_xdp_attach(static_cast<int>(ifindex), bpf_program__fd(xdp_prog),
                             xdp_mode | XDP_FLAGS_UPDATE_IF_NOEXIST, nullptr);
        if (err) {
            std::cerr << "Failed to attach XDP program in " << options.xdp_mode
                      << " mode: " << strerror(-err) << "\n";
            bpf_object__close(obj);
            return 1;
        }
        attachments.xdp_attached = true;
    }

    bpf_map *events_map = bpf_object__find_map_by_name(obj, "dns_events");
    bpf_map *dropped_map = bpf_object__find_map_by_name(obj, "dropped_events");
    bpf_map *cache_stats_map =
        bpf_object__find_map_by_name(obj, "dns_cache_stats");
    if (!events_map || !dropped_map) {
        std::cerr << "Failed to find dns_events or dropped_events map\n";
        cleanup_attachments(&attachments, ifindex, xdp_mode);
        bpf_object__close(obj);
        return 1;
    }

    ReaderState state = {};
    state.options = &options;
    state.dropped_events_fd = bpf_map__fd(dropped_map);
    state.cache_stats_fd = cache_stats_map ? bpf_map__fd(cache_stats_map) : -1;
    state.last_drop_total = read_dropped_events_total(state.dropped_events_fd);
    state.last_cache_hits =
        read_percpu_counter_total(state.cache_stats_fd, DNS_CACHE_STAT_HIT);
    state.last_cache_misses =
        read_percpu_counter_total(state.cache_stats_fd, DNS_CACHE_STAT_MISS);
    state.last_cache_expired =
        read_percpu_counter_total(state.cache_stats_fd, DNS_CACHE_STAT_EXPIRED);
    state.last_cache_tx =
        read_percpu_counter_total(state.cache_stats_fd, DNS_CACHE_STAT_TX);
    state.last_cache_learned =
        read_percpu_counter_total(state.cache_stats_fd, DNS_CACHE_STAT_LEARNED);
    state.last_cache_learn_rejected = read_percpu_counter_total(
        state.cache_stats_fd, DNS_CACHE_STAT_LEARN_REJECTED);
    state.last_cache_pending_expired = read_percpu_counter_total(
        state.cache_stats_fd, DNS_CACHE_STAT_PENDING_EXPIRED);

    ring_buffer *ring =
        ring_buffer__new(bpf_map__fd(events_map), handle_dns_event, &state, nullptr);
    if (!ring) {
        std::cerr << "Failed to create ring buffer\n";
        cleanup_attachments(&attachments, ifindex, xdp_mode);
        bpf_object__close(obj);
        return 1;
    }

    std::cout << "Listening for DNS metrics on " << options.ifname
              << " role=" << options.role << " with " << options.hook;
    if (options.hook == "xdp")
        std::cout << "/" << options.xdp_mode;
    std::cout << ". Press Ctrl-C to stop.\n";

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
    cleanup_attachments(&attachments, ifindex, xdp_mode);
    bpf_object__close(obj);
    return 0;
}
