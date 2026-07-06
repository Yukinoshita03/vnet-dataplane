#include "vnet/packet.h"

#include <cctype>
#include <cstddef>
#include <cstdlib>
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

void PrintUsage(const char *program) {
  std::cerr << "Usage: " << program
            << " (--hex-frame <hex-bytes> | --raw-file <path>)\n";
}

bool ParseOptions(int argc, char **argv, Options *options) {
  for (int index = 1; index < argc; ++index) {
    const std::string arg = argv[index];
    if (arg == "--hex-frame" && index + 1 < argc) {
      options->hex_frame = argv[++index];
    } else if (arg == "--raw-file" && index + 1 < argc) {
      options->raw_file = argv[++index];
    } else if (arg == "-h" || arg == "--help") {
      return false;
    } else {
      std::cerr << "Unknown or incomplete option: " << arg << '\n';
      return false;
    }
  }

  const bool has_hex = !options->hex_frame.empty();
  const bool has_file = !options->raw_file.empty();
  return has_hex != has_file;
}

bool ParseHexNibble(char ch, std::uint8_t *value) {
  if (ch >= '0' && ch <= '9') {
    *value = static_cast<std::uint8_t>(ch - '0');
    return true;
  }
  ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
  if (ch >= 'a' && ch <= 'f') {
    *value = static_cast<std::uint8_t>(10 + ch - 'a');
    return true;
  }
  return false;
}

bool ParseHexFrame(const std::string &text, std::vector<std::byte> *bytes) {
  std::string compact;
  compact.reserve(text.size());
  for (char ch : text) {
    if (std::isspace(static_cast<unsigned char>(ch)) || ch == ':' ||
        ch == '-') {
      continue;
    }
    compact.push_back(ch);
  }

  if (compact.empty() || compact.size() % 2 != 0) {
    return false;
  }

  bytes->clear();
  bytes->reserve(compact.size() / 2);
  for (std::size_t index = 0; index < compact.size(); index += 2) {
    std::uint8_t hi = 0;
    std::uint8_t lo = 0;
    if (!ParseHexNibble(compact[index], &hi) ||
        !ParseHexNibble(compact[index + 1], &lo)) {
      return false;
    }
    bytes->push_back(std::byte{static_cast<unsigned char>((hi << 4U) | lo)});
  }
  return true;
}

bool ReadRawFile(const std::string &path, std::vector<std::byte> *bytes) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    return false;
  }

  std::vector<char> buffer(std::istreambuf_iterator<char>(input), {});
  bytes->clear();
  bytes->reserve(buffer.size());
  for (unsigned char ch : buffer) {
    bytes->push_back(std::byte{ch});
  }
  return true;
}

void PrintPacket(const vnet::ParsedPacket &packet, std::size_t frame_size) {
  const auto kind = vnet::ClassifyService(packet);

  std::cout << "frame_bytes=" << frame_size << '\n';
  std::cout << "service=" << vnet::ServiceKindName(kind) << '\n';
  std::cout << "ethernet src=" << vnet::FormatMac(packet.ethernet.source)
            << " dst=" << vnet::FormatMac(packet.ethernet.destination)
            << " ether_type=0x" << std::hex << std::setw(4)
            << std::setfill('0') << packet.ethernet.ether_type << std::dec
            << std::setfill(' ') << '\n';

  if (!packet.ipv4.has_value()) {
    std::cout << "ipv4=absent\n";
    return;
  }

  std::cout << "ipv4 src=" << vnet::FormatIpv4(packet.ipv4->source_ip)
            << " dst=" << vnet::FormatIpv4(packet.ipv4->destination_ip)
            << " ttl="
            << static_cast<unsigned int>(packet.ipv4->time_to_live)
            << " protocol="
            << static_cast<unsigned int>(packet.ipv4->protocol)
            << " total_length=" << packet.ipv4->total_length << '\n';

  if (packet.udp.has_value()) {
    std::cout << "udp src_port=" << packet.udp->source_port
              << " dst_port=" << packet.udp->destination_port
              << " length=" << packet.udp->length << '\n';
  }

  if (packet.tcp.has_value()) {
    std::cout << "tcp src_port=" << packet.tcp->source_port
              << " dst_port=" << packet.tcp->destination_port
              << " seq=" << packet.tcp->sequence_number
              << " ack=" << packet.tcp->acknowledgment_number
              << " flags=0x" << std::hex
              << static_cast<unsigned int>(packet.tcp->flags) << std::dec
              << '\n';
  }
}

} // namespace

int main(int argc, char **argv) {
  Options options;
  if (!ParseOptions(argc, argv, &options)) {
    PrintUsage(argv[0]);
    return EXIT_FAILURE;
  }

  std::vector<std::byte> bytes;
  bool ok = false;
  if (!options.hex_frame.empty()) {
    ok = ParseHexFrame(options.hex_frame, &bytes);
  } else {
    ok = ReadRawFile(options.raw_file, &bytes);
  }

  if (!ok) {
    std::cerr << "Failed to load input frame\n";
    return EXIT_FAILURE;
  }

  const auto packet = vnet::ParsePacket(bytes);
  if (!packet.has_value()) {
    std::cerr << "Failed to parse packet\n";
    return EXIT_FAILURE;
  }

  PrintPacket(*packet, bytes.size());
  return EXIT_SUCCESS;
}
