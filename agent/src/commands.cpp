#include "vnet/agent/commands.hpp"

#include "vnet/agent/command_runner.hpp"

#include <filesystem>
#include <iostream>

namespace vnet::agent {
namespace {

std::filesystem::path RepoRoot() {
#if defined(VNET_AGENT_SOURCE_DIR)
  return std::filesystem::path{VNET_AGENT_SOURCE_DIR}.parent_path();
#else
  return std::filesystem::current_path();
#endif
}

}  // namespace

int RunProbe() {
  if (!IsLinuxPlatform()) {
    std::cerr << "probe is Linux-only in v1\n";
    return 1;
  }
  return RunLinuxScript(RepoRoot() / "linux_accel" / "bench" / "openstack_path_probe.sh");
}

int RunBenchVirtPath() {
  if (!IsLinuxPlatform()) {
    std::cerr << "bench virt-path is Linux-only in v1\n";
    return 1;
  }
  return RunLinuxScript(RepoRoot() / "linux_accel" / "bench" / "virt_path_bench.sh");
}

}  // namespace vnet::agent
