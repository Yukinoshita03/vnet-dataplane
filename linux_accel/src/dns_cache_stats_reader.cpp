#include "dns_event.h"

#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <linux/bpf.h>
#include <string.h>
#include <unistd.h>

#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

namespace {

bool read_counter(int map_fd, uint32_t key, int cpu_count, uint64_t *total)
{
    std::vector<uint64_t> values(static_cast<size_t>(cpu_count));
    if (bpf_map_lookup_elem(map_fd, &key, values.data()) != 0)
        return false;
    *total = 0;
    for (uint64_t value : values)
        *total += value;
    return true;
}

} // namespace

int main(int argc, char **argv)
{
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0]
                  << " <pinned-dns-cache-stats-map>\n";
        return 1;
    }

    const std::string path = argv[1];
    const int map_fd = bpf_obj_get(path.c_str());
    if (map_fd < 0) {
        std::cerr << "Failed to open " << path << ": "
                  << strerror(errno) << "\n";
        return 1;
    }

    bpf_map_info info = {};
    uint32_t info_len = sizeof(info);
    if (bpf_obj_get_info_by_fd(map_fd, &info, &info_len) != 0 ||
        info.type != BPF_MAP_TYPE_PERCPU_ARRAY ||
        info.key_size != sizeof(uint32_t) ||
        info.value_size != sizeof(uint64_t) ||
        info.max_entries < DNS_CACHE_STAT_COUNT) {
        std::cerr << "Incompatible DNS cache stats map: " << path << "\n";
        close(map_fd);
        return 1;
    }

    const int cpu_count = libbpf_num_possible_cpus();
    if (cpu_count <= 0) {
        std::cerr << "Failed to determine possible CPU count\n";
        close(map_fd);
        return 1;
    }

    const char *names[DNS_CACHE_STAT_COUNT] = {
        "cache_hit",
        "cache_miss",
        "cache_expired",
        "cache_tx",
        "cache_learned",
        "learn_rejected",
        "pending_expired",
        "policy_bypass",
        "shadow_hit",
        "shadow_miss",
    };
    for (uint32_t key = 0; key < DNS_CACHE_STAT_COUNT; ++key) {
        uint64_t total = 0;
        if (!read_counter(map_fd, key, cpu_count, &total)) {
            std::cerr << "Failed to read counter " << key << ": "
                      << strerror(errno) << "\n";
            close(map_fd);
            return 1;
        }
        if (key)
            std::cout << " ";
        std::cout << names[key] << "=" << total;
    }
    std::cout << "\n";
    close(map_fd);
    return 0;
}
