#include "vnet/packet.h"

#include <array>
#include <cstddef>
#include <cstdlib>
#include <iostream>
#include <span>

namespace {

int Fail(const char *message) {
  std::cerr << message << '\n';
  return EXIT_FAILURE;
}

int TestEthernetFrame() {
  constexpr std::array<std::byte, 14> kFrame = {
      std::byte{0xde}, std::byte{0xad}, std::byte{0xbe}, std::byte{0xef},
      std::byte{0x00}, std::byte{0x01}, std::byte{0xca}, std::byte{0xfe},
      std::byte{0xba}, std::byte{0xbe}, std::byte{0x00}, std::byte{0x02},
      std::byte{0x08}, std::byte{0x06},
  };

  const auto frame = vnet::ParseEthernetFrame(kFrame);
  if (!frame.has_value()) {
    return Fail("expected Ethernet frame to parse");
  }
  if (frame->ether_type != 0x0806) {
    return Fail("unexpected ether_type");
  }
  if (vnet::FormatMac(frame->destination) != "de:ad:be:ef:00:01") {
    return Fail("unexpected destination MAC");
  }
  if (vnet::FormatMac(frame->source) != "ca:fe:ba:be:00:02") {
    return Fail("unexpected source MAC");
  }
  return EXIT_SUCCESS;
}

int TestDnsClassification() {
  constexpr std::array<std::byte, 42> kDnsFrame = {
      std::byte{0x00}, std::byte{0x11}, std::byte{0x22}, std::byte{0x33},
      std::byte{0x44}, std::byte{0x55}, std::byte{0xaa}, std::byte{0xbb},
      std::byte{0xcc}, std::byte{0xdd}, std::byte{0xee}, std::byte{0xff},
      std::byte{0x08}, std::byte{0x00}, std::byte{0x45}, std::byte{0x00},
      std::byte{0x00}, std::byte{0x1c}, std::byte{0x12}, std::byte{0x34},
      std::byte{0x00}, std::byte{0x00}, std::byte{0x40}, std::byte{0x11},
      std::byte{0x00}, std::byte{0x00}, std::byte{0x0a}, std::byte{0x00},
      std::byte{0x00}, std::byte{0x01}, std::byte{0x0a}, std::byte{0x00},
      std::byte{0x00}, std::byte{0x02}, std::byte{0xc0}, std::byte{0x01},
      std::byte{0x00}, std::byte{0x35}, std::byte{0x00}, std::byte{0x08},
      std::byte{0x00}, std::byte{0x00},
  };

  const auto packet = vnet::ParsePacket(kDnsFrame);
  if (!packet.has_value()) {
    return Fail("expected DNS frame to parse");
  }
  if (!packet->ipv4.has_value() || !packet->udp.has_value()) {
    return Fail("expected IPv4 and UDP headers");
  }
  if (vnet::ClassifyService(*packet) != vnet::ServiceKind::kDns) {
    return Fail("expected DNS classification");
  }
  if (vnet::FormatIpv4(packet->ipv4->source_ip) != "10.0.0.1") {
    return Fail("unexpected IPv4 source");
  }
  return EXIT_SUCCESS;
}

int TestGrpcClassification() {
  constexpr std::array<std::byte, 54> kGrpcFrame = {
      std::byte{0x10}, std::byte{0x20}, std::byte{0x30}, std::byte{0x40},
      std::byte{0x50}, std::byte{0x60}, std::byte{0xa0}, std::byte{0xb0},
      std::byte{0xc0}, std::byte{0xd0}, std::byte{0xe0}, std::byte{0xf0},
      std::byte{0x08}, std::byte{0x00}, std::byte{0x45}, std::byte{0x00},
      std::byte{0x00}, std::byte{0x28}, std::byte{0x56}, std::byte{0x78},
      std::byte{0x00}, std::byte{0x00}, std::byte{0x40}, std::byte{0x06},
      std::byte{0x00}, std::byte{0x00}, std::byte{0xc0}, std::byte{0xa8},
      std::byte{0x01}, std::byte{0x0a}, std::byte{0xc0}, std::byte{0xa8},
      std::byte{0x01}, std::byte{0x14}, std::byte{0xa4}, std::byte{0x4f},
      std::byte{0xc3}, std::byte{0x83}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x00}, std::byte{0x01}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x00}, std::byte{0x00}, std::byte{0x50}, std::byte{0x18},
      std::byte{0x20}, std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x00}, std::byte{0x00},
  };

  const auto packet = vnet::ParsePacket(kGrpcFrame);
  if (!packet.has_value()) {
    return Fail("expected gRPC frame to parse");
  }
  if (!packet->ipv4.has_value() || !packet->tcp.has_value()) {
    return Fail("expected IPv4 and TCP headers");
  }
  if (vnet::ClassifyService(*packet) != vnet::ServiceKind::kGrpc) {
    return Fail("expected gRPC classification");
  }
  if (vnet::TcpHeaderLength(*packet->tcp) != 20) {
    return Fail("unexpected TCP header length");
  }
  return EXIT_SUCCESS;
}

} // namespace

int main() {
  if (const int result = TestEthernetFrame(); result != EXIT_SUCCESS) {
    return result;
  }
  if (const int result = TestDnsClassification(); result != EXIT_SUCCESS) {
    return result;
  }
  if (const int result = TestGrpcClassification(); result != EXIT_SUCCESS) {
    return result;
  }
  return EXIT_SUCCESS;
}
