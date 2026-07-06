#include "vnet/packet.h"

#include <array>
#include <cstddef>
#include <cstdlib>
#include <iostream>

namespace {

int Fail(const char* message) {
  std::cerr << message << '\n';
  return EXIT_FAILURE;
}

}  // namespace

int main() {
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
