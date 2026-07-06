#include "vnet/packet.h"

#include <iomanip>
#include <sstream>

namespace vnet {

namespace {

std::uint16_t ReadBigEndian16(std::span<const std::byte> bytes, std::size_t offset) {
  const auto hi = std::to_integer<std::uint8_t>(bytes[offset]);
  const auto lo = std::to_integer<std::uint8_t>(bytes[offset + 1]);
  return static_cast<std::uint16_t>((hi << 8U) | lo);
}

}  // namespace

std::optional<EthernetFrame> ParseEthernetFrame(std::span<const std::byte> bytes) {
  constexpr std::size_t kEthernetHeaderSize = 14;
  if (bytes.size() < kEthernetHeaderSize) {
    return std::nullopt;
  }

  EthernetFrame frame;
  for (std::size_t index = 0; index < 6; ++index) {
    frame.destination[index] = bytes[index];
    frame.source[index] = bytes[index + 6];
  }
  frame.ether_type = ReadBigEndian16(bytes, 12);
  return frame;
}

std::string FormatMac(const std::array<std::byte, 6>& mac) {
  std::ostringstream stream;
  stream << std::hex << std::setfill('0');
  for (std::size_t index = 0; index < mac.size(); ++index) {
    if (index != 0) {
      stream << ':';
    }
    stream << std::setw(2) << static_cast<int>(std::to_integer<std::uint8_t>(mac[index]));
  }
  return stream.str();
}

}  // namespace vnet
