#include "dhcp_relay_control.hpp"

#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <linux/if_ether.h>
#include <net/if.h>
#include <stdio.h>
#include <string.h>

#include <array>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <sstream>
#include <unordered_set>
#include <utility>

namespace {

constexpr unsigned kMinLeaseSeconds = 1;
constexpr unsigned kMaxLeaseSeconds = 24 * 60 * 60;

struct ParsedPolicy {
    __be32 relay_ipv4 = 0;
    __be32 server_ipv4 = 0;
    std::array<__u8, 6> relay_mac = {};
    std::array<__u8, 6> server_mac = {};
    unsigned client_ifindex = 0;
    unsigned relay_ifindex = 0;
};

uint64_t monotonic_now_ns()
{
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
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
    for (__u8 byte : *mac) {
        if (byte != 0)
            return true;
    }
    return false;
}

bool parse_lease(const std::string &text, unsigned *lease_seconds)
{
    if (text.empty() || text[0] == '-')
        return false;
    char *end = nullptr;
    errno = 0;
    unsigned long parsed = std::strtoul(text.c_str(), &end, 10);
    if (errno || !end || *end != '\0' || parsed < kMinLeaseSeconds ||
        parsed > kMaxLeaseSeconds ||
        parsed > std::numeric_limits<unsigned>::max())
        return false;
    *lease_seconds = static_cast<unsigned>(parsed);
    return true;
}

bool parse_spec(const DhcpRelayPolicySpec &spec, ParsedPolicy *parsed,
                std::string *error)
{
    *parsed = {};
    parsed->client_ifindex = if_nametoindex(spec.client_ifname.c_str());
    parsed->relay_ifindex = if_nametoindex(spec.relay_ifname.c_str());
    if (!parsed->client_ifindex || !parsed->relay_ifindex) {
        if (error)
            *error = "DHCP relay interface does not exist: " +
                     spec.client_ifname + " or " + spec.relay_ifname;
        return false;
    }
    if (!parse_ipv4(spec.relay_ipv4, &parsed->relay_ipv4) ||
        !parse_ipv4(spec.server_ipv4, &parsed->server_ipv4)) {
        if (error)
            *error = "invalid DHCP relay/server IPv4 address";
        return false;
    }
    if (!parse_mac(spec.relay_mac, &parsed->relay_mac) ||
        !parse_mac(spec.server_mac, &parsed->server_mac)) {
        if (error)
            *error = "invalid DHCP relay/server MAC address";
        return false;
    }
    if (spec.lease_seconds < kMinLeaseSeconds ||
        spec.lease_seconds > kMaxLeaseSeconds) {
        if (error)
            *error = "DHCP relay lease must be between " +
                     std::to_string(kMinLeaseSeconds) + " and " +
                     std::to_string(kMaxLeaseSeconds) + " seconds";
        return false;
    }
    return true;
}

} // namespace

bool parse_dhcp_relay_policy_file(
    const std::string &path, std::vector<DhcpRelayPolicySpec> *policies,
    std::string *error)
{
    if (!policies) {
        if (error)
            *error = "DHCP relay policy output is null";
        return false;
    }
    policies->clear();

    std::ifstream input(path);
    if (!input) {
        if (error)
            *error = "failed to open DHCP relay policy file: " + path;
        return false;
    }

    std::string line;
    int line_no = 0;
    while (std::getline(input, line)) {
        ++line_no;
        size_t comment = line.find('#');
        if (comment != std::string::npos)
            line.resize(comment);

        std::istringstream stream(line);
        DhcpRelayPolicySpec spec;
        std::string lease_text;
        std::string extra;
        if (!(stream >> spec.client_ifname))
            continue;
        if (!(stream >> spec.relay_ifname >> spec.relay_ipv4 >>
              spec.server_ipv4 >> spec.relay_mac >> spec.server_mac >>
              lease_text) ||
            (stream >> extra)) {
            if (error)
                *error = "invalid DHCP relay policy line " +
                         std::to_string(line_no) +
                         ": expected 'client_if relay_if relay_ipv4 "
                         "server_ipv4 relay_mac server_mac lease_seconds'";
            return false;
        }
        if (!parse_lease(lease_text, &spec.lease_seconds)) {
            if (error)
                *error = "invalid DHCP relay lease on line " +
                         std::to_string(line_no);
            return false;
        }
        policies->push_back(std::move(spec));
    }

    if (policies->empty()) {
        if (error)
            *error = "DHCP relay policy file has no usable entries: " + path;
        return false;
    }
    return validate_dhcp_relay_specs(*policies, true, error);
}

bool validate_dhcp_relay_specs(
    const std::vector<DhcpRelayPolicySpec> &policies,
    bool require_interfaces, std::string *error)
{
    std::unordered_set<std::string> client_names;
    std::unordered_set<unsigned int> clients;
    for (const DhcpRelayPolicySpec &spec : policies) {
        if (spec.client_ifname.empty() || spec.relay_ifname.empty() ||
            spec.relay_ipv4.empty() || spec.server_ipv4.empty() ||
            spec.relay_mac.empty() || spec.server_mac.empty()) {
            if (error)
                *error = "DHCP relay policy has an empty field";
            return false;
        }
        if (require_interfaces &&
            (!if_nametoindex(spec.client_ifname.c_str()) ||
             !if_nametoindex(spec.relay_ifname.c_str()))) {
            if (error)
                *error = "DHCP relay policy interface does not exist";
            return false;
        }
        ParsedPolicy parsed;
        if (require_interfaces && !parse_spec(spec, &parsed, error))
            return false;
        if (!parse_ipv4(spec.relay_ipv4, &parsed.relay_ipv4) ||
            !parse_ipv4(spec.server_ipv4, &parsed.server_ipv4) ||
            !parse_mac(spec.relay_mac, &parsed.relay_mac) ||
            !parse_mac(spec.server_mac, &parsed.server_mac) ||
            spec.lease_seconds < kMinLeaseSeconds ||
            spec.lease_seconds > kMaxLeaseSeconds) {
            if (error)
                *error = "invalid DHCP relay policy value";
            return false;
        }
        if (!client_names.insert(spec.client_ifname).second) {
            if (error)
                *error = "duplicate DHCP relay client interface: " +
                         spec.client_ifname;
            return false;
        }
        unsigned int client_ifindex = if_nametoindex(spec.client_ifname.c_str());
        if (client_ifindex && !clients.insert(client_ifindex).second) {
            if (error)
                *error = "duplicate DHCP relay client interface: " +
                         spec.client_ifname;
            return false;
        }
    }
    return true;
}

struct DhcpRelayControl::Record {
    DhcpRelayPolicySpec spec;
    ParsedPolicy parsed;
    dhcp_relay_policy_key key = {};
};

DhcpRelayControl::DhcpRelayControl(int policy_map_fd, int transaction_map_fd,
                                   int stats_map_fd)
    : policy_map_fd_(policy_map_fd), transaction_map_fd_(transaction_map_fd),
      stats_map_fd_(stats_map_fd)
{
}

DhcpRelayControl::~DhcpRelayControl()
{
    disable_all();
}

std::unique_ptr<DhcpRelayControl> DhcpRelayControl::Create(
    bpf_object *loaded_object,
    const std::vector<DhcpRelayPolicySpec> &policies, std::string *error)
{
    if (!loaded_object || policies.empty())
        return nullptr;
    bpf_map *policy_map =
        bpf_object__find_map_by_name(loaded_object, "dhcp_relay_policies");
    bpf_map *transaction_map = bpf_object__find_map_by_name(
        loaded_object, "dhcp_relay_transactions");
    bpf_map *stats_map =
        bpf_object__find_map_by_name(loaded_object, "dhcp_relay_stats");
    if (!policy_map || !transaction_map || !stats_map) {
        if (error)
            *error = "loaded BPF object has no DHCP relay maps";
        return nullptr;
    }

    std::unique_ptr<DhcpRelayControl> control(new DhcpRelayControl(
        bpf_map__fd(policy_map), bpf_map__fd(transaction_map),
        bpf_map__fd(stats_map)));
    if (!control->initialize(policies, error))
        return nullptr;
    return control;
}

bool DhcpRelayControl::initialize(
    const std::vector<DhcpRelayPolicySpec> &policies, std::string *error)
{
    for (const DhcpRelayPolicySpec &spec : policies) {
        Record record;
        record.spec = spec;
        if (!parse_spec(spec, &record.parsed, error)) {
            disable_all();
            return false;
        }
        record.key.client_ifindex = record.parsed.client_ifindex;
        for (const Record &existing : records_) {
            if (existing.key.client_ifindex == record.key.client_ifindex) {
                if (error)
                    *error = "duplicate DHCP relay client interface";
                disable_all();
                return false;
            }
        }
        dhcp_relay_policy value = {};
        value.relay_ifindex = record.parsed.relay_ifindex;
        value.relay_ipv4 = record.parsed.relay_ipv4;
        value.server_ipv4 = record.parsed.server_ipv4;
        memcpy(value.relay_mac, record.parsed.relay_mac.data(), ETH_ALEN);
        memcpy(value.server_mac, record.parsed.server_mac.data(), ETH_ALEN);
        value.flags = DHCP_RELAY_POLICY_ENABLED;
        value.generation = 1;
        value.expires_ns = monotonic_now_ns() +
                           static_cast<uint64_t>(spec.lease_seconds) *
                               1000000000ull;
        if (bpf_map_update_elem(policy_map_fd_, &record.key, &value,
                                BPF_ANY) != 0) {
            if (error)
                *error = std::string("failed to install DHCP relay policy: ") +
                         strerror(errno);
            disable_all();
            return false;
        }
        records_.push_back(record);
        ifindices_.push_back(record.parsed.client_ifindex);
        if (record.parsed.relay_ifindex != record.parsed.client_ifindex)
            ifindices_.push_back(record.parsed.relay_ifindex);
    }
    return true;
}

void DhcpRelayControl::disable_all() noexcept
{
    for (const Record &record : records_)
        bpf_map_delete_elem(policy_map_fd_, &record.key);
    records_.clear();
    ifindices_.clear();
}

bool DhcpRelayControl::RenewAll(std::string *error)
{
    const uint64_t now = monotonic_now_ns();
    for (const Record &record : records_) {
        dhcp_relay_policy value = {};
        value.relay_ifindex = record.parsed.relay_ifindex;
        value.relay_ipv4 = record.parsed.relay_ipv4;
        value.server_ipv4 = record.parsed.server_ipv4;
        memcpy(value.relay_mac, record.parsed.relay_mac.data(), ETH_ALEN);
        memcpy(value.server_mac, record.parsed.server_mac.data(), ETH_ALEN);
        value.flags = DHCP_RELAY_POLICY_ENABLED;
        value.generation = 1;
        value.expires_ns = now + static_cast<uint64_t>(record.spec.lease_seconds) *
                                      1000000000ull;
        if (bpf_map_update_elem(policy_map_fd_, &record.key, &value,
                                BPF_ANY) != 0) {
            if (error)
                *error = std::string("failed to renew DHCP relay policy: ") +
                         strerror(errno);
            return false;
        }
    }
    return true;
}

DhcpRelayStats DhcpRelayControl::ReadStats() const
{
    DhcpRelayStats stats;
    const int cpus = libbpf_num_possible_cpus();
    if (cpus <= 0 || stats_map_fd_ < 0)
        return stats;
    std::vector<__u64> values(static_cast<size_t>(cpus));
    auto read = [&](enum dhcp_relay_stat_key key) {
        __u32 map_key = static_cast<__u32>(key);
        if (bpf_map_lookup_elem(stats_map_fd_, &map_key, values.data()) != 0)
            return uint64_t{0};
        uint64_t total = 0;
        for (__u64 value : values)
            total += value;
        return total;
    };
    stats.request = read(DHCP_RELAY_STAT_REQUEST);
    stats.response = read(DHCP_RELAY_STAT_RESPONSE);
    stats.redirect = read(DHCP_RELAY_STAT_REDIRECT);
    stats.policy_miss = read(DHCP_RELAY_STAT_POLICY_MISS);
    stats.transaction_miss = read(DHCP_RELAY_STAT_TRANSACTION_MISS);
    stats.transaction_expired = read(DHCP_RELAY_STAT_TRANSACTION_EXPIRED);
    stats.transaction_update_fail =
        read(DHCP_RELAY_STAT_TRANSACTION_UPDATE_FAIL);
    stats.format_invalid = read(DHCP_RELAY_STAT_FORMAT_INVALID);
    stats.unsupported = read(DHCP_RELAY_STAT_UNSUPPORTED);
    stats.policy_expired = read(DHCP_RELAY_STAT_POLICY_EXPIRED);
    return stats;
}

const std::vector<unsigned int> &DhcpRelayControl::ifindices() const
{
    return ifindices_;
}

size_t DhcpRelayControl::policy_count() const
{
    return records_.size();
}
