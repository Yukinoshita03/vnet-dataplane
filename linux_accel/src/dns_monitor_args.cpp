#include "dns_monitor.hpp"

#include <climits>
#include <cerrno>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

bool parse_int(const std::string &value, int *out)
{
    errno = 0;
    char *end = nullptr;
    long parsed = std::strtol(value.c_str(), &end, 10);
    if (errno == ERANGE || !end || *end != '\0' || parsed <= 0 ||
        parsed > INT_MAX)
        return false;
    *out = static_cast<int>(parsed);
    return true;
}

bool parse_nonnegative_int(const std::string &value, int *out)
{
    errno = 0;
    char *end = nullptr;
    long parsed = std::strtol(value.c_str(), &end, 10);
    if (errno == ERANGE || !end || *end != '\0' || parsed < 0 ||
        parsed > INT_MAX)
        return false;
    *out = static_cast<int>(parsed);
    return true;
}

bool parse_double(const std::string &value, double *out)
{
    char *end = nullptr;
    double parsed = std::strtod(value.c_str(), &end);
    if (!end || *end != '\0' || parsed <= 0.0)
        return false;
    *out = parsed;
    return true;
}

} // namespace

void print_usage(const char *program)
{
    std::cerr << "Usage: " << program
              << " [--dev <ifname>] [--bpf-object <path>]"
              << " [--xdp-dispatcher-object <path>]"
              << " [--udp-bpf-object <path>]"
              << " [--hook tc|xdp] [--xdp-mode native|generic]"
              << " [--role server|client]"
              << " [--merge-xdp --udp-policy-file <path>]"
              << " [--arp-policy-file <path> [--arp-lease-seconds <sec>]]"
              << " [--arp-policy-feed <socket> [--arp-policy-feed-uid <uid>]"
              << " [--arp-feed-startup-timeout-ms <ms>]]"
              << " [--interface-feed <socket> [--interface-feed-uid <uid>]]"
              << " [--dhcp-policy-file <path>]"
              << " [--cache-domain <name> --cache-ip <ipv4> [--cache-ttl <sec>]]"
              << " [--cache-file <path>]"
              << " [--trusted-dns <ipv4>] [--max-learn-ttl <sec>]"
              << " [--learn-window-ms <ms>]"
              << " [--timeout-ms <ms>] [--detailed-events] [--verbose-events]"
              << " [--qps-spike-factor <n>] [--latency-spike-factor <n>]\n";
}

bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--dev" && i + 1 < argc) {
            options->ifname = argv[++i];
        } else if (arg == "--bpf-object" && i + 1 < argc) {
            options->bpf_object = argv[++i];
        } else if (arg == "--xdp-dispatcher-object" && i + 1 < argc) {
            options->xdp_dispatcher_object = argv[++i];
        } else if (arg == "--udp-bpf-object" && i + 1 < argc) {
            options->udp_bpf_object = argv[++i];
        } else if (arg == "--hook" && i + 1 < argc) {
            options->hook = argv[++i];
            if (options->hook != "tc" && options->hook != "xdp")
                return false;
        } else if (arg == "--role" && i + 1 < argc) {
            options->role = argv[++i];
            if (options->role != "server" && options->role != "client")
                return false;
        } else if (arg == "--xdp-mode" && i + 1 < argc) {
            options->xdp_mode = argv[++i];
            if (options->xdp_mode != "native" && options->xdp_mode != "generic")
                return false;
        } else if (arg == "--merge-xdp") {
            options->merge_xdp = true;
        } else if (arg == "--udp-policy-file" && i + 1 < argc) {
            options->udp_policy_file = argv[++i];
        } else if (arg == "--cache-domain" && i + 1 < argc) {
            options->cache_domain = argv[++i];
        } else if (arg == "--cache-ip" && i + 1 < argc) {
            options->cache_ip = argv[++i];
        } else if (arg == "--cache-file" && i + 1 < argc) {
            options->cache_file = argv[++i];
        } else if (arg == "--arp-policy-file" && i + 1 < argc) {
            options->arp_policy_file = argv[++i];
        } else if (arg == "--arp-policy-feed" && i + 1 < argc) {
            options->arp_policy_feed = argv[++i];
        } else if (arg == "--interface-feed" && i + 1 < argc) {
            options->interface_feed = argv[++i];
        } else if (arg == "--dhcp-policy-file" && i + 1 < argc) {
            options->dhcp_policy_file = argv[++i];
        } else if (arg == "--arp-policy-feed-uid" && i + 1 < argc) {
            if (!parse_nonnegative_int(argv[++i],
                                       &options->arp_policy_feed_uid))
                return false;
        } else if (arg == "--interface-feed-uid" && i + 1 < argc) {
            if (!parse_nonnegative_int(argv[++i],
                                       &options->interface_feed_uid))
                return false;
        } else if (arg == "--arp-feed-startup-timeout-ms" && i + 1 < argc) {
            if (!parse_int(argv[++i], &options->arp_feed_startup_timeout_ms))
                return false;
        } else if (arg == "--arp-lease-seconds" && i + 1 < argc) {
            if (!parse_int(argv[++i], &options->arp_lease_seconds) ||
                options->arp_lease_seconds > 24 * 60 * 60)
                return false;
        } else if (arg == "--trusted-dns" && i + 1 < argc) {
            options->trusted_dns.emplace_back(argv[++i]);
        } else if (arg == "--cache-ttl" && i + 1 < argc) {
            if (!parse_int(argv[++i], &options->cache_ttl))
                return false;
        } else if (arg == "--max-learn-ttl" && i + 1 < argc) {
            if (!parse_int(argv[++i], &options->max_learn_ttl))
                return false;
        } else if (arg == "--learn-window-ms" && i + 1 < argc) {
            if (!parse_int(argv[++i], &options->learn_window_ms))
                return false;
        } else if (arg == "--timeout-ms" && i + 1 < argc) {
            if (!parse_int(argv[++i], &options->timeout_ms))
                return false;
        } else if (arg == "--detailed-events") {
            options->detailed_events = true;
        } else if (arg == "--verbose-events") {
            // Verbose printing requires the event stream to be enabled too.
            options->detailed_events = true;
            options->verbose_events = true;
        } else if (arg == "--qps-spike-factor" && i + 1 < argc) {
            if (!parse_double(argv[++i], &options->qps_spike_factor))
                return false;
        } else if (arg == "--latency-spike-factor" && i + 1 < argc) {
            if (!parse_double(argv[++i], &options->latency_spike_factor))
                return false;
        } else if (arg == "-h" || arg == "--help") {
            return false;
        } else {
            std::cerr << "Unknown or incomplete option: " << arg << "\n";
            return false;
        }
    }

    if (options->ifname.empty() && options->arp_policy_file.empty() &&
        options->arp_policy_feed.empty() && options->dhcp_policy_file.empty() &&
        options->udp_policy_file.empty() && options->interface_feed.empty())
        return false;
    if (options->merge_xdp && options->hook != "xdp") {
        std::cerr << "--merge-xdp requires --hook xdp\n";
        return false;
    }
    if (!options->udp_policy_file.empty()) {
        if (options->hook != "xdp") {
            std::cerr << "UDP policy merge requires --hook xdp\n";
            return false;
        }
        std::string error;
        if (!parse_udp_fastpath_policy_file(options->udp_policy_file,
                                            &options->udp_policies, &error)) {
            std::cerr << error << "\n";
            return false;
        }
        /* A UDP policy is the explicit request to compose the same-interface
         * XDP path. The standalone udp_fastpath loader remains available for
         * an interface that is not owned by dns_monitor. */
        options->merge_xdp = true;
    }
    if (options->merge_xdp && options->udp_policy_file.empty()) {
        std::cerr << "--merge-xdp requires --udp-policy-file\n";
        return false;
    }
    if (options->merge_xdp && !options->ifname.empty()) {
        for (const UdpFastpathPolicyEntry &policy : options->udp_policies) {
            if (policy.ifname != options->ifname) {
                std::cerr << "UDP policy interface " << policy.ifname
                          << " differs from --dev " << options->ifname
                          << "; keep different-NIC XDP hooks separate\n";
                return false;
            }
        }
    }
    if (!options->arp_policy_file.empty()) {
        if (options->hook != "xdp") {
            std::cerr << "ARP proxy policy requires --hook xdp\n";
            return false;
        }
        std::string error;
        if (!parse_arp_policy_file(options->arp_policy_file,
                                   &options->arp_policies, &error)) {
            std::cerr << error << "\n";
            return false;
        }
        if (options->arp_lease_seconds > 0) {
            for (TapArpPolicy &policy : options->arp_policies) {
                for (ArpBindingSpec &binding : policy.bindings)
                    binding.lease_seconds =
                        static_cast<unsigned>(options->arp_lease_seconds);
            }
        }
    } else if (options->arp_lease_seconds > 0) {
        std::cerr << "--arp-lease-seconds requires --arp-policy-file\n";
        return false;
    }
    if (!options->arp_policy_feed.empty() && options->hook != "xdp") {
        std::cerr << "ARP policy feed requires --hook xdp\n";
        return false;
    }
    if (options->arp_policy_feed.empty() &&
        options->arp_policy_feed_uid >= 0) {
        std::cerr << "--arp-policy-feed-uid requires --arp-policy-feed\n";
        return false;
    }
    if (options->interface_feed.empty() && options->interface_feed_uid >= 0) {
        std::cerr << "--interface-feed-uid requires --interface-feed\n";
        return false;
    }
    if (!options->dhcp_policy_file.empty()) {
        if (options->hook != "xdp" || options->role != "server") {
            std::cerr << "DHCP relay policy requires --hook xdp --role server\n";
            return false;
        }
        std::string error;
        if (!parse_dhcp_relay_policy_file(options->dhcp_policy_file,
                                          &options->dhcp_policies, &error)) {
            std::cerr << error << "\n";
            return false;
        }
    }
    if (options->cache_domain.empty() != options->cache_ip.empty()) {
        std::cerr << "--cache-domain and --cache-ip must be used together\n";
        return false;
    }
    if ((!options->cache_domain.empty() || !options->cache_file.empty()) &&
        options->hook != "xdp") {
        std::cerr << "DNS cache injection is only supported with --hook xdp\n";
        return false;
    }
    if (options->role == "client" && options->hook != "xdp") {
        std::cerr << "--role client requires --hook xdp\n";
        return false;
    }
    if (options->role == "client" && options->trusted_dns.empty()) {
        std::cerr << "--role client requires at least one --trusted-dns\n";
        return false;
    }
    if (options->role == "client" &&
        (!options->cache_domain.empty() || !options->cache_file.empty())) {
        std::cerr << "client cache learns responses and does not accept static cache entries\n";
        return false;
    }
    if (options->role != "client" && !options->trusted_dns.empty()) {
        std::cerr << "--trusted-dns is only supported with --role client\n";
        return false;
    }

    if (options->bpf_object.empty()) {
        if (options->hook == "tc")
            options->bpf_object = "build/dns_monitor.bpf.o";
        else if (options->role == "client")
            options->bpf_object = "build/dns_client_cache.bpf.o";
        else
            options->bpf_object = "build/dns_xdp_monitor.bpf.o";
    }
    if (options->merge_xdp) {
        if (options->xdp_dispatcher_object.empty())
            options->xdp_dispatcher_object = "build/xdp_dispatcher.bpf.o";
        if (options->udp_bpf_object.empty())
            options->udp_bpf_object = "build/udp_fastpath.bpf.o";
    }
    return true;
}
