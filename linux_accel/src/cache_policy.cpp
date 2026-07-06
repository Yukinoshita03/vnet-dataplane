#include "cache_policy.hpp"

#include <sstream>
#include <fstream>

uint64_t hash_grpc_method(const std::string &method)
{
    uint64_t hash = 1469598103934665603ull;
    for (unsigned char ch : method) {
        hash ^= ch;
        hash *= 1099511628211ull;
    }
    return hash;
}

uint64_t hash_grpc_payload(const std::string &payload)
{
    uint64_t hash = 1469598103934665603ull;
    for (unsigned char ch : payload) {
        hash ^= ch;
        hash *= 1099511628211ull;
    }
    return hash;
}

namespace {

bool parse_positive_int(const std::string &value, int *out)
{
    if (value.empty())
        return false;

    int result = 0;
    for (char ch : value) {
        if (ch < '0' || ch > '9')
            return false;
        result = result * 10 + (ch - '0');
        if (result <= 0)
            return false;
    }

    *out = result;
    return true;
}

bool valid_grpc_method(const std::string &method)
{
    if (method.size() < 4 || method[0] != '/')
        return false;
    size_t second_slash = method.find('/', 1);
    return second_slash != std::string::npos &&
           second_slash + 1 < method.size();
}

bool parse_bool_token(const std::string &value, bool *out)
{
    if (value == "true" || value == "yes" || value == "1" ||
        value == "idempotent") {
        *out = true;
        return true;
    }
    if (value == "false" || value == "no" || value == "0" ||
        value == "non-idempotent") {
        *out = false;
        return true;
    }
    return false;
}

bool valid_grpc_cache_status(const std::string &status)
{
    return status == "SERVING" || status == "NOT_SERVING" ||
           status == "serving" || status == "not_serving";
}

} // namespace

bool parse_cache_policy_file(const std::string &path,
                             CachePolicy *policy,
                             std::string *error)
{
    std::ifstream input(path);
    if (!input) {
        if (error)
            *error = "failed to open policy file: " + path;
        return false;
    }

    *policy = {};
    std::string line;
    int line_no = 0;
    while (std::getline(input, line)) {
        line_no++;
        size_t comment = line.find('#');
        if (comment != std::string::npos)
            line.resize(comment);

        std::istringstream stream(line);
        std::string kind;
        if (!(stream >> kind))
            continue;

        if (kind == "dns") {
            DnsCacheEntry entry;
            std::string ttl;
            std::string extra;
            if (!(stream >> entry.domain >> entry.ip >> ttl) || (stream >> extra)) {
                if (error) {
                    *error = "invalid policy line " + std::to_string(line_no) +
                             ": expected 'dns domain ipv4 ttl'";
                }
                return false;
            }
            if (!parse_positive_int(ttl, &entry.ttl)) {
                if (error)
                    *error = "invalid DNS TTL on policy line " +
                             std::to_string(line_no);
                return false;
            }
            dns_cache_key key = {};
            if (!encode_dns_qname(entry.domain, &key)) {
                if (error)
                    *error = "invalid DNS domain on policy line " +
                             std::to_string(line_no) + ": " + entry.domain;
                return false;
            }
            dns_cache_value value = {};
            if (!build_dns_cache_value(entry, &value, error))
                return false;
            policy->dns_entries.push_back(entry);
            continue;
        }

        if (kind == "grpc") {
            GrpcPolicyEntry entry;
            std::string ttl;
            std::string idempotent;
            std::string extra;
            if (!(stream >> entry.method >> ttl >> idempotent) ||
                (stream >> extra)) {
                if (error) {
                    *error = "invalid policy line " + std::to_string(line_no) +
                             ": expected 'grpc /Service/Method ttl idempotent'";
                }
                return false;
            }
            if (!valid_grpc_method(entry.method)) {
                if (error)
                    *error = "invalid gRPC method on policy line " +
                             std::to_string(line_no) + ": " + entry.method;
                return false;
            }
            if (!parse_positive_int(ttl, &entry.ttl)) {
                if (error)
                    *error = "invalid gRPC TTL on policy line " +
                             std::to_string(line_no);
                return false;
            }
            if (!parse_bool_token(idempotent, &entry.idempotent)) {
                if (error)
                    *error = "invalid gRPC idempotent flag on policy line " +
                             std::to_string(line_no);
                return false;
            }
            if (!entry.idempotent) {
                if (error) {
                    *error = "non-idempotent gRPC method is not cacheable on policy line " +
                             std::to_string(line_no);
                }
                return false;
            }
            entry.method_hash = hash_grpc_method(entry.method);
            policy->grpc_entries.push_back(entry);
            continue;
        }

        if (kind == "grpc-cache") {
            GrpcResponseCacheEntry entry;
            std::string ttl;
            std::string extra;
            if (!(stream >> entry.method >> entry.payload >> entry.status >> ttl) ||
                (stream >> extra)) {
                if (error) {
                    *error = "invalid policy line " + std::to_string(line_no) +
                             ": expected 'grpc-cache /Service/Method payload SERVING|NOT_SERVING ttl'";
                }
                return false;
            }
            if (!valid_grpc_method(entry.method)) {
                if (error)
                    *error = "invalid gRPC cache method on policy line " +
                             std::to_string(line_no) + ": " + entry.method;
                return false;
            }
            if (entry.payload.empty()) {
                if (error)
                    *error = "empty gRPC cache payload on policy line " +
                             std::to_string(line_no);
                return false;
            }
            if (!valid_grpc_cache_status(entry.status)) {
                if (error)
                    *error = "invalid gRPC cache status on policy line " +
                             std::to_string(line_no) + ": " + entry.status;
                return false;
            }
            if (!parse_positive_int(ttl, &entry.ttl)) {
                if (error)
                    *error = "invalid gRPC cache TTL on policy line " +
                             std::to_string(line_no);
                return false;
            }
            entry.method_hash = hash_grpc_method(entry.method);
            entry.payload_hash = hash_grpc_payload(entry.payload);
            policy->grpc_cache_entries.push_back(entry);
            continue;
        }

        if (error)
            *error = "unknown policy kind on line " + std::to_string(line_no) +
                     ": " + kind;
        return false;
    }

    if (policy->dns_entries.empty() && policy->grpc_entries.empty() &&
        policy->grpc_cache_entries.empty()) {
        if (error)
            *error = "policy file has no usable entries: " + path;
        return false;
    }
    return true;
}

