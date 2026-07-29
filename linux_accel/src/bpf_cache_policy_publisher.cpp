#include "bpf_cache_policy_publisher.hpp"

#include "cache_runtime_control.h"

#include <bpf/bpf.h>
#include <errno.h>
#include <linux/bpf.h>
#include <string.h>
#include <unistd.h>

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace {

struct OpenMap {
    std::string path;
    int fd = -1;
    cache_runtime_control previous = {};
};

void close_maps(std::vector<OpenMap> *maps)
{
    for (OpenMap &map : *maps) {
        if (map.fd >= 0)
            close(map.fd);
        map.fd = -1;
    }
}

bool validate_map(int fd, const std::string &path, std::string *error)
{
    bpf_map_info info = {};
    uint32_t info_len = sizeof(info);
    if (bpf_obj_get_info_by_fd(fd, &info, &info_len) != 0) {
        *error = "inspect " + path + ": " + strerror(errno);
        return false;
    }
    if (info.key_size != sizeof(uint32_t) ||
        info.value_size != sizeof(cache_runtime_control) ||
        info.max_entries < 1) {
        *error = "incompatible runtime control map: " + path;
        return false;
    }
    return true;
}

bool rollback_maps(std::vector<OpenMap> *maps, size_t applied,
                   std::string *error)
{
    const uint32_t key = 0;
    bool ok = true;
    for (size_t i = 0; i < applied; ++i) {
        if (bpf_map_update_elem((*maps)[i].fd, &key, &(*maps)[i].previous,
                                BPF_ANY) != 0) {
            ok = false;
            if (error)
                *error += "; rollback " + (*maps)[i].path + ": " +
                          strerror(errno);
        }
    }
    return ok;
}

} // namespace

BpfCachePolicyPublisher::BpfCachePolicyPublisher(
    std::vector<std::string> map_paths)
    : map_paths_(std::move(map_paths))
{
}

bool BpfCachePolicyPublisher::publish(CacheMode mode, uint64_t epoch,
                                      std::string *error)
{
    if (map_paths_.empty()) {
        if (error)
            *error = "no runtime control maps";
        return false;
    }

    std::vector<OpenMap> maps;
    maps.reserve(map_paths_.size());
    const uint32_t key = 0;
    for (const std::string &path : map_paths_) {
        OpenMap map;
        map.path = path;
        map.fd = bpf_obj_get(path.c_str());
        if (map.fd < 0) {
            if (error)
                *error = "open " + path + ": " + strerror(errno);
            close_maps(&maps);
            return false;
        }
        if (!validate_map(map.fd, path, error)) {
            close(map.fd);
            close_maps(&maps);
            return false;
        }
        if (bpf_map_lookup_elem(map.fd, &key, &map.previous) != 0) {
            if (error)
                *error = "snapshot " + path + ": " + strerror(errno);
            close(map.fd);
            close_maps(&maps);
            return false;
        }
        maps.push_back(std::move(map));
    }

    cache_runtime_control next = {};
    next.epoch = epoch;
    next.mode = static_cast<uint32_t>(mode);
    next.flags = CACHE_RUNTIME_COMMITTED;

    size_t applied = 0;
    for (; applied < maps.size(); ++applied) {
        if (bpf_map_update_elem(maps[applied].fd, &key, &next, BPF_ANY) != 0) {
            if (error)
                *error = "publish " + maps[applied].path + ": " +
                         strerror(errno);
            rollback_maps(&maps, applied, error);
            close_maps(&maps);
            return false;
        }
    }

    for (const OpenMap &map : maps) {
        cache_runtime_control observed = {};
        if (bpf_map_lookup_elem(map.fd, &key, &observed) != 0 ||
            observed.epoch != next.epoch || observed.mode != next.mode ||
            observed.flags != next.flags) {
            if (error)
                *error = "verify " + map.path;
            rollback_maps(&maps, maps.size(), error);
            close_maps(&maps);
            return false;
        }
    }

    close_maps(&maps);
    return true;
}
