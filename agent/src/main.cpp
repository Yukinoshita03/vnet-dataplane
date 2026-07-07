#include <array>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>

#if !defined(_WIN32)
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace {

constexpr std::string_view kProgramName = "vnet-agent";

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

bool IsUnixLikePlatform() {
  return !IsWindowsPlatform();
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
     << "  status         Check local environment and build prerequisites.\n"
     << "  probe          Run the OpenStack path probe script.\n"
     << "  bench virt-path Run the virtualization path benchmark script.\n";
}

std::filesystem::path LinuxAccelRoot() {
  return RepoRoot() / "linux_accel";
}

std::filesystem::path LinuxAccelBuildDir() {
  return LinuxAccelRoot() / "build";
}

std::optional<std::string> RunCommandCapture(const std::string& command);

std::string TrimCopy(std::string value) {
  while (!value.empty() && (value.back() == '\n' || value.back() == '\r' || value.back() == ' ' || value.back() == '\t')) {
    value.pop_back();
  }
  std::size_t begin = 0;
  while (begin < value.size() && (value[begin] == ' ' || value[begin] == '\t')) {
    ++begin;
  }
  return value.substr(begin);
}

std::string KernelDescription() {
#if defined(_WIN32)
  return "Windows";
#else
  const std::optional<std::string> output = RunCommandCapture("uname -sr");
  if (output.has_value() && !output->empty()) {
    return TrimCopy(*output);
  }
  return "Linux";
#endif
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

bool CommandExists(const std::string& command) {
  const std::string shell =
#if defined(_WIN32)
      "where " + command;
#else
      "command -v " + command;
#endif
  const std::optional<std::string> output = RunCommandCapture(shell);
  return output.has_value() && !output->empty();
}

bool PathExists(const std::filesystem::path& path) {
  std::error_code ec;
  return std::filesystem::exists(path, ec);
}

void PrintCheckLine(const std::string& label, bool ok, const std::string& detail) {
  std::cout << (ok ? "[OK]   " : "[WARN] ") << label;
  if (!detail.empty()) {
    std::cout << " - " << detail;
  }
  std::cout << '\n';
}

int RunStatus() {
  std::cout << kProgramName << " status\n";
  std::cout << "OS: " << PlatformLabel() << '\n';
  std::cout << "Kernel: " << KernelDescription() << '\n';
  std::cout << "Repo root: " << RepoRoot().string() << '\n';

  bool all_ok = true;

  const bool has_tc = CommandExists("tc");
  const bool has_clang = CommandExists("clang");
  const bool has_bpftool = CommandExists("bpftool");
  const bool has_ovs_vsctl = CommandExists("ovs-vsctl");
  const bool has_cmake = CommandExists("cmake");

  PrintCheckLine("tc", has_tc, has_tc ? "found" : "missing");
  PrintCheckLine("clang", has_clang, has_clang ? "found" : "missing");
  PrintCheckLine("bpftool", has_bpftool, has_bpftool ? "found" : "missing");
  PrintCheckLine("ovs-vsctl", has_ovs_vsctl, has_ovs_vsctl ? "found" : "missing");
  PrintCheckLine("cmake", has_cmake, has_cmake ? "found" : "missing");

  bool has_root_access = true;
#if defined(_WIN32)
  PrintCheckLine("root", true, "n/a on Windows");
#else
  has_root_access = (geteuid() == 0);
  PrintCheckLine("root", has_root_access, has_root_access ? "yes" : "no");
#endif

  const bool has_build_dir = PathExists(LinuxAccelBuildDir());
  const bool has_dns_monitor = PathExists(LinuxAccelBuildDir() / "dns_monitor");
  const bool has_grpc_monitor = PathExists(LinuxAccelBuildDir() / "grpc_monitor");
  const bool has_grpc_fast_cache = PathExists(LinuxAccelBuildDir() / "grpc_fast_cache");
  const bool has_cachectl = PathExists(LinuxAccelBuildDir() / "cachectl");
  const bool has_virt_classifier = PathExists(LinuxAccelBuildDir() / "virt_service_classifier");

  PrintCheckLine("linux_accel/build", has_build_dir, has_build_dir ? "present" : "missing");
  PrintCheckLine("dns_monitor", has_dns_monitor, has_dns_monitor ? "present" : "missing");
  PrintCheckLine("grpc_monitor", has_grpc_monitor, has_grpc_monitor ? "present" : "missing");
  PrintCheckLine("grpc_fast_cache", has_grpc_fast_cache, has_grpc_fast_cache ? "present" : "missing");
  PrintCheckLine("cachectl", has_cachectl, has_cachectl ? "present" : "missing");
  PrintCheckLine("virt_service_classifier", has_virt_classifier, has_virt_classifier ? "present" : "missing");

  all_ok = has_tc && has_clang && has_bpftool && has_ovs_vsctl && has_cmake &&
           has_root_access && has_build_dir && has_dns_monitor && has_grpc_monitor &&
           has_grpc_fast_cache && has_cachectl && has_virt_classifier;

  std::cout << "Status: " << (all_ok ? "ready" : "not ready") << '\n';
  return 0;
}

int RunLinuxScript(const std::filesystem::path& script_path) {
  if (!PathExists(script_path)) {
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
