#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "dns_event.h"

struct DnsCacheEntry {
    std::string domain;
    std::string ip;
    int ttl = 60;
};

uint64_t monotonic_now_ns();
bool encode_dns_qname(const std::string &domain, dns_cache_key *key);
bool parse_dns_cache_file(const std::string &path,
                          std::vector<DnsCacheEntry> *entries,
                          std::string *error);
bool build_dns_cache_value(const DnsCacheEntry &entry,
                           dns_cache_value *value,
                           std::string *error);
bool install_dns_cache_entry(int cache_fd,
                             const DnsCacheEntry &entry,
                             std::string *error);
