#include "vnet/agent/command_runner.hpp"

#include <array>
#include <cstdio>
#include <cstdlib>
#include <iostream>

#if !defined(_WIN32)
#include <sys/wait.h>
#endif

namespace vnet::agent {

bool IsLinuxPlatform() {
#if defined(__linux__)
  return true;
#else
  return false;
#endif
}

bool CommandExists(std::string_view command) {
#if defined(_WIN32)
  return std::system(("where " + std::string(command) + " >nul 2>nul").c_str()) == 0;
#else
  return std::system(("command -v " + std::string(command) + " >/dev/null 2>&1").c_str()) == 0;
#endif
}

std::optional<std::string> RunCommandCapture(const std::string& command) {
#if defined(_WIN32)
  FILE* pipe = _popen((command + " 2>nul").c_str(), "r");
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

int RunLinuxScript(const std::filesystem::path& script_path) {
  if (!std::filesystem::exists(script_path)) {
    std::cerr << "error: script not found: " << script_path.string() << '\n';
    return 1;
  }

  const int result = std::system(("\"" + script_path.string() + "\"").c_str());
  if (result == -1) {
    std::cerr << "error: failed to launch script\n";
    return 1;
  }

#if defined(_WIN32)
  return result;
#else
  if (WIFEXITED(result)) {
    return WEXITSTATUS(result);
  }
  if (WIFSIGNALED(result)) {
    std::cerr << "error: script terminated by signal " << WTERMSIG(result) << '\n';
  }
  return 1;
#endif
}

}  // namespace vnet::agent
