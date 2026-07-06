#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>

namespace vnet {

struct EthernetFrame {
  std::array<std::byte, 6> destination{};
  std::array<std::byte, 6> source{};
  std::uint16_t ether_type{};
};

std::optional<EthernetFrame> ParseEthernetFrame(std::span<const std::byte> bytes);
std::string FormatMac(const std::array<std::byte, 6>& mac);

}  // namespace vnet
