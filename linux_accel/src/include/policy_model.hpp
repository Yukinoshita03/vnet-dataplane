#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "arp_proxy_control.hpp"

struct PolicyOwner {
    std::string cluster_id;
    std::string source_id;

    bool operator<(const PolicyOwner &other) const
    {
        if (cluster_id != other.cluster_id)
            return cluster_id < other.cluster_id;
        return source_id < other.source_id;
    }

    bool operator==(const PolicyOwner &other) const
    {
        return cluster_id == other.cluster_id &&
               source_id == other.source_id;
    }
};

struct PolicySnapshot {
    uint32_t schema_version = 1;
    PolicyOwner owner;
    uint64_t revision = 0;
    unsigned lease_seconds = 30;
    // Static bootstrap sources (for example a local policy file) do not
    // expire. Network adapters must leave this false and renew via leases.
    bool persistent = false;
    std::vector<TapArpPolicy> policies;
};

enum class PolicyFeedOperation {
    ReplaceSnapshot,
    WithdrawSource,
};

struct PolicyFeedEvent {
    PolicyFeedOperation operation = PolicyFeedOperation::ReplaceSnapshot;
    PolicySnapshot snapshot;
    PolicyOwner owner;
    uint64_t revision = 0;
};
