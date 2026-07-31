#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace cache_policy_txn {

inline bool has_prefix(std::string_view value, std::string_view prefix)
{
    return value.size() >= prefix.size() &&
           value.compare(0, prefix.size(), prefix) == 0;
}

inline bool parse_clean_absolute_path(
    std::string_view path, std::vector<std::string_view> *components)
{
    if (path.size() < 2 || path.front() != '/' || path.back() == '/')
        return false;
    components->clear();
    size_t start = 1;
    while (start < path.size()) {
        const size_t separator = path.find('/', start);
        const size_t end = separator == std::string_view::npos
                               ? path.size()
                               : separator;
        const std::string_view component = path.substr(start, end - start);
        if (component.empty() || component == "." || component == "..")
            return false;
        components->push_back(component);
        if (separator == std::string_view::npos)
            break;
        start = separator + 1;
    }
    return !components->empty();
}

inline bool clean_path_below(std::string_view path, std::string_view root)
{
    std::vector<std::string_view> components;
    return parse_clean_absolute_path(path, &components) &&
           path.size() > root.size() && has_prefix(path, root) &&
           path[root.size()] == '/';
}

inline bool production_control_map_path(std::string_view path)
{
    constexpr std::string_view agent_root =
        "/sys/fs/bpf/vnet-dataplane-agent";
    constexpr std::string_view guest_root =
        "/sys/fs/bpf/vnet-dataplane-guest";
    return clean_path_below(path, agent_root) ||
           clean_path_below(path, guest_root);
}

inline bool validate_production_paths(
    const std::string &lock_file, const std::string &quiesce_file,
    const std::vector<std::string> &control_maps, std::string *error)
{
    constexpr std::string_view policy_root = "/run/vnet-dataplane-policy";
    if (!clean_path_below(lock_file, policy_root)) {
        *error = "lock file must be below /run/vnet-dataplane-policy";
        return false;
    }
    if (!clean_path_below(quiesce_file, policy_root)) {
        *error = "quiesce file must be below /run/vnet-dataplane-policy";
        return false;
    }
    for (const std::string &path : control_maps) {
        if (!production_control_map_path(path)) {
            *error = "control map must be a DNS or gRPC runtime map under a "
                     "production vnet-dataplane pin root: " +
                     path;
            return false;
        }
    }
    return true;
}

} // namespace cache_policy_txn
