#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "policy_model.hpp"

class PolicyReconciler {
public:
    bool ApplySnapshot(const PolicySnapshot &snapshot, std::string *error);
    bool WithdrawSource(const PolicyOwner &owner, uint64_t revision,
                        std::string *error);
    bool Expire(uint64_t now_ns, std::string *error);

    const std::vector<TapArpPolicy> &merged_policies() const;
    bool empty() const;

private:
    struct SourceRecord {
        PolicySnapshot snapshot;
        uint64_t expires_ns = 0;
    };

    bool rebuild_merged(const std::map<PolicyOwner, SourceRecord> &candidate,
                        std::vector<TapArpPolicy> *merged,
                        std::string *error) const;

    std::map<PolicyOwner, SourceRecord> sources_;
    // Tombstones keep a withdrawn/expired source from being rolled back by a
    // delayed packet after a reconnect.
    std::map<PolicyOwner, uint64_t> last_revisions_;
    std::vector<TapArpPolicy> merged_;
};

uint64_t policy_monotonic_now_ns();
