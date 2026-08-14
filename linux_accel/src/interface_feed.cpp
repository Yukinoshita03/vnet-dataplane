#include "interface_feed.hpp"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <map>
#include <sstream>
#include <utility>

namespace {

constexpr const char *kProtocol = "YUKINONET_INTERFACE/1";
constexpr size_t kMaxMessageBytes = 64 * 1024;
constexpr size_t kMaxTargets = 4096;
constexpr size_t kMaxTokenBytes = 128;
constexpr size_t kMaxStableIdBytes = 256;
constexpr unsigned kMaxLeaseSeconds = 24 * 60 * 60;
constexpr size_t kMaxIfnameBytes = 15;

bool parse_u64(const std::string &text, uint64_t *value)
{
    if (text.empty() || text[0] == '-')
        return false;
    errno = 0;
    char *end = nullptr;
    unsigned long long parsed = std::strtoull(text.c_str(), &end, 10);
    if (errno == ERANGE || !end || *end != '\0' ||
        parsed > std::numeric_limits<uint64_t>::max())
        return false;
    *value = static_cast<uint64_t>(parsed);
    return true;
}

bool parse_unsigned(const std::string &text, unsigned *value)
{
    uint64_t parsed = 0;
    if (!parse_u64(text, &parsed) || parsed == 0 ||
        parsed > std::numeric_limits<unsigned>::max())
        return false;
    *value = static_cast<unsigned>(parsed);
    return true;
}

bool valid_token(const std::string &token, size_t max_bytes = kMaxTokenBytes)
{
    return !token.empty() && token.size() <= max_bytes &&
           token.find_first_of(" \t\r\n") == std::string::npos;
}

bool valid_interface_target(const InterfaceTarget &target, std::string *error)
{
    if (!valid_token(target.ifname, kMaxIfnameBytes) ||
        target.ifname.find('/') != std::string::npos ||
        target.ifname == "." || target.ifname == "..") {
        if (error)
            *error = "invalid interface name in interface feed";
        return false;
    }
    if (!valid_token(target.stable_id, kMaxStableIdBytes)) {
        if (error)
            *error = "invalid stable interface identity in interface feed";
        return false;
    }
    return true;
}

bool valid_owner(const InterfaceFeedOwner &owner, std::string *error)
{
    if (!valid_token(owner.cluster_id) || !valid_token(owner.source_id)) {
        if (error)
            *error = "invalid interface feed source owner";
        return false;
    }
    return true;
}

bool validate_snapshot(const InterfaceSnapshot &snapshot, bool allow_persistent,
                       std::string *error)
{
    if (snapshot.schema_version != 1 || snapshot.revision == 0 ||
        (!snapshot.persistent && snapshot.lease_seconds == 0) ||
        snapshot.lease_seconds > kMaxLeaseSeconds ||
        (!allow_persistent && snapshot.persistent) ||
        !valid_owner(snapshot.owner, error) ||
        snapshot.targets.size() > kMaxTargets)
        return false;

    std::map<std::string, std::string> seen;
    for (const InterfaceTarget &target : snapshot.targets) {
        if (!valid_interface_target(target, error))
            return false;
        auto inserted = seen.emplace(target.ifname, target.stable_id);
        if (!inserted.second) {
            if (error)
                *error = "duplicate interface in interface feed: " +
                         target.ifname;
            return false;
        }
    }
    return true;
}

bool same_snapshot(const InterfaceSnapshot &left,
                   const InterfaceSnapshot &right)
{
    if (left.schema_version != right.schema_version ||
        !(left.owner == right.owner) || left.revision != right.revision ||
        left.lease_seconds != right.lease_seconds ||
        left.persistent != right.persistent ||
        left.targets.size() != right.targets.size())
        return false;
    for (size_t i = 0; i < left.targets.size(); ++i) {
        if (!(left.targets[i] == right.targets[i]))
            return false;
    }
    return true;
}

int accept_client(int listen_fd)
{
#ifdef __linux__
    return accept4(listen_fd, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
#else
    int client_fd = accept(listen_fd, nullptr, nullptr);
    if (client_fd < 0)
        return client_fd;
    int flags = fcntl(client_fd, F_GETFL, 0);
    if (flags >= 0)
        fcntl(client_fd, F_SETFL, flags | O_NONBLOCK);
    fcntl(client_fd, F_SETFD, FD_CLOEXEC);
    return client_fd;
#endif
}

} // namespace

uint64_t interface_feed_monotonic_now_ns()
{
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

bool decode_interface_feed_message(const std::string &wire,
                                   InterfaceFeedEvent *event,
                                   std::string *error)
{
    if (!event) {
        if (error)
            *error = "interface feed event output is null";
        return false;
    }
    if (wire.empty() || wire.size() > kMaxMessageBytes) {
        if (error)
            *error = "interface feed message size is invalid";
        return false;
    }

    std::istringstream input(wire);
    std::string protocol;
    std::string operation;
    if (!(input >> protocol >> operation) || protocol != kProtocol) {
        if (error)
            *error = "invalid interface feed protocol header";
        return false;
    }

    *event = {};
    if (operation == "WITHDRAW") {
        std::string cluster;
        std::string source;
        std::string revision_text;
        uint64_t revision = 0;
        if (!(input >> cluster >> source >> revision_text) ||
            !parse_u64(revision_text, &revision) || revision == 0) {
            if (error)
                *error = "invalid WITHDRAW interface feed message";
            return false;
        }
        event->owner = {cluster, source};
        if (!valid_owner(event->owner, error))
            return false;
        std::string extra;
        if (input >> extra) {
            if (error)
                *error = "unexpected tokens after WITHDRAW interface message";
            return false;
        }
        event->operation = InterfaceFeedOperation::WithdrawSource;
        event->revision = revision;
        return true;
    }

    if (operation != "REPLACE") {
        if (error)
            *error = "unknown interface feed operation: " + operation;
        return false;
    }

    std::string cluster;
    std::string source;
    std::string revision_text;
    std::string lease_text;
    std::string count_text;
    uint64_t revision = 0;
    unsigned lease_seconds = 0;
    uint64_t count = 0;
    if (!(input >> cluster >> source >> revision_text >> lease_text >>
          count_text) ||
        !parse_u64(revision_text, &revision) || revision == 0 ||
        !parse_unsigned(lease_text, &lease_seconds) ||
        lease_seconds > kMaxLeaseSeconds || !parse_u64(count_text, &count) ||
        count > kMaxTargets) {
        if (error)
            *error = "invalid REPLACE interface feed header";
        return false;
    }

    event->operation = InterfaceFeedOperation::ReplaceSnapshot;
    event->snapshot.schema_version = 1;
    event->snapshot.owner = {cluster, source};
    event->snapshot.revision = revision;
    event->snapshot.lease_seconds = lease_seconds;
    event->snapshot.targets.reserve(static_cast<size_t>(count));
    for (uint64_t i = 0; i < count; ++i) {
        InterfaceTarget target;
        if (!(input >> target.ifname >> target.stable_id) ||
            !valid_interface_target(target, error))
            return false;
        event->snapshot.targets.push_back(std::move(target));
    }

    std::string extra;
    if (input >> extra) {
        if (error)
            *error = "unexpected tokens after REPLACE interface message";
        return false;
    }
    return validate_snapshot(event->snapshot, false, error);
}

std::string encode_interface_feed_message(const InterfaceFeedEvent &event,
                                          std::string *error)
{
    std::ostringstream output;
    if (event.operation == InterfaceFeedOperation::WithdrawSource) {
        if (event.revision == 0 || !valid_owner(event.owner, error)) {
            if (error && error->empty())
                *error = "invalid WITHDRAW interface event";
            return {};
        }
        output << kProtocol << " WITHDRAW " << event.owner.cluster_id << ' '
               << event.owner.source_id << ' ' << event.revision << '\n';
    } else {
        const InterfaceSnapshot &snapshot = event.snapshot;
        if (!validate_snapshot(snapshot, false, error))
            return {};
        output << kProtocol << " REPLACE " << snapshot.owner.cluster_id << ' '
               << snapshot.owner.source_id << ' ' << snapshot.revision << ' '
               << snapshot.lease_seconds << ' ' << snapshot.targets.size()
               << '\n';
        for (const InterfaceTarget &target : snapshot.targets)
            output << target.ifname << ' ' << target.stable_id << '\n';
    }

    std::string wire = output.str();
    if (wire.size() > kMaxMessageBytes) {
        if (error)
            *error = "interface feed message exceeds the limit";
        return {};
    }
    return wire;
}

InterfaceFeedServer::InterfaceFeedServer(int listen_fd,
                                         std::string socket_path,
                                         int allowed_uid)
    : listen_fd_(listen_fd),
      socket_path_(std::move(socket_path)),
      allowed_uid_(allowed_uid)
{
}

std::unique_ptr<InterfaceFeedServer>
InterfaceFeedServer::Create(const std::string &socket_path, int allowed_uid,
                            std::string *error)
{
    sockaddr_un address = {};
    if (socket_path.empty() || socket_path.size() >= sizeof(address.sun_path)) {
        if (error)
            *error = "interface feed socket path is empty or too long";
        return nullptr;
    }

    int socket_fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    if (socket_fd < 0) {
        if (error)
            *error = std::string("failed to create interface feed socket: ") +
                     strerror(errno);
        return nullptr;
    }
    int socket_flags = fcntl(socket_fd, F_GETFL, 0);
    if (socket_flags < 0 || fcntl(socket_fd, F_SETFL,
                                  socket_flags | O_NONBLOCK) != 0 ||
        fcntl(socket_fd, F_SETFD, FD_CLOEXEC) != 0) {
        if (error)
            *error = std::string("failed to configure interface feed socket: ") +
                     strerror(errno);
        close(socket_fd);
        return nullptr;
    }

    address.sun_family = AF_UNIX;
    std::strncpy(address.sun_path, socket_path.c_str(),
                 sizeof(address.sun_path) - 1);
    if (bind(socket_fd, reinterpret_cast<sockaddr *>(&address),
             sizeof(address)) != 0) {
        if (error)
            *error = std::string("failed to bind interface feed socket: ") +
                     strerror(errno);
        close(socket_fd);
        return nullptr;
    }
    if (chmod(socket_path.c_str(), 0660) != 0 || listen(socket_fd, 16) != 0) {
        if (error)
            *error = std::string("failed to configure interface feed socket: ") +
                     strerror(errno);
        close(socket_fd);
        unlink(socket_path.c_str());
        return nullptr;
    }

    int effective_uid = allowed_uid < 0 ? static_cast<int>(geteuid())
                                        : allowed_uid;
    return std::unique_ptr<InterfaceFeedServer>(new InterfaceFeedServer(
        socket_fd, socket_path, effective_uid));
}

bool InterfaceFeedServer::accept_clients(std::string *error)
{
#ifndef SO_PEERCRED
    (void)allowed_uid_;
#endif
    for (;;) {
        int client_fd = accept_client(listen_fd_);
        if (client_fd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                return true;
            if (errno == EINTR)
                continue;
            if (error)
                *error = std::string("failed to accept interface feed client: ") +
                         strerror(errno);
            return false;
        }

#ifdef SO_PEERCRED
        ucred credentials = {};
        socklen_t length = sizeof(credentials);
        if (getsockopt(client_fd, SOL_SOCKET, SO_PEERCRED, &credentials,
                       &length) != 0 ||
            (allowed_uid_ >= 0 && credentials.uid != 0 &&
             static_cast<int>(credentials.uid) != allowed_uid_)) {
            close(client_fd);
            continue;
        }
#endif
        clients_.push_back(client_fd);
    }
}

int InterfaceFeedServer::Poll(std::vector<InterfaceFeedEvent> *events,
                               std::string *error)
{
    if (!events) {
        if (error)
            *error = "interface feed event output is null";
        return -1;
    }
    events->clear();
    if (!accept_clients(error))
        return -1;

    std::vector<pollfd> descriptors;
    descriptors.reserve(clients_.size());
    for (int client_fd : clients_)
        descriptors.push_back({client_fd, POLLIN | POLLERR | POLLHUP, 0});
    if (!descriptors.empty() &&
        poll(descriptors.data(), descriptors.size(), 0) < 0 && errno != EINTR) {
        if (error)
            *error = std::string("failed to poll interface feed clients: ") +
                     strerror(errno);
        return -1;
    }

    for (size_t index = 0; index < descriptors.size();) {
        const short revents = descriptors[index].revents;
        if (!(revents & (POLLIN | POLLERR | POLLHUP))) {
            index++;
            continue;
        }

        std::array<char, kMaxMessageBytes + 1> buffer = {};
        ssize_t received = recv(descriptors[index].fd, buffer.data(),
                                kMaxMessageBytes + 1, MSG_DONTWAIT);
        if (received <= 0) {
            if (received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                index++;
                continue;
            }
            close(descriptors[index].fd);
            clients_.erase(clients_.begin() + static_cast<ptrdiff_t>(index));
            descriptors.erase(descriptors.begin() +
                              static_cast<ptrdiff_t>(index));
            continue;
        }

        InterfaceFeedEvent event;
        std::string decode_error;
        if (decode_interface_feed_message(
                std::string(buffer.data(), static_cast<size_t>(received)),
                &event, &decode_error)) {
            events->push_back(std::move(event));
        } else if (error && error->empty()) {
            *error = decode_error;
        }
        index++;
    }
    return static_cast<int>(events->size());
}

InterfaceFeedServer::~InterfaceFeedServer()
{
    for (int client_fd : clients_)
        close(client_fd);
    if (listen_fd_ >= 0)
        close(listen_fd_);
    if (!socket_path_.empty())
        unlink(socket_path_.c_str());
}

bool InterfaceReconciler::ApplySnapshot(const InterfaceSnapshot &snapshot,
                                        std::string *error)
{
    if (!validate_snapshot(snapshot, false, error))
        return false;

    const uint64_t now = interface_feed_monotonic_now_ns();
    std::map<InterfaceFeedOwner, SourceRecord> candidate = sources_;
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
                *error = "stale interface snapshot revision";
            return false;
        }
        if (snapshot.revision == existing->second.snapshot.revision &&
            !same_snapshot(snapshot, existing->second.snapshot)) {
            if (error)
                *error = "interface snapshot revision was reused with different data";
            return false;
        }
    }
    auto last_revision = last_revisions_.find(snapshot.owner);
    if (last_revision != last_revisions_.end() &&
        snapshot.revision < last_revision->second) {
        if (error)
            *error = "stale interface snapshot revision";
        return false;
    }

    SourceRecord replacement;
    replacement.snapshot = snapshot;
    replacement.expires_ns = snapshot.persistent
                                 ? std::numeric_limits<uint64_t>::max()
                                 : now + static_cast<uint64_t>(snapshot.lease_seconds) *
                                           1000000000ull;
    candidate[snapshot.owner] = std::move(replacement);

    std::vector<InterfaceTarget> merged;
    if (!rebuild_merged(candidate, &merged, error))
        return false;
    sources_ = std::move(candidate);
    last_revisions_[snapshot.owner] = snapshot.revision;
    merged_ = std::move(merged);
    return true;
}

bool InterfaceReconciler::WithdrawSource(const InterfaceFeedOwner &owner,
                                         uint64_t revision, std::string *error)
{
    if (!valid_owner(owner, error) || revision == 0) {
        if (error && error->empty())
            *error = "invalid interface withdrawal owner or revision";
        return false;
    }
    auto last_revision = last_revisions_.find(owner);
    if (last_revision != last_revisions_.end() &&
        revision < last_revision->second) {
        if (error)
            *error = "stale interface withdrawal revision";
        return false;
    }

    std::map<InterfaceFeedOwner, SourceRecord> candidate = sources_;
    candidate.erase(owner);
    std::vector<InterfaceTarget> merged;
    if (!rebuild_merged(candidate, &merged, error))
        return false;
    sources_ = std::move(candidate);
    last_revisions_[owner] = revision;
    merged_ = std::move(merged);
    return true;
}

bool InterfaceReconciler::Expire(uint64_t now_ns, std::string *error)
{
    std::map<InterfaceFeedOwner, SourceRecord> candidate = sources_;
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

    std::vector<InterfaceTarget> merged;
    if (!rebuild_merged(candidate, &merged, error))
        return false;
    sources_ = std::move(candidate);
    merged_ = std::move(merged);
    return true;
}

const std::vector<InterfaceTarget> &InterfaceReconciler::merged_targets() const
{
    return merged_;
}

bool InterfaceReconciler::empty() const
{
    return merged_.empty();
}

bool InterfaceReconciler::rebuild_merged(
    const std::map<InterfaceFeedOwner, SourceRecord> &candidate,
    std::vector<InterfaceTarget> *merged, std::string *error) const
{
    std::map<std::string, std::pair<InterfaceTarget, InterfaceFeedOwner>> grouped;
    for (const auto &source : candidate) {
        for (const InterfaceTarget &target : source.second.snapshot.targets) {
            auto existing = grouped.find(target.ifname);
            if (existing != grouped.end()) {
                if (!(existing->second.first == target)) {
                    if (error)
                        *error = "interface ownership conflict on " +
                                 target.ifname;
                    return false;
                }
                continue;
            }
            grouped.emplace(target.ifname,
                            std::make_pair(target, source.first));
        }
    }

    merged->clear();
    merged->reserve(grouped.size());
    for (auto &entry : grouped)
        merged->push_back(std::move(entry.second.first));
    return true;
}
