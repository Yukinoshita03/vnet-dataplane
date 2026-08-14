#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <numeric>
#include <random>
#include <string>
#include <thread>
#include <vector>

namespace {

struct Endpoint {
    std::string host;
    uint16_t port = 0;
};

struct Options {
    Endpoint endpoint;
    unsigned threads = 8;
    unsigned requests = 20000;
    unsigned warmup = 100;
    unsigned population = 4096;
    unsigned hot_keys = 1024;
    unsigned cache_entries = 0;
    double zipf = 0.99;
    std::string distribution = "zipf";
    unsigned timeout_ms = 1000;
    uint64_t seed = 202108;
    bool emit_policy = false;
    bool populate = false;
    bool warm_all = false;
    bool stats = false;
    bool update_one = false;
    bool expect_miss = false;
    unsigned update_key = 0;
    unsigned key_offset = 0;
    std::string ifname;
    unsigned lease_seconds = 300;
};

struct __attribute__((packed)) MemcachedUdpHeader {
    uint16_t request_id;
    uint16_t sequence;
    uint16_t datagrams;
    uint16_t reserved;
};

struct WorkerResult {
    std::vector<uint64_t> latency_ns;
    uint64_t failures = 0;
    uint64_t send_errors = 0;
    uint64_t recv_timeouts = 0;
    uint64_t recv_errors = 0;
    uint64_t length_mismatches = 0;
    uint64_t content_mismatches = 0;
    uint64_t hot_requests = 0;
    std::string first_failure = "none";
    int first_errno = 0;
    ssize_t first_received = -1;
    std::string first_response_hex = "-";
};

enum class ExchangeStatus {
    ok,
    send_error,
    recv_timeout,
    recv_error,
    length_mismatch,
    content_mismatch,
};

struct ExchangeOutcome {
    ExchangeStatus status = ExchangeStatus::ok;
    int error_number = 0;
    ssize_t received = -1;
    std::string response_hex;
};

bool parse_endpoint(const std::string &text, Endpoint *endpoint)
{
    size_t colon = text.rfind(':');
    if (colon == std::string::npos || colon == 0 || colon + 1 >= text.size())
        return false;
    char *end = nullptr;
    errno = 0;
    unsigned long port = std::strtoul(text.c_str() + colon + 1, &end, 10);
    if (errno || !end || *end || port == 0 || port > 65535)
        return false;
    endpoint->host = text.substr(0, colon);
    in_addr address = {};
    if (inet_pton(AF_INET, endpoint->host.c_str(), &address) != 1)
        return false;
    endpoint->port = static_cast<uint16_t>(port);
    return true;
}

bool parse_unsigned(const char *text, unsigned *value, bool allow_zero = false)
{
    char *end = nullptr;
    errno = 0;
    unsigned long parsed = std::strtoul(text, &end, 10);
    if (errno || !end || *end || (!allow_zero && parsed == 0) ||
        parsed > UINT32_MAX)
        return false;
    *value = static_cast<unsigned>(parsed);
    return true;
}

bool parse_double(const char *text, double *value)
{
    char *end = nullptr;
    errno = 0;
    double parsed = std::strtod(text, &end);
    if (errno || !end || *end || parsed < 0.0 || parsed > 5.0)
        return false;
    *value = parsed;
    return true;
}

bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; ++i) {
        std::string argument = argv[i];
        if (argument == "--server" && i + 1 < argc) {
            if (!parse_endpoint(argv[++i], &options->endpoint))
                return false;
        } else if (argument == "--threads" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->threads) ||
                options->threads > 256)
                return false;
        } else if (argument == "--requests" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->requests))
                return false;
        } else if (argument == "--warmup" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->warmup, true))
                return false;
        } else if (argument == "--population" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->population))
                return false;
        } else if (argument == "--hot-keys" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->hot_keys, true))
                return false;
        } else if (argument == "--cache-entries" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->cache_entries))
                return false;
        } else if (argument == "--key-offset" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->key_offset, true))
                return false;
        } else if (argument == "--zipf" && i + 1 < argc) {
            if (!parse_double(argv[++i], &options->zipf))
                return false;
        } else if (argument == "--distribution" && i + 1 < argc) {
            options->distribution = argv[++i];
        } else if (argument == "--timeout-ms" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->timeout_ms))
                return false;
        } else if (argument == "--seed" && i + 1 < argc) {
            unsigned value = 0;
            if (!parse_unsigned(argv[++i], &value, true))
                return false;
            options->seed = value;
        } else if (argument == "--emit-policy" && i + 1 < argc) {
            options->emit_policy = true;
            options->ifname = argv[++i];
        } else if (argument == "--populate") {
            options->populate = true;
        } else if (argument == "--warm-all") {
            options->warm_all = true;
        } else if (argument == "--stats") {
            options->stats = true;
        } else if (argument == "--update-key" && i + 1 < argc) {
            options->update_one = true;
            if (!parse_unsigned(argv[++i], &options->update_key, true))
                return false;
        } else if (argument == "--expect-miss") {
            options->expect_miss = true;
        } else if (argument == "--lease-seconds" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->lease_seconds))
                return false;
        } else {
            return false;
        }
    }
    if (options->cache_entries == 0)
        options->cache_entries = options->hot_keys;
    unsigned modes = options->emit_policy + options->populate +
                     options->warm_all + options->stats + options->update_one;
    bool valid_distribution = options->distribution == "zipf" ||
                              options->distribution == "facebook-etc-coarse";
    bool valid_coarse = options->distribution != "facebook-etc-coarse" ||
                        (options->hot_keys > 0 &&
                         options->hot_keys < options->population);
    return modes <= 1 && options->endpoint.port != 0 && options->population > 0 &&
           options->hot_keys <= options->population &&
           options->cache_entries <= options->population &&
           options->key_offset <= UINT32_MAX - options->population &&
           (!options->update_one || options->update_key < options->population) &&
           (!options->emit_policy || !options->ifname.empty()) &&
           valid_distribution && valid_coarse;
}

std::string key_for(unsigned index)
{
    char buffer[17];
    snprintf(buffer, sizeof(buffer), "key%013u", index);
    return std::string(buffer, 16);
}

std::string value_for(unsigned index)
{
    char prefix[17];
    snprintf(prefix, sizeof(prefix), "val%013u", index);
    std::string value(prefix, 16);
    value += value;
    return value;
}

std::string request_for(unsigned index, uint16_t request_id)
{
    MemcachedUdpHeader header = {htons(request_id), 0, htons(1), 0};
    std::string packet(reinterpret_cast<const char *>(&header), sizeof(header));
    packet += "get ";
    packet += key_for(index);
    packet += "\r\n";
    return packet;
}

std::string response_for(unsigned index, uint16_t request_id)
{
    MemcachedUdpHeader header = {htons(request_id), 0, htons(1), 0};
    std::string packet(reinterpret_cast<const char *>(&header), sizeof(header));
    packet += "VALUE ";
    packet += key_for(index);
    packet += " 0 32\r\n";
    packet += value_for(index);
    packet += "\r\nEND\r\n";
    return packet;
}

std::string miss_response_for(uint16_t request_id)
{
    MemcachedUdpHeader header = {htons(request_id), 0, htons(1), 0};
    std::string packet(reinterpret_cast<const char *>(&header), sizeof(header));
    packet += "END\r\n";
    return packet;
}

std::string hex(const std::string &value)
{
    static const char digits[] = "0123456789abcdef";
    std::string output;
    output.reserve(value.size() * 2);
    for (unsigned char byte : value) {
        output.push_back(digits[byte >> 4]);
        output.push_back(digits[byte & 15]);
    }
    return output;
}

int emit_policy(const Options &options)
{
    for (unsigned index = 0; index < options.cache_entries; ++index) {
        std::cout << options.ifname << ' ' << options.endpoint.host << ' '
                  << options.endpoint.port << ' '
                  << hex(request_for(index, 0)) << ' '
                  << hex(response_for(index, 0)) << ' '
                  << options.lease_seconds << '\n';
    }
    return 0;
}

int open_socket(const Options &options)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return -1;
    sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_port = htons(options.endpoint.port);
    if (inet_pton(AF_INET, options.endpoint.host.c_str(), &address.sin_addr) !=
            1 ||
        connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) !=
            0) {
        close(fd);
        return -1;
    }
    timeval timeout = {
        static_cast<time_t>(options.timeout_ms / 1000),
        static_cast<suseconds_t>((options.timeout_ms % 1000) * 1000),
    };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    return fd;
}

int open_tcp_socket(const Options &options)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_port = htons(options.endpoint.port);
    if (inet_pton(AF_INET, options.endpoint.host.c_str(), &address.sin_addr) !=
            1 ||
        connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) !=
            0) {
        close(fd);
        return -1;
    }
    timeval timeout = {
        static_cast<time_t>(options.timeout_ms / 1000),
        static_cast<suseconds_t>((options.timeout_ms % 1000) * 1000),
    };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    return fd;
}

bool write_all(int fd, const std::string &data)
{
    size_t offset = 0;
    while (offset < data.size()) {
        ssize_t count = send(fd, data.data() + offset, data.size() - offset,
                             MSG_NOSIGNAL);
        if (count <= 0)
            return false;
        offset += static_cast<size_t>(count);
    }
    return true;
}

bool read_exact(int fd, const std::string &expected)
{
    std::string received(expected.size(), '\0');
    size_t offset = 0;
    while (offset < received.size()) {
        ssize_t count = recv(fd, &received[offset], received.size() - offset, 0);
        if (count <= 0)
            return false;
        offset += static_cast<size_t>(count);
    }
    return received == expected;
}

int populate(const Options &options)
{
    int fd = open_tcp_socket(options);
    if (fd < 0) {
        std::cerr << "memcached TCP connection failed: " << strerror(errno)
                  << '\n';
        return 1;
    }
    for (unsigned index = 0; index < options.population; ++index) {
        std::string command = "set " + key_for(index) + " 0 0 32\r\n" +
                              value_for(index) + "\r\n";
        if (!write_all(fd, command) || !read_exact(fd, "STORED\r\n")) {
            std::cerr << "memcached SET failed key=" << index << '\n';
            close(fd);
            return 1;
        }
    }
    close(fd);
    std::cout << "memcached_populate keys=" << options.population
              << " key_bytes=16 value_bytes=32\n";
    return 0;
}

int update_one(const Options &options)
{
    int fd = open_tcp_socket(options);
    if (fd < 0)
        return 1;
    std::string command = "set " + key_for(options.update_key) +
                          " 0 0 32\r\n" + value_for(options.update_key) +
                          "\r\n";
    bool success = write_all(fd, command) && read_exact(fd, "STORED\r\n");
    close(fd);
    if (!success)
        return 1;
    std::cout << "memcached_update key=" << options.update_key << '\n';
    return 0;
}

int print_stats(const Options &options)
{
    int fd = open_tcp_socket(options);
    if (fd < 0)
        return 1;
    if (!write_all(fd, "stats\r\n")) {
        close(fd);
        return 1;
    }
    std::string response;
    char buffer[4096];
    while (response.find("END\r\n") == std::string::npos) {
        ssize_t count = recv(fd, buffer, sizeof(buffer), 0);
        if (count <= 0) {
            close(fd);
            return 1;
        }
        response.append(buffer, static_cast<size_t>(count));
        if (response.size() > 1024 * 1024) {
            close(fd);
            return 1;
        }
    }
    close(fd);
    std::cout << response;
    return 0;
}

uint64_t monotonic_ns()
{
    timespec timestamp = {};
    clock_gettime(CLOCK_MONOTONIC_RAW, &timestamp);
    return static_cast<uint64_t>(timestamp.tv_sec) * 1000000000ull +
           timestamp.tv_nsec;
}

const char *exchange_status_name(ExchangeStatus status)
{
    switch (status) {
    case ExchangeStatus::ok:
        return "ok";
    case ExchangeStatus::send_error:
        return "send_error";
    case ExchangeStatus::recv_timeout:
        return "recv_timeout";
    case ExchangeStatus::recv_error:
        return "recv_error";
    case ExchangeStatus::length_mismatch:
        return "length_mismatch";
    case ExchangeStatus::content_mismatch:
        return "content_mismatch";
    }
    return "unknown";
}

ExchangeOutcome exchange_detailed(int fd, unsigned key, uint16_t id,
                                  bool expect_miss = false)
{
    std::string request = request_for(key, id);
    std::string expected = expect_miss ? miss_response_for(id)
                                       : response_for(key, id);
    char response[512];
    ssize_t sent = send(fd, request.data(), request.size(), MSG_NOSIGNAL);
    if (sent != static_cast<ssize_t>(request.size()))
        return {ExchangeStatus::send_error, sent < 0 ? errno : 0, -1, {}};
    ssize_t count = recv(fd, response, sizeof(response), 0);
    if (count < 0) {
        int error_number = errno;
        ExchangeStatus status =
            error_number == EAGAIN || error_number == EWOULDBLOCK ||
                    error_number == ETIMEDOUT
                ? ExchangeStatus::recv_timeout
                : ExchangeStatus::recv_error;
        return {status, error_number, count, {}};
    }
    if (count != static_cast<ssize_t>(expected.size())) {
        std::string received(response, static_cast<size_t>(count));
        return {ExchangeStatus::length_mismatch, 0, count, hex(received)};
    }
    if (memcmp(response, expected.data(), expected.size()) != 0) {
        std::string received(response, static_cast<size_t>(count));
        return {ExchangeStatus::content_mismatch, 0, count, hex(received)};
    }
    return {ExchangeStatus::ok, 0, count, {}};
}

bool exchange(int fd, unsigned key, uint16_t id, bool expect_miss = false)
{
    return exchange_detailed(fd, key, id, expect_miss).status ==
           ExchangeStatus::ok;
}

void record_failure(const ExchangeOutcome &outcome, WorkerResult *result)
{
    ++result->failures;
    switch (outcome.status) {
    case ExchangeStatus::send_error:
        ++result->send_errors;
        break;
    case ExchangeStatus::recv_timeout:
        ++result->recv_timeouts;
        break;
    case ExchangeStatus::recv_error:
        ++result->recv_errors;
        break;
    case ExchangeStatus::length_mismatch:
        ++result->length_mismatches;
        break;
    case ExchangeStatus::content_mismatch:
        ++result->content_mismatches;
        break;
    case ExchangeStatus::ok:
        return;
    }
    if (result->first_failure == "none") {
        result->first_failure = exchange_status_name(outcome.status);
        result->first_errno = outcome.error_number;
        result->first_received = outcome.received;
        result->first_response_hex = outcome.response_hex.empty()
                                         ? "-"
                                         : outcome.response_hex;
    }
}

int warm_all(const Options &options)
{
    int fd = open_socket(options);
    if (fd < 0)
        return 1;
    unsigned completed = 0;
    for (unsigned index = 0; index < options.cache_entries; ++index)
        completed += exchange(fd, index, 0);
    close(fd);
    std::cout << "memcached_warm requested=" << options.cache_entries
              << " completed=" << completed << '\n';
    return completed == options.cache_entries ? 0 : 1;
}

std::vector<double> zipf_weights(unsigned population, double exponent)
{
    std::vector<double> weights(population);
    for (unsigned index = 0; index < population; ++index)
        weights[index] = 1.0 / std::pow(static_cast<double>(index + 1), exponent);
    return weights;
}

void worker(const Options &options, unsigned worker_id,
            const std::vector<double> &weights, std::atomic<unsigned> *ready,
            std::atomic<bool> *go, WorkerResult *result)
{
    int fd = open_socket(options);
    if (fd < 0) {
        result->failures = options.requests;
        ++(*ready);
        return;
    }
    std::mt19937_64 random(options.seed + worker_id * 0x9e3779b9u);
    std::discrete_distribution<unsigned> zipf_distribution(weights.begin(),
                                                            weights.end());
    std::uniform_int_distribution<unsigned> hot_distribution(
        0, options.hot_keys ? options.hot_keys - 1 : 0);
    auto sample_key_rank = [&](unsigned index) {
        if (options.distribution == "zipf")
            return zipf_distribution(random);

        // Facebook's ETC coarse trace split places 99% of requests in one
        // half of the key space and 1% in the other half. Interleaving worker
        // ordinals makes the aggregate ratio exact when total requests are a
        // multiple of 100. Cold ranks are traversed without replacement when
        // total requests equal 100 times the cold-key count; selection inside
        // the hot half is synthetic uniform because the paper does not publish
        // a rank CDF for that half.
        uint64_t ordinal = static_cast<uint64_t>(index) * options.threads +
                           worker_id;
        if (ordinal % 100 != 99)
            return hot_distribution(random);
        unsigned cold_keys = options.population - options.hot_keys;
        return options.hot_keys +
               static_cast<unsigned>((ordinal / 100) % cold_keys);
    };
    for (unsigned index = 0; index < options.warmup; ++index)
        exchange(fd, sample_key_rank(index) + options.key_offset, 0,
                 options.expect_miss);
    ++(*ready);
    while (!go->load(std::memory_order_acquire))
        std::this_thread::yield();
    result->latency_ns.reserve(options.requests);
    for (unsigned index = 0; index < options.requests; ++index) {
        unsigned key_rank = sample_key_rank(index);
        unsigned key = key_rank + options.key_offset;
        result->hot_requests += key_rank < options.hot_keys;
        uint64_t start = monotonic_ns();
        ExchangeOutcome outcome =
            exchange_detailed(fd, key, 0, options.expect_miss);
        if (outcome.status != ExchangeStatus::ok) {
            record_failure(outcome, result);
            continue;
        }
        result->latency_ns.push_back(monotonic_ns() - start);
    }
    close(fd);
}

double percentile_us(const std::vector<uint64_t> &values, double percentile)
{
    if (values.empty())
        return 0.0;
    size_t index = static_cast<size_t>(percentile * (values.size() - 1));
    return static_cast<double>(values[index]) / 1000.0;
}

int run_client(const Options &options)
{
    std::vector<double> weights = zipf_weights(options.population, options.zipf);
    std::vector<WorkerResult> results(options.threads);
    std::vector<std::thread> workers;
    std::atomic<unsigned> ready{0};
    std::atomic<bool> go{false};
    for (unsigned index = 0; index < options.threads; ++index)
        workers.emplace_back(worker, std::cref(options), index,
                             std::cref(weights), &ready, &go, &results[index]);
    while (ready.load() != options.threads)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    uint64_t start = monotonic_ns();
    go.store(true, std::memory_order_release);
    for (std::thread &thread : workers)
        thread.join();
    uint64_t elapsed_ns = monotonic_ns() - start;

    std::vector<uint64_t> latency;
    uint64_t failures = 0;
    uint64_t send_errors = 0;
    uint64_t recv_timeouts = 0;
    uint64_t recv_errors = 0;
    uint64_t length_mismatches = 0;
    uint64_t content_mismatches = 0;
    uint64_t hot_requests = 0;
    std::string first_failure = "none";
    int first_errno = 0;
    ssize_t first_received = -1;
    std::string first_response_hex = "-";
    for (WorkerResult &result : results) {
        failures += result.failures;
        send_errors += result.send_errors;
        recv_timeouts += result.recv_timeouts;
        recv_errors += result.recv_errors;
        length_mismatches += result.length_mismatches;
        content_mismatches += result.content_mismatches;
        hot_requests += result.hot_requests;
        if (first_failure == "none" && result.first_failure != "none") {
            first_failure = result.first_failure;
            first_errno = result.first_errno;
            first_received = result.first_received;
            first_response_hex = result.first_response_hex;
        }
        latency.insert(latency.end(), result.latency_ns.begin(),
                       result.latency_ns.end());
    }
    std::sort(latency.begin(), latency.end());
    long double sum = std::accumulate(latency.begin(), latency.end(),
                                      static_cast<long double>(0));
    uint64_t attempted = static_cast<uint64_t>(options.threads) *
                         options.requests;
    double qps = elapsed_ns ? latency.size() * 1e9 / elapsed_ns : 0.0;
    double average = latency.empty() ? 0.0 : sum / latency.size() / 1000.0;
    std::cout << "memcached_udp_zipf"
              << " threads=" << options.threads
              << " attempted=" << attempted
              << " completed=" << latency.size()
              << " failed=" << failures
              << " send_errors=" << send_errors
              << " recv_timeouts=" << recv_timeouts
              << " recv_errors=" << recv_errors
              << " length_mismatches=" << length_mismatches
              << " content_mismatches=" << content_mismatches
              << " first_failure=" << first_failure
              << " first_errno=" << first_errno
              << " first_received=" << first_received
              << " first_response_hex=" << first_response_hex
              << " qps=" << qps
              << " avg_us=" << average
              << " p50_us=" << percentile_us(latency, 0.50)
              << " p95_us=" << percentile_us(latency, 0.95)
              << " p99_us=" << percentile_us(latency, 0.99)
              << " hot_fraction="
              << (attempted ? static_cast<double>(hot_requests) / attempted : 0)
              << " population=" << options.population
              << " hot_keys=" << options.hot_keys
              << " cache_entries=" << options.cache_entries
              << " key_offset=" << options.key_offset
              << " expect_miss=" << options.expect_miss
              << " distribution=" << options.distribution
              << " zipf=" << options.zipf << '\n';
    return failures ? 1 : 0;
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) {
        std::cerr << "Usage: " << argv[0]
                  << " --server IPv4:port [--threads N] [--requests N]"
                  << " [--warmup N] [--population N] [--hot-keys N]"
                  << " [--cache-entries N] [--key-offset N] [--zipf S]"
                  << " [--distribution zipf|facebook-etc-coarse]"
                  << " [--timeout-ms N] [--seed N]"
                  << " [--expect-miss]"
                  << " [--emit-policy IFNAME | --populate | --warm-all | --stats"
                  << " | --update-key N]"
                  << " [--lease-seconds N]\n";
        return 2;
    }
    if (options.emit_policy)
        return emit_policy(options);
    if (options.populate)
        return populate(options);
    if (options.warm_all)
        return warm_all(options);
    if (options.stats)
        return print_stats(options);
    if (options.update_one)
        return update_one(options);
    return run_client(options);
}
