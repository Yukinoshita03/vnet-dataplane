#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

// The interface feed deliberately has its own owner type.  The ARP policy
// model includes the BPF/map ABI, while an interface adapter must remain a
// small, dependency-free control-plane module.
struct InterfaceFeedOwner {
    std::string cluster_id;
    std::string source_id;

    bool operator<(const InterfaceFeedOwner &other) const
    {
        if (cluster_id != other.cluster_id)
            return cluster_id < other.cluster_id;
        return source_id < other.source_id;
    }

    bool operator==(const InterfaceFeedOwner &other) const
    {
        return cluster_id == other.cluster_id &&
               source_id == other.source_id;
    }
};

struct InterfaceTarget {
    std::string ifname;
    // Stable identity is normally Pod UID + network attachment.  It protects
    // the data plane from ifindex/name reuse after a Pod is deleted.
    std::string stable_id;

    bool operator==(const InterfaceTarget &other) const
    {
        return ifname == other.ifname && stable_id == other.stable_id;
    }
};

struct InterfaceSnapshot {
    uint32_t schema_version = 1;
    InterfaceFeedOwner owner;
    uint64_t revision = 0;
    unsigned lease_seconds = 30;
    bool persistent = false;
    std::vector<InterfaceTarget> targets;
};

enum class InterfaceFeedOperation {
    ReplaceSnapshot,
    WithdrawSource,
};

struct InterfaceFeedEvent {
    InterfaceFeedOperation operation = InterfaceFeedOperation::ReplaceSnapshot;
    InterfaceSnapshot snapshot;
    InterfaceFeedOwner owner;
    uint64_t revision = 0;
};

bool decode_interface_feed_message(const std::string &wire,
                                   InterfaceFeedEvent *event,
                                   std::string *error);
std::string encode_interface_feed_message(const InterfaceFeedEvent &event,
                                          std::string *error);

class InterfaceFeedServer {
public:
    static std::unique_ptr<InterfaceFeedServer>
    Create(const std::string &socket_path, int allowed_uid, std::string *error);

    InterfaceFeedServer(const InterfaceFeedServer &) = delete;
    InterfaceFeedServer &operator=(const InterfaceFeedServer &) = delete;

    ~InterfaceFeedServer();

    // Non-blocking. Returns the number of accepted interface events.
    int Poll(std::vector<InterfaceFeedEvent> *events, std::string *error);

private:
    InterfaceFeedServer(int listen_fd, std::string socket_path, int allowed_uid);

    bool accept_clients(std::string *error);

    int listen_fd_;
    std::string socket_path_;
    int allowed_uid_;
    std::vector<int> clients_;
};

class InterfaceReconciler {
public:
    bool ApplySnapshot(const InterfaceSnapshot &snapshot, std::string *error);
    bool WithdrawSource(const InterfaceFeedOwner &owner, uint64_t revision,
                        std::string *error);
    bool Expire(uint64_t now_ns, std::string *error);

    const std::vector<InterfaceTarget> &merged_targets() const;
    bool empty() const;

private:
    struct SourceRecord {
        InterfaceSnapshot snapshot;
        uint64_t expires_ns = 0;
    };

    bool rebuild_merged(
        const std::map<InterfaceFeedOwner, SourceRecord> &candidate,
        std::vector<InterfaceTarget> *merged, std::string *error) const;

    std::map<InterfaceFeedOwner, SourceRecord> sources_;
    std::map<InterfaceFeedOwner, uint64_t> last_revisions_;
    std::vector<InterfaceTarget> merged_;
};

uint64_t interface_feed_monotonic_now_ns();
