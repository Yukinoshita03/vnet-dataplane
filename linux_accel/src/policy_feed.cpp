#include "policy_feed.hpp"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <map>
#include <sstream>

namespace {

constexpr const char *kProtocol = "YUKINONET_POLICY/1";
constexpr size_t kMaxMessageBytes = 64 * 1024;
constexpr size_t kMaxBindings = 4096;
constexpr size_t kMaxTokenBytes = 128;

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

bool valid_token(const std::string &token)
{
    return !token.empty() && token.size() <= kMaxTokenBytes &&
           token.find_first_of(" \t\r\n") == std::string::npos;
}

bool group_binding(std::vector<TapArpPolicy> *policies,
                   const ArpBindingSpec &binding, const std::string &tap,
                   std::string *error)
{
    if (!valid_token(tap)) {
        if (error)
            *error = "invalid tap name in policy feed";
        return false;
    }
    TapArpPolicy *policy = nullptr;
    for (TapArpPolicy &candidate : *policies) {
        if (candidate.tap_ifname == tap) {
            policy = &candidate;
            break;
        }
    }
    if (!policy) {
        policies->push_back({});
        policy = &policies->back();
        policy->tap_ifname = tap;
    }
    policy->bindings.push_back(binding);
    return true;
}

bool parse_owner(const std::string &cluster, const std::string &source,
                 PolicyOwner *owner, std::string *error)
{
    if (!valid_token(cluster) || !valid_token(source)) {
        if (error)
            *error = "invalid policy source owner token";
        return false;
    }
    owner->cluster_id = cluster;
    owner->source_id = source;
    return true;
}

} // namespace

bool decode_policy_feed_message(const std::string &wire,
                                PolicyFeedEvent *event, std::string *error)
{
    if (!event) {
        if (error)
            *error = "policy feed event output is null";
        return false;
    }
    if (wire.empty() || wire.size() > kMaxMessageBytes) {
        if (error)
            *error = "policy feed message size is invalid";
        return false;
    }

    std::istringstream input(wire);
    std::string protocol;
    std::string operation;
    if (!(input >> protocol >> operation) || protocol != kProtocol) {
        if (error)
            *error = "invalid policy feed protocol header";
        return false;
    }

    *event = {};
    if (operation == "WITHDRAW") {
        std::string cluster;
        std::string source;
        std::string revision_text;
        uint64_t revision = 0;
        if (!(input >> cluster >> source >> revision_text) ||
            !parse_u64(revision_text, &revision) || revision == 0 ||
            !parse_owner(cluster, source, &event->owner, error)) {
            if (error && error->empty())
                *error = "invalid WITHDRAW policy feed message";
            return false;
        }
        std::string extra;
        if (input >> extra) {
            if (error)
                *error = "unexpected tokens after WITHDRAW message";
            return false;
        }
        event->operation = PolicyFeedOperation::WithdrawSource;
        event->revision = revision;
        return true;
    }

    if (operation != "REPLACE") {
        if (error)
            *error = "unknown policy feed operation: " + operation;
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
    if (!(input >> cluster >> source >> revision_text >> lease_text >> count_text) ||
        !parse_u64(revision_text, &revision) || revision == 0 ||
        !parse_unsigned(lease_text, &lease_seconds) ||
        lease_seconds > 24 * 60 * 60 ||
        !parse_u64(count_text, &count) || count > kMaxBindings ||
        !parse_owner(cluster, source, &event->snapshot.owner, error)) {
        if (error && error->empty())
            *error = "invalid REPLACE policy feed header";
        return false;
    }

    event->operation = PolicyFeedOperation::ReplaceSnapshot;
    event->snapshot.schema_version = 1;
    event->snapshot.revision = revision;
    event->snapshot.lease_seconds = lease_seconds;
    for (uint64_t i = 0; i < count; ++i) {
        std::string tap;
        ArpBindingSpec binding;
        std::string binding_lease;
        if (!(input >> tap >> binding.target_ipv4 >> binding.target_mac >>
              binding_lease) || !parse_unsigned(binding_lease,
                                                  &binding.lease_seconds) ||
            !group_binding(&event->snapshot.policies, binding, tap, error)) {
            if (error && error->empty())
                *error = "invalid binding in REPLACE policy feed message";
            return false;
        }
    }
    std::string extra;
    if (input >> extra) {
        if (error)
            *error = "unexpected tokens after REPLACE policy message";
        return false;
    }
    if (!validate_arp_policy_specs(event->snapshot.policies, false, error))
        return false;
    return true;
}

std::string encode_policy_feed_message(const PolicyFeedEvent &event,
                                       std::string *error)
{
    std::ostringstream output;
    if (event.operation == PolicyFeedOperation::WithdrawSource) {
        if (!valid_token(event.owner.cluster_id) ||
            !valid_token(event.owner.source_id) || event.revision == 0) {
            if (error && error->empty())
                *error = "invalid WITHDRAW event";
            return {};
        }
        output << kProtocol << " WITHDRAW " << event.owner.cluster_id << ' '
               << event.owner.source_id << ' ' << event.revision << '\n';
        std::string wire = output.str();
        if (wire.size() > kMaxMessageBytes) {
            if (error)
                *error = "WITHDRAW policy feed message exceeds the limit";
            return {};
        }
        return wire;
    }

    const PolicySnapshot &snapshot = event.snapshot;
    if (snapshot.schema_version != 1 || snapshot.revision == 0 ||
        snapshot.persistent || snapshot.lease_seconds == 0 ||
        snapshot.lease_seconds > 24 * 60 * 60 ||
        !valid_token(snapshot.owner.cluster_id) ||
        !valid_token(snapshot.owner.source_id) ||
        !validate_arp_policy_specs(snapshot.policies, false, error))
        return {};

    size_t count = 0;
    for (const TapArpPolicy &policy : snapshot.policies)
        count += policy.bindings.size();
    if (count > kMaxBindings) {
        if (error)
            *error = "policy feed binding count exceeds the limit";
        return {};
    }
    output << kProtocol << " REPLACE " << snapshot.owner.cluster_id << ' '
           << snapshot.owner.source_id << ' ' << snapshot.revision << ' '
           << snapshot.lease_seconds << ' ' << count << '\n';
    for (const TapArpPolicy &policy : snapshot.policies) {
        for (const ArpBindingSpec &binding : policy.bindings) {
            output << policy.tap_ifname << ' ' << binding.target_ipv4 << ' '
                   << binding.target_mac << ' ' << binding.lease_seconds << '\n';
        }
    }
    std::string wire = output.str();
    if (wire.size() > kMaxMessageBytes) {
        if (error)
            *error = "REPLACE policy feed message exceeds the limit";
        return {};
    }
    return wire;
}

PolicyFeedServer::PolicyFeedServer(int listen_fd, std::string socket_path,
                                   int allowed_uid)
    : listen_fd_(listen_fd),
      socket_path_(std::move(socket_path)),
      allowed_uid_(allowed_uid)
{
}

std::unique_ptr<PolicyFeedServer>
PolicyFeedServer::Create(const std::string &socket_path, int allowed_uid,
                         std::string *error)
{
    sockaddr_un address = {};
    if (socket_path.empty() || socket_path.size() >= sizeof(address.sun_path)) {
        if (error)
            *error = "policy feed socket path is empty or too long";
        return nullptr;
    }

    int socket_fd = socket(AF_UNIX,
                           SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (socket_fd < 0) {
        if (error)
            *error = std::string("failed to create policy feed socket: ") +
                     strerror(errno);
        return nullptr;
    }

    address.sun_family = AF_UNIX;
    std::strncpy(address.sun_path, socket_path.c_str(),
                 sizeof(address.sun_path) - 1);
    if (bind(socket_fd, reinterpret_cast<sockaddr *>(&address),
             sizeof(address)) != 0) {
        if (error)
            *error = std::string("failed to bind policy feed socket: ") +
                     strerror(errno);
        close(socket_fd);
        return nullptr;
    }
    if (chmod(socket_path.c_str(), 0660) != 0 || listen(socket_fd, 16) != 0) {
        if (error)
            *error = std::string("failed to configure policy feed socket: ") +
                     strerror(errno);
        close(socket_fd);
        unlink(socket_path.c_str());
        return nullptr;
    }

    int effective_uid = allowed_uid < 0 ? static_cast<int>(geteuid())
                                        : allowed_uid;
    return std::unique_ptr<PolicyFeedServer>(
        new PolicyFeedServer(socket_fd, socket_path, effective_uid));
}

bool PolicyFeedServer::accept_clients(std::string *error)
{
    for (;;) {
        int client_fd = accept4(listen_fd_, nullptr, nullptr,
                                SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (client_fd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                return true;
            if (errno == EINTR)
                continue;
            if (error)
                *error = std::string("failed to accept policy feed client: ") +
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

int PolicyFeedServer::Poll(std::vector<PolicyFeedEvent> *events,
                           std::string *error)
{
    if (!events) {
        if (error)
            *error = "policy feed event output is null";
        return -1;
    }
    events->clear();
    if (!accept_clients(error))
        return -1;

    std::vector<pollfd> descriptors;
    descriptors.reserve(clients_.size());
    for (int client_fd : clients_)
        descriptors.push_back({client_fd, POLLIN | POLLERR | POLLHUP, 0});
    if (!descriptors.empty() && poll(descriptors.data(), descriptors.size(), 0) < 0 &&
        errno != EINTR) {
        if (error)
            *error = std::string("failed to poll policy feed clients: ") +
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
            descriptors.erase(descriptors.begin() + static_cast<ptrdiff_t>(index));
            continue;
        }

        PolicyFeedEvent event;
        std::string decode_error;
        if (decode_policy_feed_message(
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

PolicyFeedServer::~PolicyFeedServer()
{
    for (int client_fd : clients_)
        close(client_fd);
    if (listen_fd_ >= 0)
        close(listen_fd_);
    if (!socket_path_.empty())
        unlink(socket_path_.c_str());
}
