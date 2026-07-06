#include "vnet/packet.h"

#include <algorithm>
#include <array>
#include <iomanip>
#include <optional>
#include <span>
#include <sstream>

namespace vnet {

namespace {

constexpr std::size_t kEthernetHeaderSize = 14;
constexpr std::size_t kIpv4MinimumHeaderSize = 20;
constexpr std::size_t kUdpHeaderSize = 8;
constexpr std::size_t kTcpMinimumHeaderSize = 20;

constexpr std::uint16_t kEtherTypeIpv4 = 0x0800;
constexpr std::uint8_t kIpProtocolTcp = 6;
constexpr std::uint8_t kIpProtocolUdp = 17;
constexpr std::uint16_t kDnsPort = 53;
constexpr std::uint16_t kGrpcPort = 50051;

std::uint16_t ReadBigEndian16(std::span<const std::byte> bytes,
                              std::size_t offset) {
  const auto hi = std::to_integer<std::uint8_t>(bytes[offset]);
  const auto lo = std::to_integer<std::uint8_t>(bytes[offset + 1]);
  return static_cast<std::uint16_t>((hi << 8U) | lo);
}

std::uint32_t ReadBigEndian32(std::span<const std::byte> bytes,
                              std::size_t offset) {
  return (static_cast<std::uint32_t>(
              std::to_integer<std::uint8_t>(bytes[offset]))
          << 24U) |
         (static_cast<std::uint32_t>(
              std::to_integer<std::uint8_t>(bytes[offset + 1]))
          << 16U) |
         (static_cast<std::uint32_t>(
              std::to_integer<std::uint8_t>(bytes[offset + 2]))
          << 8U) |
         static_cast<std::uint32_t>(
             std::to_integer<std::uint8_t>(bytes[offset + 3]));
}

std::span<const std::byte> Subspan(std::span<const std::byte> bytes,
                                   std::size_t offset) {
  if (offset > bytes.size()) {
    return {};
  }
  return bytes.subspan(offset);
}

} // namespace

std::optional<EthernetFrame>
ParseEthernetFrame(std::span<const std::byte> bytes) {
  if (bytes.size() < kEthernetHeaderSize) {
    return std::nullopt;
  }

  EthernetFrame frame;
  std::copy(bytes.begin(), bytes.begin() + 6, frame.destination.begin());
  std::copy(bytes.begin() + 6, bytes.begin() + 12, frame.source.begin());
  frame.ether_type = ReadBigEndian16(bytes, 12);
  return frame;
}

std::size_t Ipv4HeaderLength(const Ipv4Header &header) {
  return static_cast<std::size_t>(header.version_ihl & 0x0fU) * 4U;
}

std::optional<Ipv4Header> ParseIpv4Header(std::span<const std::byte> bytes) {
  if (bytes.size() < kIpv4MinimumHeaderSize) {
    return std::nullopt;
  }

  Ipv4Header header;
  header.version_ihl = std::to_integer<std::uint8_t>(bytes[0]);
  const auto version = static_cast<std::uint8_t>(header.version_ihl >> 4U);
  const auto ihl = static_cast<std::uint8_t>(header.version_ihl & 0x0fU);
  if (version != 4 || ihl < 5) {
    return std::nullopt;
  }

  const auto header_length = static_cast<std::size_t>(ihl) * 4U;
  if (bytes.size() < header_length) {
    return std::nullopt;
  }

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

std::optional<UdpHeader> ParseUdpHeader(std::span<const std::byte> bytes) {
  if (bytes.size() < kUdpHeaderSize) {
    return std::nullopt;
  }

  UdpHeader header;
  header.source_port = ReadBigEndian16(bytes, 0);
  header.destination_port = ReadBigEndian16(bytes, 2);
  header.length = ReadBigEndian16(bytes, 4);
  header.checksum = ReadBigEndian16(bytes, 6);
  if (header.length < kUdpHeaderSize) {
    return std::nullopt;
  }
  return header;
}

std::size_t TcpHeaderLength(const TcpHeader &header) {
  return static_cast<std::size_t>(header.data_offset_reserved >> 4U) * 4U;
}

std::optional<TcpHeader> ParseTcpHeader(std::span<const std::byte> bytes) {
  if (bytes.size() < kTcpMinimumHeaderSize) {
    return std::nullopt;
  }

  TcpHeader header;
  header.source_port = ReadBigEndian16(bytes, 0);
  header.destination_port = ReadBigEndian16(bytes, 2);
  header.sequence_number = ReadBigEndian32(bytes, 4);
  header.acknowledgment_number = ReadBigEndian32(bytes, 8);
  header.data_offset_reserved = std::to_integer<std::uint8_t>(bytes[12]);
  header.flags = std::to_integer<std::uint8_t>(bytes[13]);
  header.window_size = ReadBigEndian16(bytes, 14);
  header.checksum = ReadBigEndian16(bytes, 16);
  header.urgent_pointer = ReadBigEndian16(bytes, 18);

  const auto data_offset_words =
      static_cast<std::uint8_t>(header.data_offset_reserved >> 4U);
  if (data_offset_words < 5) {
    return std::nullopt;
  }
  if (bytes.size() < static_cast<std::size_t>(data_offset_words) * 4U) {
    return std::nullopt;
  }
  return header;
}

std::optional<ParsedPacket> ParsePacket(std::span<const std::byte> bytes) {
  const auto ethernet = ParseEthernetFrame(bytes);
  if (!ethernet.has_value()) {
    return std::nullopt;
  }

  ParsedPacket packet;
  packet.ethernet = *ethernet;
  if (ethernet->ether_type != kEtherTypeIpv4) {
    return packet;
  }

  const auto l3 = Subspan(bytes, kEthernetHeaderSize);
  const auto ipv4 = ParseIpv4Header(l3);
  if (!ipv4.has_value()) {
    return std::nullopt;
  }
  packet.ipv4 = *ipv4;

  const auto l4 = Subspan(l3, Ipv4HeaderLength(*ipv4));
  if (ipv4->protocol == kIpProtocolUdp) {
    const auto udp = ParseUdpHeader(l4);
    if (!udp.has_value()) {
      return std::nullopt;
    }
    packet.udp = *udp;
  } else if (ipv4->protocol == kIpProtocolTcp) {
    const auto tcp = ParseTcpHeader(l4);
    if (!tcp.has_value()) {
      return std::nullopt;
    }
    packet.tcp = *tcp;
  }

  return packet;
}

ServiceKind ClassifyService(const ParsedPacket &packet) {
  if (packet.udp.has_value()) {
    if (packet.udp->source_port == kDnsPort ||
        packet.udp->destination_port == kDnsPort) {
      return ServiceKind::kDns;
    }
    return ServiceKind::kOther;
  }

  if (packet.tcp.has_value()) {
    if (packet.tcp->source_port == kGrpcPort ||
        packet.tcp->destination_port == kGrpcPort) {
      return ServiceKind::kGrpc;
    }
    return ServiceKind::kOther;
  }

  return packet.ipv4.has_value() ? ServiceKind::kOther : ServiceKind::kUnknown;
}

const char *ServiceKindName(ServiceKind kind) {
  switch (kind) {
  case ServiceKind::kDns:
    return "dns";
  case ServiceKind::kGrpc:
    return "grpc";
  case ServiceKind::kOther:
    return "other";
  case ServiceKind::kUnknown:
  default:
    return "unknown";
  }
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

std::string FormatIpv4(const std::array<std::byte, 4> &ip) {
  std::ostringstream stream;
  stream << static_cast<unsigned int>(std::to_integer<std::uint8_t>(ip[0]))
         << '.'
         << static_cast<unsigned int>(std::to_integer<std::uint8_t>(ip[1]))
         << '.'
         << static_cast<unsigned int>(std::to_integer<std::uint8_t>(ip[2]))
         << '.'
         << static_cast<unsigned int>(std::to_integer<std::uint8_t>(ip[3]));
  return stream.str();
}

} // namespace vnet
