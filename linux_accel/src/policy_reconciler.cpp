#include "policy_reconciler.hpp"

#include <arpa/inet.h>

#include <chrono>
#include <limits>
#include <map>
#include <utility>

namespace {

constexpr unsigned kMaxPolicyLeaseSeconds = 24 * 60 * 60;
constexpr size_t kMaxOwnerTokenBytes = 128;

bool valid_owner_token(const std::string &token)
{
    return !token.empty() && token.size() <= kMaxOwnerTokenBytes &&
           token.find_first_of(" \t\r\n") == std::string::npos;
}

std::string binding_key(const TapArpPolicy &policy,
                        const ArpBindingSpec &binding)
{
    __be32 address = 0;
    inet_pton(AF_INET, binding.target_ipv4.c_str(), &address);
    std::string key = policy.tap_ifname;
    key.push_back('\0');
    key.append(reinterpret_cast<const char *>(&address), sizeof(address));
    return key;
}

bool same_snapshot(const PolicySnapshot &left, const PolicySnapshot &right)
{
    if (left.schema_version != right.schema_version ||
        !(left.owner == right.owner) || left.revision != right.revision ||
        left.lease_seconds != right.lease_seconds ||
        left.persistent != right.persistent ||
        left.policies.size() != right.policies.size())
        return false;
    for (size_t i = 0; i < left.policies.size(); ++i) {
        const TapArpPolicy &lhs = left.policies[i];
        const TapArpPolicy &rhs = right.policies[i];
        if (lhs.tap_ifname != rhs.tap_ifname ||
            lhs.bindings.size() != rhs.bindings.size())
            return false;
        for (size_t j = 0; j < lhs.bindings.size(); ++j) {
            const ArpBindingSpec &left_binding = lhs.bindings[j];
            const ArpBindingSpec &right_binding = rhs.bindings[j];
            if (left_binding.target_ipv4 != right_binding.target_ipv4 ||
                left_binding.target_mac != right_binding.target_mac ||
                left_binding.lease_seconds != right_binding.lease_seconds)
                return false;
        }
    }
    return true;
}

} // namespace

uint64_t policy_monotonic_now_ns()
{
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

bool PolicyReconciler::ApplySnapshot(const PolicySnapshot &snapshot,
                                     std::string *error)
{
    if (snapshot.schema_version != 1) {
        if (error)
            *error = "unsupported policy snapshot schema version";
        return false;
    }
    if (!valid_owner_token(snapshot.owner.cluster_id) ||
        !valid_owner_token(snapshot.owner.source_id)) {
        if (error)
            *error = "policy snapshot owner is incomplete";
        return false;
    }
    if (snapshot.revision == 0 ||
        (!snapshot.persistent && snapshot.lease_seconds == 0) ||
        snapshot.lease_seconds > kMaxPolicyLeaseSeconds) {
        if (error)
            *error = "policy snapshot revision or lease is invalid";
        return false;
    }
    if (!validate_arp_policy_specs(snapshot.policies, false, error))
        return false;

    const uint64_t now = policy_monotonic_now_ns();
    std::map<PolicyOwner, SourceRecord> candidate = sources_;
    for (auto it = candidate.begin(); it != candidate.end();) {
        if (it->second.expires_ns <= now)
            it = candidate.erase(it);
        else
            ++it;
    }

    auto existing = candidate.find(snapshot.owner);
    if (existing != candidate.end()) {
        if (snapshot.revision < existing->second.snapshot.revision) {
            if (error)
                *error = "stale policy snapshot revision";
            return false;
        }
        if (snapshot.revision == existing->second.snapshot.revision &&
            !same_snapshot(snapshot, existing->second.snapshot)) {
            if (error)
                *error = "policy snapshot revision was reused with different data";
            return false;
        }
    }
    auto last_revision = last_revisions_.find(snapshot.owner);
    if (last_revision != last_revisions_.end() &&
        snapshot.revision < last_revision->second) {
        if (error)
            *error = "stale policy snapshot revision";
        return false;
    }

    SourceRecord replacement;
    replacement.snapshot = snapshot;
    replacement.expires_ns = snapshot.persistent
                                 ? std::numeric_limits<uint64_t>::max()
                                 : now + static_cast<uint64_t>(snapshot.lease_seconds) *
                                           1000000000ull;
    candidate[snapshot.owner] = std::move(replacement);

    std::vector<TapArpPolicy> merged;
    if (!rebuild_merged(candidate, &merged, error))
        return false;
    sources_ = std::move(candidate);
    last_revisions_[snapshot.owner] = snapshot.revision;
    merged_ = std::move(merged);
    return true;
}

bool PolicyReconciler::WithdrawSource(const PolicyOwner &owner,
                                      uint64_t revision, std::string *error)
{
    if (!valid_owner_token(owner.cluster_id) ||
        !valid_owner_token(owner.source_id) || revision == 0) {
        if (error)
            *error = "policy withdrawal owner or revision is invalid";
        return false;
    }

    auto last_revision = last_revisions_.find(owner);
    if (last_revision != last_revisions_.end() &&
        revision < last_revision->second) {
        if (error)
            *error = "stale policy withdrawal revision";
        return false;
    }

    auto existing = sources_.find(owner);
    if (existing == sources_.end()) {
        last_revisions_[owner] = revision;
        return true;
    }
    if (revision < existing->second.snapshot.revision) {
        if (error)
            *error = "stale policy withdrawal revision";
        return false;
    }

    std::map<PolicyOwner, SourceRecord> candidate = sources_;
    candidate.erase(owner);
    std::vector<TapArpPolicy> merged;
    if (!rebuild_merged(candidate, &merged, error))
        return false;
    sources_ = std::move(candidate);
    last_revisions_[owner] = revision;
    merged_ = std::move(merged);
    return true;
}

bool PolicyReconciler::Expire(uint64_t now_ns, std::string *error)
{
    std::map<PolicyOwner, SourceRecord> candidate = sources_;
    bool changed = false;
    for (auto it = candidate.begin(); it != candidate.end();) {
        if (it->second.expires_ns != std::numeric_limits<uint64_t>::max() &&
            it->second.expires_ns <= now_ns) {
            it = candidate.erase(it);
            changed = true;
        } else {
            ++it;
        }
    }
    if (!changed)
        return true;

    std::vector<TapArpPolicy> merged;
    if (!rebuild_merged(candidate, &merged, error))
        return false;
    sources_ = std::move(candidate);
    merged_ = std::move(merged);
    return true;
}

const std::vector<TapArpPolicy> &PolicyReconciler::merged_policies() const
{
    return merged_;
}

bool PolicyReconciler::empty() const
{
    return merged_.empty();
}

bool PolicyReconciler::rebuild_merged(
    const std::map<PolicyOwner, SourceRecord> &candidate,
    std::vector<TapArpPolicy> *merged, std::string *error) const
{
    std::map<std::string, PolicyOwner> owners;
    std::map<std::string, TapArpPolicy> grouped;
    for (const auto &source : candidate) {
        for (const TapArpPolicy &policy : source.second.snapshot.policies) {
            for (const ArpBindingSpec &binding : policy.bindings) {
                const std::string key = binding_key(policy, binding);
                auto owner = owners.find(key);
                if (owner != owners.end() &&
                    !(owner->second == source.first)) {
                    if (error)
                        *error = "ARP binding conflict between policy sources on " +
                                 policy.tap_ifname + " target " +
                                 binding.target_ipv4;
                    return false;
                }
                owners[key] = source.first;
                auto group = grouped.find(policy.tap_ifname);
                if (group == grouped.end()) {
                    TapArpPolicy new_policy;
                    new_policy.tap_ifname = policy.tap_ifname;
                    group = grouped.emplace(policy.tap_ifname,
                                            std::move(new_policy))
                                .first;
                }
                group->second.bindings.push_back(binding);
            }
        }
    }

    merged->clear();
    merged->reserve(grouped.size());
    for (auto &entry : grouped)
        merged->push_back(std::move(entry.second));
    return true;
}
