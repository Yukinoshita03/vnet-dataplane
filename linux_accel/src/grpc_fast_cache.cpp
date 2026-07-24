#include "cache_policy.hpp"
#include "grpc_cache_protocol.hpp"
#include "grpc_cache_types.hpp"
#include "grpc_event.h"

#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

volatile sig_atomic_t exiting = 0;

void handle_signal(int)
{
    exiting = 1;
}

uint64_t hash_grpc_method(const std::string &method)
{
    uint64_t hash = 1469598103934665603ull;
    for (unsigned char ch : method) {
        hash ^= ch;
        hash *= 1099511628211ull;
    }
    return hash;
}

uint64_t hash_payload_string(const std::string &payload)
{
    uint64_t hash = 1469598103934665603ull;
    for (unsigned char ch : payload) {
        hash ^= ch;
        hash *= 1099511628211ull;
    }
    return hash;
}

uint64_t fnv1a_update(uint64_t hash, const uint8_t *data, size_t len)
{
    for (size_t i = 0; i < len; ++i) {
        hash ^= data[i];
        hash *= 1099511628211ull;
    }
    return hash;
}

void print_usage(const char *program)
{
    std::cerr << "Usage: " << program
              << " [--grpc-map <pinned-map-path>]"
              << " [--grpc-response-map <pinned-map-path>]"
              << " [--listen 0.0.0.0:50051]"
              << " [--backend 127.0.0.1:50051]"
              << " [--cache-file policy.txt]"
              << " [--method /grpc.health.v1.Health/Check]"
              << " [--cache-entry /Service/Method:payload:SERVING]"
              << " [--verbose]\n";
}

bool parse_health_status(const std::string &value, HealthStatus *status)
{
    if (value == "SERVING" || value == "serving") {
        *status = HealthStatus::Serving;
        return true;
    }
    if (value == "NOT_SERVING" || value == "not_serving" ||
        value == "NOT-SERVING" || value == "not-serving") {
        *status = HealthStatus::NotServing;
        return true;
    }
    return false;
}

bool install_response_cache_entry(const std::string &method,
                                  const std::string &payload,
                                  const std::string &status_text,
                                  ResponseCache *cache)
{
    HealthStatus status = HealthStatus::Serving;
    if (method.empty() || payload.empty() ||
        !parse_health_status(status_text, &status))
        return false;

    GrpcCacheKey key = {};
    key.method_hash = hash_grpc_method(method);
    key.payload_hash = hash_payload_string(payload);
    (*cache)[key] = CacheEntry{status};
    return true;
}

bool parse_cache_entry_arg(const std::string &value, ResponseCache *cache)
{
    size_t first = value.find(':');
    size_t second = value.find(':', first == std::string::npos ? first : first + 1);
    if (first == std::string::npos || second == std::string::npos ||
        first == 0 || second + 1 >= value.size())
        return false;

    std::string method = value.substr(0, first);
    std::string payload = value.substr(first + 1, second - first - 1);
    std::string status_text = value.substr(second + 1);
    return install_response_cache_entry(method, payload, status_text, cache);
}

bool load_response_cache_file(const std::string &path, ResponseCache *cache)
{
    CachePolicy policy;
    std::string error;
    if (!parse_cache_policy_file(path, &policy, &error)) {
        std::cerr << error << "\n";
        return false;
    }

    for (const GrpcResponseCacheEntry &entry : policy.grpc_cache_entries) {
        if (!install_response_cache_entry(entry.method, entry.payload,
                                          entry.status, cache)) {
            std::cerr << "Invalid grpc-cache entry for " << entry.method << "\n";
            return false;
        }
    }
    return true;
}

bool parse_host_port(const std::string &value, std::string *host, int *port)
{
    size_t colon = value.rfind(':');
    if (colon == std::string::npos || colon == 0 || colon + 1 >= value.size())
        return false;

    char *end = nullptr;
    long parsed_port = std::strtol(value.c_str() + colon + 1, &end, 10);
    if (!end || *end != '\0' || parsed_port <= 0 || parsed_port > 65535)
        return false;

    *host = value.substr(0, colon);
    *port = static_cast<int>(parsed_port);
    return true;
}

bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--grpc-map" && i + 1 < argc) {
            options->grpc_map_path = argv[++i];
        } else if (arg == "--grpc-response-map" && i + 1 < argc) {
            options->grpc_response_map_path = argv[++i];
        } else if (arg == "--listen" && i + 1 < argc) {
            if (!parse_host_port(argv[++i], &options->listen_host,
                                 &options->listen_port))
                return false;
        } else if (arg == "--backend" && i + 1 < argc) {
            if (!parse_host_port(argv[++i], &options->backend_host,
                                 &options->backend_port))
                return false;
        } else if (arg == "--cache-file" && i + 1 < argc) {
            options->cache_file = argv[++i];
        } else if (arg == "--method" && i + 1 < argc) {
            options->method = argv[++i];
        } else if (arg == "--cache-entry" && i + 1 < argc) {
            options->cache_entries.push_back(argv[++i]);
        } else if (arg == "--verbose") {
            options->verbose = true;
        } else if (arg == "-h" || arg == "--help") {
            return false;
        } else {
            std::cerr << "Unknown or incomplete option: " << arg << "\n";
            return false;
        }
    }

    return (!options->grpc_map_path.empty() ||
            !options->cache_file.empty() ||
            !options->cache_entries.empty()) &&
           !options->backend_host.empty() &&
           options->backend_port > 0 &&
           options->method.size() > 3 &&
           options->method[0] == '/';
}

bool policy_allows_method(int map_fd, const std::string &method)
{
    grpc_policy_key key = {};
    grpc_policy_value value = {};
    key.method_hash = hash_grpc_method(method);

    if (bpf_map_lookup_elem(map_fd, &key, &value) != 0)
        return false;
    return value.idempotent && value.ttl > 0;
}

int connect_backend(const Options &options)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;

    sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(options.backend_port));
    if (inet_pton(AF_INET, options.backend_host.c_str(), &addr.sin_addr) != 1) {
        close(fd);
        errno = EINVAL;
        return -1;
    }

    if (connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

bool fallback_to_backend(int client, const Options &options,
                         const std::vector<uint8_t> &raw_request)
{
    int backend = connect_backend(options);
    if (backend < 0)
        return false;

    if (!send_all(backend, raw_request)) {
        close(backend);
        return false;
    }
    shutdown(backend, SHUT_WR);

    bool ok = true;
    std::vector<uint8_t> buffer(16384);
    while (true) {
        ssize_t n = recv(backend, buffer.data(), buffer.size(), 0);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            ok = false;
            break;
        }
        if (n == 0)
            break;

        size_t sent = 0;
        while (sent < static_cast<size_t>(n)) {
            ssize_t m = send(client, buffer.data() + sent,
                             static_cast<size_t>(n) - sent, MSG_NOSIGNAL);
            if (m < 0) {
                if (errno == EINTR)
                    continue;
                ok = false;
                break;
            }
            if (m == 0) {
                ok = false;
                break;
            }
            sent += static_cast<size_t>(m);
        }
        if (!ok)
            break;
    }

    close(backend);
    return ok;
}

int create_listener(const Options &options)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(options.listen_port));
    if (inet_pton(AF_INET, options.listen_host.c_str(), &addr.sin_addr) != 1) {
        close(fd);
        errno = EINVAL;
        return -1;
    }

    if (bind(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0 ||
        listen(fd, 1024) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

void print_stats(const Options &options, const CacheStats &stats)
{
    std::cout << "grpc_fast_cache listen=" << options.listen_host << ":"
              << options.listen_port
              << " backend=" << options.backend_host << ":"
              << options.backend_port
              << " default_method=" << options.method
              << " accepted=" << stats.accepted
              << " policy_miss=" << stats.policy_miss
              << " parse_error=" << stats.parse_error
              << " cache_hit=" << stats.cache_hit
              << " serving_cache_hit=" << stats.serving_cache_hit
              << " not_serving_cache_hit=" << stats.not_serving_cache_hit
              << " response_cache_miss=" << stats.response_cache_miss
              << " fallback=" << stats.fallback
              << " fallback_error=" << stats.fallback_error
              << " tx_error=" << stats.tx_error << "\n";
}

void print_request_decision(const Options &options, const RequestInfo &request,
                            const char *decision)
{
    if (!options.verbose)
        return;

    std::cout << "grpc_fast_cache_event"
              << " listen=" << options.listen_host << ":"
              << options.listen_port
              << " method=" << request.method
              << " payload_hash=" << request.payload_hash
              << " stream_id=" << request.stream_id
              << " decision=" << decision << "\n";
}

uint64_t monotonic_now_ns()
{
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count());
}

bool userspace_policy_allows_method(const ResponseCache &cache,
                                    const std::string &method)
{
    uint64_t method_hash = hash_grpc_method(method);
    for (const auto &entry : cache) {
        if (entry.first.method_hash == method_hash)
            return true;
    }
    return false;
}

bool response_cache_entry_from_value(const grpc_response_cache_value &value,
                                     CacheEntry *entry)
{
    if (value.status == GRPC_RESPONSE_SERVING)
        entry->status = HealthStatus::Serving;
    else if (value.status == GRPC_RESPONSE_NOT_SERVING)
        entry->status = HealthStatus::NotServing;
    else
        return false;
    return true;
}

bool lookup_response_cache(const ResponseCache &cache, int response_map_fd,
                           const RequestInfo &request, CacheEntry *entry)
{
    if (response_map_fd >= 0) {
        grpc_response_cache_key key = {};
        key.method_hash = hash_grpc_method(request.method);
        key.payload_hash = request.payload_hash;
        grpc_response_cache_value value = {};
        if (bpf_map_lookup_elem(response_map_fd, &key, &value) != 0)
            return false;
        if (value.expires_ns && monotonic_now_ns() >= value.expires_ns) {
            bpf_map_delete_elem(response_map_fd, &key);
            return false;
        }
        return response_cache_entry_from_value(value, entry);
    }

    GrpcCacheKey key = {};
    key.method_hash = hash_grpc_method(request.method);
    key.payload_hash = request.payload_hash;
    auto it = cache.find(key);
    if (it == cache.end())
        return false;
    *entry = it->second;
    return true;
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) {
        print_usage(argv[0]);
        return 1;
    }

    int map_fd = -1;
    if (!options.grpc_map_path.empty()) {
        map_fd = bpf_obj_get(options.grpc_map_path.c_str());
        if (map_fd < 0) {
            std::cerr << "Failed to open grpc policy map " << options.grpc_map_path
                      << ": " << strerror(errno) << "\n";
            return 1;
        }
    }

    int response_map_fd = -1;
    if (!options.grpc_response_map_path.empty()) {
        response_map_fd = bpf_obj_get(options.grpc_response_map_path.c_str());
        if (response_map_fd < 0) {
            std::cerr << "Failed to open grpc response map "
                      << options.grpc_response_map_path << ": "
                      << strerror(errno) << "\n";
            if (map_fd >= 0)
                close(map_fd);
            return 1;
        }
    }

    int listener = create_listener(options);
    if (listener < 0) {
        std::cerr << "Failed to listen on " << options.listen_host << ":"
                  << options.listen_port << ": " << strerror(errno) << "\n";
        if (response_map_fd >= 0)
            close(response_map_fd);
        if (map_fd >= 0)
            if (map_fd >= 0)
                close(map_fd);
        return 1;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    ResponseCache response_cache;
    if (!options.cache_file.empty() &&
        !load_response_cache_file(options.cache_file, &response_cache)) {
        if (response_map_fd >= 0)
            close(response_map_fd);
        close(listener);
        if (map_fd >= 0)
            close(map_fd);
        return 1;
    }
    for (const std::string &entry : options.cache_entries) {
        if (!parse_cache_entry_arg(entry, &response_cache)) {
            std::cerr << "Invalid --cache-entry: " << entry << "\n";
            if (response_map_fd >= 0)
                close(response_map_fd);
            close(listener);
            close(map_fd);
            return 1;
        }
    }

    CacheStats stats = {};
    std::cout << "Listening for h2c gRPC cache/proxy on "
              << options.listen_host << ":" << options.listen_port
              << " backend " << options.backend_host << ":"
              << options.backend_port
              << " method " << options.method << "\n";

    while (!exiting) {
        sockaddr_in peer = {};
        socklen_t peer_len = sizeof(peer);
        int client = accept(listener, reinterpret_cast<sockaddr *>(&peer), &peer_len);
        if (client < 0) {
            if (errno == EINTR)
                continue;
            std::cerr << "accept failed: " << strerror(errno) << "\n";
            break;
        }

        stats.accepted++;
        RequestInfo request;
        std::vector<uint8_t> raw_request;
        bool parsed = read_request_stream(client, &request, &raw_request);
        if (request.method.empty())
            request.method = options.method;

        bool allowed = false;
        if (parsed) {
            allowed = map_fd >= 0
                          ? policy_allows_method(map_fd, request.method)
                          : userspace_policy_allows_method(response_cache,
                                                           request.method);
        }
        if (!parsed) {
            stats.parse_error++;
            if (!raw_request.empty() && fallback_to_backend(client, options, raw_request)) {
                stats.fallback++;
                print_request_decision(options, request, "parse_fallback");
            } else {
                stats.fallback_error++;
                print_request_decision(options, request, "parse_fallback_error");
            }
        } else if (!allowed) {
            stats.policy_miss++;
            if (fallback_to_backend(client, options, raw_request)) {
                stats.fallback++;
                print_request_decision(options, request, "fallback");
            } else {
                stats.fallback_error++;
                print_request_decision(options, request, "fallback_error");
            }
        } else {
            CacheEntry cache_entry = {};
            if (!lookup_response_cache(response_cache, response_map_fd,
                                       request, &cache_entry)) {
                stats.response_cache_miss++;
                if (fallback_to_backend(client, options, raw_request)) {
                    stats.fallback++;
                    print_request_decision(options, request, "response_cache_miss");
                } else {
                    stats.fallback_error++;
                    print_request_decision(options, request,
                                           "response_cache_miss_error");
                }
                close(client);
                if (options.verbose || stats.accepted % 1000 == 0)
                    print_stats(options, stats);
                continue;
            }

            std::vector<uint8_t> response =
                build_grpc_health_response(request.stream_id, cache_entry.status);
            if (send_server_settings(client) && send_all(client, response)) {
                stats.cache_hit++;
                if (cache_entry.status == HealthStatus::Serving)
                    stats.serving_cache_hit++;
                else
                    stats.not_serving_cache_hit++;
                print_request_decision(options, request, "cache_hit");
            } else {
                stats.tx_error++;
                print_request_decision(options, request, "tx_error");
            }
        }

        close(client);
        if (options.verbose || stats.accepted % 1000 == 0)
            print_stats(options, stats);
    }

    print_stats(options, stats);
    close(listener);
    if (response_map_fd >= 0)
        close(response_map_fd);
    if (map_fd >= 0)
        close(map_fd);
    return 0;
}
