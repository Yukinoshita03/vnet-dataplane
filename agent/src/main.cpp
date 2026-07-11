#include "vnet/agent/commands.hpp"
#include "vnet/agent/status.hpp"

#include <iostream>
#include <string_view>

namespace {

void PrintUsage(std::ostream& output) {
  output << "Usage:\n"
         << "  vnet-agent --help\n"
         << "  vnet-agent status\n"
         << "  vnet-agent probe\n"
         << "  vnet-agent bench virt-path\n\n"
         << "Commands:\n"
         << "  status          Check local environment and build prerequisites.\n"
         << "  probe           Run the OpenStack path probe script.\n"
         << "  bench virt-path Run the virtualization path benchmark script.\n";
}

bool IsHelpFlag(std::string_view argument) {
  return argument == "--help" || argument == "-h";
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
    return vnet::agent::RunStatus();
  }

  if (command == "probe") {
    return vnet::agent::RunProbe();
  }

  if (command == "bench") {
    if (argc < 3) {
      std::cerr << "error: missing benchmark name\n";
      PrintUsage(std::cout);
      return 1;
    }

    const std::string_view benchmark = argv[2];
    if (benchmark == "virt-path") {
      return vnet::agent::RunBenchVirtPath();
    }

    std::cerr << "error: unknown benchmark: " << benchmark << '\n';
    PrintUsage(std::cout);
    return 1;
  }

  std::cerr << "error: unknown command: " << command << '\n';
  PrintUsage(std::cout);
  return 1;
}
  
