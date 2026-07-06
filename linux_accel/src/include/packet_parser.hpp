#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace packet_parser {

struct ByteView {
    const uint8_t *data = nullptr;
    size_t size = 0;
};

struct EthernetFrame {
    std::array<uint8_t, 6> destination = {};
    std::array<uint8_t, 6> source = {};
    uint16_t ether_type = 0;
};

struct Ipv4Header {
    uint8_t version_ihl = 0;
    uint8_t type_of_service = 0;
    uint16_t total_length = 0;
    uint16_t identification = 0;
    uint16_t flags_fragment_offset = 0;
    uint8_t time_to_live = 0;
    uint8_t protocol = 0;
    uint16_t header_checksum = 0;
    std::array<uint8_t, 4> source_ip = {};
    std::array<uint8_t, 4> destination_ip = {};
};

struct UdpHeader {
    uint16_t source_port = 0;
    uint16_t destination_port = 0;
    uint16_t length = 0;
    uint16_t checksum = 0;
};

struct TcpHeader {
    uint16_t source_port = 0;
    uint16_t destination_port = 0;
    uint32_t sequence_number = 0;
    uint32_t acknowledgment_number = 0;
    uint8_t data_offset_reserved = 0;
    uint8_t flags = 0;
    uint16_t window_size = 0;
    uint16_t checksum = 0;
    uint16_t urgent_pointer = 0;
};

struct ParsedPacket {
    EthernetFrame ethernet = {};
    std::optional<Ipv4Header> ipv4;
    std::optional<UdpHeader> udp;
    std::optional<TcpHeader> tcp;
};

enum class ServiceKind {
    Unknown = 0,
    Dns,
    Grpc,
    Other,
};

ByteView make_view(const std::vector<uint8_t> &bytes);
ByteView subview(ByteView view, size_t offset);

std::optional<EthernetFrame> parse_ethernet_frame(ByteView view);
std::optional<Ipv4Header> parse_ipv4_header(ByteView view);
std::optional<UdpHeader> parse_udp_header(ByteView view);
std::optional<TcpHeader> parse_tcp_header(ByteView view);
std::optional<ParsedPacket> parse_packet(ByteView view);

size_t ipv4_header_length(const Ipv4Header &header);
size_t tcp_header_length(const TcpHeader &header);

ServiceKind classify_service(const ParsedPacket &packet);
const char *service_kind_name(ServiceKind kind);

std::string format_mac(const std::array<uint8_t, 6> &mac);
std::string format_ipv4(const std::array<uint8_t, 4> &ip);

} // namespace packet_parser
