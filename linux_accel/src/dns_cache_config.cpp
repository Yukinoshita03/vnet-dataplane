#include "dns_cache_config.hpp"

#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <errno.h>
#include <string.h>

#include <chrono>
#include <fstream>
#include <sstream>

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
        std::string extra;
        if (!(stream >> entry.domain))
            continue;
        if (!(stream >> entry.ip >> entry.ttl) || (stream >> extra)) {
            if (error) {
                *error = "invalid cache file line " + std::to_string(line_no) +
                         ": expected 'domain ipv4 ttl'";
            }
            return false;
        }
        if (entry.ttl <= 0) {
            if (error)
                *error = "invalid TTL in cache file line " + std::to_string(line_no);
            return false;
        }
        dns_cache_key key = {};
        if (!encode_dns_qname(entry.domain, &key)) {
            if (error)
                *error = "invalid domain in cache file line " +
                         std::to_string(line_no) + ": " + entry.domain;
            return false;
        }
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
    if (inet_pton(AF_INET, entry.ip.c_str(), &value->answer_ipv4) != 1) {
        if (error)
            *error = "invalid cache IPv4 address: " + entry.ip;
        return false;
    }
    if (entry.ttl <= 0) {
        if (error)
            *error = "invalid cache TTL: " + std::to_string(entry.ttl);
        return false;
    }

    value->ttl = static_cast<__u32>(entry.ttl);
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
