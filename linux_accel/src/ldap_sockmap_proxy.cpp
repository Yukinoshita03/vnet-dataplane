#include "ldap_sockmap.h"

#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iostream>
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
    Endpoint listen = {"127.0.0.1", 2389};
    Endpoint backend;
    std::string mode = "userspace";
    std::string bpf_object = "build/ldap_sockmap.bpf.o";
    unsigned connect_timeout_ms = 5000;
};

struct ProxyStats {
    std::atomic<uint64_t> accepted{0};
    std::atomic<uint64_t> active{0};
    std::atomic<uint64_t> completed{0};
    std::atomic<uint64_t> connect_error{0};
    std::atomic<uint64_t> relay_error{0};
    std::atomic<uint64_t> userspace_bytes{0};
    std::atomic<uint64_t> splice_bytes{0};
    std::atomic<uint64_t> sockmap_pairs{0};
    std::atomic<uint64_t> sockmap_fallback_bytes{0};
};

void handle_signal(int)
{
    exiting = 1;
}

void print_usage(const char *program)
{
    std::cerr << "Usage: " << program
              << " --backend <IPv4:port> [--listen <IPv4:port>]"
              << " [--mode userspace|splice|sockmap] [--bpf-object <path>]"
              << " [--connect-timeout-ms <1..60000>]\n";
}

bool parse_endpoint(const std::string &text, Endpoint *endpoint)
{
    size_t colon = text.rfind(':');
    if (colon == std::string::npos || colon == 0 || colon + 1 >= text.size())
        return false;
    std::string port_text = text.substr(colon + 1);
    char *end = nullptr;
    errno = 0;
    long port = std::strtol(port_text.c_str(), &end, 10);
    if (errno || !end || *end != '\0' || port <= 0 || port > 65535)
        return false;
    in_addr address = {};
    endpoint->host = text.substr(0, colon);
    if (inet_pton(AF_INET, endpoint->host.c_str(), &address) != 1)
        return false;
    endpoint->port = static_cast<uint16_t>(port);
    return true;
}

bool parse_unsigned(const char *text, unsigned minimum, unsigned maximum,
                    unsigned *value)
{
    char *end = nullptr;
    errno = 0;
    unsigned long parsed = std::strtoul(text, &end, 10);
    if (errno || !end || *end != '\0' || parsed < minimum ||
        parsed > maximum)
        return false;
    *value = static_cast<unsigned>(parsed);
    return true;
}

bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--listen" && i + 1 < argc) {
            if (!parse_endpoint(argv[++i], &options->listen))
                return false;
        } else if (arg == "--backend" && i + 1 < argc) {
            if (!parse_endpoint(argv[++i], &options->backend))
                return false;
        } else if (arg == "--mode" && i + 1 < argc) {
            options->mode = argv[++i];
        } else if (arg == "--bpf-object" && i + 1 < argc) {
            options->bpf_object = argv[++i];
        } else if (arg == "--connect-timeout-ms" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], 1, 60000,
                                &options->connect_timeout_ms))
                return false;
        } else if (arg == "-h" || arg == "--help") {
            return false;
        } else {
            std::cerr << "Unknown or incomplete option: " << arg << "\n";
            return false;
        }
    }
    if (options->backend.port == 0)
        return false;
    if (options->mode != "userspace" && options->mode != "splice" &&
        options->mode != "sockmap")
        return false;
    return true;
}

int make_tcp_socket()
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    return fd;
}

bool fill_sockaddr(const Endpoint &endpoint, sockaddr_in *address)
{
    *address = {};
    address->sin_family = AF_INET;
    address->sin_port = htons(endpoint.port);
    return inet_pton(AF_INET, endpoint.host.c_str(), &address->sin_addr) == 1;
}

int create_listener(const Endpoint &endpoint)
{
    int fd = make_tcp_socket();
    if (fd < 0)
        return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in address = {};
    if (!fill_sockaddr(endpoint, &address) ||
        bind(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0 ||
        listen(fd, 4096) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int connect_backend(const Endpoint &endpoint, unsigned timeout_ms)
{
    int fd = make_tcp_socket();
    if (fd < 0)
        return -1;
    sockaddr_in address = {};
    int flags = fcntl(fd, F_GETFL);
    if (!fill_sockaddr(endpoint, &address) || flags < 0 ||
        fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) {
        close(fd);
        return -1;
    }
    int result =
        connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address));
    if (result != 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }
    if (result != 0) {
        pollfd descriptor = {fd, POLLOUT, 0};
        do {
            result = poll(&descriptor, 1, static_cast<int>(timeout_ms));
        } while (result < 0 && errno == EINTR && !exiting);
        int socket_error = 0;
        socklen_t error_length = sizeof(socket_error);
        if (result <= 0 || !(descriptor.revents & POLLOUT) ||
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &socket_error,
                       &error_length) != 0 ||
            socket_error != 0) {
            if (socket_error)
                errno = socket_error;
            else if (result == 0)
                errno = ETIMEDOUT;
            close(fd);
            return -1;
        }
    }
    if (fcntl(fd, F_SETFL, flags) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

bool send_all(int fd, const uint8_t *data, size_t length)
{
    size_t sent = 0;
    while (sent < length) {
        ssize_t count = send(fd, data + sent, length - sent, MSG_NOSIGNAL);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            return false;
        }
        if (count == 0)
            return false;
        sent += static_cast<size_t>(count);
    }
    return true;
}

uint64_t read_percpu_counter(int map_fd, __u32 key)
{
    int cpus = libbpf_num_possible_cpus();
    if (cpus <= 0)
        return 0;
    std::vector<__u64> values(static_cast<size_t>(cpus));
    if (bpf_map_lookup_elem(map_fd, &key, values.data()) != 0)
        return 0;
    uint64_t total = 0;
    for (__u64 value : values)
        total += value;
    return total;
}

class SockmapState {
public:
    ~SockmapState()
    {
        Close();
    }

    bool Open(const std::string &path, std::string *error)
    {
        object_ = bpf_object__open_file(path.c_str(), nullptr);
        if (!object_) {
            *error = "failed to open LDAP sockmap BPF object: " + path;
            return false;
        }
        bpf_program *parser =
            bpf_object__find_program_by_name(object_, "ldap_stream_parser");
        bpf_program *verdict =
            bpf_object__find_program_by_name(object_, "ldap_stream_verdict");
        bpf_map *sockets = bpf_object__find_map_by_name(object_, "ldap_sockets");
        bpf_map *peers = bpf_object__find_map_by_name(object_, "ldap_peers");
        bpf_map *stats =
            bpf_object__find_map_by_name(object_, "ldap_sockmap_stats");
        if (!parser || !verdict || !sockets || !peers || !stats) {
            *error = "LDAP sockmap object is missing programs or maps";
            return false;
        }
        bpf_program__set_type(parser, BPF_PROG_TYPE_SK_SKB);
        bpf_program__set_expected_attach_type(parser,
                                               BPF_SK_SKB_STREAM_PARSER);
        bpf_program__set_type(verdict, BPF_PROG_TYPE_SK_SKB);
        bpf_program__set_expected_attach_type(verdict,
                                               BPF_SK_SKB_STREAM_VERDICT);
        int load_error = bpf_object__load(object_);
        if (load_error) {
            *error = std::string("failed to load LDAP sockmap object: ") +
                     strerror(-load_error);
            return false;
        }

        parser_fd_ = bpf_program__fd(parser);
        verdict_fd_ = bpf_program__fd(verdict);
        sockets_fd_ = bpf_map__fd(sockets);
        peers_fd_ = bpf_map__fd(peers);
        stats_fd_ = bpf_map__fd(stats);
        int attach_error = bpf_prog_attach(parser_fd_, sockets_fd_,
                                           BPF_SK_SKB_STREAM_PARSER, 0);
        if (attach_error) {
            *error = std::string("failed to attach stream parser: ") +
                     strerror(-attach_error);
            return false;
        }
        parser_attached_ = true;
        attach_error = bpf_prog_attach(verdict_fd_, sockets_fd_,
                                       BPF_SK_SKB_STREAM_VERDICT, 0);
        if (attach_error) {
            *error = std::string("failed to attach stream verdict: ") +
                     strerror(-attach_error);
            return false;
        }
        verdict_attached_ = true;
        return true;
    }

    bool AddPair(int client_fd, int backend_fd, uint64_t *client_cookie,
                 uint64_t *backend_cookie, std::string *error)
    {
        socklen_t cookie_length = sizeof(*client_cookie);
        if (getsockopt(client_fd, SOL_SOCKET, SO_COOKIE, client_cookie,
                       &cookie_length) != 0) {
            *error = std::string("failed to read client socket cookie: ") +
                     strerror(errno);
            return false;
        }
        cookie_length = sizeof(*backend_cookie);
        if (getsockopt(backend_fd, SOL_SOCKET, SO_COOKIE, backend_cookie,
                       &cookie_length) != 0) {
            *error = std::string("failed to read backend socket cookie: ") +
                     strerror(errno);
            return false;
        }
        if (!*client_cookie || !*backend_cookie ||
            *client_cookie == *backend_cookie) {
            *error = "invalid LDAP socket cookies";
            return false;
        }

        if (bpf_map_update_elem(peers_fd_, client_cookie, backend_cookie,
                                BPF_ANY) != 0 ||
            bpf_map_update_elem(peers_fd_, backend_cookie, client_cookie,
                                BPF_ANY) != 0) {
            *error = std::string("failed to install LDAP peer map: ") +
                     strerror(errno);
            RemovePair(*client_cookie, *backend_cookie);
            return false;
        }
        if (bpf_map_update_elem(sockets_fd_, client_cookie, &client_fd,
                                BPF_ANY) != 0 ||
            bpf_map_update_elem(sockets_fd_, backend_cookie, &backend_fd,
                                BPF_ANY) != 0) {
            *error = std::string("failed to install LDAP sockhash pair: ") +
                     strerror(errno);
            RemovePair(*client_cookie, *backend_cookie);
            return false;
        }
        return true;
    }

    void RemovePair(uint64_t client_cookie, uint64_t backend_cookie)
    {
        if (sockets_fd_ >= 0) {
            bpf_map_delete_elem(sockets_fd_, &client_cookie);
            bpf_map_delete_elem(sockets_fd_, &backend_cookie);
        }
        if (peers_fd_ >= 0) {
            bpf_map_delete_elem(peers_fd_, &client_cookie);
            bpf_map_delete_elem(peers_fd_, &backend_cookie);
        }
    }

    int stats_fd() const
    {
        return stats_fd_;
    }

    void Close()
    {
        if (verdict_attached_) {
            bpf_prog_detach2(verdict_fd_, sockets_fd_,
                             BPF_SK_SKB_STREAM_VERDICT);
            verdict_attached_ = false;
        }
        if (parser_attached_) {
            bpf_prog_detach2(parser_fd_, sockets_fd_,
                             BPF_SK_SKB_STREAM_PARSER);
            parser_attached_ = false;
        }
        if (object_) {
            bpf_object__close(object_);
            object_ = nullptr;
        }
        parser_fd_ = -1;
        verdict_fd_ = -1;
        sockets_fd_ = -1;
        peers_fd_ = -1;
        stats_fd_ = -1;
    }

private:
    bpf_object *object_ = nullptr;
    int parser_fd_ = -1;
    int verdict_fd_ = -1;
    int sockets_fd_ = -1;
    int peers_fd_ = -1;
    int stats_fd_ = -1;
    bool parser_attached_ = false;
    bool verdict_attached_ = false;
};

bool relay_loop(int client_fd, int backend_fd, bool sockmap_mode,
                ProxyStats *stats)
{
    pollfd fds[2] = {
        {client_fd, POLLIN | POLLRDHUP, 0},
        {backend_fd, POLLIN | POLLRDHUP, 0},
    };
    bool read_closed[2] = {false, false};
    uint8_t buffer[32768];

    while (!exiting && (!read_closed[0] || !read_closed[1])) {
        int ready = poll(fds, 2, 500);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            return false;
        }
        if (ready == 0)
            continue;

        for (int side = 0; side < 2; ++side) {
            int peer = 1 - side;
            if (fds[side].revents & (POLLERR | POLLNVAL))
                return false;
            if (fds[side].revents & POLLIN) {
                ssize_t count = recv(fds[side].fd, buffer, sizeof(buffer), 0);
                if (count < 0) {
                    if (errno == EINTR || errno == EAGAIN)
                        continue;
                    return false;
                }
                if (count == 0) {
                    read_closed[side] = true;
                    shutdown(fds[peer].fd, SHUT_WR);
                } else {
                    if (!send_all(fds[peer].fd, buffer,
                                  static_cast<size_t>(count)))
                        return false;
                    if (sockmap_mode)
                        stats->sockmap_fallback_bytes.fetch_add(
                            static_cast<uint64_t>(count));
                    else
                        stats->userspace_bytes.fetch_add(
                            static_cast<uint64_t>(count));
                }
            }
            if ((fds[side].revents & (POLLRDHUP | POLLHUP)) &&
                !(fds[side].revents & POLLIN)) {
                read_closed[side] = true;
                shutdown(fds[peer].fd, SHUT_WR);
            }
            fds[side].revents = 0;
        }
    }
    return true;
}

bool splice_direction(int source_fd, int target_fd, int pipe_read,
                      int pipe_write, ProxyStats *stats, bool *source_closed)
{
    ssize_t received = splice(source_fd, nullptr, pipe_write, nullptr, 65536,
                              SPLICE_F_MOVE);
    if (received < 0) {
        if (errno == EINTR || errno == EAGAIN)
            return true;
        return false;
    }
    if (received == 0) {
        *source_closed = true;
        shutdown(target_fd, SHUT_WR);
        return true;
    }

    ssize_t remaining = received;
    while (remaining > 0) {
        ssize_t sent = splice(pipe_read, nullptr, target_fd, nullptr,
                              static_cast<size_t>(remaining),
                              SPLICE_F_MOVE);
        if (sent < 0) {
            if (errno == EINTR)
                continue;
            return false;
        }
        if (sent == 0)
            return false;
        remaining -= sent;
    }
    stats->splice_bytes.fetch_add(static_cast<uint64_t>(received));
    return true;
}

bool splice_loop(int client_fd, int backend_fd, ProxyStats *stats)
{
    int pipes[2][2] = {{-1, -1}, {-1, -1}};
    if (pipe(pipes[0]) != 0 || pipe(pipes[1]) != 0) {
        if (pipes[0][0] >= 0) {
            close(pipes[0][0]);
            close(pipes[0][1]);
        }
        return false;
    }
    for (auto &direction : pipes) {
        fcntl(direction[0], F_SETFD,
              fcntl(direction[0], F_GETFD) | FD_CLOEXEC);
        fcntl(direction[1], F_SETFD,
              fcntl(direction[1], F_GETFD) | FD_CLOEXEC);
    }

    pollfd fds[2] = {
        {client_fd, POLLIN | POLLRDHUP, 0},
        {backend_fd, POLLIN | POLLRDHUP, 0},
    };
    bool closed[2] = {false, false};
    bool ok = true;
    while (!exiting && (!closed[0] || !closed[1])) {
        int ready = poll(fds, 2, 500);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            ok = false;
            break;
        }
        if (ready == 0)
            continue;
        for (int side = 0; side < 2; ++side) {
            int peer = 1 - side;
            if (fds[side].revents & (POLLERR | POLLNVAL)) {
                ok = false;
                break;
            }
            if (fds[side].revents & POLLIN) {
                if (!splice_direction(fds[side].fd, fds[peer].fd,
                                      pipes[side][0], pipes[side][1], stats,
                                      &closed[side])) {
                    ok = false;
                    break;
                }
            }
            if ((fds[side].revents & (POLLRDHUP | POLLHUP)) &&
                !(fds[side].revents & POLLIN)) {
                closed[side] = true;
                shutdown(fds[peer].fd, SHUT_WR);
            }
            if (closed[side])
                fds[side].events = 0;
            fds[side].revents = 0;
        }
        if (!ok)
            break;
    }
    for (auto &direction : pipes) {
        close(direction[0]);
        close(direction[1]);
    }
    return ok;
}

void connection_worker(int client_fd, const Options &options,
                       SockmapState *sockmap, ProxyStats *stats)
{
    stats->active++;
    int backend_fd =
        connect_backend(options.backend, options.connect_timeout_ms);
    if (backend_fd < 0) {
        stats->connect_error++;
        close(client_fd);
        stats->active--;
        return;
    }

    bool sockmap_mode = options.mode == "sockmap";
    uint64_t client_cookie = 0;
    uint64_t backend_cookie = 0;
    bool paired = false;
    if (sockmap_mode) {
        std::string error;
        paired = sockmap->AddPair(client_fd, backend_fd, &client_cookie,
                                  &backend_cookie, &error);
        if (!paired)
            std::cerr << error << "\n";
        else
            stats->sockmap_pairs++;
    }

    bool relay_ok = options.mode == "splice"
                        ? splice_loop(client_fd, backend_fd, stats)
                        : relay_loop(client_fd, backend_fd, paired, stats);
    if (!relay_ok)
        stats->relay_error++;
    if (paired)
        sockmap->RemovePair(client_cookie, backend_cookie);
    close(client_fd);
    close(backend_fd);
    stats->completed++;
    stats->active--;
}

void print_stats(const Options &options, const ProxyStats &stats,
                 const SockmapState *sockmap)
{
    std::cout << "ldap_proxy mode=" << options.mode
              << " accepted=" << stats.accepted.load()
              << " active=" << stats.active.load()
              << " completed=" << stats.completed.load()
              << " connect_error=" << stats.connect_error.load()
              << " relay_error=" << stats.relay_error.load()
              << " userspace_bytes=" << stats.userspace_bytes.load()
              << " splice_bytes=" << stats.splice_bytes.load()
              << " sockmap_pairs=" << stats.sockmap_pairs.load()
              << " fallback_bytes=" << stats.sockmap_fallback_bytes.load();
    if (sockmap && sockmap->stats_fd() >= 0) {
        int fd = sockmap->stats_fd();
        std::cout << " peer_miss="
                  << read_percpu_counter(fd, LDAP_SOCKMAP_STAT_PEER_MISS)
                  << " redirect_fail="
                  << read_percpu_counter(fd, LDAP_SOCKMAP_STAT_REDIRECT_FAIL);
    }
    std::cout << std::endl;
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) {
        print_usage(argv[0]);
        return 1;
    }

    libbpf_set_strict_mode(LIBBPF_STRICT_ALL);
    SockmapState sockmap;
    if (options.mode == "sockmap") {
        std::string error;
        if (!sockmap.Open(options.bpf_object, &error)) {
            std::cerr << error << "\n";
            return 1;
        }
    }

    int listener = create_listener(options.listen);
    if (listener < 0) {
        std::cerr << "failed to listen on " << options.listen.host << ':'
                  << options.listen.port << ": " << strerror(errno) << "\n";
        return 1;
    }
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    std::cout << "ldap_proxy listen=" << options.listen.host << ':'
              << options.listen.port << " backend=" << options.backend.host
              << ':' << options.backend.port << " mode=" << options.mode
              << " connect_timeout_ms=" << options.connect_timeout_ms
              << "\n";

    ProxyStats stats;
    std::vector<std::thread> workers;
    auto next_report = std::chrono::steady_clock::now() +
                       std::chrono::seconds(1);
    while (!exiting) {
        pollfd descriptor = {listener, POLLIN, 0};
        int ready = poll(&descriptor, 1, 250);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            std::cerr << "listener poll failed: " << strerror(errno) << "\n";
            break;
        }
        if (ready > 0 && (descriptor.revents & POLLIN)) {
            int client = accept(listener, nullptr, nullptr);
            if (client < 0) {
                if (errno != EINTR)
                    std::cerr << "accept failed: " << strerror(errno) << "\n";
            } else {
                fcntl(client, F_SETFD,
                      fcntl(client, F_GETFD) | FD_CLOEXEC);
                int one = 1;
                setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
                stats.accepted++;
                workers.emplace_back(connection_worker, client,
                                     std::cref(options), &sockmap, &stats);
            }
        }
        auto now = std::chrono::steady_clock::now();
        if (now >= next_report) {
            print_stats(options, stats,
                        options.mode == "sockmap" ? &sockmap : nullptr);
            next_report = now + std::chrono::seconds(1);
        }
    }

    close(listener);
    for (std::thread &worker : workers) {
        if (worker.joinable())
            worker.join();
    }
    print_stats(options, stats,
                options.mode == "sockmap" ? &sockmap : nullptr);
    return stats.connect_error.load() || stats.relay_error.load() ? 1 : 0;
}
