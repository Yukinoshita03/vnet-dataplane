#include "packet_parser.hpp"

#include <algorithm>
#include <iomanip>
#include <sstream>

namespace packet_parser {

namespace {

constexpr size_t kEthernetHeaderSize = 14;
constexpr size_t kIpv4MinimumHeaderSize = 20;
constexpr size_t kUdpHeaderSize = 8;
constexpr size_t kTcpMinimumHeaderSize = 20;
constexpr uint16_t kEtherTypeIpv4 = 0x0800;
constexpr uint8_t kIpProtocolTcp = 6;
constexpr uint8_t kIpProtocolUdp = 17;
constexpr uint16_t kDnsPort = 53;
constexpr uint16_t kGrpcPort = 50051;

uint16_t read_big_endian16(ByteView view, size_t offset)
{
    const uint16_t hi = view.data[offset];
    const uint16_t lo = view.data[offset + 1];
    return static_cast<uint16_t>((hi << 8U) | lo);
}

uint32_t read_big_endian32(ByteView view, size_t offset)
{
    return (static_cast<uint32_t>(view.data[offset]) << 24U) |
           (static_cast<uint32_t>(view.data[offset + 1]) << 16U) |
           (static_cast<uint32_t>(view.data[offset + 2]) << 8U) |
           static_cast<uint32_t>(view.data[offset + 3]);
}

} // namespace

ByteView make_view(const std::vector<uint8_t> &bytes)
{
    return ByteView{bytes.data(), bytes.size()};
}

ByteView subview(ByteView view, size_t offset)
{
    if (offset > view.size)
        return {};
    return ByteView{view.data + offset, view.size - offset};
}

std::optional<EthernetFrame> parse_ethernet_frame(ByteView view)
{
    if (view.size < kEthernetHeaderSize)
        return std::nullopt;

    EthernetFrame frame;
    std::copy(view.data, view.data + 6, frame.destination.begin());
    std::copy(view.data + 6, view.data + 12, frame.source.begin());
    frame.ether_type = read_big_endian16(view, 12);
    return frame;
}

size_t ipv4_header_length(const Ipv4Header &header)
{
    return static_cast<size_t>(header.version_ihl & 0x0fU) * 4U;
}

std::optional<Ipv4Header> parse_ipv4_header(ByteView view)
{
    if (view.size < kIpv4MinimumHeaderSize)
        return std::nullopt;

    Ipv4Header header;
    header.version_ihl = view.data[0];
    const uint8_t version = header.version_ihl >> 4U;
    const uint8_t ihl = header.version_ihl & 0x0fU;
    if (version != 4 || ihl < 5)
        return std::nullopt;

    const size_t header_len = static_cast<size_t>(ihl) * 4U;
    if (view.size < header_len)
        return std::nullopt;

    header.type_of_service = view.data[1];
    header.total_length = read_big_endian16(view, 2);
    header.identification = read_big_endian16(view, 4);
    header.flags_fragment_offset = read_big_endian16(view, 6);
    header.time_to_live = view.data[8];
    header.protocol = view.data[9];
    header.header_checksum = read_big_endian16(view, 10);
    std::copy(view.data + 12, view.data + 16, header.source_ip.begin());
    std::copy(view.data + 16, view.data + 20, header.destination_ip.begin());
    return header;
}

std::optional<UdpHeader> parse_udp_header(ByteView view)
{
    if (view.size < kUdpHeaderSize)
        return std::nullopt;

    UdpHeader header;
    header.source_port = read_big_endian16(view, 0);
    header.destination_port = read_big_endian16(view, 2);
    header.length = read_big_endian16(view, 4);
    header.checksum = read_big_endian16(view, 6);
    if (header.length < kUdpHeaderSize)
        return std::nullopt;
    return header;
}

size_t tcp_header_length(const TcpHeader &header)
{
    return static_cast<size_t>(header.data_offset_reserved >> 4U) * 4U;
}

std::optional<TcpHeader> parse_tcp_header(ByteView view)
{
    if (view.size < kTcpMinimumHeaderSize)
        return std::nullopt;

    TcpHeader header;
    header.source_port = read_big_endian16(view, 0);
    header.destination_port = read_big_endian16(view, 2);
    header.sequence_number = read_big_endian32(view, 4);
    header.acknowledgment_number = read_big_endian32(view, 8);
    header.data_offset_reserved = view.data[12];
    header.flags = view.data[13];
    header.window_size = read_big_endian16(view, 14);
    header.checksum = read_big_endian16(view, 16);
    header.urgent_pointer = read_big_endian16(view, 18);

    const uint8_t data_offset_words = header.data_offset_reserved >> 4U;
    if (data_offset_words < 5)
        return std::nullopt;
    if (view.size < static_cast<size_t>(data_offset_words) * 4U)
        return std::nullopt;
    return header;
}

std::optional<ParsedPacket> parse_packet(ByteView view)
{
    auto ethernet = parse_ethernet_frame(view);
    if (!ethernet)
        return std::nullopt;

    ParsedPacket packet;
    packet.ethernet = *ethernet;
    if (ethernet->ether_type != kEtherTypeIpv4)
        return packet;

    ByteView l3 = subview(view, kEthernetHeaderSize);
    auto ipv4 = parse_ipv4_header(l3);
    if (!ipv4)
        return std::nullopt;
    packet.ipv4 = *ipv4;

    const size_t l4_offset = ipv4_header_length(*ipv4);
    ByteView l4 = subview(l3, l4_offset);
    if (ipv4->protocol == kIpProtocolUdp) {
        auto udp = parse_udp_header(l4);
        if (!udp)
            return std::nullopt;
        packet.udp = *udp;
    } else if (ipv4->protocol == kIpProtocolTcp) {
        auto tcp = parse_tcp_header(l4);
        if (!tcp)
            return std::nullopt;
        packet.tcp = *tcp;
    }

    return packet;
}

ServiceKind classify_service(const ParsedPacket &packet)
{
    if (packet.udp) {
        if (packet.udp->source_port == kDnsPort ||
            packet.udp->destination_port == kDnsPort)
            return ServiceKind::Dns;
        return ServiceKind::Other;
    }

    if (packet.tcp) {
        if (packet.tcp->source_port == kGrpcPort ||
            packet.tcp->destination_port == kGrpcPort)
            return ServiceKind::Grpc;
        return ServiceKind::Other;
    }

    return packet.ipv4 ? ServiceKind::Other : ServiceKind::Unknown;
}

const char *service_kind_name(ServiceKind kind)
{
    switch (kind) {
    case ServiceKind::Dns:
        return "dns";
    case ServiceKind::Grpc:
        return "grpc";
    case ServiceKind::Other:
        return "other";
    case ServiceKind::Unknown:
    default:
        return "unknown";
    }
}

std::string format_mac(const std::array<uint8_t, 6> &mac)
{
    std::ostringstream stream;
    stream << std::hex << std::setfill('0');
    for (size_t i = 0; i < mac.size(); ++i) {
        if (i != 0)
            stream << ':';
        stream << std::setw(2) << static_cast<unsigned int>(mac[i]);
    }
    return stream.str();
}

std::string format_ipv4(const std::array<uint8_t, 4> &ip)
{
    std::ostringstream stream;
    stream << static_cast<unsigned int>(ip[0]) << '.'
           << static_cast<unsigned int>(ip[1]) << '.'
           << static_cast<unsigned int>(ip[2]) << '.'
           << static_cast<unsigned int>(ip[3]);
    return stream.str();
}

} // namespace packet_parser
