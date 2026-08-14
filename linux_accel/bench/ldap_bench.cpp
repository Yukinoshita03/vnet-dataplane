#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
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
    unsigned response_bytes = 0;
    unsigned pipeline = 1;
    unsigned timeout_ms = 5000;
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

bool parse_unsigned(const char *text, unsigned *value)
{
    char *end = nullptr;
    errno = 0;
    unsigned long parsed = std::strtoul(text, &end, 10);
    if (errno || !end || *end != '\0' || parsed == 0 || parsed > UINT32_MAX)
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
            if (!parse_unsigned(argv[++i], &options->threads) ||
                options->threads > 256)
                return false;
        } else if (arg == "--requests" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->requests))
                return false;
        } else if (arg == "--warmup" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->warmup))
                return false;
        } else if (arg == "--response-bytes" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->response_bytes) ||
                options->response_bytes > 60000)
                return false;
        } else if (arg == "--pipeline" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->pipeline) ||
                options->pipeline > 64)
                return false;
        } else if (arg == "--timeout-ms" && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &options->timeout_ms) ||
                options->timeout_ms > 60000)
                return false;
        } else {
            return false;
        }
    }
    return options->server != options->client && options->endpoint.port != 0;
}

int make_socket()
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    return fd;
}

bool endpoint_address(const Endpoint &endpoint, sockaddr_in *address)
{
    *address = {};
    address->sin_family = AF_INET;
    address->sin_port = htons(endpoint.port);
    return inet_pton(AF_INET, endpoint.host.c_str(), &address->sin_addr) == 1;
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

bool read_all(int fd, uint8_t *data, size_t length)
{
    size_t received = 0;
    while (received < length) {
        ssize_t count = recv(fd, data + received, length - received, 0);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            return false;
        }
        if (count == 0)
            return false;
        received += static_cast<size_t>(count);
    }
    return true;
}

bool read_ber_message(int fd, std::vector<uint8_t> *message)
{
    uint8_t header[6] = {};
    if (!read_all(fd, header, 2))
        return false;
    if (header[0] != 0x30)
        return false;

    size_t header_length = 2;
    size_t payload_length = 0;
    if (!(header[1] & 0x80)) {
        payload_length = header[1];
    } else {
        unsigned length_bytes = header[1] & 0x7f;
        if (length_bytes == 0 || length_bytes > 4 ||
            !read_all(fd, header + 2, length_bytes))
            return false;
        header_length += length_bytes;
        for (unsigned i = 0; i < length_bytes; ++i)
            payload_length = (payload_length << 8) | header[2 + i];
    }
    if (payload_length > 65536)
        return false;
    message->assign(header, header + header_length);
    size_t old_size = message->size();
    message->resize(old_size + payload_length);
    return read_all(fd, message->data() + old_size, payload_length);
}

bool parse_message_id_and_operation(const std::vector<uint8_t> &message,
                                    uint8_t *message_id, uint8_t *operation)
{
    size_t offset = 2;
    if (message.size() < 7)
        return false;
    if (message[1] & 0x80)
        offset += message[1] & 0x7f;
    if (offset + 3 > message.size() || message[offset] != 0x02 ||
        message[offset + 1] != 0x01)
        return false;
    *message_id = message[offset + 2];
    offset += 3;
    if (offset >= message.size())
        return false;
    *operation = message[offset];
    return true;
}

std::vector<uint8_t> build_ldap_result(uint8_t message_id, uint8_t tag)
{
    return {
        0x30, 0x0c,
        0x02, 0x01, message_id,
        tag, 0x07,
        0x0a, 0x01, 0x00,
        0x04, 0x00,
        0x04, 0x00,
    };
}

void append_ber_length(std::vector<uint8_t> *output, size_t length)
{
    if (length < 128) {
        output->push_back(static_cast<uint8_t>(length));
        return;
    }
    uint8_t bytes[sizeof(size_t)] = {};
    unsigned count = 0;
    while (length) {
        bytes[count++] = static_cast<uint8_t>(length & 0xff);
        length >>= 8;
    }
    output->push_back(static_cast<uint8_t>(0x80 | count));
    while (count)
        output->push_back(bytes[--count]);
}

void append_tlv(std::vector<uint8_t> *output, uint8_t tag,
                const std::vector<uint8_t> &content)
{
    output->push_back(tag);
    append_ber_length(output, content.size());
    output->insert(output->end(), content.begin(), content.end());
}

std::vector<uint8_t> build_search_entry(uint8_t message_id,
                                        unsigned response_bytes)
{
    std::vector<uint8_t> attribute_content;
    std::vector<uint8_t> attribute;
    std::vector<uint8_t> attributes_content;
    std::vector<uint8_t> attributes;
    std::vector<uint8_t> values_content;
    std::vector<uint8_t> values;
    std::vector<uint8_t> operation_content;
    std::vector<uint8_t> operation;
    std::vector<uint8_t> message_content = {0x02, 0x01, message_id};
    std::vector<uint8_t> message;

    const std::string object_name = "cn=bench";
    const std::string attribute_name = "description";
    append_tlv(&operation_content, 0x04,
               std::vector<uint8_t>(object_name.begin(), object_name.end()));
    append_tlv(&attribute_content, 0x04,
               std::vector<uint8_t>(attribute_name.begin(),
                                    attribute_name.end()));
    std::vector<uint8_t> value(response_bytes, 'x');
    append_tlv(&values_content, 0x04, value);
    append_tlv(&values, 0x31, values_content);
    attribute_content.insert(attribute_content.end(), values.begin(),
                             values.end());
    append_tlv(&attribute, 0x30, attribute_content);
    attributes_content.insert(attributes_content.end(), attribute.begin(),
                              attribute.end());
    append_tlv(&attributes, 0x30, attributes_content);
    operation_content.insert(operation_content.end(), attributes.begin(),
                             attributes.end());
    append_tlv(&operation, 0x64, operation_content);
    message_content.insert(message_content.end(), operation.begin(),
                           operation.end());
    append_tlv(&message, 0x30, message_content);
    return message;
}

void server_connection(int fd, unsigned response_bytes,
                       std::atomic<uint64_t> *requests)
{
    while (!exiting) {
        std::vector<uint8_t> message;
        if (!read_ber_message(fd, &message))
            break;
        uint8_t message_id = 0;
        uint8_t operation = 0;
        if (!parse_message_id_and_operation(message, &message_id, &operation))
            break;
        if (operation == 0x42)
            break;
        if (operation == 0x63 && response_bytes) {
            std::vector<uint8_t> entry =
                build_search_entry(message_id, response_bytes);
            if (!send_all(fd, entry.data(), entry.size()))
                break;
        }
        uint8_t response_tag = operation == 0x60 ? 0x61 : 0x65;
        std::vector<uint8_t> response =
            build_ldap_result(message_id, response_tag);
        if (!send_all(fd, response.data(), response.size()))
            break;
        (*requests)++;
    }
    close(fd);
}

int run_server(const Options &options)
{
    int listener = make_socket();
    if (listener < 0)
        return 1;
    int one = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in address = {};
    if (!endpoint_address(options.endpoint, &address) ||
        bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof(address)) !=
            0 ||
        listen(listener, 4096) != 0) {
        std::cerr << "LDAP benchmark server listen failed: " << strerror(errno)
                  << "\n";
        close(listener);
        return 1;
    }
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    std::atomic<uint64_t> requests{0};
    std::cout << "ldap_bench_server listen=" << options.endpoint.host << ':'
              << options.endpoint.port << "\n";
    while (!exiting) {
        pollfd descriptor = {listener, POLLIN, 0};
        int ready = poll(&descriptor, 1, 250);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (ready == 0 || !(descriptor.revents & POLLIN))
            continue;
        int fd = accept(listener, nullptr, nullptr);
        if (fd < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC);
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        std::thread(server_connection, fd, options.response_bytes, &requests)
            .detach();
    }
    close(listener);
    std::cout << "ldap_bench_server requests=" << requests.load() << "\n";
    return 0;
}

std::vector<uint8_t> bind_request()
{
    return {
        0x30, 0x0c,
        0x02, 0x01, 0x01,
        0x60, 0x07,
        0x02, 0x01, 0x03,
        0x04, 0x00,
        0x80, 0x00,
    };
}

std::vector<uint8_t> search_request(uint8_t message_id)
{
    return {
        0x30, 0x25,
        0x02, 0x01, message_id,
        0x63, 0x20,
        0x04, 0x00,
        0x0a, 0x01, 0x00,
        0x0a, 0x01, 0x00,
        0x02, 0x01, 0x00,
        0x02, 0x01, 0x00,
        0x01, 0x01, 0x00,
        0x87, 0x0b,
        'o', 'b', 'j', 'e', 'c', 't', 'C', 'l', 'a', 's', 's',
        0x30, 0x00,
    };
}

int connect_target(const Endpoint &endpoint, unsigned timeout_ms)
{
    int fd = make_socket();
    sockaddr_in address = {};
    timeval timeout = {};
    timeout.tv_sec = static_cast<time_t>(timeout_ms / 1000);
    timeout.tv_usec = static_cast<suseconds_t>((timeout_ms % 1000) * 1000);
    if (fd < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) !=
            0 ||
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) !=
            0 ||
        !endpoint_address(endpoint, &address) ||
        connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) !=
            0) {
        if (fd >= 0)
            close(fd);
        return -1;
    }
    return fd;
}

uint64_t monotonic_ns()
{
    timespec ts = {};
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000000ull + ts.tv_nsec;
}

bool exchange(int fd, const std::vector<uint8_t> &request,
              uint8_t expected_tag)
{
    if (!send_all(fd, request.data(), request.size()))
        return false;
    while (true) {
        std::vector<uint8_t> response;
        if (!read_ber_message(fd, &response))
            return false;
        uint8_t response_id = 0;
        uint8_t response_tag = 0;
        if (!parse_message_id_and_operation(response, &response_id,
                                            &response_tag))
            return false;
        if (expected_tag == 0x65 && response_tag == 0x64)
            continue;
        return response_tag == expected_tag;
    }
}

struct ClientResult {
    std::vector<uint64_t> latencies_ns;
    uint64_t failed = 0;
};

bool run_pipelined_searches(int fd, const Options &options,
                            ClientResult *result)
{
    uint64_t started_ns[256] = {};
    bool active[256] = {};
    unsigned sent = 0;
    unsigned completed = 0;
    unsigned outstanding = 0;
    uint8_t next_id = 2;

    result->latencies_ns.reserve(options.requests);
    while (completed < options.requests) {
        while (sent < options.requests && outstanding < options.pipeline) {
            unsigned attempts = 0;
            while (active[next_id] && attempts++ < 120) {
                next_id++;
                if (next_id > 121)
                    next_id = 2;
            }
            if (active[next_id])
                return false;
            std::vector<uint8_t> request = search_request(next_id);
            started_ns[next_id] = monotonic_ns();
            active[next_id] = true;
            if (!send_all(fd, request.data(), request.size()))
                return false;
            sent++;
            outstanding++;
            next_id++;
            if (next_id > 121)
                next_id = 2;
        }

        std::vector<uint8_t> response;
        if (!read_ber_message(fd, &response))
            return false;
        uint8_t response_id = 0;
        uint8_t response_tag = 0;
        if (!parse_message_id_and_operation(response, &response_id,
                                            &response_tag))
            return false;
        if (response_tag == 0x64)
            continue;
        if (response_tag != 0x65 || !active[response_id])
            return false;
        result->latencies_ns.push_back(monotonic_ns() - started_ns[response_id]);
        active[response_id] = false;
        outstanding--;
        completed++;
    }
    return true;
}

void client_worker(const Options &options, unsigned thread_index,
                   std::atomic<unsigned> *ready, std::atomic<bool> *go,
                   ClientResult *result)
{
    int fd = connect_target(options.endpoint, options.timeout_ms);
    if (fd < 0) {
        result->failed = options.requests;
        (*ready)++;
        return;
    }
    std::vector<uint8_t> bind = bind_request();
    if (!exchange(fd, bind, 0x61)) {
        result->failed = options.requests;
        close(fd);
        (*ready)++;
        return;
    }
    for (unsigned i = 0; i < options.warmup; ++i) {
        uint8_t id = static_cast<uint8_t>(2 + ((i + thread_index) % 120));
        if (!exchange(fd, search_request(id), 0x65)) {
            result->failed = options.requests;
            close(fd);
            (*ready)++;
            return;
        }
    }
    (*ready)++;
    while (!go->load(std::memory_order_acquire))
        std::this_thread::yield();

    if (!run_pipelined_searches(fd, options, result))
        result->failed = options.requests - result->latencies_ns.size();
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
        workers.emplace_back(client_worker, std::cref(options), i, &ready, &go,
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
    uint64_t completed = latencies.size();
    double average_us = 0.0;
    if (!latencies.empty()) {
        long double total = std::accumulate(
            latencies.begin(), latencies.end(), static_cast<long double>(0));
        average_us = static_cast<double>(total / latencies.size() / 1000.0L);
    }
    double qps = elapsed_ns
                     ? static_cast<double>(completed) * 1000000000.0 /
                           static_cast<double>(elapsed_ns)
                     : 0.0;
    std::cout << "ldap_bench_client"
              << " threads=" << options.threads
              << " response_bytes=" << options.response_bytes
              << " pipeline=" << options.pipeline
              << " timeout_ms=" << options.timeout_ms
              << " completed=" << completed << " failed=" << failed
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
                  << " [--threads N] [--requests N] [--warmup N]"
                  << " [--response-bytes N] [--pipeline N]"
                  << " [--timeout-ms N]\n";
        return 2;
    }
    return options.server ? run_server(options) : run_client(options);
}
