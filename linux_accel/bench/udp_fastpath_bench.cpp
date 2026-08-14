#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <numeric>
#include <string>
#include <thread>
#include <vector>

namespace {

volatile sig_atomic_t exiting = 0;

struct Endpoint {
    std::string host;
    uint16_t port = 0;
};

struct Options {
    bool server = false;
    bool client = false;
    Endpoint endpoint;
    unsigned threads = 4;
    unsigned requests = 10000;
    unsigned warmup = 100;
};

void handle_signal(int)
{
    exiting = 1;
}

bool parse_endpoint(const std::string &text, Endpoint *endpoint)
{
    size_t colon = text.rfind(':');
    if (colon == std::string::npos || colon == 0 || colon + 1 >= text.size())
        return false;
    char *end = nullptr;
    errno = 0;
    long port = std::strtol(text.c_str() + colon + 1, &end, 10);
    if (errno || !end || *end != '\0' || port <= 0 || port > 65535)
        return false;
    endpoint->host = text.substr(0, colon);
    in_addr address = {};
    if (inet_pton(AF_INET, endpoint->host.c_str(), &address) != 1)
        return false;
    endpoint->port = static_cast<uint16_t>(port);
    return true;
}

bool parse_unsigned(const char *text, unsigned *value, bool allow_zero)
{
    char *end = nullptr;
    errno = 0;
    unsigned long parsed = std::strtoul(text, &end, 10);
    if (errno || !end || *end != '\0' || (!allow_zero && parsed == 0) ||
        parsed > UINT32_MAX)
        return false;
    *value = static_cast<unsigned>(parsed);
    return true;
}

bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--server" && i + 1 < argc) {
            options->server = parse_endpoint(argv[++i], &options->endpoint);
            if (!options->server)
                return false;
        } else if (arg == "--client" && i + 1 < argc) {
            options->client = parse_endpoint(argv[++i], &options->endpoint);
            if (!options->client)
                return false;
        } else if (arg == "--threads" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->threads, false) ||
                options->threads > 256)
                return false;
        } else if (arg == "--requests" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->requests, false))
                return false;
        } else if (arg == "--warmup" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->warmup, true))
                return false;
        } else {
            return false;
        }
    }
    return options->server != options->client && options->endpoint.port != 0;
}

bool fill_address(const Endpoint &endpoint, sockaddr_in *address)
{
    *address = {};
    address->sin_family = AF_INET;
    address->sin_port = htons(endpoint.port);
    return inet_pton(AF_INET, endpoint.host.c_str(), &address->sin_addr) == 1;
}

int run_server(const Options &options)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return 1;
    sockaddr_in address = {};
    if (!fill_address(options.endpoint, &address) ||
        bind(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0) {
        std::cerr << "UDP server bind failed: " << strerror(errno) << "\n";
        close(fd);
        return 1;
    }
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    uint64_t requests = 0;
    const uint8_t expected[] = {'p', 'i', 'n', 'g'};
    const uint8_t response[] = {'p', 'o', 'n', 'g', '-', 'o', 'k'};
    std::cout << "udp_bench_server listen=" << options.endpoint.host << ':'
              << options.endpoint.port << "\n";
    while (!exiting) {
        pollfd descriptor = {fd, POLLIN, 0};
        int ready = poll(&descriptor, 1, 250);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (ready == 0 || !(descriptor.revents & POLLIN))
            continue;
        uint8_t buffer[2048];
        sockaddr_in peer = {};
        socklen_t peer_length = sizeof(peer);
        ssize_t count = recvfrom(fd, buffer, sizeof(buffer), 0,
                                 reinterpret_cast<sockaddr *>(&peer),
                                 &peer_length);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        requests++;
        if (count == static_cast<ssize_t>(sizeof(expected)) &&
            memcmp(buffer, expected, sizeof(expected)) == 0) {
            sendto(fd, response, sizeof(response), MSG_NOSIGNAL,
                   reinterpret_cast<sockaddr *>(&peer), peer_length);
        }
    }
    std::cout << "udp_bench_server requests=" << requests << "\n";
    close(fd);
    return 0;
}

uint64_t monotonic_ns()
{
    timespec ts = {};
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000000ull + ts.tv_nsec;
}

struct ClientResult {
    std::vector<uint64_t> latencies_ns;
    uint64_t failed = 0;
};

int connect_socket(const Endpoint &endpoint)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return -1;
    sockaddr_in address = {};
    if (!fill_address(endpoint, &address) ||
        connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) !=
            0) {
        close(fd);
        return -1;
    }
    timeval timeout = {1, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    return fd;
}

bool exchange(int fd)
{
    const uint8_t request[] = {'p', 'i', 'n', 'g'};
    const uint8_t expected[] = {'p', 'o', 'n', 'g', '-', 'o', 'k'};
    uint8_t response[64];
    if (send(fd, request, sizeof(request), MSG_NOSIGNAL) !=
        static_cast<ssize_t>(sizeof(request)))
        return false;
    ssize_t count = recv(fd, response, sizeof(response), 0);
    return count == static_cast<ssize_t>(sizeof(expected)) &&
           memcmp(response, expected, sizeof(expected)) == 0;
}

void client_worker(const Options &options, std::atomic<unsigned> *ready,
                   std::atomic<bool> *go, ClientResult *result)
{
    int fd = connect_socket(options.endpoint);
    if (fd < 0) {
        result->failed = options.requests;
        (*ready)++;
        return;
    }
    for (unsigned i = 0; i < options.warmup; ++i) {
        if (!exchange(fd)) {
            result->failed = options.requests;
            close(fd);
            (*ready)++;
            return;
        }
    }
    (*ready)++;
    while (!go->load(std::memory_order_acquire))
        std::this_thread::yield();
    result->latencies_ns.reserve(options.requests);
    for (unsigned i = 0; i < options.requests; ++i) {
        uint64_t start = monotonic_ns();
        if (!exchange(fd)) {
            result->failed++;
            continue;
        }
        result->latencies_ns.push_back(monotonic_ns() - start);
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
    std::vector<ClientResult> results(options.threads);
    std::vector<std::thread> workers;
    std::atomic<unsigned> ready{0};
    std::atomic<bool> go{false};
    for (unsigned i = 0; i < options.threads; ++i) {
        workers.emplace_back(client_worker, std::cref(options), &ready, &go,
                             &results[i]);
    }
    while (ready.load() < options.threads)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    uint64_t start = monotonic_ns();
    go.store(true, std::memory_order_release);
    for (std::thread &worker : workers)
        worker.join();
    uint64_t elapsed_ns = monotonic_ns() - start;

    std::vector<uint64_t> latencies;
    uint64_t failed = 0;
    for (ClientResult &result : results) {
        failed += result.failed;
        latencies.insert(latencies.end(), result.latencies_ns.begin(),
                         result.latencies_ns.end());
    }
    std::sort(latencies.begin(), latencies.end());
    long double total = std::accumulate(
        latencies.begin(), latencies.end(), static_cast<long double>(0));
    double average_us = latencies.empty()
                            ? 0.0
                            : static_cast<double>(total / latencies.size() /
                                                  1000.0L);
    double qps = elapsed_ns
                     ? static_cast<double>(latencies.size()) * 1000000000.0 /
                           static_cast<double>(elapsed_ns)
                     : 0.0;
    std::cout << "udp_bench_client threads=" << options.threads
              << " completed=" << latencies.size() << " failed=" << failed
              << " qps=" << qps << " avg_us=" << average_us
              << " p50_us=" << percentile_us(latencies, 0.50)
              << " p95_us=" << percentile_us(latencies, 0.95)
              << " p99_us=" << percentile_us(latencies, 0.99) << "\n";
    return failed ? 1 : 0;
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) {
        std::cerr << "Usage: " << argv[0]
                  << " --server IPv4:port | --client IPv4:port"
                  << " [--threads N] [--requests N] [--warmup N]\n";
        return 2;
    }
    return options.server ? run_server(options) : run_client(options);
}
