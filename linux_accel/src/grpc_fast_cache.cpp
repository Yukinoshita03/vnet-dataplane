#include "cache_policy.hpp"
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

enum class HealthStatus : uint8_t {
    Serving = 1,
    NotServing = 2,
};

struct GrpcCacheKey {
    uint64_t method_hash = 0;
    uint64_t payload_hash = 0;
};

struct GrpcCacheKeyHash {
    size_t operator()(const GrpcCacheKey &key) const
    {
        return static_cast<size_t>(key.method_hash ^
                                   (key.payload_hash + 0x9e3779b97f4a7c15ull +
                                    (key.method_hash << 6) +
                                    (key.method_hash >> 2)));
    }
};

struct GrpcCacheKeyEqual {
    bool operator()(const GrpcCacheKey &lhs, const GrpcCacheKey &rhs) const
    {
        return lhs.method_hash == rhs.method_hash &&
               lhs.payload_hash == rhs.payload_hash;
    }
};

struct CacheEntry {
    HealthStatus status = HealthStatus::Serving;
};

using ResponseCache =
    std::unordered_map<GrpcCacheKey, CacheEntry, GrpcCacheKeyHash, GrpcCacheKeyEqual>;

struct Options {
    std::string listen_host = "0.0.0.0";
    int listen_port = 50051;
    std::string backend_host;
    int backend_port = 0;
    std::string grpc_map_path;
    std::string cache_file;
    std::string method = "/grpc.health.v1.Health/Check";
    std::vector<std::string> cache_entries;
    bool verbose = false;
};

struct CacheStats {
    uint64_t accepted = 0;
    uint64_t policy_miss = 0;
    uint64_t parse_error = 0;
    uint64_t cache_hit = 0;
    uint64_t serving_cache_hit = 0;
    uint64_t not_serving_cache_hit = 0;
    uint64_t response_cache_miss = 0;
    uint64_t fallback = 0;
    uint64_t fallback_error = 0;
    uint64_t tx_error = 0;
};

struct RequestInfo {
    uint32_t stream_id = 1;
    std::string method;
    uint64_t payload_hash = 1469598103934665603ull;
    bool saw_headers = false;
    bool saw_data = false;
};

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
              << " --grpc-map <pinned-map-path>"
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

    return !options->grpc_map_path.empty() &&
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

bool append_all(std::vector<uint8_t> *out, const std::vector<uint8_t> &data)
{
    out->insert(out->end(), data.begin(), data.end());
    return true;
}

bool read_hpack_string(const std::vector<uint8_t> &block, size_t *offset,
                       std::string *out)
{
    if (*offset >= block.size())
        return false;

    uint8_t first = block[*offset];
    bool huffman = first & 0x80;
    size_t len = first & 0x7f;
    (*offset)++;

    if (huffman || *offset + len > block.size())
        return false;

    out->assign(reinterpret_cast<const char *>(block.data() + *offset), len);
    *offset += len;
    return true;
}

void parse_demo_headers(const std::vector<uint8_t> &block, RequestInfo *info)
{
    size_t offset = 0;
    while (offset < block.size()) {
        uint8_t first = block[offset++];

        if (first & 0x80) {
            continue;
        }

        if ((first & 0xf0) == 0x00) {
            std::string name;
            std::string value;
            if (!read_hpack_string(block, &offset, &name) ||
                !read_hpack_string(block, &offset, &value))
                return;
            if (name == ":path") {
                info->method = value;
                info->saw_headers = true;
            }
            continue;
        }

        return;
    }
}

void update_payload_hash(const std::vector<uint8_t> &payload, RequestInfo *info)
{
    if (payload.size() <= 5)
        return;

    info->payload_hash = fnv1a_update(info->payload_hash,
                                      payload.data() + 5,
                                      payload.size() - 5);
    info->saw_data = true;
}

void append_frame_header(std::vector<uint8_t> *out, uint32_t len, uint8_t type,
                         uint8_t flags, uint32_t stream_id)
{
    out->push_back(static_cast<uint8_t>((len >> 16) & 0xff));
    out->push_back(static_cast<uint8_t>((len >> 8) & 0xff));
    out->push_back(static_cast<uint8_t>(len & 0xff));
    out->push_back(type);
    out->push_back(flags);
    out->push_back(static_cast<uint8_t>((stream_id >> 24) & 0x7f));
    out->push_back(static_cast<uint8_t>((stream_id >> 16) & 0xff));
    out->push_back(static_cast<uint8_t>((stream_id >> 8) & 0xff));
    out->push_back(static_cast<uint8_t>(stream_id & 0xff));
}

void append_hpack_string(std::vector<uint8_t> *out, const std::string &value)
{
    out->push_back(static_cast<uint8_t>(value.size()));
    out->insert(out->end(), value.begin(), value.end());
}

void append_literal_header(std::vector<uint8_t> *out, const std::string &name,
                           const std::string &value)
{
    out->push_back(0x00);
    append_hpack_string(out, name);
    append_hpack_string(out, value);
}

std::vector<uint8_t> build_headers_block(bool trailers)
{
    std::vector<uint8_t> block;
    if (!trailers) {
        block.push_back(0x88); // HPACK static table index 8: :status 200.
        append_literal_header(&block, "content-type", "application/grpc");
    } else {
        append_literal_header(&block, "grpc-status", "0");
    }
    return block;
}

std::vector<uint8_t> build_grpc_health_response(uint32_t stream_id,
                                                HealthStatus status)
{
    std::vector<uint8_t> response;
    std::vector<uint8_t> headers = build_headers_block(false);
    append_frame_header(&response, headers.size(), 0x1, 0x4, stream_id);
    append_all(&response, headers);

    std::vector<uint8_t> grpc_data = {
        0x00, 0x00, 0x00, 0x00, 0x02,
        0x08,
        static_cast<uint8_t>(status)
    };
    append_frame_header(&response, grpc_data.size(), 0x0, 0x0, stream_id);
    append_all(&response, grpc_data);

    std::vector<uint8_t> trailers = build_headers_block(true);
    append_frame_header(&response, trailers.size(), 0x1, 0x5, stream_id);
    append_all(&response, trailers);
    return response;
}

bool send_all(int fd, const std::vector<uint8_t> &data)
{
    size_t sent = 0;
    while (sent < data.size()) {
        ssize_t n = send(fd, data.data() + sent, data.size() - sent, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return false;
        }
        if (n == 0)
            return false;
        sent += static_cast<size_t>(n);
    }
    return true;
}

bool send_server_settings(int fd)
{
    std::vector<uint8_t> settings;
    append_frame_header(&settings, 0, 0x4, 0x0, 0);
    append_frame_header(&settings, 0, 0x4, 0x1, 0);
    return send_all(fd, settings);
}

bool read_exact(int fd, uint8_t *buf, size_t len, std::vector<uint8_t> *copy)
{
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, buf + got, len - got, 0);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return false;
        }
        if (n == 0)
            return false;
        size_t read_len = static_cast<size_t>(n);
        if (copy)
            copy->insert(copy->end(), buf + got, buf + got + read_len);
        got += read_len;
    }
    return true;
}

bool read_request_stream(int fd, RequestInfo *info, std::vector<uint8_t> *raw_request)
{
    const char expected_preface[] = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    uint8_t preface[24] = {};
    if (!read_exact(fd, preface, sizeof(preface), raw_request))
        return false;
    if (memcmp(preface, expected_preface, sizeof(preface)) != 0)
        return false;

    bool saw_stream = false;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (std::chrono::steady_clock::now() < deadline) {
        uint8_t hdr[9] = {};
        if (!read_exact(fd, hdr, sizeof(hdr), raw_request))
            return false;

        uint32_t len = (static_cast<uint32_t>(hdr[0]) << 16) |
                       (static_cast<uint32_t>(hdr[1]) << 8) |
                       static_cast<uint32_t>(hdr[2]);
        uint8_t type = hdr[3];
        uint8_t flags = hdr[4];
        uint32_t sid = ((static_cast<uint32_t>(hdr[5]) & 0x7f) << 24) |
                       (static_cast<uint32_t>(hdr[6]) << 16) |
                       (static_cast<uint32_t>(hdr[7]) << 8) |
                       static_cast<uint32_t>(hdr[8]);

        std::vector<uint8_t> payload(len);
        if (len > 0 && !read_exact(fd, payload.data(), payload.size(), raw_request))
            return false;

        if (type == 0x1 && sid != 0) {
            info->stream_id = sid;
            saw_stream = true;
            parse_demo_headers(payload, info);
        } else if (type == 0x0 && sid == info->stream_id) {
            update_payload_hash(payload, info);
        }
        if (saw_stream && sid == info->stream_id && (flags & 0x1))
            return true;
    }
    return saw_stream;
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

const CacheEntry *lookup_response_cache(const ResponseCache &cache,
                                        const RequestInfo &request)
{
    GrpcCacheKey key = {};
    key.method_hash = hash_grpc_method(request.method);
    key.payload_hash = request.payload_hash;
    auto it = cache.find(key);
    if (it == cache.end())
        return nullptr;
    return &it->second;
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) {
        print_usage(argv[0]);
        return 1;
    }

    int map_fd = bpf_obj_get(options.grpc_map_path.c_str());
    if (map_fd < 0) {
        std::cerr << "Failed to open grpc policy map " << options.grpc_map_path
                  << ": " << strerror(errno) << "\n";
        return 1;
    }

    int listener = create_listener(options);
    if (listener < 0) {
        std::cerr << "Failed to listen on " << options.listen_host << ":"
                  << options.listen_port << ": " << strerror(errno) << "\n";
        close(map_fd);
        return 1;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    ResponseCache response_cache;
    if (!options.cache_file.empty() &&
        !load_response_cache_file(options.cache_file, &response_cache)) {
        close(listener);
        close(map_fd);
        return 1;
    }
    for (const std::string &entry : options.cache_entries) {
        if (!parse_cache_entry_arg(entry, &response_cache)) {
            std::cerr << "Invalid --cache-entry: " << entry << "\n";
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

        bool allowed = parsed && policy_allows_method(map_fd, request.method);
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
            const CacheEntry *cache_entry =
                lookup_response_cache(response_cache, request);
            if (!cache_entry) {
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
                build_grpc_health_response(request.stream_id, cache_entry->status);
            if (send_server_settings(client) && send_all(client, response)) {
                stats.cache_hit++;
                if (cache_entry->status == HealthStatus::Serving)
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
    close(map_fd);
    return 0;
}
