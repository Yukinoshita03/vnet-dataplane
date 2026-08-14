#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {

volatile sig_atomic_t stopping = 0;

struct Endpoint {
    std::string host;
    uint16_t port = 0;
};

enum class Mode { Rr, Crr };

struct Options {
    bool server = false;
    bool client = false;
    Endpoint endpoint;
    Mode mode = Mode::Rr;
    unsigned threads = 8;
    unsigned requests = 1000;
    unsigned warmup = 100;
    unsigned request_bytes = 64;
    unsigned response_bytes = 64;
    unsigned timeout_ms = 5000;
};

struct ClientResult {
    std::vector<uint64_t> latencies_ns;
    uint64_t failed = 0;
    uint64_t connect_failed = 0;
};

void handle_signal(int)
{
    stopping = 1;
}

uint64_t monotonic_ns()
{
    timespec ts = {};
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000000ull + ts.tv_nsec;
}

bool parse_unsigned(const char *text, unsigned *value, unsigned max,
                    bool allow_zero = false)
{
    char *end = nullptr;
    errno = 0;
    unsigned long parsed = std::strtoul(text, &end, 10);
    if (errno || !end || *end != '\0' || (!allow_zero && parsed == 0) ||
        parsed > max) {
        return false;
    }
    *value = static_cast<unsigned>(parsed);
    return true;
}

bool parse_endpoint(const std::string &text, Endpoint *endpoint)
{
    size_t colon = text.rfind(':');
    if (colon == std::string::npos || colon == 0 || colon + 1 >= text.size())
        return false;
    unsigned port = 0;
    if (!parse_unsigned(text.c_str() + colon + 1, &port, 65535))
        return false;
    in_addr address = {};
    endpoint->host = text.substr(0, colon);
    if (inet_pton(AF_INET, endpoint->host.c_str(), &address) != 1)
        return false;
    endpoint->port = static_cast<uint16_t>(port);
    return true;
}

bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if ((arg == "--server" || arg == "--client") && i + 1 < argc) {
            bool parsed = parse_endpoint(argv[++i], &options->endpoint);
            if (!parsed)
                return false;
            options->server = arg == "--server";
            options->client = arg == "--client";
        } else if (arg == "--mode" && i + 1 < argc) {
            std::string mode = argv[++i];
            if (mode == "rr")
                options->mode = Mode::Rr;
            else if (mode == "crr")
                options->mode = Mode::Crr;
            else
                return false;
        } else if (arg == "--threads" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->threads, 256))
                return false;
        } else if (arg == "--requests" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->requests,
                                100000000))
                return false;
        } else if (arg == "--warmup" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->warmup, 100000000, true))
                return false;
        } else if (arg == "--request-bytes" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->request_bytes, 65536))
                return false;
        } else if (arg == "--response-bytes" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->response_bytes, 65536))
                return false;
        } else if (arg == "--timeout-ms" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->timeout_ms, 60000))
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

void set_socket_timeouts(int fd, unsigned timeout_ms)
{
    timeval timeout = {};
    timeout.tv_sec = static_cast<time_t>(timeout_ms / 1000);
    timeout.tv_usec = static_cast<suseconds_t>((timeout_ms % 1000) * 1000);
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

int connect_socket(const Endpoint &endpoint, unsigned timeout_ms)
{
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -1;
    sockaddr_in address = {};
    if (!fill_address(endpoint, &address)) {
        close(fd);
        return -1;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(fd);
        return -1;
    }
    int result = connect(fd, reinterpret_cast<sockaddr *>(&address),
                         sizeof(address));
    if (result != 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }
    if (result != 0) {
        pollfd descriptor = {fd, POLLOUT, 0};
        int ready = poll(&descriptor, 1, static_cast<int>(timeout_ms));
        if (ready <= 0 || !(descriptor.revents & (POLLOUT | POLLERR | POLLHUP))) {
            close(fd);
            return -1;
        }
        int error = 0;
        socklen_t length = sizeof(error);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) != 0 ||
            error != 0) {
            close(fd);
            return -1;
        }
    }
    if (fcntl(fd, F_SETFL, flags) < 0) {
        close(fd);
        return -1;
    }
    set_socket_timeouts(fd, timeout_ms);
    return fd;
}

bool read_all(int fd, void *buffer, size_t length)
{
    auto *bytes = static_cast<uint8_t *>(buffer);
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = recv(fd, bytes + offset, length - offset, 0);
        if (count <= 0)
            return false;
        offset += static_cast<size_t>(count);
    }
    return true;
}

bool write_all(int fd, const void *buffer, size_t length)
{
    const auto *bytes = static_cast<const uint8_t *>(buffer);
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = send(fd, bytes + offset, length - offset,
                             MSG_NOSIGNAL);
        if (count <= 0)
            return false;
        offset += static_cast<size_t>(count);
    }
    return true;
}

bool exchange(int fd, unsigned request_bytes, unsigned response_bytes)
{
    std::vector<uint8_t> request(request_bytes, 0x51);
    std::vector<uint8_t> response(response_bytes);
    uint32_t request_length = htonl(request_bytes);
    if (!write_all(fd, &request_length, sizeof(request_length)) ||
        !write_all(fd, request.data(), request.size())) {
        return false;
    }
    uint32_t response_length = 0;
    if (!read_all(fd, &response_length, sizeof(response_length)) ||
        ntohl(response_length) != response_bytes ||
        !read_all(fd, response.data(), response.size())) {
        return false;
    }
    return true;
}

void serve_connection(int fd, unsigned response_bytes)
{
    set_socket_timeouts(fd, 5000);
    std::vector<uint8_t> request(65536);
    std::vector<uint8_t> response(response_bytes, 0xa5);
    while (!stopping) {
        uint32_t request_length = 0;
        if (!read_all(fd, &request_length, sizeof(request_length)))
            break;
        request_length = ntohl(request_length);
        if (request_length > request.size() ||
            !read_all(fd, request.data(), request_length)) {
            break;
        }
        uint32_t response_length = htonl(response_bytes);
        if (!write_all(fd, &response_length, sizeof(response_length)) ||
            !write_all(fd, response.data(), response.size())) {
            break;
        }
    }
    close(fd);
}

int run_server(const Options &options)
{
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    signal(SIGPIPE, SIG_IGN);
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return 1;
    int reuse = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in address = {};
    if (!fill_address(options.endpoint, &address) ||
        bind(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0 ||
        listen(fd, 4096) != 0) {
        std::cerr << "tcp benchmark server setup failed: " << strerror(errno)
                  << "\n";
        close(fd);
        return 1;
    }
    std::cout << "tcp_bench_server listen=" << options.endpoint.host << ':'
              << options.endpoint.port << " mode="
              << (options.mode == Mode::Rr ? "rr" : "crr")
              << " response_bytes=" << options.response_bytes << "\n";
    while (!stopping) {
        pollfd descriptor = {fd, POLLIN, 0};
        int ready = poll(&descriptor, 1, 250);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (ready == 0 || !(descriptor.revents & POLLIN))
            continue;
        int client = accept4(fd, nullptr, nullptr, SOCK_CLOEXEC);
        if (client < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        try {
            std::thread(serve_connection, client, options.response_bytes).detach();
        } catch (...) {
            close(client);
            break;
        }
    }
    close(fd);
    return 0;
}

void client_worker(const Options &options, std::atomic<unsigned> *ready,
                   std::atomic<bool> *go, ClientResult *result)
{
    int fd = -1;
    auto do_exchange = [&]() {
        if (options.mode == Mode::Crr) {
            int connection = connect_socket(options.endpoint, options.timeout_ms);
            if (connection < 0) {
                result->connect_failed++;
                return false;
            }
            bool ok = exchange(connection, options.request_bytes,
                               options.response_bytes);
            close(connection);
            return ok;
        }
        return fd >= 0 && exchange(fd, options.request_bytes,
                                   options.response_bytes);
    };

    if (options.mode == Mode::Rr) {
        fd = connect_socket(options.endpoint, options.timeout_ms);
        if (fd < 0) {
            result->connect_failed++;
            result->failed = options.requests;
            ready->fetch_add(1, std::memory_order_release);
            return;
        }
    }
    for (unsigned i = 0; i < options.warmup; ++i) {
        if (!do_exchange()) {
            result->failed++;
            if (options.mode == Mode::Rr)
                break;
        }
    }
    ready->fetch_add(1, std::memory_order_release);
    while (!go->load(std::memory_order_acquire))
        std::this_thread::yield();

    result->latencies_ns.reserve(options.requests);
    for (unsigned i = 0; i < options.requests; ++i) {
        uint64_t start = monotonic_ns();
        bool ok = do_exchange();
        uint64_t elapsed = monotonic_ns() - start;
        if (!ok) {
            result->failed++;
            if (options.mode == Mode::Rr)
                break;
            continue;
        }
        result->latencies_ns.push_back(elapsed);
    }
    if (fd >= 0)
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
    while (ready.load(std::memory_order_acquire) < options.threads)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    uint64_t start = monotonic_ns();
    go.store(true, std::memory_order_release);
    for (std::thread &worker : workers)
        worker.join();
    uint64_t elapsed = monotonic_ns() - start;

    std::vector<uint64_t> latencies;
    uint64_t failed = 0;
    uint64_t connect_failed = 0;
    for (ClientResult &result : results) {
        failed += result.failed;
        connect_failed += result.connect_failed;
        latencies.insert(latencies.end(), result.latencies_ns.begin(),
                         result.latencies_ns.end());
    }
    std::sort(latencies.begin(), latencies.end());
    long double sum = 0;
    for (uint64_t latency : latencies)
        sum += latency;
    double average_us = latencies.empty()
                            ? 0.0
                            : static_cast<double>(sum / latencies.size() /
                                                  1000.0L);
    double qps = elapsed
                     ? static_cast<double>(latencies.size()) * 1e9 /
                           static_cast<double>(elapsed)
                     : 0.0;
    std::cout << "tcp_bench_client mode="
              << (options.mode == Mode::Rr ? "rr" : "crr")
              << " threads=" << options.threads
              << " requests=" << options.requests
              << " warmup=" << options.warmup
              << " request_bytes=" << options.request_bytes
              << " response_bytes=" << options.response_bytes
              << " completed=" << latencies.size() << " failed=" << failed
              << " connect_failed=" << connect_failed << " qps=" << qps
              << " avg_us=" << average_us
              << " p50_us=" << percentile_us(latencies, 0.50)
              << " p95_us=" << percentile_us(latencies, 0.95)
              << " p99_us=" << percentile_us(latencies, 0.99) << "\n";
    return failed || connect_failed ? 1 : 0;
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) {
        std::cerr << "Usage: " << argv[0]
                  << " --server IPv4:port | --client IPv4:port"
                  << " --mode rr|crr [--threads N] [--requests N]"
                  << " [--warmup N] [--request-bytes N]"
                  << " [--response-bytes N] [--timeout-ms N]\n";
        return 2;
    }
    return options.server ? run_server(options) : run_client(options);
}
