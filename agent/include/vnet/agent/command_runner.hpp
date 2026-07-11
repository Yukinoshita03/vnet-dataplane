#pragma once

#include <filesystem>
#include <optional>
#include <string>
#include <string_view>

namespace vnet::agent {

bool IsLinuxPlatform();
bool CommandExists(std::string_view command);
std::optional<std::string> RunCommandCapture(const std::string& command);
int RunLinuxScript(const std::filesystem::path& script_path);

}  // namespace vnet::agent
