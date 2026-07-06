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

struct Ipv4Header {
  std::uint8_t version_ihl{};
  std::uint8_t type_of_service{};
  std::uint16_t total_length{};
  std::uint16_t identification{};
  std::uint16_t flags_fragment_offset{};
  std::uint8_t time_to_live{};
  std::uint8_t protocol{};
  std::uint16_t header_checksum{};
  std::array<std::byte, 4> source_ip{};
  std::array<std::byte, 4> destination_ip{};
};

struct UdpHeader {
  std::uint16_t source_port{};
  std::uint16_t destination_port{};
  std::uint16_t length{};
  std::uint16_t checksum{};
};

struct TcpHeader {
  std::uint16_t source_port{};
  std::uint16_t destination_port{};
  std::uint32_t sequence_number{};
  std::uint32_t acknowledgment_number{};
  std::uint8_t data_offset_reserved{};
  std::uint8_t flags{};
  std::uint16_t window_size{};
  std::uint16_t checksum{};
  std::uint16_t urgent_pointer{};
};

std::optional<EthernetFrame>
ParseEthernetFrame(std::span<const std::byte> bytes);
std::optional<Ipv4Header>
ParseIpv4Header(std::span<const std::byte> bytes);
std::optional<UdpHeader>
ParseUdpHeader(std::span<const std::byte> bytes);
std::optional<TcpHeader>
ParseTcpHeader(std::span<const std::byte> bytes);
std::string FormatMac(const std::array<std::byte, 6> &mac);

} // namespace vnet
