#include "dns_monitor.hpp"

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

void handle_signal(int)
{
    exiting = 1;
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

int xdp_flags_for_mode(const std::string &mode)
{
    if (mode == "generic")
        return XDP_FLAGS_SKB_MODE;
    return XDP_FLAGS_DRV_MODE;
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
                  << " A " << entry.ip
                  << " ttl=" << entry.ttl << "\n";
    }
    return true;
}

void cleanup_attached(bool xdp_attached, unsigned int ifindex, int xdp_flags,
                      bpf_tc_hook *hook, bpf_tc_opts *ingress_opts,
                      bpf_tc_opts *egress_opts, bool destroy_clsact)
{
    if (xdp_attached)
        bpf_xdp_detach(static_cast<int>(ifindex), xdp_flags, nullptr);
    else
        cleanup_tc(hook, ingress_opts, egress_opts, destroy_clsact);
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
    int xdp_flags = xdp_flags_for_mode(options.xdp_mode);

    if (options.hook == "xdp") {
        xdp_prog = bpf_object__find_program_by_name(obj, "dns_xdp_monitor");
        if (!xdp_prog) {
            std::cerr << "Failed to find dns_xdp_monitor program\n";
            bpf_object__close(obj);
            return 1;
        }
        bpf_program__set_type(xdp_prog, BPF_PROG_TYPE_XDP);
    } else {
        ingress_prog = bpf_object__find_program_by_name(obj, "dns_ingress");
        egress_prog = bpf_object__find_program_by_name(obj, "dns_egress");
        if (!ingress_prog || !egress_prog) {
            std::cerr << "Failed to find dns_ingress/dns_egress programs\n";
            bpf_object__close(obj);
            return 1;
        }
        bpf_program__set_type(ingress_prog, BPF_PROG_TYPE_SCHED_CLS);
        bpf_program__set_type(egress_prog, BPF_PROG_TYPE_SCHED_CLS);
    }

    int err = bpf_object__load(obj);
    if (err) {
        std::cerr << "Failed to load BPF object: " << strerror(-err) << "\n";
        bpf_object__close(obj);
        return 1;
    }

    if (options.hook == "xdp" && !install_dns_cache(obj, options)) {
        bpf_object__close(obj);
        return 1;
    }

    bpf_tc_hook hook = {};
    bpf_tc_opts ingress_opts = {};
    bpf_tc_opts egress_opts = {};
    bool destroy_clsact = false;
    bool xdp_attached = false;

    if (options.hook == "xdp") {
        err = bpf_xdp_attach(static_cast<int>(ifindex),
                             bpf_program__fd(xdp_prog), xdp_flags, nullptr);
        if (err) {
            std::cerr << "Failed to attach XDP program in " << options.xdp_mode
                      << " mode: " << strerror(-err) << "\n";
            bpf_object__close(obj);
            return 1;
        }
        xdp_attached = true;
    } else {
        hook.sz = sizeof(hook);
        hook.ifindex = static_cast<int>(ifindex);
        hook.attach_point =
            static_cast<decltype(hook.attach_point)>(BPF_TC_INGRESS | BPF_TC_EGRESS);

        err = bpf_tc_hook_create(&hook);
        destroy_clsact = err == 0;
        if (err && err != -EEXIST) {
            std::cerr << "Failed to create clsact qdisc: " << strerror(-err)
                      << "\n";
            bpf_object__close(obj);
            return 1;
        }

        ingress_opts.sz = sizeof(ingress_opts);
        ingress_opts.prog_fd = bpf_program__fd(ingress_prog);
        ingress_opts.handle = 1;
        ingress_opts.priority = 1;

        egress_opts.sz = sizeof(egress_opts);
        egress_opts.prog_fd = bpf_program__fd(egress_prog);
        egress_opts.handle = 1;
        egress_opts.priority = 1;

        hook.attach_point = BPF_TC_INGRESS;
        bpf_tc_detach(&hook, &ingress_opts);
        err = bpf_tc_attach(&hook, &ingress_opts);
        if (err) {
            std::cerr << "Failed to attach ingress program: " << strerror(-err)
                      << "\n";
            cleanup_tc(&hook, &ingress_opts, &egress_opts, destroy_clsact);
            bpf_object__close(obj);
            return 1;
        }

        hook.attach_point = BPF_TC_EGRESS;
        bpf_tc_detach(&hook, &egress_opts);
        err = bpf_tc_attach(&hook, &egress_opts);
        if (err) {
            std::cerr << "Failed to attach egress program: " << strerror(-err)
                      << "\n";
            cleanup_tc(&hook, &ingress_opts, &egress_opts, destroy_clsact);
            bpf_object__close(obj);
            return 1;
        }
    }

    bpf_map *events_map = bpf_object__find_map_by_name(obj, "dns_events");
    bpf_map *dropped_map = bpf_object__find_map_by_name(obj, "dropped_events");
    bpf_map *cache_stats_map = bpf_object__find_map_by_name(obj, "dns_cache_stats");
    if (!events_map || !dropped_map) {
        std::cerr << "Failed to find dns_events or dropped_events map\n";
        cleanup_attached(xdp_attached, ifindex, xdp_flags, &hook,
                         &ingress_opts, &egress_opts, destroy_clsact);
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

    ring_buffer *ring =
        ring_buffer__new(bpf_map__fd(events_map), handle_dns_event, &state, nullptr);
    if (!ring) {
        std::cerr << "Failed to create ring buffer\n";
        cleanup_attached(xdp_attached, ifindex, xdp_flags, &hook,
                         &ingress_opts, &egress_opts, destroy_clsact);
        bpf_object__close(obj);
        return 1;
    }

    std::cout << "Listening for DNS metrics on " << options.ifname
              << " with " << options.hook;
    if (options.hook == "xdp")
        std::cout << "/" << options.xdp_mode;
    std::cout << ". Press Ctrl-C to stop.\n";

    auto next_report = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    while (!exiting) {
        err = ring_buffer__poll(ring, 100);
        if (err == -EINTR)
            break;
        if (err < 0) {
            std::cerr << "ring_buffer__poll failed: " << strerror(-err)
                      << "\n";
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
    cleanup_attached(xdp_attached, ifindex, xdp_flags, &hook,
                     &ingress_opts, &egress_opts, destroy_clsact);
    bpf_object__close(obj);
    return 0;
}
