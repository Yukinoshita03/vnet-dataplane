#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "udp_fastpath.h"

struct UdpFastpathPolicyEntry {
    std::string ifname;
    unsigned int ifindex = 0;
    __be32 server_ipv4 = 0;
    std::string server_text;
    uint16_t server_port = 0;
    std::vector<uint8_t> request;
    std::vector<uint8_t> response;
    unsigned lease_seconds = 0;
};

uint64_t udp_fastpath_now_ns();

bool parse_udp_fastpath_policy_file(
    const std::string &path, std::vector<UdpFastpathPolicyEntry> *entries,
    std::string *error);

bool install_udp_fastpath_entries(
    int map_fd, const std::vector<UdpFastpathPolicyEntry> &entries,
    uint64_t now_ns, std::string *error);
