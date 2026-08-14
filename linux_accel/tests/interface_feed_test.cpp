#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <iostream>
#include <string>
#include <utility>

#include "interface_feed.hpp"

namespace {

int check(bool condition, const std::string &message)
{
    if (!condition) {
        std::cerr << "not ok - " << message << "\n";
        return 1;
    }
    return 0;
}

InterfaceSnapshot snapshot(const char *source, uint64_t revision,
                           unsigned lease, std::vector<InterfaceTarget> targets)
{
    InterfaceSnapshot result;
    result.owner = {"kubernetes", source};
    result.revision = revision;
    result.lease_seconds = lease;
    result.targets = std::move(targets);
    return result;
}

#ifdef __linux__
int connect_feed(const std::string &path)
{
    int fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    if (fd < 0)
        return -1;
    sockaddr_un address = {};
    address.sun_family = AF_UNIX;
    if (path.size() >= sizeof(address.sun_path)) {
        close(fd);
        return -1;
    }
    std::strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);
    if (connect(fd, reinterpret_cast<sockaddr *>(&address),
                sizeof(address)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}
#endif

} // namespace

int main()
{
    std::string error;
    InterfaceFeedEvent replace;
    replace.snapshot = snapshot(
        "cni-node1", 4, 30,
        {{"veth-a", "pod-a/eth0"}, {"veth-b", "pod-b/eth0"}});

    std::string wire = encode_interface_feed_message(replace, &error);
    if (check(!wire.empty(), "encode interface REPLACE: " + error) != 0)
        return 1;

    InterfaceFeedEvent decoded;
    if (check(decode_interface_feed_message(wire, &decoded, &error),
              "decode interface REPLACE: " + error) != 0)
        return 1;
    if (check(decoded.snapshot.owner == replace.snapshot.owner &&
                  decoded.snapshot.revision == 4 &&
                  decoded.snapshot.targets.size() == 2 &&
                  decoded.snapshot.targets[1].stable_id == "pod-b/eth0",
              "REPLACE round trip preserves target identity") != 0)
        return 1;

    InterfaceSnapshot empty = snapshot("empty", 1, 30, {});
    replace.snapshot = empty;
    wire = encode_interface_feed_message(replace, &error);
    if (check(!wire.empty() && decode_interface_feed_message(wire, &decoded,
                                                              &error),
              "empty snapshot is a valid keep-alive state: " + error) != 0)
        return 1;

    if (check(!decode_interface_feed_message(
                  "YUKINONET_INTERFACE/1 REPLACE kubernetes cni 1 30 2\n"
                  "veth-a pod-a/eth0\n"
                  "veth-a pod-b/eth0\n",
                  &decoded, &error),
              "duplicate interface target is rejected") != 0)
        return 1;

    InterfaceReconciler reconciler;
    InterfaceSnapshot node1 = snapshot(
        "cni-node1", 1, 30, {{"veth-a", "pod-a/eth0"}});
    if (check(reconciler.ApplySnapshot(node1, &error),
              "apply first source: " + error) != 0)
        return 1;
    InterfaceSnapshot duplicate = snapshot(
        "profile", 1, 30, {{"veth-a", "pod-a/eth0"}});
    if (check(reconciler.ApplySnapshot(duplicate, &error),
              "identical target from another source is idempotent: " + error) !=
        0)
        return 1;
    if (check(reconciler.merged_targets().size() == 1,
              "identical targets are merged once") != 0)
        return 1;

    InterfaceSnapshot conflict = snapshot(
        "conflict", 1, 30, {{"veth-a", "pod-other/eth0"}});
    error.clear();
    if (check(!reconciler.ApplySnapshot(conflict, &error) &&
                  error.find("conflict") != std::string::npos,
              "different stable identity on one interface is rejected") != 0)
        return 1;
    if (check(reconciler.merged_targets().size() == 1,
              "rejected conflict leaves desired state unchanged") != 0)
        return 1;

    InterfaceSnapshot stale = node1;
    stale.revision = 0;
    error.clear();
    if (check(!reconciler.ApplySnapshot(stale, &error),
              "zero revision is rejected") != 0)
        return 1;

    if (check(reconciler.WithdrawSource(node1.owner, 2, &error),
              "withdraw source: " + error) != 0)
        return 1;
    error.clear();
    node1.revision = 1;
    if (check(!reconciler.ApplySnapshot(node1, &error) &&
                  error.find("stale") != std::string::npos,
              "withdraw tombstone rejects delayed snapshot") != 0)
        return 1;

    InterfaceSnapshot expiring = snapshot(
        "short", 3, 1, {{"veth-expire", "pod-expire/eth0"}});
    if (check(reconciler.ApplySnapshot(expiring, &error),
              "apply expiring source: " + error) != 0)
        return 1;
    if (check(reconciler.Expire(interface_feed_monotonic_now_ns() +
                                   2'000'000'000ull,
                               &error),
              "expire source: " + error) != 0)
        return 1;
    bool expired_present = false;
    for (const InterfaceTarget &target : reconciler.merged_targets()) {
        if (target.ifname == "veth-expire")
            expired_present = true;
    }
    if (check(!expired_present, "expired source removes its target") != 0)
        return 1;

    InterfaceFeedEvent withdraw;
    withdraw.operation = InterfaceFeedOperation::WithdrawSource;
    withdraw.owner = {"kubernetes", "cni-node1"};
    withdraw.revision = 3;
    wire = encode_interface_feed_message(withdraw, &error);
    if (check(!wire.empty() && decode_interface_feed_message(wire, &decoded,
                                                              &error) &&
                  decoded.operation == InterfaceFeedOperation::WithdrawSource,
              "WITHDRAW round trip preserves operation: " + error) != 0)
        return 1;

#ifdef __linux__
    const std::string socket_path = "/tmp/yukinonet-interface-feed-test-" +
                                    std::to_string(getpid()) + ".sock";
    std::unique_ptr<InterfaceFeedServer> server =
        InterfaceFeedServer::Create(socket_path, -1, &error);
    if (check(server != nullptr, "create interface feed server: " + error) != 0)
        return 1;
    int client_fd = connect_feed(socket_path);
    if (check(client_fd >= 0,
              std::string("connect interface feed client: ") +
                  std::strerror(errno)) != 0)
        return 1;
    InterfaceFeedEvent server_event;
    server_event.snapshot = snapshot(
        "server", 5, 30, {{"veth-server", "pod-server/eth0"}});
    wire = encode_interface_feed_message(server_event, &error);
    if (check(send(client_fd, wire.data(), wire.size(), 0) ==
                  static_cast<ssize_t>(wire.size()),
              "send interface feed datagram") != 0)
        return 1;
    std::vector<InterfaceFeedEvent> events;
    bool received = false;
    for (int attempt = 0; attempt < 50 && !received; ++attempt) {
        error.clear();
        int count = server->Poll(&events, &error);
        if (check(count >= 0, "poll interface feed server: " + error) != 0)
            return 1;
        received = !events.empty();
        if (!received)
            usleep(2 * 1000);
    }
    close(client_fd);
    if (check(received && events[0].snapshot.targets[0].stable_id ==
                                "pod-server/eth0",
              "interface feed server emits decoded datagram") != 0)
        return 1;
#endif

    std::cout << "Interface feed and reconciler tests passed\n";
    return 0;
}
