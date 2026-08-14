#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "dhcp_relay.h"

struct bpf_object;

struct DhcpRelayPolicySpec {
    std::string client_ifname;
    std::string relay_ifname;
    std::string relay_ipv4;
    std::string server_ipv4;
    std::string relay_mac;
    std::string server_mac;
    unsigned lease_seconds = 30;
};

struct DhcpRelayStats {
    uint64_t request = 0;
    uint64_t response = 0;
    uint64_t redirect = 0;
    uint64_t policy_miss = 0;
    uint64_t transaction_miss = 0;
    uint64_t transaction_expired = 0;
    uint64_t transaction_update_fail = 0;
    uint64_t format_invalid = 0;
    uint64_t unsupported = 0;
    uint64_t policy_expired = 0;
};

bool parse_dhcp_relay_policy_file(
    const std::string &path, std::vector<DhcpRelayPolicySpec> *policies,
    std::string *error);
bool validate_dhcp_relay_specs(
    const std::vector<DhcpRelayPolicySpec> &policies,
    bool require_interfaces, std::string *error);

class DhcpRelayControl {
public:
    static std::unique_ptr<DhcpRelayControl>
    Create(bpf_object *loaded_object,
           const std::vector<DhcpRelayPolicySpec> &policies,
           std::string *error);

    DhcpRelayControl(const DhcpRelayControl &) = delete;
    DhcpRelayControl &operator=(const DhcpRelayControl &) = delete;

    ~DhcpRelayControl();

    bool RenewAll(std::string *error);
    DhcpRelayStats ReadStats() const;
    const std::vector<unsigned int> &ifindices() const;
    size_t policy_count() const;

private:
    struct Record;

    DhcpRelayControl(int policy_map_fd, int transaction_map_fd,
                     int stats_map_fd);

    bool initialize(const std::vector<DhcpRelayPolicySpec> &policies,
                    std::string *error);
    void disable_all() noexcept;

    int policy_map_fd_;
    int transaction_map_fd_;
    int stats_map_fd_;
    std::vector<Record> records_;
    std::vector<unsigned int> ifindices_;
};
