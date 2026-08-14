#include "udp_fastpath_policy.hpp"

#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <linux/if_link.h>
#include <net/if.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <iostream>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace {

volatile sig_atomic_t exiting = 0;

struct Options {
    std::string bpf_object = "build/udp_fastpath.bpf.o";
    std::string policy_file;
    std::string xdp_mode = "native";
    bool validate_only = false;
};

struct Attachment {
    unsigned int ifindex = 0;
    std::string ifname;
};

void handle_signal(int)
{
    exiting = 1;
}

void print_usage(const char *program)
{
    std::cerr
        << "Usage: " << program
        << " --policy-file <path> [--bpf-object <path>]"
        << " [--xdp-mode native|generic] [--validate-only]\n\n"
        << "Policy format:\n"
        << "  ifname server_ipv4 server_port request_hex response_hex lease_seconds\n"
        << "Use '-' for an empty request or response payload.\n";
}

bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--policy-file" && i + 1 < argc) {
            options->policy_file = argv[++i];
        } else if (arg == "--bpf-object" && i + 1 < argc) {
            options->bpf_object = argv[++i];
        } else if (arg == "--xdp-mode" && i + 1 < argc) {
            options->xdp_mode = argv[++i];
        } else if (arg == "--validate-only") {
            options->validate_only = true;
        } else if (arg == "-h" || arg == "--help") {
            return false;
        } else {
            std::cerr << "Unknown or incomplete option: " << arg << "\n";
            return false;
        }
    }
    if (options->policy_file.empty())
        return false;
    if (options->xdp_mode != "native" && options->xdp_mode != "generic") {
        std::cerr << "Unsupported XDP mode: " << options->xdp_mode << "\n";
        return false;
    }
    return true;
}

uint64_t read_percpu_counter(int map_fd, __u32 key)
{
    int cpus = libbpf_num_possible_cpus();
    if (cpus <= 0)
        return 0;
    std::vector<__u64> values(static_cast<size_t>(cpus));
    if (bpf_map_lookup_elem(map_fd, &key, values.data()) != 0)
        return 0;
    uint64_t total = 0;
    for (__u64 value : values)
        total += value;
    return total;
}

void print_stats(int stats_fd)
{
    std::cout
        << "udp_fastpath"
        << " request=" << read_percpu_counter(stats_fd, UDP_FASTPATH_STAT_REQUEST)
        << " hit=" << read_percpu_counter(stats_fd, UDP_FASTPATH_STAT_HIT)
        << " miss=" << read_percpu_counter(stats_fd, UDP_FASTPATH_STAT_MISS)
        << " expired=" << read_percpu_counter(stats_fd, UDP_FASTPATH_STAT_EXPIRED)
        << " unsupported="
        << read_percpu_counter(stats_fd, UDP_FASTPATH_STAT_UNSUPPORTED)
        << " malformed="
        << read_percpu_counter(stats_fd, UDP_FASTPATH_STAT_MALFORMED)
        << " tx=" << read_percpu_counter(stats_fd, UDP_FASTPATH_STAT_TX)
        << " adjust_fail="
        << read_percpu_counter(stats_fd, UDP_FASTPATH_STAT_ADJUST_FAIL)
        << std::endl;
}

int xdp_mode_flags(const std::string &mode)
{
    return mode == "generic" ? XDP_FLAGS_SKB_MODE : XDP_FLAGS_DRV_MODE;
}

void detach_all(const std::vector<Attachment> &attachments, int mode_flags,
                int program_fd)
{
    for (auto it = attachments.rbegin(); it != attachments.rend(); ++it) {
        bpf_xdp_attach_opts opts = {};
        opts.sz = sizeof(opts);
        opts.old_prog_fd = program_fd;
        int error = bpf_xdp_detach(static_cast<int>(it->ifindex), mode_flags,
                                   &opts);
        if (error && error != -ENOENT) {
            std::cerr << "Refusing to detach a different program from "
                      << it->ifname << ": " << strerror(-error) << "\n";
        }
    }
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) {
        print_usage(argv[0]);
        return 1;
    }

    std::vector<UdpFastpathPolicyEntry> entries;
    std::string error;
    if (!parse_udp_fastpath_policy_file(options.policy_file, &entries, &error)) {
        std::cerr << error << "\n";
        return 1;
    }
    if (options.validate_only) {
        std::cout << "UDP policy valid entries=" << entries.size() << "\n";
        return 0;
    }

    libbpf_set_strict_mode(LIBBPF_STRICT_ALL);
    bpf_object *object = bpf_object__open_file(options.bpf_object.c_str(), nullptr);
    if (!object) {
        std::cerr << "failed to open BPF object " << options.bpf_object << "\n";
        return 1;
    }
    bpf_program *program =
        bpf_object__find_program_by_name(object, "udp_fastpath_xdp");
    bpf_map *entry_map =
        bpf_object__find_map_by_name(object, "udp_fastpath_entries");
    bpf_map *stats_map =
        bpf_object__find_map_by_name(object, "udp_fastpath_stats");
    if (!program || !entry_map || !stats_map) {
        std::cerr << "BPF object is missing UDP fast-path programs or maps\n";
        bpf_object__close(object);
        return 1;
    }
    if (bpf_map__key_size(entry_map) != sizeof(struct udp_fastpath_key) ||
        bpf_map__value_size(entry_map) != sizeof(struct udp_fastpath_value)) {
        std::cerr << "UDP fast-path ABI mismatch: object key/value="
                  << bpf_map__key_size(entry_map) << "/"
                  << bpf_map__value_size(entry_map)
                  << " loader key/value=" << sizeof(struct udp_fastpath_key)
                  << "/" << sizeof(struct udp_fastpath_value) << "\n";
        bpf_object__close(object);
        return 1;
    }
    bpf_program__set_type(program, BPF_PROG_TYPE_XDP);
    int load_error = bpf_object__load(object);
    if (load_error != 0) {
        std::cerr << "failed to load UDP fast-path BPF object: "
                  << strerror(-load_error) << "\n";
        bpf_object__close(object);
        return 1;
    }

    int entry_fd = bpf_map__fd(entry_map);
    int stats_fd = bpf_map__fd(stats_map);
    int program_fd = bpf_program__fd(program);
    if (!install_udp_fastpath_entries(entry_fd, entries,
                                      udp_fastpath_now_ns(), &error)) {
        std::cerr << error << "\n";
        bpf_object__close(object);
        return 1;
    }

    std::vector<Attachment> attachments;
    std::set<unsigned int> attached_ifindices;
    int mode_flags = xdp_mode_flags(options.xdp_mode);
    for (const UdpFastpathPolicyEntry &entry : entries) {
        if (!attached_ifindices.insert(entry.ifindex).second)
            continue;
        int attach_error = bpf_xdp_attach(
            static_cast<int>(entry.ifindex), program_fd,
            mode_flags | XDP_FLAGS_UPDATE_IF_NOEXIST, nullptr);
        if (attach_error) {
            std::cerr << "failed to attach " << options.xdp_mode << " XDP to "
                      << entry.ifname << ": " << strerror(-attach_error) << "\n";
            detach_all(attachments, mode_flags, program_fd);
            bpf_object__close(object);
            return 1;
        }
        attachments.push_back({entry.ifindex, entry.ifname});
        std::cout << "udp_fastpath attached dev=" << entry.ifname
                  << " ifindex=" << entry.ifindex
                  << " mode=" << options.xdp_mode << "\n";
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    auto next_renew = std::chrono::steady_clock::now() +
                      std::chrono::seconds(1);
    auto next_report = next_renew;
    int exit_code = 0;
    while (!exiting) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        auto now = std::chrono::steady_clock::now();
        if (now >= next_renew) {
            if (!install_udp_fastpath_entries(entry_fd, entries,
                                              udp_fastpath_now_ns(), &error)) {
                std::cerr << "UDP lease renewal failed: " << error << "\n";
                exit_code = 1;
                break;
            }
            next_renew = now + std::chrono::seconds(1);
        }
        if (now >= next_report) {
            print_stats(stats_fd);
            next_report = now + std::chrono::seconds(1);
        }
    }

    print_stats(stats_fd);
    detach_all(attachments, mode_flags, program_fd);
    bpf_object__close(object);
    return exit_code;
}
