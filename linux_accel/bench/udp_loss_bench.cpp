#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
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

struct Options {
    bool server = false;
    bool client = false;
    Endpoint endpoint;
    uint64_t rate = 10000;
    unsigned duration_sec = 3;
    unsigned threads = 4;
    unsigned batch = 32;
    unsigned timeout_us = 50000;
};

struct ThreadStats {
    uint64_t offered = 0;
    uint64_t sent = 0;
    uint64_t received = 0;
    uint64_t send_errors = 0;
    uint64_t unexpected = 0;
    uint64_t invalid = 0;
};

struct RunState {
    Options options;
    std::atomic<bool> go{false};
    uint64_t start_ns = 0;
    uint64_t end_ns = 0;
};

void handle_signal(int)
{
    stopping = 1;
}

uint64_t monotonic_ns()
{
    timespec ts = {};
    clock_gettime(CLOCK_MONOTONIC, &ts);
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

bool parse_u64(const char *text, uint64_t *value, uint64_t max)
{
    char *end = nullptr;
    errno = 0;
    unsigned long long parsed = std::strtoull(text, &end, 10);
    if (errno || !end || *end != '\0' || parsed == 0 || parsed > max)
        return false;
    *value = static_cast<uint64_t>(parsed);
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
            if (!parse_endpoint(argv[++i], &options->endpoint))
                return false;
            options->server = arg == "--server";
            options->client = arg == "--client";
        } else if (arg == "--rate" && i + 1 < argc) {
            if (!parse_u64(argv[++i], &options->rate, 100000000))
                return false;
        } else if (arg == "--duration" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->duration_sec, 60))
                return false;
        } else if (arg == "--threads" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->threads, 64))
                return false;
        } else if (arg == "--batch" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->batch, 128))
                return false;
        } else if (arg == "--timeout-us" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->timeout_us, 1000000))
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

int open_socket(const Endpoint &endpoint)
{
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -1;
    int buffer = 4 * 1024 * 1024;
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, sizeof(buffer));
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, sizeof(buffer));
    sockaddr_in address = {};
    if (!fill_address(endpoint, &address) ||
        connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) !=
            0) {
        close(fd);
        return -1;
    }
    return fd;
}

void drain_responses(int fd, const std::string &response, ThreadStats *stats,
                     unsigned budget_us)
{
    uint8_t buffer[2048];
    uint64_t deadline = monotonic_ns() + static_cast<uint64_t>(budget_us) * 1000;
    while (monotonic_ns() < deadline) {
        ssize_t count = recv(fd, buffer, sizeof(buffer), MSG_DONTWAIT);
        if (count < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
                break;
            break;
        }
        if (static_cast<size_t>(count) != response.size() ||
            memcmp(buffer, response.data(), response.size()) != 0) {
            stats->invalid++;
        } else {
            stats->received++;
        }
    }
}

void run_client_thread(RunState *run, unsigned index, ThreadStats *stats)
{
    const Options &options = run->options;
    Endpoint endpoint = options.endpoint;
    int fd = open_socket(endpoint);
    if (fd < 0) {
        stats->send_errors++;
        return;
    }
    const std::string request = "ping";
    const std::string response = "pong-ok";
    const uint64_t thread_rate = options.rate / options.threads +
                                 (index < options.rate % options.threads ? 1 : 0);
    uint64_t interval_ns = thread_rate
                               ? (static_cast<uint64_t>(options.batch) * 1000000000ull +
                                  thread_rate - 1) /
                                     thread_rate
                               : 1000000ull;

    while (!run->go.load(std::memory_order_acquire))
        std::this_thread::yield();
    uint64_t next_send_ns = run->start_ns;
    while (monotonic_ns() < run->end_ns) {
        timespec deadline = {};
        deadline.tv_sec = static_cast<time_t>(next_send_ns / 1000000000ull);
        deadline.tv_nsec = static_cast<long>(next_send_ns % 1000000000ull);
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &deadline, nullptr);
        uint64_t now = monotonic_ns();
        if (now >= run->end_ns)
            break;

        stats->offered += options.batch;
        for (unsigned i = 0; i < options.batch; ++i) {
            ssize_t sent = send(fd, request.data(), request.size(),
                                MSG_DONTWAIT | MSG_NOSIGNAL);
            if (sent == static_cast<ssize_t>(request.size()))
                stats->sent++;
            else
                stats->send_errors++;
        }
        drain_responses(fd, response, stats, 200);
        next_send_ns += interval_ns;
        now = monotonic_ns();
        if (next_send_ns + interval_ns * 4 < now)
            next_send_ns = now;
    }
    drain_responses(fd, response, stats, options.timeout_us);
    close(fd);
}

int run_server(const Options &options)
{
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    signal(SIGPIPE, SIG_IGN);
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return 1;
    int reuse = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in address = {};
    if (!fill_address(options.endpoint, &address) ||
        bind(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0) {
        std::cerr << "udp loss server bind failed: " << strerror(errno) << "\n";
        close(fd);
        return 1;
    }
    std::cout << "udp_loss_server listen=" << options.endpoint.host << ':'
              << options.endpoint.port << "\n";
    uint64_t requests = 0;
    const std::string request = "ping";
    const std::string response = "pong-ok";
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
        if (static_cast<size_t>(count) == request.size() &&
            memcmp(buffer, request.data(), request.size()) == 0) {
            requests++;
            (void)sendto(fd, response.data(), response.size(), MSG_NOSIGNAL,
                         reinterpret_cast<sockaddr *>(&peer), peer_length);
        }
    }
    std::cout << "udp_loss_server requests=" << requests << "\n";
    close(fd);
    return 0;
}

int run_client(const Options &options)
{
    RunState run;
    run.options = options;
    std::vector<ThreadStats> stats(options.threads);
    std::vector<std::thread> workers;
    for (unsigned i = 0; i < options.threads; ++i)
        workers.emplace_back(run_client_thread, &run, i, &stats[i]);
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    run.start_ns = monotonic_ns() + 100000000ull;
    run.end_ns = run.start_ns + static_cast<uint64_t>(options.duration_sec) *
                 1000000000ull;
    run.go.store(true, std::memory_order_release);
    for (std::thread &worker : workers)
        worker.join();

    uint64_t offered = 0, sent = 0, received = 0, send_errors = 0;
    uint64_t unexpected = 0, invalid = 0;
    for (const ThreadStats &item : stats) {
        offered += item.offered;
        sent += item.sent;
        received += item.received;
        send_errors += item.send_errors;
        unexpected += item.unexpected;
        invalid += item.invalid;
    }
    uint64_t lost = sent >= received ? sent - received : 0;
    double elapsed_sec = static_cast<double>(options.duration_sec);
    double loss_pct = sent ? static_cast<double>(lost) * 100.0 / sent : 0.0;
    double send_error_pct = offered
                                ? static_cast<double>(send_errors) * 100.0 /
                                      offered
                                : 0.0;
    std::cout << "udp_loss_client rate=" << options.rate
              << " duration_sec=" << options.duration_sec
              << " threads=" << options.threads << " batch=" << options.batch
              << " offered=" << offered << " sent=" << sent
              << " received=" << received << " lost=" << lost
              << " send_errors=" << send_errors
              << " unexpected=" << unexpected << " invalid=" << invalid
              << " qps_offered=" << (offered / elapsed_sec)
              << " qps_sent=" << (sent / elapsed_sec)
              << " qps_received=" << (received / elapsed_sec)
              << " loss_pct=" << loss_pct
              << " send_error_pct=" << send_error_pct << "\n";
    return (sent && received == sent && send_errors == 0 && invalid == 0) ? 0
                                                                           : 0;
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) {
        std::cerr << "Usage: " << argv[0]
                  << " --server IPv4:port | --client IPv4:port"
                  << " [--rate QPS] [--duration SEC] [--threads N]"
                  << " [--batch N] [--timeout-us N]\n";
        return 2;
    }
    return options.server ? run_server(options) : run_client(options);
}
