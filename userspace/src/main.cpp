#include "vnet/packet.h"

#include <array>
#include <cstddef>
#include <iostream>

int main() {
  constexpr std::array<std::byte, 14> kDemoFrame = {
      std::byte{0x00}, std::byte{0x11}, std::byte{0x22}, std::byte{0x33},
      std::byte{0x44}, std::byte{0x55}, std::byte{0xaa}, std::byte{0xbb},
      std::byte{0xcc}, std::byte{0xdd}, std::byte{0xee}, std::byte{0xff},
      std::byte{0x08}, std::byte{0x00},
  };

  const auto frame = vnet::ParseEthernetFrame(kDemoFrame);
  if (!frame.has_value()) {
    std::cerr << "failed to parse demo Ethernet frame\n";
    return 1;
  }

  std::cout << "vnet-dataplane bootstrap\n";
  std::cout << "dst=" << vnet::FormatMac(frame->destination)
            << " src=" << vnet::FormatMac(frame->source)
            << " ether_type=0x" << std::hex << frame->ether_type << '\n';
  return 0;
}
