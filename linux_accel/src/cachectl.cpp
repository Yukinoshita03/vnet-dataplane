#include "cache_policy.hpp"
#include "dns_cache_config.hpp"
#include "grpc_event.h"

#include <bpf/bpf.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

#include <iostream>
#include <string>
#include <vector>

namespace {

struct Options {
    std::string cache_file;
    std::string policy_file;
    std::string map_path;
    std::string grpc_map_path;
    bool validate_only = false;
};

void print_usage(const char *program)
{
    std::cerr << "Usage: " << program
              << " --dns-cache-file <path> [--dns-map <pinned-map-path>]"
              << " | --policy-file <path> [--dns-map <pinned-map-path>]"
              << " [--grpc-map <pinned-map-path>]"
              << " [--validate-only]\n";
}

bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--dns-cache-file" && i + 1 < argc) {
            options->cache_file = argv[++i];
        } else if (arg == "--policy-file" && i + 1 < argc) {
            options->policy_file = argv[++i];
        } else if (arg == "--dns-map" && i + 1 < argc) {
            options->map_path = argv[++i];
        } else if (arg == "--grpc-map" && i + 1 < argc) {
            options->grpc_map_path = argv[++i];
        } else if (arg == "--validate-only") {
            options->validate_only = true;
        } else if (arg == "-h" || arg == "--help") {
            return false;
        } else {
            std::cerr << "Unknown or incomplete option: " << arg << "\n";
            return false;
        }
    }

    if (options->cache_file.empty() == options->policy_file.empty()) {
        std::cerr << "Use exactly one of --dns-cache-file or --policy-file\n";
        return false;
    }
    if (!options->validate_only && options->map_path.empty() && options->grpc_map_path.empty()) {
        std::cerr << "at least one of --dns-map or --grpc-map is required unless --validate-only is set\n";
        return false;
    }
    if (!options->cache_file.empty() && !options->grpc_map_path.empty()) {
        std::cerr << "--grpc-map requires --policy-file\n";
        return false;
    }
    return true;
}


bool install_grpc_policy_entries(int map_fd,
                                 const std::vector<GrpcPolicyEntry> &entries,
                                 std::string *error)
{
    for (const GrpcPolicyEntry &entry : entries) {
        grpc_policy_key key = {entry.method_hash};
        grpc_policy_value value = {};
        value.ttl = static_cast<__u32>(entry.ttl);
        value.idempotent = entry.idempotent ? 1 : 0;
        if (bpf_map_update_elem(map_fd, &key, &value, BPF_ANY) != 0) {
            if (error) {
                *error = std::string("failed to update grpc_policy_map: ") +
                         strerror(errno);
            }
            return false;
        }
        std::cout << "Installed gRPC policy entry " << entry.method
                  << " hash=" << entry.method_hash
                  << " ttl=" << entry.ttl << "\n";
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

    std::vector<DnsCacheEntry> entries;
    CachePolicy policy;
    std::string error;
    if (!options.cache_file.empty()) {
        if (!parse_dns_cache_file(options.cache_file, &entries, &error)) {
            std::cerr << error << "\n";
            return 1;
        }
    } else {
        if (!parse_cache_policy_file(options.policy_file, &policy, &error)) {
            std::cerr << error << "\n";
            return 1;
        }
        entries = policy.dns_entries;
    }

    if (options.validate_only) {
        if (!options.cache_file.empty()) {
            std::cout << "Validated DNS cache file " << options.cache_file
                      << " entries=" << entries.size() << "\n";
        } else {
            std::cout << "Validated cache policy file " << options.policy_file
                      << " dns_entries=" << policy.dns_entries.size()
                      << " grpc_entries=" << policy.grpc_entries.size()
                      << " grpc_cache_entries="
                      << policy.grpc_cache_entries.size() << "\n";
        }
        return 0;
    }

        int cache_fd = -1;
    int grpc_fd = -1;

    if (!options.map_path.empty()) {
        cache_fd = bpf_obj_get(options.map_path.c_str());
        if (cache_fd < 0) {
            std::cerr << "Failed to open pinned DNS cache map " << options.map_path
                      << ": " << strerror(errno) << "\n";
            return 1;
        }

        for (const DnsCacheEntry &entry : entries) {
            if (!install_dns_cache_entry(cache_fd, entry, &error)) {
                std::cerr << error << "\n";
                close(cache_fd);
                return 1;
            }
            std::cout << "Installed DNS cache entry " << entry.domain
                      << " A " << entry.ip
                      << " ttl=" << entry.ttl << "\n";
        }
        close(cache_fd);
        std::cout << "Installed DNS cache entries=" << entries.size() << "\n";
    }

    if (!options.grpc_map_path.empty()) {
        grpc_fd = bpf_obj_get(options.grpc_map_path.c_str());
        if (grpc_fd < 0) {
            std::cerr << "Failed to open pinned gRPC policy map "
                      << options.grpc_map_path << ": " << strerror(errno) << "\n";
            return 1;
        }
        if (!install_grpc_policy_entries(grpc_fd, policy.grpc_entries, &error)) {
            std::cerr << error << "\n";
            close(grpc_fd);
            return 1;
        }
        close(grpc_fd);
        std::cout << "Installed gRPC policy entries="
                  << policy.grpc_entries.size() << "\n";
    }

    if (options.map_path.empty() && options.grpc_map_path.empty()) {
        std::cout << "No maps selected\n";
    }
    return 0;
}

