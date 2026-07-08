#include <array>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <iomanip>
#include <initializer_list>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

#if !defined(_WIN32)
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace {

constexpr std::string_view kProgramName = "vnet-agent";
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

bool IsWindowsPlatform() {
#if defined(_WIN32)
  return true;
#else
  return false;
#endif
}

bool IsLinuxPlatform() {
#if defined(__linux__)
  return true;
#else
  return false;
#endif
}

std::filesystem::path SourceDir() {
#if defined(VNET_AGENT_SOURCE_DIR)
  return std::filesystem::path{VNET_AGENT_SOURCE_DIR};
#else
  return std::filesystem::current_path() / "agent";
#endif
}

std::filesystem::path RepoRoot() {
  return SourceDir().parent_path();
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

void PrintUsage(std::ostream& os) {
  os << "Usage:\n"
     << "  vnet-agent --help\n"
     << "  vnet-agent status\n"
     << "  vnet-agent probe\n"
     << "  vnet-agent bench virt-path\n\n"
     << "Commands:\n"
     << "  status          Check local environment and build prerequisites.\n"
     << "  probe           Run the OpenStack path probe script.\n"
     << "  bench virt-path Run the virtualization path benchmark script.\n";
}

std::filesystem::path LinuxAccelRoot() {
  return RepoRoot() / "linux_accel";
}

std::filesystem::path LinuxAccelBuildDir() {
  return LinuxAccelRoot() / "build";
}

std::optional<std::string> RunCommandCapture(const std::string& command);
bool CommandExists(std::string_view command);

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

CheckResult MakeOk(std::string detail) {
  return {CheckState::kOk, std::move(detail)};
}

CheckResult MakeMissing(std::string detail) {
  return {CheckState::kMissing, std::move(detail)};
}

CheckResult MakeSkipped(std::string detail) {
  return {CheckState::kSkipped, std::move(detail)};
}

CheckResult MakeLinuxOnly(std::string detail) {
  return {CheckState::kLinuxOnly, std::move(detail)};
}

CheckResult CheckPlatformInfo(std::string detail) {
  return MakeOk(std::move(detail));
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
  if (CommandExists(command)) {
    return MakeOk("found");
  }
  return MakeMissing("not found");
}

CheckResult CheckPath(const std::filesystem::path& path) {
  std::error_code ec;
  if (std::filesystem::exists(path, ec)) {
    return MakeOk("found");
  }
  return MakeMissing("not found");
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
  const CheckResult script = CheckPath(RepoRoot() / "linux_accel" / "bench" / "openstack_path_probe.sh");
  if (script.state == CheckState::kOk) {
    return MakeOk("ready");
  }
  return MakeMissing("script missing");
}

CheckResult LinuxAccelBuildCapability() {
  const CheckResult build_dir = CheckPath(LinuxAccelBuildDir());
  const CheckResult dns_monitor = CheckPath(LinuxAccelBuildDir() / "dns_monitor");
  const CheckResult grpc_monitor = CheckPath(LinuxAccelBuildDir() / "grpc_monitor");
  const CheckResult grpc_fast_cache = CheckPath(LinuxAccelBuildDir() / "grpc_fast_cache");
  const CheckResult cachectl = CheckPath(LinuxAccelBuildDir() / "cachectl");
  const CheckResult virt_classifier = CheckPath(LinuxAccelBuildDir() / "virt_service_classifier");
  const bool ready = build_dir.state == CheckState::kOk && dns_monitor.state == CheckState::kOk &&
                     grpc_monitor.state == CheckState::kOk &&
                     grpc_fast_cache.state == CheckState::kOk &&
                     cachectl.state == CheckState::kOk &&
                     virt_classifier.state == CheckState::kOk;
  if (ready) {
    return MakeOk("ready");
  }
  return MakeMissing("missing build artifacts");
}

std::optional<std::string> RunCommandCapture(const std::string& command) {
#if defined(_WIN32)
  const std::string full_command = command + " 2>nul";
  FILE* pipe = _popen(full_command.c_str(), "r");
#else
  FILE* pipe = popen((command + " 2>/dev/null").c_str(), "r");
#endif
  if (pipe == nullptr) {
    return std::nullopt;
  }

  std::string output;
  std::array<char, 256> buffer{};
  while (fgets(buffer.data(), static_cast<int>(buffer.size()), pipe) != nullptr) {
    output.append(buffer.data());
  }

#if defined(_WIN32)
  _pclose(pipe);
#else
  pclose(pipe);
#endif

  return output;
}

bool CommandExists(std::string_view command) {
#if defined(_WIN32)
  return std::system(("where " + std::string(command) + " >nul 2>nul").c_str()) == 0;
#else
  return std::system(("command -v " + std::string(command) + " >/dev/null 2>&1").c_str()) == 0;
#endif
}

int RunStatus() {
  const CheckResult os = CheckPlatformInfo(PlatformLabel());
  const CheckResult kernel = CheckKernel();
  const CheckResult root = CheckRootStatus();

  const CheckResult cmake = CheckCommand("cmake");
  const CheckResult clang = CheckCommand("clang");
  const CheckResult tc = CheckCommand("tc", true);
  const CheckResult bpftool = CheckCommand("bpftool", true);
  const CheckResult ovs_vsctl = CheckCommand("ovs-vsctl");

  const CheckResult linux_accel_build = CheckPath(LinuxAccelBuildDir());
  const CheckResult dns_monitor = CheckPath(LinuxAccelBuildDir() / "dns_monitor");
  const CheckResult grpc_monitor = CheckPath(LinuxAccelBuildDir() / "grpc_monitor");
  const CheckResult grpc_fast_cache = CheckPath(LinuxAccelBuildDir() / "grpc_fast_cache");
  const CheckResult cachectl = CheckPath(LinuxAccelBuildDir() / "cachectl");
  const CheckResult virt_classifier = CheckPath(LinuxAccelBuildDir() / "virt_service_classifier");

  const CheckResult openstack_path_probe =
      CheckPath(RepoRoot() / "linux_accel" / "bench" / "openstack_path_probe.sh");
  const CheckResult virt_path_bench = CheckPath(RepoRoot() / "linux_accel" / "bench" / "virt_path_bench.sh");

  std::cout << kProgramName << " status\n\n";

  PrintGroup("System", {
                            {"OS", os},
                            {"Kernel", kernel},
                            {"Root", root},
                        });

  PrintGroup("Toolchain", {
                              {"cmake", cmake},
                              {"clang", clang},
                              {"tc", tc},
                              {"bpftool", bpftool},
                              {"ovs-vsctl", ovs_vsctl},
                          });

  PrintGroup("Linux accel artifacts", {
                                          {"linux_accel/build", linux_accel_build},
                                          {"dns_monitor", dns_monitor},
                                          {"grpc_monitor", grpc_monitor},
                                          {"grpc_fast_cache", grpc_fast_cache},
                                          {"cachectl", cachectl},
                                          {"virt_service_classifier", virt_classifier},
                                      });

  PrintGroup("Scripts", {
                           {"openstack_path_probe.sh", openstack_path_probe},
                           {"virt_path_bench.sh", virt_path_bench},
                       });

  PrintGroup("Summary", {
                             {"status command", MakeOk("ready")},
                             {"read-only CLI", MakeOk("ready")},
                             {"linux probe", ProbeCapability()},
                             {"linux_accel build", LinuxAccelBuildCapability()},
                         });

  return 0;
}

int RunLinuxScript(const std::filesystem::path& script_path) {
  if (!std::filesystem::exists(script_path)) {
    std::cerr << "error: script not found: " << script_path.string() << '\n';
    return 1;
  }

  const std::string command = "\"" + script_path.string() + "\"";
  const int rc = std::system(command.c_str());
  if (rc == -1) {
    std::cerr << "error: failed to launch script\n";
    return 1;
  }
#if defined(_WIN32)
  return rc;
#else
  if (WIFEXITED(rc)) {
    return WEXITSTATUS(rc);
  }
  if (WIFSIGNALED(rc)) {
    std::cerr << "error: script terminated by signal " << WTERMSIG(rc) << '\n';
    return 1;
  }
  return 1;
#endif
}

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

bool IsHelpFlag(std::string_view arg) {
  return arg == "--help" || arg == "-h";
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    PrintUsage(std::cout);
    return 1;
  }

  const std::string_view command = argv[1];
  if (IsHelpFlag(command)) {
    PrintUsage(std::cout);
    return 0;
  }

  if (command == "status") {
    return RunStatus();
  }

  if (command == "probe") {
    return RunProbe();
  }

  if (command == "bench") {
    if (argc < 3) {
      std::cerr << "error: missing benchmark name\n";
      PrintUsage(std::cout);
      return 1;
    }
    const std::string_view bench_name = argv[2];
    if (bench_name == "virt-path") {
      return RunBenchVirtPath();
    }
    std::cerr << "error: unknown benchmark: " << bench_name << '\n';
    PrintUsage(std::cout);
    return 1;
  }

  std::cerr << "error: unknown command: " << command << '\n';
  PrintUsage(std::cout);
  return 1;
}
