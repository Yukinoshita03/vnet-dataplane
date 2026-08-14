#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

#include "policy_feed.hpp"
#include "policy_reconciler.hpp"

namespace {

int check(bool condition, const std::string &message)
{
    if (!condition) {
        std::cerr << "not ok - " << message << "\n";
        return -1;
    }
    return 0;
}

PolicySnapshot snapshot(const char *cluster, const char *source,
                        uint64_t revision, const char *tap,
                        const char *address, const char *mac,
                        unsigned lease = 30)
{
    PolicySnapshot result;
    result.owner = {cluster, source};
    result.revision = revision;
    result.lease_seconds = lease;
    result.policies = {{tap, {{address, mac, lease}}}};
    return result;
}

bool contains_target(const std::vector<TapArpPolicy> &policies,
                     const std::string &tap, const std::string &address)
{
    for (const TapArpPolicy &policy : policies) {
        if (policy.tap_ifname != tap)
            continue;
        for (const ArpBindingSpec &binding : policy.bindings) {
            if (binding.target_ipv4 == address)
                return true;
        }
    }
    return false;
}

int connect_feed(const std::string &path)
{
    int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
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

} // namespace

int main()
{
    PolicyReconciler reconciler;
    std::string error;
    PolicySnapshot empty_snapshot = snapshot(
        "openstack", "empty", 1, "tap-empty", "10.0.0.1",
        "fa:16:3e:aa:bb:cc");
    empty_snapshot.policies.clear();
    if (check(reconciler.ApplySnapshot(empty_snapshot, &error),
              "apply an empty source snapshot: " + error) != 0)
        return 1;
    if (check(reconciler.empty(),
              "empty source snapshot has no effective merged policy") != 0)
        return 1;

    PolicySnapshot openstack = snapshot(
        "openstack", "neutron", 1, "tap-os", "10.0.0.1",
        "fa:16:3e:aa:bb:cc");
    if (check(reconciler.ApplySnapshot(openstack, &error),
              "apply OpenStack snapshot: " + error) != 0)
        return 1;
    if (check(contains_target(reconciler.merged_policies(), "tap-os",
                              "10.0.0.1"),
              "merged policy contains OpenStack target") != 0)
        return 1;

    PolicySnapshot kubernetes = snapshot(
        "kubernetes", "cni", 7, "veth-k8s", "10.244.0.1",
        "02:42:ac:11:00:02");
    if (check(reconciler.ApplySnapshot(kubernetes, &error),
              "apply Kubernetes snapshot: " + error) != 0)
        return 1;
    if (check(reconciler.merged_policies().size() == 2,
              "different clusters coexist in the merged view") != 0)
        return 1;

    PolicySnapshot conflict = snapshot(
        "kubernetes", "conflicting-cni", 1, "tap-os", "10.0.0.1",
        "fa:16:3e:00:00:01");
    error.clear();
    if (check(!reconciler.ApplySnapshot(conflict, &error) &&
                  error.find("conflict") != std::string::npos,
              "same tap/target ownership conflict is rejected") != 0)
        return 1;
    if (check(reconciler.merged_policies().size() == 2,
              "rejected conflict does not mutate merged policy") != 0)
        return 1;

    PolicySnapshot stale = openstack;
    stale.revision = 0;
    error.clear();
    if (check(!reconciler.ApplySnapshot(stale, &error),
              "zero revision is rejected") != 0)
        return 1;
    stale = openstack;
    // The source is still at revision one; reusing that revision with changed
    // data must be rejected instead of silently changing the owner state.
    stale.revision = 1;
    stale.policies[0].bindings[0].target_mac = "fa:16:3e:aa:bb:dd";
    error.clear();
    if (check(!reconciler.ApplySnapshot(stale, &error) &&
                  error.find("reused") != std::string::npos,
              "revision reuse with different data is rejected") != 0)
        return 1;

    if (check(reconciler.WithdrawSource(kubernetes.owner, 8, &error),
              "withdraw Kubernetes source: " + error) != 0)
        return 1;
    if (check(reconciler.merged_policies().size() == 1,
              "withdraw removes only the selected source") != 0)
        return 1;
    PolicySnapshot delayed_kubernetes = kubernetes;
    delayed_kubernetes.revision = 7;
    error.clear();
    if (check(!reconciler.ApplySnapshot(delayed_kubernetes, &error) &&
                  error.find("stale") != std::string::npos,
              "withdrawn source tombstone rejects delayed old snapshot") != 0)
        return 1;

    PolicySnapshot expiring = snapshot(
        "kubernetes", "short-lease", 2, "veth-short", "10.244.0.2",
        "02:42:ac:11:00:03", 1);
    if (check(reconciler.ApplySnapshot(expiring, &error),
              "apply expiring source: " + error) != 0)
        return 1;
    if (check(reconciler.Expire(policy_monotonic_now_ns() + 2'000'000'000ull,
                                &error),
              "expire short lease source: " + error) != 0)
        return 1;
    if (check(!contains_target(reconciler.merged_policies(), "veth-short",
                               "10.244.0.2"),
              "expired source is removed") != 0)
        return 1;
    PolicySnapshot delayed_expired = expiring;
    delayed_expired.revision = 1;
    error.clear();
    if (check(!reconciler.ApplySnapshot(delayed_expired, &error) &&
                  error.find("stale") != std::string::npos,
              "expired source tombstone rejects delayed old snapshot") != 0)
        return 1;

    PolicyFeedEvent replace;
    replace.snapshot = openstack;
    replace.snapshot.revision = 2;
    replace.operation = PolicyFeedOperation::ReplaceSnapshot;
    std::string wire = encode_policy_feed_message(replace, &error);
    if (check(!wire.empty(), "encode REPLACE feed message: " + error) != 0)
        return 1;
    PolicyFeedEvent decoded;
    if (check(decode_policy_feed_message(wire, &decoded, &error),
              "decode REPLACE feed message: " + error) != 0)
        return 1;
    if (check(decoded.snapshot.owner == replace.snapshot.owner &&
                  decoded.snapshot.revision == 2 &&
                  decoded.snapshot.policies.size() == 1,
              "REPLACE round trip preserves owner, revision and bindings") != 0)
        return 1;

    PolicyFeedEvent withdraw;
    withdraw.operation = PolicyFeedOperation::WithdrawSource;
    withdraw.owner = openstack.owner;
    withdraw.revision = 3;
    wire = encode_policy_feed_message(withdraw, &error);
    if (check(!wire.empty(), "encode WITHDRAW feed message: " + error) != 0)
        return 1;
    if (check(decode_policy_feed_message(wire, &decoded, &error) &&
                  decoded.operation == PolicyFeedOperation::WithdrawSource &&
                  decoded.owner == withdraw.owner && decoded.revision == 3,
              "WITHDRAW round trip preserves source revision") != 0)
        return 1;

    error.clear();
    if (check(!decode_policy_feed_message("YUKINONET_POLICY/1 REPLACE bad\n",
                                          &decoded, &error),
              "malformed feed message is rejected") != 0)
        return 1;

    PolicyFeedEvent oversized = replace;
    oversized.snapshot.policies.clear();
    for (int i = 0; i < 4096; ++i) {
        oversized.snapshot.policies.push_back(
            {"tap-" + std::to_string(i),
             {{"10.0.0.1", "fa:16:3e:aa:bb:cc", 30}}});
    }
    error.clear();
    if (check(encode_policy_feed_message(oversized, &error).empty() &&
                  error.find("exceeds") != std::string::npos,
              "oversized feed message is rejected") != 0)
        return 1;

    const std::string path = "/tmp/yukinonet-policy-feed-test-" +
                             std::to_string(getpid()) + ".sock";
    std::unique_ptr<PolicyFeedServer> server =
        PolicyFeedServer::Create(path, -1, &error);
    if (check(server != nullptr, "create policy feed server: " + error) != 0)
        return 1;
    int client_fd = connect_feed(path);
    if (check(client_fd >= 0,
              std::string("connect policy feed client: ") +
                  std::strerror(errno)) != 0)
        return 1;
    if (check(send(client_fd, wire.data(), wire.size(), 0) ==
                  static_cast<ssize_t>(wire.size()),
              "send one sequenced policy feed message") != 0)
        return 1;

    std::vector<PolicyFeedEvent> events;
    bool received = false;
    for (int attempt = 0; attempt < 50 && !received; ++attempt) {
        error.clear();
        int count = server->Poll(&events, &error);
        if (check(count >= 0, "poll policy feed server: " + error) != 0)
            return 1;
        received = !events.empty();
        if (!received)
            usleep(2 * 1000);
    }
    close(client_fd);
    if (check(received && events[0].operation ==
                                PolicyFeedOperation::WithdrawSource,
              "server emits decoded event to reconciler") != 0)
        return 1;

    std::cout << "Policy reconciler and feed tests passed\n";
    return 0;
}
