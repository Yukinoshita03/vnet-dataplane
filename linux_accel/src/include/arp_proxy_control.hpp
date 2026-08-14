#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "arp_proxy.h"

struct bpf_object;

struct ArpBindingSpec {
    std::string target_ipv4;
    std::string target_mac;
    unsigned lease_seconds = 30;
};

struct TapArpPolicy {
    std::string tap_ifname;
    std::vector<ArpBindingSpec> bindings;
};

struct ArpProxyStats {
    uint64_t request = 0;
    uint64_t tx = 0;
    uint64_t tap_miss = 0;
    uint64_t binding_miss = 0;
    uint64_t wrong_generation = 0;
    uint64_t expired = 0;
    uint64_t source_invalid = 0;
    uint64_t format_invalid = 0;
    uint64_t binding_invalid = 0;
};

bool parse_arp_policy_file(const std::string &path,
                           std::vector<TapArpPolicy> *policies,
                           std::string *error);
bool validate_arp_policy_specs(const std::vector<TapArpPolicy> &policies,
                               bool require_interfaces, std::string *error);

class ArpProxyControl {
public:
    static std::unique_ptr<ArpProxyControl>
    Create(bpf_object *loaded_object,
           const std::vector<TapArpPolicy> &policies,
           std::string *error);

    ArpProxyControl(const ArpProxyControl &) = delete;
    ArpProxyControl &operator=(const ArpProxyControl &) = delete;

    ~ArpProxyControl();

    bool RenewAll(std::string *error);
    bool ReplaceTapPolicy(const TapArpPolicy &policy, std::string *error);
    bool Reconcile(const std::vector<TapArpPolicy> &policies,
                   std::vector<unsigned int> *added_ifindices,
                   std::vector<unsigned int> *removed_ifindices,
                   std::string *error);
    ArpProxyStats ReadStats() const;
    const std::vector<unsigned int> &ifindices() const;

private:
    struct TapRecord;

    ArpProxyControl(int tap_map_fd, int binding_map_fd, int stats_map_fd);

    bool install_tap_record(const TapArpPolicy &policy, __u32 generation,
                            TapRecord *record, std::string *error);
    void remove_tap_record(const TapRecord &record) noexcept;

    bool initialize(const std::vector<TapArpPolicy> &policies,
                    std::string *error);
    void disable_all() noexcept;

    int tap_map_fd_;
    int binding_map_fd_;
    int stats_map_fd_;
    std::vector<TapRecord> taps_;
    std::vector<unsigned int> ifindices_;
};
