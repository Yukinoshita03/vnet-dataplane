#include "packet_parser.hpp"

#include <cctype>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

namespace {

struct Options {
    std::string hex_frame;
    std::string raw_file;
};

void print_usage(const char *program)
{
    std::cerr << "Usage: " << program
              << " (--hex-frame <hex-bytes> | --raw-file <path>)\n";
}

bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--hex-frame" && i + 1 < argc) {
            options->hex_frame = argv[++i];
        } else if (arg == "--raw-file" && i + 1 < argc) {
            options->raw_file = argv[++i];
        } else if (arg == "-h" || arg == "--help") {
            return false;
        } else {
            std::cerr << "Unknown or incomplete option: " << arg << "\n";
            return false;
        }
    }

    const bool has_hex = !options->hex_frame.empty();
    const bool has_file = !options->raw_file.empty();
    return has_hex != has_file;
}

bool parse_hex_nibble(char ch, uint8_t *value)
{
    if (ch >= '0' && ch <= '9') {
        *value = static_cast<uint8_t>(ch - '0');
        return true;
    }
    ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    if (ch >= 'a' && ch <= 'f') {
        *value = static_cast<uint8_t>(10 + ch - 'a');
        return true;
    }
    return false;
}

bool parse_hex_frame(const std::string &text, std::vector<uint8_t> *bytes)
{
    std::string compact;
    compact.reserve(text.size());
    for (char ch : text) {
        if (std::isspace(static_cast<unsigned char>(ch)) ||
            ch == ':' || ch == '-')
            continue;
        compact.push_back(ch);
    }

    if (compact.empty() || compact.size() % 2 != 0)
        return false;

    bytes->clear();
    bytes->reserve(compact.size() / 2);
    for (size_t i = 0; i < compact.size(); i += 2) {
        uint8_t hi = 0;
        uint8_t lo = 0;
        if (!parse_hex_nibble(compact[i], &hi) ||
            !parse_hex_nibble(compact[i + 1], &lo)) {
            return false;
        }
        bytes->push_back(static_cast<uint8_t>((hi << 4U) | lo));
    }
    return true;
}

bool read_raw_file(const std::string &path, std::vector<uint8_t> *bytes)
{
    std::ifstream input(path, std::ios::binary);
    if (!input)
        return false;

    bytes->assign(std::istreambuf_iterator<char>(input),
                  std::istreambuf_iterator<char>());
    return true;
}

void print_packet(const packet_parser::ParsedPacket &packet, size_t frame_size)
{
    using packet_parser::classify_service;
    using packet_parser::format_ipv4;
    using packet_parser::format_mac;
    using packet_parser::service_kind_name;

    const auto kind = classify_service(packet);
    std::cout << "frame_bytes=" << frame_size << "\n";
    std::cout << "service=" << service_kind_name(kind) << "\n";
    std::cout << "ethernet src=" << format_mac(packet.ethernet.source)
              << " dst=" << format_mac(packet.ethernet.destination)
              << " ether_type=0x" << std::hex << std::setw(4)
              << std::setfill('0') << packet.ethernet.ether_type
              << std::dec << std::setfill(' ') << "\n";

    if (!packet.ipv4) {
        std::cout << "ipv4=absent\n";
        return;
    }

    std::cout << "ipv4 src=" << format_ipv4(packet.ipv4->source_ip)
              << " dst=" << format_ipv4(packet.ipv4->destination_ip)
              << " ttl=" << static_cast<unsigned int>(packet.ipv4->time_to_live)
              << " protocol=" << static_cast<unsigned int>(packet.ipv4->protocol)
              << " total_length=" << packet.ipv4->total_length << "\n";

    if (packet.udp) {
        std::cout << "udp src_port=" << packet.udp->source_port
                  << " dst_port=" << packet.udp->destination_port
                  << " length=" << packet.udp->length << "\n";
    }

    if (packet.tcp) {
        std::cout << "tcp src_port=" << packet.tcp->source_port
                  << " dst_port=" << packet.tcp->destination_port
                  << " seq=" << packet.tcp->sequence_number
                  << " ack=" << packet.tcp->acknowledgment_number
                  << " flags=0x" << std::hex
                  << static_cast<unsigned int>(packet.tcp->flags)
                  << std::dec << "\n";
    }
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) {
        print_usage(argv[0]);
        return 1;
    }

    std::vector<uint8_t> bytes;
    bool ok = false;
    if (!options.hex_frame.empty())
        ok = parse_hex_frame(options.hex_frame, &bytes);
    else
        ok = read_raw_file(options.raw_file, &bytes);

    if (!ok) {
        std::cerr << "Failed to load input frame\n";
        return 1;
    }

    auto packet = packet_parser::parse_packet(packet_parser::make_view(bytes));
    if (!packet) {
        std::cerr << "Failed to parse packet\n";
        return 1;
    }

    print_packet(*packet, bytes.size());
    return 0;
}
