#include "dns_cache_config.hpp"

#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <errno.h>
#include <string.h>

#include <chrono>
#include <fstream>
#include <sstream>

namespace {

bool parse_qtype(const std::string &token, __u16 *qtype)
{
    if (token == "A") {
        *qtype = 1;
        return true;
    }
    if (token == "AAAA") {
        *qtype = 28;
        return true;
    }
    if (token == "HTTPS") {
        *qtype = 65;
        return true;
    }
    return false;
}

bool parse_positive_ttl(const std::string &token, int *ttl)
{
    if (token.empty())
        return false;
    int value = 0;
    for (char character : token) {
        if (character < '0' || character > '9')
            return false;
        value = value * 10 + (character - '0');
        if (value <= 0)
            return false;
    }
    *ttl = value;
    return true;
}

bool decode_hex(const std::string &text, std::vector<unsigned char> *bytes)
{
    if (text.empty() || text.size() % 2 != 0)
        return false;
    bytes->clear();
    bytes->reserve(text.size() / 2);
    auto digit = [](char character) -> int {
        if (character >= '0' && character <= '9')
            return character - '0';
        if (character >= 'a' && character <= 'f')
            return character - 'a' + 10;
        if (character >= 'A' && character <= 'F')
            return character - 'A' + 10;
        return -1;
    };
    for (size_t i = 0; i < text.size(); i += 2) {
        int high = digit(text[i]);
        int low = digit(text[i + 1]);
        if (high < 0 || low < 0)
            return false;
        bytes->push_back(static_cast<unsigned char>((high << 4) | low));
    }
    return true;
}

const char *qtype_name(__u16 qtype)
{
    switch (qtype) {
    case 1:
        return "A";
    case 28:
        return "AAAA";
    case 65:
        return "HTTPS";
    default:
        return "UNKNOWN";
    }
}

} // namespace

uint64_t monotonic_now_ns()
{
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

bool encode_dns_qname(const std::string &domain, dns_cache_key *key)
{
    if (domain.empty() || domain.size() >= DNS_CACHE_QNAME_MAX)
        return false;

    *key = {};
    size_t out = 0;
    size_t label_start = 0;
    std::string name = domain;

    if (!name.empty() && name.back() == '.')
        name.pop_back();

    while (label_start < name.size()) {
        size_t dot = name.find('.', label_start);
        size_t label_end = dot == std::string::npos ? name.size() : dot;
        size_t label_len = label_end - label_start;

        if (label_len == 0 || label_len > 63)
            return false;
        if (out + 1 + label_len >= DNS_XDP_QNAME_SCAN_MAX)
            return false;

        key->qname[out++] = static_cast<__u8>(label_len);
        for (size_t i = 0; i < label_len; ++i) {
            char character = name[label_start + i];
            if (character >= 'A' && character <= 'Z')
                character += 'a' - 'A';
            key->qname[out++] = static_cast<__u8>(character);
        }

        if (dot == std::string::npos)
            break;
        label_start = dot + 1;
    }

    if (out >= DNS_XDP_QNAME_SCAN_MAX)
        return false;
    key->qname[out] = 0;
    key->qtype = 1;
    key->qclass = 1;
    return true;
}

bool parse_dns_cache_file(const std::string &path,
                          std::vector<DnsCacheEntry> *entries,
                          std::string *error)
{
    std::ifstream input(path);
    if (!input) {
        if (error)
            *error = "failed to open cache file: " + path;
        return false;
    }

    std::string line;
    int line_no = 0;
    while (std::getline(input, line)) {
        line_no++;
        size_t comment = line.find('#');
        if (comment != std::string::npos)
            line.resize(comment);

        std::istringstream stream(line);
        DnsCacheEntry entry;
        std::string first;
        std::string address_or_rdata;
        std::string ttl_text;
        std::string extra;
        if (!(stream >> entry.domain))
            continue;
        if (!(stream >> first)) {
            if (error) {
                *error = "invalid cache file line " + std::to_string(line_no) +
                         ": expected 'domain [A|AAAA|HTTPS] address-or-rdata ttl'";
            }
            return false;
        }

        if (parse_qtype(first, &entry.qtype)) {
            if (!(stream >> address_or_rdata >> ttl_text) ||
                (stream >> extra)) {
                if (error) {
                    *error = "invalid cache file line " +
                             std::to_string(line_no) +
                             ": expected 'domain type address-or-rdata ttl'";
                }
                return false;
            }
        } else {
            entry.qtype = 1;
            address_or_rdata = first;
            if (!(stream >> ttl_text) || (stream >> extra)) {
                if (error) {
                    *error = "invalid cache file line " +
                             std::to_string(line_no) +
                             ": expected 'domain ipv4 ttl'";
                }
                return false;
            }
        }

        entry.ip = address_or_rdata;
        if (entry.qtype == 65)
            entry.rdata_hex = address_or_rdata;
        if (!parse_positive_ttl(ttl_text, &entry.ttl)) {
            if (error)
                *error = "invalid TTL in cache file line " +
                         std::to_string(line_no);
            return false;
        }

        dns_cache_key key = {};
        if (!encode_dns_qname(entry.domain, &key)) {
            if (error)
                *error = "invalid domain in cache file line " +
                         std::to_string(line_no) + ": " + entry.domain;
            return false;
        }
        key.qtype = entry.qtype;
        dns_cache_value value = {};
        if (!build_dns_cache_value(entry, &value, error))
            return false;
        entries->push_back(entry);
    }

    if (entries->empty()) {
        if (error)
            *error = "cache file has no usable entries: " + path;
        return false;
    }
    return true;
}

bool build_dns_cache_value(const DnsCacheEntry &entry,
                           dns_cache_value *value,
                           std::string *error)
{
    *value = {};
    if (entry.ttl <= 0) {
        if (error)
            *error = "invalid cache TTL: " + std::to_string(entry.ttl);
        return false;
    }

    std::vector<unsigned char> rdata;
    if (entry.qtype == 1) {
        rdata.resize(4);
        if (inet_pton(AF_INET, entry.ip.c_str(), rdata.data()) != 1) {
            if (error)
                *error = "invalid cache IPv4 address: " + entry.ip;
            return false;
        }
    } else if (entry.qtype == 28) {
        rdata.resize(16);
        if (inet_pton(AF_INET6, entry.ip.c_str(), rdata.data()) != 1) {
            if (error)
                *error = "invalid cache IPv6 address: " + entry.ip;
            return false;
        }
    } else if (entry.qtype == 65) {
        if (!decode_hex(entry.rdata_hex, &rdata)) {
            if (error)
                *error = "invalid HTTPS cache RDATA hex: " +
                         entry.rdata_hex;
            return false;
        }
    } else {
        if (error)
            *error = "unsupported DNS cache QTYPE: " +
                     std::to_string(entry.qtype);
        return false;
    }

    if (rdata.empty() || rdata.size() > DNS_CACHE_ANSWER_MAX - 12) {
        if (error)
            *error = "DNS cache RDATA is empty or too large for " +
                     std::string(qtype_name(entry.qtype));
        return false;
    }

    value->ttl = static_cast<__u32>(entry.ttl);
    value->answer_len = static_cast<__u32>(12 + rdata.size());
    value->answer[0] = 0xc0;
    value->answer[1] = 0x0c;
    value->answer[2] = static_cast<__u8>(entry.qtype >> 8);
    value->answer[3] = static_cast<__u8>(entry.qtype);
    value->answer[4] = 0x00;
    value->answer[5] = 0x01;
    __be32 ttl = htonl(value->ttl);
    __be16 rdlength = htons(static_cast<__u16>(rdata.size()));
    memcpy(value->answer + 6, &ttl, sizeof(ttl));
    memcpy(value->answer + 10, &rdlength, sizeof(rdlength));
    memcpy(value->answer + 12, rdata.data(), rdata.size());
    value->expires_ns =
        monotonic_now_ns() + static_cast<uint64_t>(entry.ttl) * 1000000000ull;
    return true;
}

bool install_dns_cache_entry(int cache_fd,
                             const DnsCacheEntry &entry,
                             std::string *error)
{
    dns_cache_key key = {};
    if (!encode_dns_qname(entry.domain, &key)) {
        if (error)
            *error = "invalid cache domain: " + entry.domain;
        return false;
    }
    key.qtype = entry.qtype;
    key.qclass = 1;

    dns_cache_value value = {};
    if (!build_dns_cache_value(entry, &value, error))
        return false;

    if (bpf_map_update_elem(cache_fd, &key, &value, BPF_ANY) != 0) {
        if (error)
            *error = std::string("failed to update dns_cache map: ") +
                     strerror(errno);
        return false;
    }
    return true;
}
