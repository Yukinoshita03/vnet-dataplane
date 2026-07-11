#include "vnet/agent/status.hpp"

#include "vnet/agent/command_runner.hpp"

#include <filesystem>
#include <iomanip>
#include <initializer_list>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

#if !defined(_WIN32)
#include <unistd.h>
#endif

namespace vnet::agent {
namespace {

constexpr int kLabelWidth = 28;
constexpr int kStateWidth = 12;

enum class CheckState {
  kOk,
  kMissing,
  kSkipped,
  kLinuxOnly,
};

struct CheckResult {
  CheckState state;
  std::string detail;
};

std::filesystem::path RepoRoot() {
#if defined(VNET_AGENT_SOURCE_DIR)
  return std::filesystem::path{VNET_AGENT_SOURCE_DIR}.parent_path();
#else
  return std::filesystem::current_path();
#endif
}

std::filesystem::path LinuxAccelBuildDir() {
  return RepoRoot() / "linux_accel" / "build";
}

std::string PlatformLabel() {
#if defined(_WIN32)
  return "Windows";
#elif defined(__linux__)
  return "Linux";
#else
  return "Other";
#endif
}

std::string TrimCopy(std::string value) {
  while (!value.empty() && (value.back() == '\n' || value.back() == '\r' ||
                            value.back() == ' ' || value.back() == '\t')) {
    value.pop_back();
  }

  std::size_t begin = 0;
  while (begin < value.size() && (value[begin] == ' ' || value[begin] == '\t')) {
    ++begin;
  }
  return value.substr(begin);
}

std::string_view CheckStateLabel(CheckState state) {
  switch (state) {
    case CheckState::kOk:
      return "OK";
    case CheckState::kMissing:
      return "MISSING";
    case CheckState::kSkipped:
      return "SKIPPED";
    case CheckState::kLinuxOnly:
      return "LINUX_ONLY";
  }
  return "MISSING";
}

CheckResult MakeResult(CheckState state, std::string detail) {
  return {state, std::move(detail)};
}

CheckResult MakeOk(std::string detail) {
  return MakeResult(CheckState::kOk, std::move(detail));
}

CheckResult MakeMissing(std::string detail) {
  return MakeResult(CheckState::kMissing, std::move(detail));
}

CheckResult MakeSkipped(std::string detail) {
  return MakeResult(CheckState::kSkipped, std::move(detail));
}

CheckResult MakeLinuxOnly(std::string detail) {
  return MakeResult(CheckState::kLinuxOnly, std::move(detail));
}

CheckResult CheckKernel() {
#if defined(_WIN32)
  return MakeOk("Windows");
#else
  const std::optional<std::string> output = RunCommandCapture("uname -sr");
  if (output.has_value() && !output->empty()) {
    return MakeOk(TrimCopy(*output));
  }
  return MakeOk("Linux");
#endif
}

CheckResult CheckRootStatus() {
#if defined(_WIN32)
  return MakeSkipped("n/a on Windows");
#else
  if (geteuid() == 0) {
    return MakeOk("yes");
  }
  return MakeMissing("not running as root");
#endif
}

CheckResult CheckCommand(std::string_view command, bool linux_only = false) {
  if (linux_only && !IsLinuxPlatform()) {
    return MakeLinuxOnly("not available on Windows");
  }
  return CommandExists(command) ? MakeOk("found") : MakeMissing("not found");
}

CheckResult CheckPath(const std::filesystem::path& path) {
  std::error_code error;
  return std::filesystem::exists(path, error) ? MakeOk("found") : MakeMissing("not found");
}

void PrintCheckLine(std::string_view label, const CheckResult& result) {
  std::cout << "  " << std::left << std::setw(kLabelWidth) << label << "  "
            << std::left << std::setw(kStateWidth) << CheckStateLabel(result.state)
            << result.detail << '\n';
}

void PrintGroup(std::string_view title,
                std::initializer_list<std::pair<std::string_view, CheckResult>> entries) {
  std::cout << title << ":\n";
  for (const auto& [label, result] : entries) {
    PrintCheckLine(label, result);
  }
  std::cout << '\n';
}

CheckResult ProbeCapability() {
  if (!IsLinuxPlatform()) {
    return MakeLinuxOnly("not available on Windows");
  }
  const CheckResult script =
      CheckPath(RepoRoot() / "linux_accel" / "bench" / "openstack_path_probe.sh");
  return script.state == CheckState::kOk ? MakeOk("ready") : MakeMissing("script missing");
}

CheckResult LinuxAccelBuildCapability() {
  const std::filesystem::path build_dir = LinuxAccelBuildDir();
  const bool ready = CheckPath(build_dir).state == CheckState::kOk &&
                     CheckPath(build_dir / "dns_monitor").state == CheckState::kOk &&
                     CheckPath(build_dir / "grpc_monitor").state == CheckState::kOk &&
                     CheckPath(build_dir / "grpc_fast_cache").state == CheckState::kOk &&
                     CheckPath(build_dir / "cachectl").state == CheckState::kOk &&
                     CheckPath(build_dir / "virt_service_classifier").state == CheckState::kOk;
  return ready ? MakeOk("ready") : MakeMissing("missing build artifacts");
}

}  // namespace

int RunStatus() {
  const std::filesystem::path build_dir = LinuxAccelBuildDir();

  std::cout << "vnet-agent status\n\n";
  PrintGroup("System", {{"OS", MakeOk(PlatformLabel())},
                        {"Kernel", CheckKernel()},
                        {"Root", CheckRootStatus()}});
  PrintGroup("Toolchain", {{"cmake", CheckCommand("cmake")},
                           {"clang", CheckCommand("clang")},
                           {"tc", CheckCommand("tc", true)},
                           {"bpftool", CheckCommand("bpftool", true)},
                           {"ovs-vsctl", CheckCommand("ovs-vsctl")}});
  PrintGroup("Linux accel artifacts",
             {{"linux_accel/build", CheckPath(build_dir)},
              {"dns_monitor", CheckPath(build_dir / "dns_monitor")},
              {"grpc_monitor", CheckPath(build_dir / "grpc_monitor")},
              {"grpc_fast_cache", CheckPath(build_dir / "grpc_fast_cache")},
              {"cachectl", CheckPath(build_dir / "cachectl")},
              {"virt_service_classifier", CheckPath(build_dir / "virt_service_classifier")}});
  PrintGroup("Scripts",
             {{"openstack_path_probe.sh",
               CheckPath(RepoRoot() / "linux_accel" / "bench" / "openstack_path_probe.sh")},
              {"virt_path_bench.sh",
               CheckPath(RepoRoot() / "linux_accel" / "bench" / "virt_path_bench.sh")}});
  PrintGroup("Summary", {{"status command", MakeOk("ready")},
                         {"read-only CLI", MakeOk("ready")},
                         {"linux probe", ProbeCapability()},
                         {"linux_accel build", LinuxAccelBuildCapability()}});
  return 0;
}

}  // namespace vnet::agent
