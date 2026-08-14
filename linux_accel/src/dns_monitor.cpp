#include "dns_monitor.hpp"
#include "xdp_dispatcher.h"

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
    unsigned int ifindex = 0;
    std::string ifname;
    std::string interface_stable_id;
    bool interface_feed_target = false;
    bpf_tc_hook hook = {};
    bpf_tc_opts ingress_opts = {};
    bpf_tc_opts egress_opts = {};
    int xdp_prog_fd = -1;
    __u32 xdp_prog_id = 0;
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

void cleanup_attachments(Attachments *attachments, int xdp_mode)
{
    if (attachments->xdp_attached) {
        bpf_xdp_attach_opts opts = {};
        opts.sz = sizeof(opts);
        opts.old_prog_fd = attachments->xdp_prog_fd;
        int err = bpf_xdp_detach(static_cast<int>(attachments->ifindex),
                                 xdp_mode, &opts);
        if (err && err != -ENOENT && err != -ENODEV)
            std::cerr << "Refusing to detach a different XDP program: "
                      << strerror(-err) << "\n";
        attachments->xdp_prog_fd = -1;
        attachments->xdp_prog_id = 0;
        attachments->xdp_attached = false;
    }
    cleanup_tc(attachments);
}

bool same_interface_targets(const std::vector<InterfaceTarget> &left,
                            const std::vector<InterfaceTarget> &right)
{
    if (left.size() != right.size())
        return false;
    for (size_t index = 0; index < left.size(); ++index) {
        if (!(left[index] == right[index]))
            return false;
    }
    return true;
}

bool record_xdp_program_id(Attachments *attachments)
{
    bpf_prog_info info = {};
    __u32 info_len = sizeof(info);

    if (bpf_obj_get_info_by_fd(attachments->xdp_prog_fd, &info, &info_len) != 0) {
        std::cerr << "Failed to read attached XDP program id: "
                  << strerror(errno) << "\n";
        return false;
    }

    attachments->xdp_prog_id = info.id;
    std::cout << "xdp_program_id=" << info.id << std::endl;
    return true;
}

bool ensure_tc_hook(Attachments *attachments, unsigned int ifindex)
{
    attachments->ifindex = ifindex;
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
                  << " qtype=" << entry.qtype << " " << entry.ip
                  << " ttl=" << entry.ttl << "\n";
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
    config.detailed_events = options.detailed_events ? 1u : 0u;
    if (bpf_map_update_elem(bpf_map__fd(config_map), &key, &config, BPF_ANY) !=
        0) {
        std::cerr << "Failed to install client DNS cache config: "
                  << strerror(errno) << "\n";
        return false;
    }
    return true;
}

bool install_server_config(bpf_object *obj, const Options &options)
{
    bpf_map *config_map =
        bpf_object__find_map_by_name(obj, "dns_server_config");
    if (!config_map) {
        std::cerr << "Failed to find server DNS cache config map\n";
        return false;
    }

    __u32 key = 0;
    dns_server_config config = {};
    config.detailed_events = options.detailed_events ? 1u : 0u;
    if (bpf_map_update_elem(bpf_map__fd(config_map), &key, &config, BPF_ANY) !=
        0) {
        std::cerr << "Failed to install server DNS cache config: "
                  << strerror(errno) << "\n";
        return false;
    }
    return true;
}

bool configure_xdp_dispatcher(bpf_object *dispatcher_obj,
                              bpf_program *dns_program,
                              bpf_program *udp_program,
                              const Options &options)
{
    bpf_map *programs_map =
        bpf_object__find_map_by_name(dispatcher_obj, "xdp_dispatch_progs");
    bpf_map *config_map =
        bpf_object__find_map_by_name(dispatcher_obj, "xdp_dispatch_config");
    if (!programs_map || !config_map) {
        std::cerr << "Failed to find XDP dispatcher maps\n";
        return false;
    }

    __u32 dns_fd = static_cast<__u32>(bpf_program__fd(dns_program));
    __u32 udp_fd = static_cast<__u32>(bpf_program__fd(udp_program));
    __u32 dns_slot = XDP_DISPATCH_DNS_SLOT;
    __u32 udp_slot = XDP_DISPATCH_UDP_SLOT;
    if (bpf_map_update_elem(bpf_map__fd(programs_map), &dns_slot, &dns_fd,
                            BPF_ANY) != 0 ||
        bpf_map_update_elem(bpf_map__fd(programs_map), &udp_slot, &udp_fd,
                            BPF_ANY) != 0) {
        std::cerr << "Failed to install XDP dispatcher tail-call targets: "
                  << strerror(errno) << "\n";
        return false;
    }

    __u32 config_key = 0;
    xdp_dispatch_config config = {};
    config.dns_slot = XDP_DISPATCH_DNS_SLOT;
    config.udp_slot = XDP_DISPATCH_UDP_SLOT;
    config.role = options.role == "client" ? XDP_DISPATCH_ROLE_CLIENT
                                             : XDP_DISPATCH_ROLE_SERVER;
    if (bpf_map_update_elem(bpf_map__fd(config_map), &config_key, &config,
                            BPF_ANY) != 0) {
        std::cerr << "Failed to install XDP dispatcher config: "
                  << strerror(errno) << "\n";
        return false;
    }
    return true;
}

void print_udp_fastpath_stats(int stats_fd)
{
    if (stats_fd < 0)
        return;
    std::cout << "udp_fastpath"
              << " request="
              << read_percpu_counter_total(stats_fd,
                                            UDP_FASTPATH_STAT_REQUEST)
              << " hit="
              << read_percpu_counter_total(stats_fd, UDP_FASTPATH_STAT_HIT)
              << " miss="
              << read_percpu_counter_total(stats_fd, UDP_FASTPATH_STAT_MISS)
              << " expired="
              << read_percpu_counter_total(stats_fd,
                                            UDP_FASTPATH_STAT_EXPIRED)
              << " unsupported="
              << read_percpu_counter_total(stats_fd,
                                            UDP_FASTPATH_STAT_UNSUPPORTED)
              << " malformed="
              << read_percpu_counter_total(stats_fd,
                                            UDP_FASTPATH_STAT_MALFORMED)
              << " tx="
              << read_percpu_counter_total(stats_fd, UDP_FASTPATH_STAT_TX)
              << " adjust_fail="
              << read_percpu_counter_total(stats_fd,
                                            UDP_FASTPATH_STAT_ADJUST_FAIL)
              << "\n";
}

bool same_policy_vectors(const std::vector<TapArpPolicy> &left,
                         const std::vector<TapArpPolicy> &right)
{
    if (left.size() != right.size())
        return false;
    for (size_t i = 0; i < left.size(); ++i) {
        if (left[i].tap_ifname != right[i].tap_ifname ||
            left[i].bindings.size() != right[i].bindings.size())
            return false;
        for (size_t j = 0; j < left[i].bindings.size(); ++j) {
            const ArpBindingSpec &lhs = left[i].bindings[j];
            const ArpBindingSpec &rhs = right[i].bindings[j];
            if (lhs.target_ipv4 != rhs.target_ipv4 ||
                lhs.target_mac != rhs.target_mac ||
                lhs.lease_seconds != rhs.lease_seconds)
                return false;
        }
    }
    return true;
}

bool wait_for_initial_policy(PolicyFeedServer *feed,
                             PolicyReconciler *reconciler, int timeout_ms,
                             std::string *error)
{
    if (!feed || !reconciler || timeout_ms <= 0) {
        if (error)
            *error = "invalid policy feed startup arguments";
        return false;
    }

    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::milliseconds(timeout_ms);
    while (!exiting && std::chrono::steady_clock::now() < deadline) {
        std::vector<PolicyFeedEvent> events;
        std::string poll_error;
        int count = feed->Poll(&events, &poll_error);
        if (count < 0) {
            if (error)
                *error = poll_error.empty() ? "policy feed poll failed"
                                             : poll_error;
            return false;
        }
        if (!poll_error.empty())
            std::cerr << "Ignoring malformed policy feed message: "
                      << poll_error << "\n";
        for (const PolicyFeedEvent &event : events) {
            std::string apply_error;
            bool applied = event.operation ==
                                   PolicyFeedOperation::ReplaceSnapshot
                               ? reconciler->ApplySnapshot(event.snapshot,
                                                           &apply_error)
                               : reconciler->WithdrawSource(event.owner,
                                                             event.revision,
                                                             &apply_error);
            if (!applied) {
                std::cerr << "Ignoring policy feed update during startup: "
                          << apply_error << "\n";
                continue;
            }
            if (!reconciler->empty())
                return true;
        }
        usleep(20 * 1000);
    }

    if (error)
        *error = "timed out waiting for a non-empty ARP policy feed snapshot";
    return false;
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) {
        print_usage(argv[0]);
        return 1;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    std::unique_ptr<PolicyFeedServer> policy_feed;
    PolicyReconciler policy_reconciler;
    if (!options.arp_policy_feed.empty()) {
        std::string feed_error;
        policy_feed = PolicyFeedServer::Create(options.arp_policy_feed,
                                                options.arp_policy_feed_uid,
                                                &feed_error);
        if (!policy_feed) {
            std::cerr << "Failed to create ARP policy feed: " << feed_error
                      << "\n";
            return 1;
        }
    }

    std::unique_ptr<InterfaceFeedServer> interface_feed;
    InterfaceReconciler interface_reconciler;
    if (!options.interface_feed.empty()) {
        std::string feed_error;
        interface_feed = InterfaceFeedServer::Create(
            options.interface_feed, options.interface_feed_uid, &feed_error);
        if (!interface_feed) {
            std::cerr << "Failed to create interface feed: " << feed_error
                      << "\n";
            return 1;
        }
    }

    if (!options.arp_policies.empty()) {
        PolicySnapshot static_snapshot;
        static_snapshot.owner = {"local", "policy-file"};
        static_snapshot.revision = 1;
        static_snapshot.lease_seconds = 0;
        static_snapshot.persistent = true;
        static_snapshot.policies = options.arp_policies;
        std::string policy_error;
        if (!policy_reconciler.ApplySnapshot(static_snapshot, &policy_error)) {
            std::cerr << "Failed to load static ARP policy into reconciler: "
                      << policy_error << "\n";
            return 1;
        }
    }
    if (policy_feed && options.ifname.empty() && policy_reconciler.empty()) {
        std::string feed_error;
        if (!wait_for_initial_policy(policy_feed.get(), &policy_reconciler,
                                     options.arp_feed_startup_timeout_ms,
                                     &feed_error)) {
            std::cerr << "Failed to receive initial ARP policy feed snapshot: "
                      << feed_error << "\n";
            return 1;
        }
    }
    options.arp_policies = policy_reconciler.merged_policies();

    std::vector<unsigned int> ifindices;
    std::vector<std::string> ifnames;
    auto add_interface = [&](const std::string &ifname) {
        if (ifname.empty())
            return true;
        unsigned int ifindex = if_nametoindex(ifname.c_str());
        if (!ifindex) {
            std::cerr << "Failed to resolve interface " << ifname << ": "
                      << strerror(errno) << "\n";
            return false;
        }
        for (unsigned int existing : ifindices) {
            if (existing == ifindex)
                return true;
        }
        ifindices.push_back(ifindex);
        ifnames.push_back(ifname);
        return true;
    };

    for (const TapArpPolicy &policy : options.arp_policies) {
        if (!add_interface(policy.tap_ifname))
            return 1;
    }
    for (const DhcpRelayPolicySpec &policy : options.dhcp_policies) {
        if (!add_interface(policy.client_ifname) ||
            !add_interface(policy.relay_ifname))
            return 1;
    }
    for (const UdpFastpathPolicyEntry &policy : options.udp_policies) {
        if (!add_interface(policy.ifname))
            return 1;
    }
    if (!add_interface(options.ifname))
        return 1;
    if (ifindices.empty() && !interface_feed) {
        std::cerr << "No interface was selected for attachment\n";
        return 1;
    }

    libbpf_set_strict_mode(LIBBPF_STRICT_ALL);

    bpf_object *obj = bpf_object__open_file(options.bpf_object.c_str(), nullptr);
    if (!obj) {
        std::cerr << "Failed to open BPF object: " << options.bpf_object << "\n";
        return 1;
    }

    bpf_object *dispatcher_obj = nullptr;
    bpf_object *udp_obj = nullptr;
    auto close_aux_objects = [&]() {
        if (udp_obj) {
            bpf_object__close(udp_obj);
            udp_obj = nullptr;
        }
        if (dispatcher_obj) {
            bpf_object__close(dispatcher_obj);
            dispatcher_obj = nullptr;
        }
    };

    bpf_program *ingress_prog = nullptr;
    bpf_program *egress_prog = nullptr;
    bpf_program *xdp_prog = nullptr;
    bpf_program *dispatcher_prog = nullptr;
    bpf_program *udp_prog = nullptr;
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

    if (options.merge_xdp) {
        dispatcher_obj = bpf_object__open_file(
            options.xdp_dispatcher_object.c_str(), nullptr);
        udp_obj = bpf_object__open_file(options.udp_bpf_object.c_str(), nullptr);
        if (!dispatcher_obj || !udp_obj) {
            std::cerr << "Failed to open merged XDP objects: dispatcher="
                      << options.xdp_dispatcher_object
                      << " udp=" << options.udp_bpf_object << "\n";
            close_aux_objects();
            bpf_object__close(obj);
            return 1;
        }
        dispatcher_prog = bpf_object__find_program_by_name(
            dispatcher_obj, "xdp_dispatcher");
        udp_prog =
            bpf_object__find_program_by_name(udp_obj, "udp_fastpath_xdp");
        if (!dispatcher_prog || !udp_prog) {
            std::cerr << "Merged XDP objects are missing dispatcher or UDP program\n";
            close_aux_objects();
            bpf_object__close(obj);
            return 1;
        }
        bpf_program__set_type(dispatcher_prog, BPF_PROG_TYPE_XDP);
        bpf_program__set_type(udp_prog, BPF_PROG_TYPE_XDP);
    }

    int err = bpf_object__load(obj);
    if (err) {
        std::cerr << "Failed to load BPF object: " << strerror(-err) << "\n";
        close_aux_objects();
        bpf_object__close(obj);
        return 1;
    }

    if (options.merge_xdp) {
        err = bpf_object__load(udp_obj);
        if (err) {
            std::cerr << "Failed to load UDP fast-path BPF object: "
                      << strerror(-err) << "\n";
            close_aux_objects();
            bpf_object__close(obj);
            return 1;
        }
        err = bpf_object__load(dispatcher_obj);
        if (err) {
            std::cerr << "Failed to load XDP dispatcher BPF object: "
                      << strerror(-err) << "\n";
            close_aux_objects();
            bpf_object__close(obj);
            return 1;
        }
    }

    if (options.hook == "xdp" && options.role == "server" &&
        (!install_dns_cache(obj, options) ||
         !install_server_config(obj, options))) {
        close_aux_objects();
        bpf_object__close(obj);
        return 1;
    }
    if (options.hook == "xdp" && options.role == "client" &&
        !install_client_config(obj, options)) {
        close_aux_objects();
        bpf_object__close(obj);
        return 1;
    }

    int udp_entry_fd = -1;
    int udp_stats_fd = -1;
    if (options.merge_xdp) {
        bpf_map *entry_map =
            bpf_object__find_map_by_name(udp_obj, "udp_fastpath_entries");
        bpf_map *stats_map =
            bpf_object__find_map_by_name(udp_obj, "udp_fastpath_stats");
        if (!entry_map || !stats_map) {
            std::cerr << "Merged UDP object is missing policy or stats maps\n";
            close_aux_objects();
            bpf_object__close(obj);
            return 1;
        }
        udp_entry_fd = bpf_map__fd(entry_map);
        udp_stats_fd = bpf_map__fd(stats_map);
        std::string udp_error;
        if (!install_udp_fastpath_entries(udp_entry_fd, options.udp_policies,
                                           udp_fastpath_now_ns(),
                                           &udp_error)) {
            std::cerr << udp_error << "\n";
            close_aux_objects();
            bpf_object__close(obj);
            return 1;
        }
        if (!configure_xdp_dispatcher(dispatcher_obj, xdp_prog, udp_prog,
                                       options)) {
            close_aux_objects();
            bpf_object__close(obj);
            return 1;
        }
    }

    std::unique_ptr<DhcpRelayControl> dhcp_control;
    if (!options.dhcp_policies.empty()) {
        std::string dhcp_error;
        dhcp_control = DhcpRelayControl::Create(obj, options.dhcp_policies,
                                                &dhcp_error);
        if (!dhcp_control) {
            std::cerr << "Failed to install DHCP relay policy: "
                      << dhcp_error << "\n";
            close_aux_objects();
            bpf_object__close(obj);
            return 1;
        }
    }

    std::unique_ptr<ArpProxyControl> arp_control;
    if (!options.arp_policies.empty() || policy_feed) {
        std::string arp_error;
        arp_control = ArpProxyControl::Create(obj, options.arp_policies,
                                              &arp_error);
        if (!arp_control) {
            std::cerr << "Failed to install ARP policy: " << arp_error << "\n";
            close_aux_objects();
            bpf_object__close(obj);
            return 1;
        }
    }

    const int xdp_mode = xdp_mode_flags(options.xdp_mode);
    std::vector<Attachments> attachments;
    auto cleanup_all = [&]() {
        for (Attachments &attachment : attachments)
            cleanup_attachments(&attachment, xdp_mode);
    };

    auto attach_interface = [&](unsigned int ifindex,
                                const std::string &ifname,
                                const std::string &stable_id) {
        for (const Attachments &existing : attachments) {
            if (existing.ifindex != ifindex)
                continue;
            if (!stable_id.empty() &&
                (!existing.interface_feed_target ||
                 existing.interface_stable_id != stable_id)) {
                std::cerr << "Refusing to share interface " << ifname
                          << " between interface-feed targets\n";
                return false;
            }
            return true;
        }

        Attachments attachment = {};
        attachment.ifindex = ifindex;
        attachment.ifname = ifname;
        attachment.interface_feed_target = !stable_id.empty();
        attachment.interface_stable_id = stable_id;
        bpf_program *xdp_attach_prog = xdp_prog;
        if (options.merge_xdp) {
            for (const UdpFastpathPolicyEntry &policy : options.udp_policies) {
                if (policy.ifindex == ifindex) {
                    xdp_attach_prog = dispatcher_prog;
                    break;
                }
            }
        }
        if (options.hook == "tc") {
            if (!ensure_tc_hook(&attachment, ifindex) ||
                !attach_tc_filter(&attachment, ingress_prog, BPF_TC_INGRESS, 1,
                                  1, &attachment.tc_ingress_attached) ||
                !attach_tc_filter(&attachment, egress_prog, BPF_TC_EGRESS, 1,
                                  1, &attachment.tc_egress_attached)) {
                cleanup_attachments(&attachment, xdp_mode);
                return false;
            }
        } else if (options.role == "client") {
            if (!ensure_tc_hook(&attachment, ifindex) ||
                !attach_tc_filter(&attachment, egress_prog, BPF_TC_EGRESS, 100,
                                  100, &attachment.tc_egress_attached)) {
                cleanup_attachments(&attachment, xdp_mode);
                return false;
            }
            int attach_err = bpf_xdp_attach(static_cast<int>(ifindex),
                                 bpf_program__fd(xdp_attach_prog),
                                 xdp_mode | XDP_FLAGS_UPDATE_IF_NOEXIST,
                                 nullptr);
            if (attach_err) {
                std::cerr << "Failed to attach client XDP program on "
                          << ifname << " in " << options.xdp_mode
                          << " mode: " << strerror(-attach_err) << "\n";
                cleanup_attachments(&attachment, xdp_mode);
                return false;
            }
            attachment.xdp_prog_fd = bpf_program__fd(xdp_attach_prog);
            attachment.xdp_attached = true;
        } else {
            int attach_err = bpf_xdp_attach(static_cast<int>(ifindex),
                                 bpf_program__fd(xdp_attach_prog),
                                 xdp_mode | XDP_FLAGS_UPDATE_IF_NOEXIST,
                                 nullptr);
            if (attach_err) {
                std::cerr << "Failed to attach XDP program on " << ifname
                          << " in " << options.xdp_mode << " mode: "
                          << strerror(-attach_err) << "\n";
                cleanup_attachments(&attachment, xdp_mode);
                return false;
            }
            attachment.xdp_prog_fd = bpf_program__fd(xdp_attach_prog);
            attachment.xdp_attached = true;
        }

        if (attachment.xdp_attached && !record_xdp_program_id(&attachment)) {
            cleanup_attachments(&attachment, xdp_mode);
            return false;
        }
        attachments.push_back(std::move(attachment));
        bool known_interface = false;
        for (unsigned int known : ifindices) {
            if (known == ifindex) {
                known_interface = true;
                break;
            }
        }
        if (!known_interface) {
            ifindices.push_back(ifindex);
            ifnames.push_back(ifname);
        }
        return true;
    };

    auto detach_interface = [&](unsigned int ifindex) {
        for (size_t index = 0; index < attachments.size(); ++index) {
            if (attachments[index].ifindex != ifindex)
                continue;
            cleanup_attachments(&attachments[index], xdp_mode);
            attachments.erase(attachments.begin() +
                             static_cast<ptrdiff_t>(index));
            return;
        }
    };

    auto reconcile_interface_targets =
        [&](const std::vector<InterfaceTarget> &desired) {
            // Remove feed-owned targets first.  This also handles a deleted
            // veth or an ifname reused by a new Pod: stable_id must match
            // before an existing attachment can be retained.
            for (size_t index = 0; index < attachments.size();) {
                Attachments &attachment = attachments[index];
                if (!attachment.interface_feed_target) {
                    ++index;
                    continue;
                }

                bool keep = false;
                for (const InterfaceTarget &target : desired) {
                    if (target.ifname != attachment.ifname ||
                        target.stable_id != attachment.interface_stable_id)
                        continue;
                    unsigned int current_ifindex =
                        if_nametoindex(target.ifname.c_str());
                    keep = current_ifindex == attachment.ifindex;
                    break;
                }
                if (keep) {
                    ++index;
                    continue;
                }
                const unsigned int ifindex = attachment.ifindex;
                detach_interface(ifindex);
            }

            for (const InterfaceTarget &target : desired) {
                unsigned int ifindex = if_nametoindex(target.ifname.c_str());
                if (!ifindex) {
                    std::cerr << "Interface feed target is not present: "
                              << target.ifname << " (" << target.stable_id
                              << ")\n";
                    return false;
                }

                bool present = false;
                for (const Attachments &attachment : attachments) {
                    if (attachment.ifindex != ifindex)
                        continue;
                    if (!attachment.interface_feed_target ||
                        attachment.interface_stable_id != target.stable_id) {
                        std::cerr << "Interface feed target collides with an "
                                     "existing attachment on "
                                  << target.ifname << "\n";
                        return false;
                    }
                    present = true;
                    break;
                }
                if (!present &&
                    !attach_interface(ifindex, target.ifname,
                                      target.stable_id))
                    return false;
            }
            return true;
        };

    const unsigned int explicit_ifindex = options.ifname.empty()
                                              ? 0
                                              : if_nametoindex(options.ifname.c_str());
    for (size_t i = 0; i < ifindices.size(); ++i) {
        if (!attach_interface(ifindices[i], ifnames[i], {})) {
            cleanup_all();
            arp_control.reset();
            close_aux_objects();
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
        arp_control.reset();
        cleanup_all();
        close_aux_objects();
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
    state.last_cache_unsupported = read_percpu_counter_total(
        state.cache_stats_fd, DNS_CACHE_STAT_UNSUPPORTED);
    state.last_cache_egress_no_pending = read_percpu_counter_total(
        state.cache_stats_fd, DNS_CACHE_STAT_EGRESS_NO_PENDING);

    ring_buffer *ring =
        ring_buffer__new(bpf_map__fd(events_map), handle_dns_event, &state, nullptr);
    if (!ring) {
        std::cerr << "Failed to create ring buffer\n";
        arp_control.reset();
        cleanup_all();
        close_aux_objects();
        bpf_object__close(obj);
        return 1;
    }

    auto reconcile_attached_policy =
        [&](const std::vector<TapArpPolicy> &previous,
            const std::vector<TapArpPolicy> &desired) {
            if (!arp_control)
                return desired.empty();

            std::vector<unsigned int> added_ifindices;
            std::vector<unsigned int> removed_ifindices;
            std::string arp_error;
            if (!arp_control->Reconcile(desired, &added_ifindices,
                                         &removed_ifindices, &arp_error)) {
                std::cerr << "Failed to reconcile ARP policy maps: "
                          << arp_error << "\n";
                return false;
            }

            std::vector<unsigned int> attached_dynamically;
            for (unsigned int ifindex : added_ifindices) {
                if (ifindex == explicit_ifindex)
                    continue;
                char ifname_buffer[IF_NAMESIZE] = {};
                if (!if_indextoname(ifindex, ifname_buffer)) {
                    std::cerr << "Failed to resolve newly added ARP interface "
                              << ifindex << ": " << strerror(errno) << "\n";
                    for (unsigned int attached : attached_dynamically)
                        detach_interface(attached);
                    std::vector<unsigned int> rollback_added;
                    std::vector<unsigned int> rollback_removed;
                    std::string rollback_error;
                    arp_control->Reconcile(previous, &rollback_added,
                                           &rollback_removed, &rollback_error);
                    return false;
                }
                if (!attach_interface(ifindex, ifname_buffer, {})) {
                    for (unsigned int attached : attached_dynamically)
                        detach_interface(attached);
                    std::vector<unsigned int> rollback_added;
                    std::vector<unsigned int> rollback_removed;
                    std::string rollback_error;
                    if (!arp_control->Reconcile(previous, &rollback_added,
                                                &rollback_removed,
                                                &rollback_error)) {
                        std::cerr << "Fatal: failed to roll back ARP policy "
                                  << "after attachment failure: "
                                  << rollback_error << "\n";
                    }
                    return false;
                }
                attached_dynamically.push_back(ifindex);
            }
            for (unsigned int ifindex : removed_ifindices) {
                if (ifindex != explicit_ifindex)
                    detach_interface(ifindex);
            }
            return true;
        };

    auto apply_policy_feed_event = [&](const PolicyFeedEvent &event) {
        PolicyReconciler before = policy_reconciler;
        std::string policy_error;
        bool applied = event.operation == PolicyFeedOperation::ReplaceSnapshot
                           ? policy_reconciler.ApplySnapshot(event.snapshot,
                                                             &policy_error)
                           : policy_reconciler.WithdrawSource(event.owner,
                                                               event.revision,
                                                               &policy_error);
        if (!applied) {
            std::cerr << "Ignoring ARP policy feed update: " << policy_error
                      << "\n";
            return true;
        }
        if (same_policy_vectors(before.merged_policies(),
                                policy_reconciler.merged_policies()))
            return true;
        if (reconcile_attached_policy(before.merged_policies(),
                                      policy_reconciler.merged_policies()))
            return true;

        policy_reconciler = before;
        std::vector<unsigned int> rollback_added;
        std::vector<unsigned int> rollback_removed;
        std::string rollback_error;
        if (!arp_control->Reconcile(before.merged_policies(), &rollback_added,
                                    &rollback_removed, &rollback_error)) {
            std::cerr << "Fatal: failed to restore previous ARP policy: "
                      << rollback_error << "\n";
            exiting = 1;
        }
        return false;
    };

    auto apply_interface_feed_event = [&](const InterfaceFeedEvent &event) {
        InterfaceReconciler before = interface_reconciler;
        std::string feed_error;
        bool applied =
            event.operation == InterfaceFeedOperation::ReplaceSnapshot
                ? interface_reconciler.ApplySnapshot(event.snapshot,
                                                      &feed_error)
                : interface_reconciler.WithdrawSource(event.owner,
                                                       event.revision,
                                                       &feed_error);
        if (!applied) {
            std::cerr << "Ignoring interface feed update: " << feed_error
                      << "\n";
            return true;
        }
        if (same_interface_targets(before.merged_targets(),
                                   interface_reconciler.merged_targets()))
            return true;
        if (reconcile_interface_targets(interface_reconciler.merged_targets()))
            return true;

        // A veth may disappear between the adapter's netlink lookup and this
        // process's if_nametoindex call.  Keep the old attachment state and
        // let the adapter's next revision/lease heartbeat retry it.
        interface_reconciler = before;
        return false;
    };

    std::cout << "Listening for DNS metrics on ";
    for (size_t i = 0; i < ifnames.size(); ++i) {
        if (i)
            std::cout << ",";
        std::cout << ifnames[i];
    }
    std::cout << " role=" << options.role << " with " << options.hook;
    if (options.hook == "xdp")
        std::cout << "/" << options.xdp_mode;
    if (arp_control)
        std::cout << " arp-policy-taps=" << arp_control->ifindices().size();
    if (interface_feed)
        std::cout << " interface-feed=enabled";
    if (dhcp_control)
        std::cout << " dhcp-relay-policies=" << dhcp_control->policy_count();
    std::cout << ". Press Ctrl-C to stop.\n";

    auto next_report = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    auto next_arp_renew = std::chrono::steady_clock::now() +
                          std::chrono::seconds(10);
    auto next_dhcp_renew = std::chrono::steady_clock::now() +
                           std::chrono::seconds(10);
    auto next_udp_renew = std::chrono::steady_clock::now() +
                          std::chrono::seconds(1);
    auto next_policy_expire = std::chrono::steady_clock::now() +
                              std::chrono::seconds(1);
    auto next_interface_expire = std::chrono::steady_clock::now() +
                                 std::chrono::seconds(1);
    while (!exiting) {
        err = ring_buffer__poll(ring, 100);
        if (err == -EINTR)
            break;
        if (err < 0) {
            std::cerr << "ring_buffer__poll failed: " << strerror(-err) << "\n";
            break;
        }

        if (policy_feed) {
            std::vector<PolicyFeedEvent> policy_events;
            std::string feed_error;
            int feed_count = policy_feed->Poll(&policy_events, &feed_error);
            if (feed_count < 0) {
                std::cerr << "ARP policy feed poll failed: " << feed_error
                          << "\n";
                break;
            }
            if (!feed_error.empty())
                std::cerr << "Ignoring malformed ARP policy feed message: "
                          << feed_error << "\n";
            for (const PolicyFeedEvent &event : policy_events)
                apply_policy_feed_event(event);
        }

        if (interface_feed) {
            std::vector<InterfaceFeedEvent> interface_events;
            std::string feed_error;
            int feed_count =
                interface_feed->Poll(&interface_events, &feed_error);
            if (feed_count < 0) {
                std::cerr << "Interface feed poll failed: " << feed_error
                          << "\n";
                break;
            }
            if (!feed_error.empty())
                std::cerr << "Ignoring malformed interface feed message: "
                          << feed_error << "\n";
            for (const InterfaceFeedEvent &event : interface_events)
                apply_interface_feed_event(event);
        }

        auto now = std::chrono::steady_clock::now();
        if (policy_feed && now >= next_policy_expire) {
            PolicyReconciler before = policy_reconciler;
            std::string policy_error;
            if (!policy_reconciler.Expire(policy_monotonic_now_ns(),
                                          &policy_error)) {
                std::cerr << "ARP policy expiry reconciliation failed: "
                          << policy_error << "\n";
                policy_reconciler = before;
            } else if (!same_policy_vectors(before.merged_policies(),
                                            policy_reconciler.merged_policies()) &&
                       !reconcile_attached_policy(
                           before.merged_policies(),
                           policy_reconciler.merged_policies())) {
                policy_reconciler = before;
                std::vector<unsigned int> rollback_added;
                std::vector<unsigned int> rollback_removed;
                std::string rollback_error;
                if (!arp_control->Reconcile(before.merged_policies(),
                                            &rollback_added,
                                            &rollback_removed,
                                            &rollback_error)) {
                    std::cerr << "Fatal: failed to restore ARP policy after "
                              << "expiry reconciliation failure: "
                              << rollback_error << "\n";
                    exiting = 1;
                }
            }
            next_policy_expire = now + std::chrono::seconds(1);
        }
        if (interface_feed && now >= next_interface_expire) {
            InterfaceReconciler before = interface_reconciler;
            std::string feed_error;
            if (!interface_reconciler.Expire(interface_feed_monotonic_now_ns(),
                                              &feed_error)) {
                std::cerr << "Interface feed expiry reconciliation failed: "
                          << feed_error << "\n";
                interface_reconciler = before;
            } else if (!same_interface_targets(
                           before.merged_targets(),
                           interface_reconciler.merged_targets()) &&
                       !reconcile_interface_targets(
                           interface_reconciler.merged_targets())) {
                interface_reconciler = before;
            }
            next_interface_expire = now + std::chrono::seconds(1);
        }
        if (arp_control && now >= next_arp_renew) {
            std::string arp_error;
            if (!arp_control->RenewAll(&arp_error))
                std::cerr << "ARP policy renewal failed: " << arp_error
                          << " (policy will fail open when its lease expires)\n";
            next_arp_renew = now + std::chrono::seconds(10);
        }
        if (dhcp_control && now >= next_dhcp_renew) {
            std::string dhcp_error;
            if (!dhcp_control->RenewAll(&dhcp_error))
                std::cerr << "DHCP relay policy renewal failed: "
                          << dhcp_error
                          << " (policy will fail open when its lease expires)\n";
            next_dhcp_renew = now + std::chrono::seconds(10);
        }
        if (options.merge_xdp && now >= next_udp_renew) {
            std::string udp_error;
            if (!install_udp_fastpath_entries(udp_entry_fd,
                                               options.udp_policies,
                                               udp_fastpath_now_ns(),
                                               &udp_error)) {
                std::cerr << "UDP fast-path lease renewal failed: "
                          << udp_error
                          << " (entries will fail open when they expire)\n";
            }
            next_udp_renew = now + std::chrono::seconds(1);
        }
        if (now >= next_report) {
            print_metrics(&state);
            print_udp_fastpath_stats(udp_stats_fd);
            if (arp_control) {
                ArpProxyStats stats = arp_control->ReadStats();
                std::cout << "arp_proxy request=" << stats.request
                          << " tx=" << stats.tx
                          << " tap_miss=" << stats.tap_miss
                          << " binding_miss=" << stats.binding_miss
                          << " wrong_generation=" << stats.wrong_generation
                          << " expired=" << stats.expired
                          << " source_invalid=" << stats.source_invalid
                          << " format_invalid=" << stats.format_invalid
                          << " binding_invalid=" << stats.binding_invalid
                          << "\n";
            }
            if (dhcp_control) {
                DhcpRelayStats stats = dhcp_control->ReadStats();
                std::cout << "dhcp_relay request=" << stats.request
                          << " response=" << stats.response
                          << " redirect=" << stats.redirect
                          << " policy_miss=" << stats.policy_miss
                          << " transaction_miss=" << stats.transaction_miss
                          << " transaction_expired="
                          << stats.transaction_expired
                          << " transaction_update_fail="
                          << stats.transaction_update_fail
                          << " format_invalid=" << stats.format_invalid
                          << " unsupported=" << stats.unsupported
                          << " policy_expired=" << stats.policy_expired
                          << "\n";
            }
            next_report = now + std::chrono::seconds(1);
        }
    }

    print_metrics(&state);
    print_udp_fastpath_stats(udp_stats_fd);
    ring_buffer__free(ring);
    if (arp_control) {
        ArpProxyStats stats = arp_control->ReadStats();
        std::cout << "arp_proxy request=" << stats.request
                  << " tx=" << stats.tx << " tap_miss=" << stats.tap_miss
                  << " binding_miss=" << stats.binding_miss
                  << " wrong_generation=" << stats.wrong_generation
                  << " expired=" << stats.expired
                  << " source_invalid=" << stats.source_invalid
                  << " format_invalid=" << stats.format_invalid
                  << " binding_invalid=" << stats.binding_invalid << "\n";
        arp_control.reset();
    }
    if (dhcp_control) {
        DhcpRelayStats stats = dhcp_control->ReadStats();
        std::cout << "dhcp_relay request=" << stats.request
                  << " response=" << stats.response
                  << " redirect=" << stats.redirect
                  << " policy_miss=" << stats.policy_miss
                  << " transaction_miss=" << stats.transaction_miss
                  << " transaction_expired=" << stats.transaction_expired
                  << " transaction_update_fail="
                  << stats.transaction_update_fail
                  << " format_invalid=" << stats.format_invalid
                  << " unsupported=" << stats.unsupported
                  << " policy_expired=" << stats.policy_expired << "\n";
        dhcp_control.reset();
    }
    cleanup_all();
    close_aux_objects();
    bpf_object__close(obj);
    return 0;
}
