#include "cache_policy_txn_path_policy.hpp"

#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr const char *kPortId = "2200c160-c07d-43ea-9cda-5aabd4e54d37";

bool expect_valid(const std::string &lock_file,
                  const std::string &quiesce_file,
                  const std::vector<std::string> &maps)
{
    std::string error;
    if (cache_policy_txn::validate_production_paths(
            lock_file, quiesce_file, maps, &error)) {
        return true;
    }
    std::cerr << "unexpected rejection: " << error << "\n";
    return false;
}

bool expect_invalid(const std::string &lock_file,
                    const std::string &quiesce_file,
                    const std::vector<std::string> &maps)
{
    std::string error;
    if (!cache_policy_txn::validate_production_paths(
            lock_file, quiesce_file, maps, &error)) {
        return !error.empty();
    }
    std::cerr << "unexpected path acceptance\n";
    return false;
}

} // namespace

int main()
{
    const std::string policy_root = "/run/vnet-dataplane-policy/";
    const std::string stem = std::string("vnet-dataplane-") + kPortId;
    const std::string lock_file = policy_root + stem + ".lock";
    const std::string quiesce_file = policy_root + stem + ".quiesce";
    const std::string host_dns =
        std::string("/sys/fs/bpf/vnet-dataplane-agent/") + kPortId +
        "/dns/cache_runtime_control";
    const std::string guest_grpc =
        std::string("/sys/fs/bpf/vnet-dataplane-guest/") + kPortId +
        "/grpc/cache_runtime_control";

    if (!expect_valid(lock_file, quiesce_file, {host_dns, guest_grpc}) ||
        !expect_invalid("/tmp/transaction.lock", quiesce_file, {host_dns}) ||
        !expect_invalid(lock_file, "/etc/shadow", {host_dns}) ||
        !expect_invalid(
            policy_root + "../outside.lock", quiesce_file, {host_dns}) ||
        !expect_invalid(lock_file, quiesce_file,
                        {"/sys/fs/bpf/other/cache_runtime_control"}) ||
        !expect_invalid(lock_file, quiesce_file,
                        {host_dns + "/../other"})) {
        return 1;
    }

    std::cout << "cache_policy_txn_path_test: PASS\n";
    return 0;
}
