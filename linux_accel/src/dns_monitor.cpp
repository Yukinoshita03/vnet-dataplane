#include "dns_monitor.hpp"
#include "dns_tc_attach_plan.hpp"

#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <linux/if_link.h>
#include <net/if.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
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
    int xdp_program_fd = -1;
    __u32 xdp_program_id = 0;
    __u32 tc_ingress_program_id = 0;
    __u32 tc_egress_program_id = 0;
    bool xdp_attached = false;
    bool tc_ingress_attached = false;
    bool tc_egress_attached = false;
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

bool read_program_id(int program_fd, __u32 *program_id, const char *label)
{
    bpf_prog_info info = {};
    __u32 info_len = sizeof(info);
    if (bpf_prog_get_info_by_fd(program_fd, &info, &info_len) != 0) {
        std::cerr << "Failed to read " << label << " program ID: "
                  << strerror(errno) << "\n";
        return false;
    }
    if (info.id == 0) {
        std::cerr << "Failed to read a non-zero " << label << " program ID\n";
        return false;
    }
    *program_id = info.id;
    return true;
}

void detach_tc_filter_if_owned(Attachments *attachments,
                               enum bpf_tc_attach_point attach_point,
                               bpf_tc_opts *opts, bool *attached,
                               __u32 expected_program_id)
{
    if (!*attached)
        return;

    attachments->hook.attach_point = attach_point;
    bpf_tc_opts query = {};
    query.sz = sizeof(query);
    query.handle = opts->handle;
    query.priority = opts->priority;
    const int err = bpf_tc_query(&attachments->hook, &query);
    const char *direction = attach_point == BPF_TC_INGRESS ? "ingress" : "egress";
    if (err == -ENOENT) {
        *attached = false;
        return;
    }
    if (err) {
        std::cerr << "Refusing to detach " << direction
                  << " tc program because ownership cannot be queried: "
                  << strerror(-err) << "\n";
        *attached = false;
        return;
    }
    if (expected_program_id == 0 || query.prog_id != expected_program_id) {
        std::cerr << "Refusing to detach " << direction
                  << " tc program because ownership changed (expected id "
                  << expected_program_id << ", found id " << query.prog_id << ")\n";
        *attached = false;
        return;
    }

    bpf_tc_opts detach = {};
    detach.sz = sizeof(detach);
    detach.handle = opts->handle;
    detach.priority = opts->priority;
    const int detach_err = bpf_tc_detach(&attachments->hook, &detach);
    if (detach_err) {
        std::cerr << "Failed to detach owned " << direction
                  << " tc program: " << strerror(-detach_err) << "\n";
    }
    *attached = false;
}

void cleanup_tc(Attachments *attachments)
{
    detach_tc_filter_if_owned(attachments, BPF_TC_INGRESS,
                              &attachments->ingress_opts,
                              &attachments->tc_ingress_attached,
                              attachments->tc_ingress_program_id);
    detach_tc_filter_if_owned(attachments, BPF_TC_EGRESS,
                              &attachments->egress_opts,
                              &attachments->tc_egress_attached,
                              attachments->tc_egress_program_id);
}

void cleanup_attachments(Attachments *attachments, unsigned int ifindex,
                         int xdp_mode)
{
    if (attachments->xdp_attached) {
        bpf_xdp_attach_opts detach_opts = {};
        detach_opts.sz = sizeof(detach_opts);
        detach_opts.old_prog_fd = attachments->xdp_program_fd;
        const int detach_err =
            bpf_xdp_detach(static_cast<int>(ifindex), xdp_mode, &detach_opts);
        if (detach_err == -EEXIST) {
            std::cerr << "Refusing to detach XDP program because ownership changed "
                      << "(expected id " << attachments->xdp_program_id << ")\n";
        } else if (detach_err) {
            std::cerr << "Failed to detach owned XDP program: "
                      << strerror(-detach_err) << "\n";
        }
        attachments->xdp_attached = false;
        attachments->xdp_program_fd = -1;
        attachments->xdp_program_id = 0;
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
    if (err && err != -EEXIST) {
        std::cerr << "Failed to create clsact qdisc: " << strerror(-err)
                  << "\n";
        return false;
    }
    return true;
}

bool attach_tc_filter(Attachments *attachments, bpf_program *program,
                      enum bpf_tc_attach_point attach_point, __u32 handle,
                      __u32 priority, bool *attached,
                      __u32 *attached_program_id)
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

    __u32 program_id = 0;
    const char *label = attach_point == BPF_TC_INGRESS ? "ingress tc" : "egress tc";
    if (!read_program_id(opts->prog_fd, &program_id, label))
        return false;

    int err = bpf_tc_attach(&attachments->hook, opts);
    if (err) {
        std::cerr << "Failed to attach "
                  << (attach_point == BPF_TC_INGRESS ? "ingress" : "egress")
                  << " tc program: " << strerror(-err) << "\n";
        return false;
    }
    *attached_program_id = program_id;
    *attached = true;
    return true;
}

bool attach_xdp_program(Attachments *attachments, unsigned int ifindex,
                        bpf_program *program, int xdp_mode,
                        const std::string &mode, const char *label)
{
    __u32 expected_program_id = 0;
    if (!read_program_id(bpf_program__fd(program), &expected_program_id, label))
        return false;

    const int err = bpf_xdp_attach(static_cast<int>(ifindex),
                                   bpf_program__fd(program),
                                   xdp_mode | XDP_FLAGS_UPDATE_IF_NOEXIST,
                                   nullptr);
    if (err) {
        std::cerr << "Failed to attach " << label << " XDP program in " << mode
                  << " mode: " << strerror(-err) << "\n";
        return false;
    }

    attachments->xdp_attached = true;
    attachments->xdp_program_fd = bpf_program__fd(program);
    attachments->xdp_program_id = expected_program_id;
    __u32 current_program_id = 0;
    const int query_err = bpf_xdp_query_id(static_cast<int>(ifindex), xdp_mode,
                                           &current_program_id);
    if (query_err) {
        std::cerr << "Failed to verify ownership of " << label
                  << " XDP program: " << strerror(-query_err) << "\n";
        return false;
    }
    if (current_program_id != expected_program_id) {
        std::cerr << "Attached " << label
                  << " XDP program has an unexpected ID (expected "
                  << expected_program_id << ", found " << current_program_id
                  << ")\n";
        return false;
    }
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

bool pin_map(bpf_object *obj, const std::string &pin_dir,
             const char *object_name, const char *pin_name)
{
    bpf_map *map = bpf_object__find_map_by_name(obj, object_name);
    if (!map) {
        std::cerr << "Failed to find " << object_name << " map\n";
        return false;
    }

    const std::string pin_path = pin_dir + "/" + pin_name;
    unlink(pin_path.c_str());
    const int err = bpf_map__pin(map, pin_path.c_str());
    if (err) {
        std::cerr << "Failed to pin " << object_name << " at " << pin_path << ": "
                  << strerror(-err) << "\n";
        return false;
    }
    std::cout << "Pinned " << object_name << " at " << pin_path << "\n";
    return true;
}

bool pin_dns_maps(bpf_object *obj, const Options &options)
{
    if (options.pin_dir.empty())
        return true;
    if (mkdir(options.pin_dir.c_str(), 0755) != 0 && errno != EEXIST) {
        std::cerr << "Failed to create pin dir " << options.pin_dir << ": "
                  << strerror(errno) << "\n";
        return false;
    }

    const char *cache_name =
        options.role == "client" ? "dns_client_cache" : "dns_cache";
    return pin_map(obj, options.pin_dir, "cache_rt_ctl",
                   "cache_runtime_control") &&
           pin_map(obj, options.pin_dir, "dns_cache_stats",
                   "dns_cache_stats") &&
           pin_map(obj, options.pin_dir, cache_name, "dns_cache_entries");
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
    if (options.hook == "xdp" &&
        !pin_dns_maps(obj, options)) {
        bpf_object__close(obj);
        return 1;
    }

    const int xdp_mode = xdp_mode_flags(options.xdp_mode);
    Attachments attachments;
    if (options.hook == "tc") {
        if (!ensure_tc_hook(&attachments, ifindex) ||
            !attach_tc_filter(&attachments, ingress_prog, BPF_TC_INGRESS, 1, 1,
                              &attachments.tc_ingress_attached,
                              &attachments.tc_ingress_program_id) ||
            !attach_tc_filter(&attachments, egress_prog, BPF_TC_EGRESS, 1, 1,
                              &attachments.tc_egress_attached,
                              &attachments.tc_egress_program_id)) {
            cleanup_attachments(&attachments, ifindex, xdp_mode);
            bpf_object__close(obj);
            return 1;
        }
    } else if (options.role == "client") {
        constexpr DnsClientTcAttachPlan tc_plan =
            dns_client_tc_attach_plan();
        if (!ensure_tc_hook(&attachments, ifindex) ||
            !attach_tc_filter(&attachments, egress_prog, BPF_TC_INGRESS,
                              tc_plan.ingress_handle,
                              tc_plan.ingress_priority,
                              &attachments.tc_ingress_attached,
                              &attachments.tc_ingress_program_id) ||
            !attach_tc_filter(&attachments, egress_prog, BPF_TC_EGRESS,
                              tc_plan.egress_handle,
                              tc_plan.egress_priority,
                              &attachments.tc_egress_attached,
                              &attachments.tc_egress_program_id)) {
            cleanup_attachments(&attachments, ifindex, xdp_mode);
            bpf_object__close(obj);
            return 1;
        }
        if (!attach_xdp_program(&attachments, ifindex, xdp_prog, xdp_mode,
                                options.xdp_mode, "client")) {
            cleanup_attachments(&attachments, ifindex, xdp_mode);
            bpf_object__close(obj);
            return 1;
        }
    } else {
        if (!attach_xdp_program(&attachments, ifindex, xdp_prog, xdp_mode,
                                options.xdp_mode, "server")) {
            cleanup_attachments(&attachments, ifindex, xdp_mode);
            bpf_object__close(obj);
            return 1;
        }
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
    state.last_cache_policy_bypass = read_percpu_counter_total(
        state.cache_stats_fd, DNS_CACHE_STAT_POLICY_BYPASS);
    state.last_cache_shadow_hit = read_percpu_counter_total(
        state.cache_stats_fd, DNS_CACHE_STAT_SHADOW_HIT);
    state.last_cache_shadow_miss = read_percpu_counter_total(
        state.cache_stats_fd, DNS_CACHE_STAT_SHADOW_MISS);

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
