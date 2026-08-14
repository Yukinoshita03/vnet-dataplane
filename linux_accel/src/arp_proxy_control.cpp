#include "arp_proxy_control.hpp"

#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <net/if.h>
#include <stdint.h>
#include <string.h>

#include <array>
#include <chrono>
#include <cstdlib>
#include <cstdio>
#include <fstream>
#include <iomanip>
#include <limits>
#include <sstream>
#include <unordered_set>
#include <utility>

namespace {

constexpr unsigned kMinLeaseSeconds = 1;
constexpr unsigned kMaxLeaseSeconds = 24 * 60 * 60;

struct ParsedBinding {
    __be32 target_ipv4 = 0;
    std::array<__u8, 6> target_mac = {};
    unsigned lease_seconds = 0;
};

uint64_t monotonic_now_ns()
{
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

bool parse_lease(const std::string &text, unsigned *lease_seconds)
{
    if (text.empty() || text[0] == '-')
        return false;

    char *end = nullptr;
    unsigned long parsed = std::strtoul(text.c_str(), &end, 10);
    if (!end || *end != '\0' || parsed < kMinLeaseSeconds ||
        parsed > kMaxLeaseSeconds || parsed > std::numeric_limits<unsigned>::max())
        return false;
    *lease_seconds = static_cast<unsigned>(parsed);
    return true;
}

bool parse_ipv4(const std::string &text, __be32 *address)
{
    return inet_pton(AF_INET, text.c_str(), address) == 1;
}

bool parse_mac(const std::string &text, std::array<__u8, 6> *mac)
{
    unsigned int bytes[6] = {};
    char tail = '\0';
    if (std::sscanf(text.c_str(), "%2x:%2x:%2x:%2x:%2x:%2x%c", &bytes[0],
                    &bytes[1], &bytes[2], &bytes[3], &bytes[4], &bytes[5],
                    &tail) != 6)
        return false;

    for (size_t i = 0; i < mac->size(); ++i) {
        if (bytes[i] > 0xff)
            return false;
        (*mac)[i] = static_cast<__u8>(bytes[i]);
    }
    if ((*mac)[0] & 1)
        return false;
    bool all_zero = true;
    for (__u8 byte : *mac) {
        if (byte != 0)
            all_zero = false;
    }
    return !all_zero;
}

bool parse_binding(const ArpBindingSpec &spec, ParsedBinding *binding,
                   std::string *error)
{
    *binding = {};
    if (!parse_ipv4(spec.target_ipv4, &binding->target_ipv4)) {
        if (error)
            *error = "invalid ARP target IPv4 address: " + spec.target_ipv4;
        return false;
    }
    if (!parse_mac(spec.target_mac, &binding->target_mac)) {
        if (error)
            *error = "invalid ARP target MAC address: " + spec.target_mac;
        return false;
    }
    if (spec.lease_seconds < kMinLeaseSeconds ||
        spec.lease_seconds > kMaxLeaseSeconds) {
        if (error)
            *error = "ARP lease must be between " +
                     std::to_string(kMinLeaseSeconds) + " and " +
                     std::to_string(kMaxLeaseSeconds) + " seconds";
        return false;
    }
    binding->lease_seconds = spec.lease_seconds;
    return true;
}

bool validate_policy(const TapArpPolicy &policy, bool require_interface,
                     std::string *error)
{
    if (policy.tap_ifname.empty()) {
        if (error)
            *error = "ARP policy has an empty tap interface name";
        return false;
    }
    if (require_interface && if_nametoindex(policy.tap_ifname.c_str()) == 0) {
        if (error)
            *error = "ARP policy interface does not exist: " +
                     policy.tap_ifname;
        return false;
    }
    if (policy.bindings.empty()) {
        if (error)
            *error = "ARP policy has no bindings for " + policy.tap_ifname;
        return false;
    }

    std::unordered_set<uint32_t> targets;
    for (const ArpBindingSpec &spec : policy.bindings) {
        ParsedBinding binding;
        if (!parse_binding(spec, &binding, error))
            return false;
        uint32_t target = static_cast<uint32_t>(binding.target_ipv4);
        if (!targets.insert(target).second) {
            if (error)
                *error = "duplicate ARP target " + spec.target_ipv4 +
                         " on interface " + policy.tap_ifname;
            return false;
        }
    }
    return true;
}

bool same_target(const arp_binding_key &key, __be32 target_ipv4)
{
    return key.target_ipv4 == target_ipv4;
}

arp_binding_key make_binding_key(unsigned int ifindex, __be32 target_ipv4)
{
    arp_binding_key key = {};
    key.ifindex = ifindex;
    key.target_ipv4 = target_ipv4;
    return key;
}

arp_binding_value make_binding_value(const ParsedBinding &parsed,
                                     __u32 generation, uint64_t expires_ns)
{
    arp_binding_value value = {};
    memcpy(value.target_mac, parsed.target_mac.data(), parsed.target_mac.size());
    value.flags = ARP_BINDING_ENABLED;
    value.generation = generation;
    value.expires_ns = expires_ns;
    return value;
}

arp_tap_key make_tap_key(unsigned int ifindex)
{
    arp_tap_key key = {};
    key.ifindex = ifindex;
    return key;
}

arp_tap_state make_tap_state(__u32 generation, __u32 flags,
                             uint64_t expires_ns)
{
    arp_tap_state state = {};
    state.generation = generation;
    state.flags = flags;
    state.expires_ns = expires_ns;
    return state;
}

} // namespace

struct ArpProxyControl::TapRecord {
    TapArpPolicy policy;
    unsigned int ifindex = 0;
    __u32 generation = 0;
    std::vector<arp_binding_key> keys;
};

namespace {

bool tap_policy_equal(const TapArpPolicy &left, const TapArpPolicy &right)
{
    if (left.tap_ifname != right.tap_ifname ||
        left.bindings.size() != right.bindings.size())
        return false;
    for (size_t i = 0; i < left.bindings.size(); ++i) {
        const ArpBindingSpec &lhs = left.bindings[i];
        const ArpBindingSpec &rhs = right.bindings[i];
        if (lhs.target_ipv4 != rhs.target_ipv4 ||
            lhs.target_mac != rhs.target_mac ||
            lhs.lease_seconds != rhs.lease_seconds)
            return false;
    }
    return true;
}

} // namespace

bool ArpProxyControl::install_tap_record(const TapArpPolicy &policy,
                                         __u32 generation, TapRecord *record,
                                         std::string *error)
{
    unsigned int ifindex = if_nametoindex(policy.tap_ifname.c_str());
    if (!ifindex) {
        if (error)
            *error = "ARP policy interface does not exist: " +
                     policy.tap_ifname;
        return false;
    }

    record->policy = policy;
    record->ifindex = ifindex;
    record->generation = generation == 0 ? 1 : generation;
    record->keys.clear();
    record->keys.reserve(policy.bindings.size());

    auto cleanup_bindings = [&]() {
        for (const arp_binding_key &key : record->keys)
            bpf_map_delete_elem(binding_map_fd_, &key);
        record->keys.clear();
    };

    const uint64_t now = monotonic_now_ns();
    uint64_t tap_expires_ns = now;
    for (const ArpBindingSpec &spec : policy.bindings) {
        ParsedBinding parsed;
        if (!parse_binding(spec, &parsed, error)) {
            cleanup_bindings();
            return false;
        }
        arp_binding_key key = make_binding_key(ifindex, parsed.target_ipv4);
        arp_binding_value value = make_binding_value(
            parsed, record->generation,
            now + static_cast<uint64_t>(spec.lease_seconds) *
                      1000000000ull);
        if (value.expires_ns > tap_expires_ns)
            tap_expires_ns = value.expires_ns;
        if (bpf_map_update_elem(binding_map_fd_, &key, &value, BPF_ANY) != 0) {
            if (error)
                *error = std::string("failed to install ARP binding: ") +
                         strerror(errno);
            cleanup_bindings();
            return false;
        }
        record->keys.push_back(key);
    }

    arp_tap_key tap_key = make_tap_key(ifindex);
    arp_tap_state tap_state = make_tap_state(
        record->generation, ARP_TAP_ENABLED, tap_expires_ns);
    if (bpf_map_update_elem(tap_map_fd_, &tap_key, &tap_state, BPF_ANY) != 0) {
        if (error)
            *error = std::string("failed to activate ARP tap policy: ") +
                     strerror(errno);
        cleanup_bindings();
        return false;
    }
    return true;
}

void ArpProxyControl::remove_tap_record(const TapRecord &record) noexcept
{
    arp_tap_key tap_key = make_tap_key(record.ifindex);
    arp_tap_state disabled = make_tap_state(record.generation, 0, 0);
    bpf_map_update_elem(tap_map_fd_, &tap_key, &disabled, BPF_ANY);
    for (const arp_binding_key &key : record.keys)
        bpf_map_delete_elem(binding_map_fd_, &key);
}

bool parse_arp_policy_file(const std::string &path,
                           std::vector<TapArpPolicy> *policies,
                           std::string *error)
{
    if (!policies) {
        if (error)
            *error = "ARP policy output is null";
        return false;
    }
    policies->clear();

    std::ifstream input(path);
    if (!input) {
        if (error)
            *error = "failed to open ARP policy file: " + path;
        return false;
    }

    std::string line;
    int line_no = 0;
    while (std::getline(input, line)) {
        line_no++;
        size_t comment = line.find('#');
        if (comment != std::string::npos)
            line.resize(comment);

        std::istringstream stream(line);
        std::string tap_ifname;
        std::string target_ipv4;
        std::string target_mac;
        std::string lease_text;
        std::string extra;
        if (!(stream >> tap_ifname))
            continue;
        if (!(stream >> target_ipv4 >> target_mac >> lease_text) ||
            (stream >> extra)) {
            if (error)
                *error = "invalid ARP policy line " + std::to_string(line_no) +
                         ": expected 'tap target_ipv4 target_mac lease_seconds'";
            return false;
        }

        unsigned lease_seconds = 0;
        if (!parse_lease(lease_text, &lease_seconds)) {
            if (error)
                *error = "invalid ARP lease on line " + std::to_string(line_no);
            return false;
        }

        TapArpPolicy *policy = nullptr;
        for (TapArpPolicy &candidate : *policies) {
            if (candidate.tap_ifname == tap_ifname) {
                policy = &candidate;
                break;
            }
        }
        if (!policy) {
            policies->push_back({});
            policy = &policies->back();
            policy->tap_ifname = tap_ifname;
        }
        policy->bindings.push_back(
            {target_ipv4, target_mac, static_cast<unsigned>(lease_seconds)});
    }

    if (policies->empty()) {
        if (error)
            *error = "ARP policy file has no usable entries: " + path;
        return false;
    }
    for (const TapArpPolicy &policy : *policies) {
        if (!validate_policy(policy, true, error))
            return false;
    }
    return true;
}

bool validate_arp_policy_specs(const std::vector<TapArpPolicy> &policies,
                               bool require_interfaces, std::string *error)
{
    std::unordered_set<std::string> seen_taps;
    std::unordered_set<unsigned int> seen_ifindices;
    for (const TapArpPolicy &policy : policies) {
        if (!validate_policy(policy, require_interfaces, error))
            return false;
        if (!seen_taps.insert(policy.tap_ifname).second) {
            if (error)
                *error = "duplicate ARP policy interface: " +
                         policy.tap_ifname;
            return false;
        }
        if (require_interfaces) {
            unsigned int ifindex = if_nametoindex(policy.tap_ifname.c_str());
            if (!seen_ifindices.insert(ifindex).second) {
                if (error)
                    *error = "multiple ARP policy names resolve to interface " +
                             policy.tap_ifname;
                return false;
            }
        }
    }
    return true;
}

ArpProxyControl::ArpProxyControl(int tap_map_fd, int binding_map_fd,
                                 int stats_map_fd)
    : tap_map_fd_(tap_map_fd),
      binding_map_fd_(binding_map_fd),
      stats_map_fd_(stats_map_fd)
{
}

std::unique_ptr<ArpProxyControl>
ArpProxyControl::Create(bpf_object *loaded_object,
                        const std::vector<TapArpPolicy> &policies,
                        std::string *error)
{
    if (!loaded_object) {
        if (error)
            *error = "cannot create ARP control without a loaded BPF object";
        return nullptr;
    }
    bpf_map *tap_map = bpf_object__find_map_by_name(loaded_object,
                                                    "arp_tap_states");
    bpf_map *binding_map = bpf_object__find_map_by_name(loaded_object,
                                                        "arp_bindings");
    bpf_map *stats_map = bpf_object__find_map_by_name(loaded_object,
                                                      "arp_proxy_stats");
    if (!tap_map || !binding_map || !stats_map) {
        if (error)
            *error = "loaded BPF object is missing ARP proxy maps";
        return nullptr;
    }
    if (bpf_map__type(tap_map) != BPF_MAP_TYPE_HASH ||
        bpf_map__key_size(tap_map) != sizeof(arp_tap_key) ||
        bpf_map__value_size(tap_map) != sizeof(arp_tap_state) ||
        bpf_map__type(binding_map) != BPF_MAP_TYPE_HASH ||
        bpf_map__key_size(binding_map) != sizeof(arp_binding_key) ||
        bpf_map__value_size(binding_map) != sizeof(arp_binding_value) ||
        bpf_map__type(stats_map) != BPF_MAP_TYPE_PERCPU_ARRAY ||
        bpf_map__key_size(stats_map) != sizeof(__u32) ||
        bpf_map__value_size(stats_map) != sizeof(__u64)) {
        if (error)
            *error = "loaded BPF object has incompatible ARP proxy map ABI";
        return nullptr;
    }

    std::unique_ptr<ArpProxyControl> control(new ArpProxyControl(
        bpf_map__fd(tap_map), bpf_map__fd(binding_map),
        bpf_map__fd(stats_map)));
    if (!control->initialize(policies, error))
        return nullptr;
    return control;
}

bool ArpProxyControl::initialize(const std::vector<TapArpPolicy> &policies,
                                 std::string *error)
{
    std::unordered_set<unsigned int> seen_ifindices;
    for (const TapArpPolicy &policy : policies) {
        if (!validate_policy(policy, true, error))
            return false;

        unsigned int ifindex = if_nametoindex(policy.tap_ifname.c_str());
        if (!seen_ifindices.insert(ifindex).second) {
            if (error)
                *error = "duplicate ARP policy interface: " +
                         policy.tap_ifname;
            return false;
        }

        TapRecord record;
        if (!install_tap_record(policy, 1, &record, error))
            return false;

        taps_.push_back(std::move(record));
        ifindices_.push_back(ifindex);
    }
    return true;
}

bool ArpProxyControl::RenewAll(std::string *error)
{
    const uint64_t now = monotonic_now_ns();
    for (const TapRecord &record : taps_) {
        uint64_t tap_expires_ns = now;
        for (const ArpBindingSpec &spec : record.policy.bindings) {
            ParsedBinding parsed;
            if (!parse_binding(spec, &parsed, error))
                return false;
            arp_binding_key key =
                make_binding_key(record.ifindex, parsed.target_ipv4);
            arp_binding_value value = make_binding_value(
                parsed, record.generation,
                now + static_cast<uint64_t>(spec.lease_seconds) *
                          1000000000ull);
            if (value.expires_ns > tap_expires_ns)
                tap_expires_ns = value.expires_ns;
            if (bpf_map_update_elem(binding_map_fd_, &key, &value, BPF_ANY) !=
                0) {
                if (error)
                    *error = std::string("failed to renew ARP binding: ") +
                             strerror(errno);
                return false;
            }
        }
        arp_tap_key tap_key = make_tap_key(record.ifindex);
        arp_tap_state tap_state = make_tap_state(
            record.generation, ARP_TAP_ENABLED, tap_expires_ns);
        if (bpf_map_update_elem(tap_map_fd_, &tap_key, &tap_state, BPF_ANY) !=
            0) {
            if (error)
                *error = std::string("failed to renew ARP tap policy: ") +
                         strerror(errno);
            return false;
        }
    }
    return true;
}

bool ArpProxyControl::ReplaceTapPolicy(const TapArpPolicy &policy,
                                       std::string *error)
{
    if (!validate_policy(policy, true, error))
        return false;

    TapRecord *record = nullptr;
    for (TapRecord &candidate : taps_) {
        if (candidate.policy.tap_ifname == policy.tap_ifname) {
            record = &candidate;
            break;
        }
    }
    if (!record) {
        if (error)
            *error = "cannot replace unknown ARP tap policy: " +
                     policy.tap_ifname;
        return false;
    }

    arp_tap_key tap_key = make_tap_key(record->ifindex);
    arp_tap_state old_tap_state = {};
    if (bpf_map_lookup_elem(tap_map_fd_, &tap_key, &old_tap_state) != 0) {
        if (error)
            *error = std::string("failed to read current ARP tap policy: ") +
                     strerror(errno);
        return false;
    }
    std::vector<std::pair<arp_binding_key, arp_binding_value>> old_bindings;
    old_bindings.reserve(record->keys.size());
    for (const arp_binding_key &old_key : record->keys) {
        arp_binding_value old_value = {};
        if (bpf_map_lookup_elem(binding_map_fd_, &old_key, &old_value) != 0) {
            if (error)
                *error = std::string("failed to read current ARP binding: ") +
                         strerror(errno);
            return false;
        }
        old_bindings.push_back({old_key, old_value});
    }

    std::vector<arp_binding_key> new_keys;

    auto rollback = [&]() {
        for (const auto &old_binding : old_bindings)
            bpf_map_update_elem(binding_map_fd_, &old_binding.first,
                                &old_binding.second, BPF_ANY);
        for (const arp_binding_key &new_key : new_keys) {
            bool existed = false;
            for (const auto &old_binding : old_bindings) {
                if (same_target(old_binding.first, new_key.target_ipv4)) {
                    existed = true;
                    break;
                }
            }
            if (!existed)
                bpf_map_delete_elem(binding_map_fd_, &new_key);
        }
        bpf_map_update_elem(tap_map_fd_, &tap_key, &old_tap_state, BPF_ANY);
    };

    __u32 generation = record->generation + 1;
    if (generation == 0)
        generation = 1;
    const uint64_t now = monotonic_now_ns();
    uint64_t tap_expires_ns = now;
    new_keys.reserve(policy.bindings.size());
    for (const ArpBindingSpec &spec : policy.bindings) {
        ParsedBinding parsed;
        if (!parse_binding(spec, &parsed, error))
            return false;
        arp_binding_key key =
            make_binding_key(record->ifindex, parsed.target_ipv4);
        arp_binding_value value = make_binding_value(
            parsed, generation,
            now + static_cast<uint64_t>(spec.lease_seconds) *
                      1000000000ull);
        if (value.expires_ns > tap_expires_ns)
            tap_expires_ns = value.expires_ns;
        new_keys.push_back(key);
        if (bpf_map_update_elem(binding_map_fd_, &key, &value, BPF_ANY) != 0) {
            if (error)
                *error = std::string("failed to install replacement ARP binding: ") +
                         strerror(errno);
            rollback();
            return false;
        }
    }

    arp_tap_state tap_state = make_tap_state(
        generation, ARP_TAP_ENABLED, tap_expires_ns);
    if (bpf_map_update_elem(tap_map_fd_, &tap_key, &tap_state, BPF_ANY) != 0) {
        if (error)
            *error = std::string("failed to activate replacement ARP policy: ") +
                     strerror(errno);
        rollback();
        return false;
    }

    for (const arp_binding_key &old_key : record->keys) {
        bool still_present = false;
        for (const arp_binding_key &new_key : new_keys) {
            if (same_target(old_key, new_key.target_ipv4)) {
                still_present = true;
                break;
            }
        }
        if (!still_present)
            bpf_map_delete_elem(binding_map_fd_, &old_key);
    }
    record->policy = policy;
    record->generation = generation;
    record->keys = std::move(new_keys);
    return true;
}

bool ArpProxyControl::Reconcile(
    const std::vector<TapArpPolicy> &policies,
    std::vector<unsigned int> *added_ifindices,
    std::vector<unsigned int> *removed_ifindices, std::string *error)
{
    if (!added_ifindices || !removed_ifindices) {
        if (error)
            *error = "ARP reconcile output vectors are null";
        return false;
    }
    added_ifindices->clear();
    removed_ifindices->clear();
    if (!validate_arp_policy_specs(policies, true, error))
        return false;

    std::vector<TapArpPolicy> previous_policies;
    previous_policies.reserve(taps_.size());
    for (const TapRecord &record : taps_)
        previous_policies.push_back(record.policy);

    auto find_previous = [&](const std::string &tap_ifname) {
        for (const TapArpPolicy &policy : previous_policies) {
            if (policy.tap_ifname == tap_ifname)
                return &policy;
        }
        return static_cast<const TapArpPolicy *>(nullptr);
    };

    auto erase_record = [&](size_t index) {
        const unsigned int ifindex = taps_[index].ifindex;
        remove_tap_record(taps_[index]);
        taps_.erase(taps_.begin() + static_cast<ptrdiff_t>(index));
        for (auto it = ifindices_.begin(); it != ifindices_.end(); ++it) {
            if (*it == ifindex) {
                ifindices_.erase(it);
                break;
            }
        }
    };

    auto rollback = [&]() {
        // ReplaceTapPolicy is already per-tap transactional. This second
        // layer restores earlier successful taps if a later tap cannot be
        // installed, keeping Reconcile a useful module-level transaction.
        for (size_t index = 0; index < taps_.size();) {
            const TapArpPolicy *old_policy =
                find_previous(taps_[index].policy.tap_ifname);
            if (!old_policy) {
                erase_record(index);
                continue;
            }
            if (!tap_policy_equal(taps_[index].policy, *old_policy)) {
                std::string rollback_error;
                if (!ReplaceTapPolicy(*old_policy, &rollback_error))
                    return false;
            }
            ++index;
        }
        for (const TapArpPolicy &old_policy : previous_policies) {
            bool present = false;
            for (const TapRecord &record : taps_) {
                if (record.policy.tap_ifname == old_policy.tap_ifname) {
                    present = true;
                    break;
                }
            }
            if (present)
                continue;
            TapRecord record;
            std::string rollback_error;
            if (!install_tap_record(old_policy, 1, &record, &rollback_error))
                return false;
            ifindices_.push_back(record.ifindex);
            taps_.push_back(std::move(record));
        }
        added_ifindices->clear();
        removed_ifindices->clear();
        return true;
    };

    std::unordered_set<std::string> desired_taps;
    for (const TapArpPolicy &policy : policies) {
        desired_taps.insert(policy.tap_ifname);
        TapRecord *current = nullptr;
        for (TapRecord &record : taps_) {
            if (record.policy.tap_ifname == policy.tap_ifname) {
                current = &record;
                break;
            }
        }
        if (current) {
            if (!tap_policy_equal(current->policy, policy) &&
                !ReplaceTapPolicy(policy, error)) {
                rollback();
                return false;
            }
            continue;
        }

        TapRecord record;
        if (!install_tap_record(policy, 1, &record, error)) {
            rollback();
            return false;
        }
        added_ifindices->push_back(record.ifindex);
        ifindices_.push_back(record.ifindex);
        taps_.push_back(std::move(record));
    }

    for (size_t index = 0; index < taps_.size();) {
        if (desired_taps.count(taps_[index].policy.tap_ifname) != 0) {
            index++;
            continue;
        }
        const unsigned int ifindex = taps_[index].ifindex;
        removed_ifindices->push_back(ifindex);
        erase_record(index);
    }
    return true;
}

ArpProxyStats ArpProxyControl::ReadStats() const
{
    ArpProxyStats stats;
    if (stats_map_fd_ < 0)
        return stats;

    int cpu_count = libbpf_num_possible_cpus();
    if (cpu_count <= 0)
        return stats;
    std::vector<__u64> values(static_cast<size_t>(cpu_count));
    auto read = [&](enum arp_proxy_stat_key key) {
        __u32 map_key = static_cast<__u32>(key);
        if (bpf_map_lookup_elem(stats_map_fd_, &map_key, values.data()) != 0)
            return uint64_t{0};
        uint64_t total = 0;
        for (__u64 value : values)
            total += value;
        return total;
    };
    stats.request = read(ARP_PROXY_STAT_REQUEST);
    stats.tx = read(ARP_PROXY_STAT_TX);
    stats.tap_miss = read(ARP_PROXY_STAT_TAP_MISS);
    stats.binding_miss = read(ARP_PROXY_STAT_BINDING_MISS);
    stats.wrong_generation = read(ARP_PROXY_STAT_WRONG_GENERATION);
    stats.expired = read(ARP_PROXY_STAT_EXPIRED);
    stats.source_invalid = read(ARP_PROXY_STAT_SOURCE_INVALID);
    stats.format_invalid = read(ARP_PROXY_STAT_FORMAT_INVALID);
    stats.binding_invalid = read(ARP_PROXY_STAT_BINDING_INVALID);
    return stats;
}

const std::vector<unsigned int> &ArpProxyControl::ifindices() const
{
    return ifindices_;
}

void ArpProxyControl::disable_all() noexcept
{
    for (const TapRecord &record : taps_) {
        arp_tap_key key = make_tap_key(record.ifindex);
        arp_tap_state state = make_tap_state(record.generation, 0, 0);
        bpf_map_update_elem(tap_map_fd_, &key, &state, BPF_ANY);
    }
}

ArpProxyControl::~ArpProxyControl()
{
    disable_all();
}
