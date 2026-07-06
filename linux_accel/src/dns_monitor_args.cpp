#include "dns_monitor.hpp"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

bool parse_int(const std::string &value, int *out)
{
    char *end = nullptr;
    long parsed = std::strtol(value.c_str(), &end, 10);
    if (!end || *end != '\0' || parsed <= 0)
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
              << " --dev <ifname> [--bpf-object <path>]"
              << " [--hook tc|xdp] [--xdp-mode native|generic]"
              << " [--cache-domain <name> --cache-ip <ipv4> [--cache-ttl <sec>]]"
              << " [--cache-file <path>]"
              << " [--timeout-ms <ms>] [--verbose-events]"
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
        } else if (arg == "--hook" && i + 1 < argc) {
            options->hook = argv[++i];
            if (options->hook != "tc" && options->hook != "xdp")
                return false;
            if (options->hook == "xdp" &&
                options->bpf_object == "build/dns_monitor.bpf.o") {
                options->bpf_object = "build/dns_xdp_monitor.bpf.o";
            }
        } else if (arg == "--xdp-mode" && i + 1 < argc) {
            options->xdp_mode = argv[++i];
            if (options->xdp_mode != "native" && options->xdp_mode != "generic")
                return false;
        } else if (arg == "--cache-domain" && i + 1 < argc) {
            options->cache_domain = argv[++i];
        } else if (arg == "--cache-ip" && i + 1 < argc) {
            options->cache_ip = argv[++i];
        } else if (arg == "--cache-file" && i + 1 < argc) {
            options->cache_file = argv[++i];
        } else if (arg == "--cache-ttl" && i + 1 < argc) {
            if (!parse_int(argv[++i], &options->cache_ttl))
                return false;
        } else if (arg == "--timeout-ms" && i + 1 < argc) {
            if (!parse_int(argv[++i], &options->timeout_ms))
                return false;
        } else if (arg == "--verbose-events") {
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

    if (options->ifname.empty())
        return false;
    if (options->cache_domain.empty() != options->cache_ip.empty()) {
        std::cerr << "--cache-domain and --cache-ip must be used together\n";
        return false;
    }
    if ((!options->cache_domain.empty() || !options->cache_file.empty()) &&
        options->hook != "xdp") {
        std::cerr << "DNS cache injection is only supported with --hook xdp\n";
        return false;
    }
    return true;
}
