#include "udp_fastpath_policy.hpp"

#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <errno.h>
#include <net/if.h>
#include <string.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <set>
#include <sstream>
#include <utility>

namespace {

bool parse_unsigned(const std::string &text, unsigned minimum,
                    unsigned maximum, unsigned *value)
{
    if (text.empty() || text[0] == '-')
        return false;
    char *end = nullptr;
    errno = 0;
    unsigned long parsed = std::strtoul(text.c_str(), &end, 10);
    if (errno || !end || *end != '\0' || parsed < minimum ||
        parsed > maximum)
        return false;
    *value = static_cast<unsigned>(parsed);
    return true;
}

int hex_nibble(char ch)
{
    if (ch >= '0' && ch <= '9')
        return ch - '0';
    if (ch >= 'a' && ch <= 'f')
        return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F')
        return ch - 'A' + 10;
    return -1;
}

bool parse_hex(const std::string &text, size_t maximum,
               std::vector<uint8_t> *bytes)
{
    bytes->clear();
    if (text == "-")
        return true;
    if (text.empty() || (text.size() & 1) ||
        text.size() > maximum * 2)
        return false;

    bytes->reserve(text.size() / 2);
    for (size_t i = 0; i < text.size(); i += 2) {
        int high = hex_nibble(text[i]);
        int low = hex_nibble(text[i + 1]);
        if (high < 0 || low < 0)
            return false;
        bytes->push_back(static_cast<uint8_t>((high << 4) | low));
    }
    return true;
}

std::string key_identity(const UdpFastpathPolicyEntry &entry)
{
    std::ostringstream out;
    out << entry.ifindex << ':' << static_cast<uint32_t>(entry.server_ipv4)
        << ':' << entry.server_port << ':';
    static const char digits[] = "0123456789abcdef";
    for (uint8_t byte : entry.request)
        out << digits[byte >> 4] << digits[byte & 0xf];
    return out.str();
}

struct udp_fastpath_key make_key(const UdpFastpathPolicyEntry &entry)
{
    struct udp_fastpath_key key = {};
    key.ifindex = entry.ifindex;
    key.server_ipv4 = entry.server_ipv4;
    key.server_port = htons(entry.server_port);
    key.request_len = static_cast<__u16>(entry.request.size());
    std::copy(entry.request.begin(), entry.request.end(), key.request);
    return key;
}

struct udp_fastpath_value make_value(const UdpFastpathPolicyEntry &entry,
                                     uint64_t now_ns)
{
    struct udp_fastpath_value value = {};
    value.expires_ns =
        now_ns + static_cast<uint64_t>(entry.lease_seconds) * 1000000000ull;
    value.response_len = static_cast<__u16>(entry.response.size());
    value.flags = UDP_FASTPATH_ENTRY_ENABLED;
    std::copy(entry.response.begin(), entry.response.end(), value.response);
    return value;
}

} // namespace

uint64_t udp_fastpath_now_ns()
{
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

bool parse_udp_fastpath_policy_file(
    const std::string &path, std::vector<UdpFastpathPolicyEntry> *entries,
    std::string *error)
{
    std::ifstream input(path);
    if (!input) {
        *error = "failed to open UDP policy file: " + path;
        return false;
    }

    entries->clear();
    std::set<std::string> identities;
    std::string line;
    unsigned line_number = 0;
    while (std::getline(input, line)) {
        line_number++;
        size_t comment = line.find('#');
        if (comment != std::string::npos)
            line.resize(comment);

        std::istringstream stream(line);
        UdpFastpathPolicyEntry entry;
        std::string port_text;
        std::string request_text;
        std::string response_text;
        std::string lease_text;
        std::string extra;
        if (!(stream >> entry.ifname))
            continue;
        if (!(stream >> entry.server_text >> port_text >> request_text >>
              response_text >> lease_text) ||
            (stream >> extra)) {
            *error = "invalid UDP policy line " + std::to_string(line_number) +
                     ": expected six fields";
            return false;
        }

        entry.ifindex = if_nametoindex(entry.ifname.c_str());
        if (!entry.ifindex) {
            *error = "UDP policy interface does not exist on line " +
                     std::to_string(line_number) + ": " + entry.ifname;
            return false;
        }
        if (inet_pton(AF_INET, entry.server_text.c_str(), &entry.server_ipv4) !=
                1 ||
            entry.server_ipv4 == 0) {
            *error = "invalid UDP server IPv4 on line " +
                     std::to_string(line_number) + ": " + entry.server_text;
            return false;
        }

        unsigned port = 0;
        if (!parse_unsigned(port_text, 1, 65535, &port)) {
            *error = "invalid UDP server port on line " +
                     std::to_string(line_number);
            return false;
        }
        entry.server_port = static_cast<uint16_t>(port);
        if (!parse_hex(request_text, UDP_FASTPATH_MAX_REQUEST,
                       &entry.request) ||
            !parse_hex(response_text, UDP_FASTPATH_MAX_RESPONSE,
                       &entry.response)) {
            *error = "invalid or oversized UDP hex payload on line " +
                     std::to_string(line_number);
            return false;
        }
        if (!parse_unsigned(lease_text, 1, 86400, &entry.lease_seconds)) {
            *error = "invalid UDP lease on line " +
                     std::to_string(line_number);
            return false;
        }
        if (!identities.insert(key_identity(entry)).second) {
            *error = "duplicate UDP cache key on line " +
                     std::to_string(line_number);
            return false;
        }
        entries->push_back(std::move(entry));
    }

    if (entries->empty()) {
        *error = "UDP policy file has no usable entries: " + path;
        return false;
    }
    return true;
}

bool install_udp_fastpath_entries(
    int map_fd, const std::vector<UdpFastpathPolicyEntry> &entries,
    uint64_t now_ns, std::string *error)
{
    for (const UdpFastpathPolicyEntry &entry : entries) {
        struct udp_fastpath_key key = make_key(entry);
        struct udp_fastpath_value value = make_value(entry, now_ns);
        if (bpf_map_update_elem(map_fd, &key, &value, BPF_ANY) != 0) {
            *error = "failed to install UDP cache entry for " + entry.ifname +
                     "/" + entry.server_text + ":" +
                     std::to_string(entry.server_port) + ": " + strerror(errno);
            return false;
        }
    }
    return true;
}
