#include "vnet/packet.h"

#include <algorithm>
#include <array>
#include <iomanip>
#include <optional>
#include <span>
#include <sstream>

namespace vnet {

namespace {

std::uint16_t ReadBigEndian16(std::span<const std::byte> bytes,
                              std::size_t offset) {
  const auto hi = std::to_integer<std::uint8_t>(bytes[offset]);
  const auto lo = std::to_integer<std::uint8_t>(bytes[offset + 1]);
  return static_cast<std::uint16_t>((hi << 8U) | lo);
}

} // namespace

std::optional<vnet::EthernetFrame>
ParseEthernetFrame(std::span<const std::byte> bytes) {
  constexpr std::size_t kEthernetHeaderSize = 14;
  if (bytes.size() < kEthernetHeaderSize) {
    return std::nullopt;
  }
  vnet::EthernetFrame frame;
  std::copy(bytes.begin(), bytes.begin() + 6, frame.destination.begin());
  std::copy(bytes.begin() + 6, bytes.begin() + 12, frame.source.begin());
  std::uint16_t ether_type = ReadBigEndian16(bytes, 12);
  frame.ether_type = ether_type;
  return frame;
}
std::optional<vnet::Ipv4Header>
ParseIpv4Header(std::span<const std::byte> bytes) {
  constexpr std::size_t kIpv4HeaderSize = 20;
  if (bytes.size() < kIpv4HeaderSize) {
    return std::nullopt;
  }
  vnet::Ipv4Header header;
  header.version_ihl = std::to_integer<std::uint8_t>(bytes[0]);
  header.type_of_service = std::to_integer<std::uint8_t>(bytes[1]);
  header.total_length = ReadBigEndian16(bytes, 2);
  header.identification = ReadBigEndian16(bytes, 4);
  header.flags_fragment_offset = ReadBigEndian16(bytes, 6);
  header.time_to_live = std::to_integer<std::uint8_t>(bytes[8]);
  header.protocol = std::to_integer<std::uint8_t>(bytes[9]);
  header.header_checksum = ReadBigEndian16(bytes, 10);
  std::copy(bytes.begin() + 12, bytes.begin() + 16, header.source_ip.begin());
  std::copy(bytes.begin() + 16, bytes.begin() + 20,
            header.destination_ip.begin());
  return header;
}
std::optional<vnet::UdpHeader>
ParseUdpHeader(std::span<const std::byte> bytes) {
  constexpr std::size_t kUdpHeaderSize = 8;
  if (bytes.size() < kUdpHeaderSize) {
    return std::nullopt;
  }
  vnet::UdpHeader header;
  header.source_port = ReadBigEndian16(bytes, 0);
  header.destination_port = ReadBigEndian16(bytes, 2);
  header.length = ReadBigEndian16(bytes, 4);
  header.checksum = ReadBigEndian16(bytes, 6);
  return header;
}
std::optional<vnet::TcpHeader>
ParseTcpHeader(std::span<const std::byte> bytes) {
  constexpr std::size_t kTcpHeaderSize = 20;
  if (bytes.size() < kTcpHeaderSize) {
    return std::nullopt;
  }
  vnet::TcpHeader header;
  header.source_port = ReadBigEndian16(bytes, 0);
  header.destination_port = ReadBigEndian16(bytes, 2);
  header.sequence_number =
      (static_cast<std::uint32_t>(ReadBigEndian16(bytes, 4)) << 16) |
      ReadBigEndian16(bytes, 6);
  header.acknowledgment_number =
      (static_cast<std::uint32_t>(ReadBigEndian16(bytes, 8)) << 16) |
      ReadBigEndian16(bytes, 10);
  header.data_offset_reserved = std::to_integer<std::uint8_t>(bytes[12]);
  header.flags = std::to_integer<std::uint8_t>(bytes[13]);
  header.window_size = ReadBigEndian16(bytes, 14);
  header.checksum = ReadBigEndian16(bytes, 16);
  header.urgent_pointer = ReadBigEndian16(bytes, 18);
  return header;
}

std::string FormatMac(const std::array<std::byte, 6> &mac) {
  std::ostringstream stream;
  stream << std::hex << std::setfill('0');
  for (std::size_t index = 0; index < mac.size(); ++index) {
    if (index != 0) {
      stream << ':';
    }
    stream << std::setw(2)
           << static_cast<int>(std::to_integer<std::uint8_t>(mac[index]));
  }
  return stream.str();
}

} // namespace vnet
