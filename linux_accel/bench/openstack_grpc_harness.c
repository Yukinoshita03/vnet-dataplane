#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <linux/bpf.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static const char preface[] = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
static const char *method = "/grpc.health.v1.Health/Check";

static int read_full(int fd, void *buf, size_t len)
{
    size_t off = 0;
    while (off < len) {
        ssize_t n = recv(fd, (char *)buf + off, len - off, 0);
        if (n <= 0)
            return -1;
        off += (size_t)n;
    }
    return 0;
}

static int send_full(int fd, const void *buf, size_t len)
{
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(fd, (const char *)buf + off, len - off, MSG_NOSIGNAL);
        if (n <= 0)
            return -1;
        off += (size_t)n;
    }
    return 0;
}

static void frame_header(unsigned char *header, uint32_t len, uint8_t type,
                         uint8_t flags, uint32_t stream_id)
{
    header[0] = (unsigned char)((len >> 16) & 0xff);
    header[1] = (unsigned char)((len >> 8) & 0xff);
    header[2] = (unsigned char)(len & 0xff);
    header[3] = type;
    header[4] = flags;
    header[5] = (unsigned char)((stream_id >> 24) & 0x7f);
    header[6] = (unsigned char)((stream_id >> 16) & 0xff);
    header[7] = (unsigned char)((stream_id >> 8) & 0xff);
    header[8] = (unsigned char)(stream_id & 0xff);
}

static int append_bytes(unsigned char *out, size_t *off, size_t cap,
                        const void *data, size_t len)
{
    if (*off + len > cap)
        return -1;
    memcpy(out + *off, data, len);
    *off += len;
    return 0;
}

static int append_byte(unsigned char *out, size_t *off, size_t cap,
                       unsigned char value)
{
    return append_bytes(out, off, cap, &value, 1);
}

static int append_literal(unsigned char *out, size_t *off, size_t cap,
                          const char *name, const char *value)
{
    size_t name_len = strlen(name);
    size_t value_len = strlen(value);
    if (name_len > 127 || value_len > 127)
        return -1;
    if (append_byte(out, off, cap, 0x00) ||
        append_byte(out, off, cap, (unsigned char)name_len) ||
        append_bytes(out, off, cap, name, name_len) ||
        append_byte(out, off, cap, (unsigned char)value_len) ||
        append_bytes(out, off, cap, value, value_len))
        return -1;
    return 0;
}

static int build_request(unsigned char *out, size_t cap, const char *payload,
                         size_t *out_len)
{
    unsigned char header[9];
    unsigned char headers[512];
    unsigned char data[512];
    size_t off = 0;
    size_t headers_len = 0;
    size_t data_len = 0;
    size_t payload_len = strlen(payload);

    if (payload_len > 400 ||
        append_bytes(out, &off, cap, preface, sizeof(preface) - 1))
        return -1;

    frame_header(header, 0, 0x4, 0x0, 0);
    if (append_bytes(out, &off, cap, header, sizeof(header)))
        return -1;

    if (append_byte(headers, &headers_len, sizeof(headers), 0x83) ||
        append_byte(headers, &headers_len, sizeof(headers), 0x86) ||
        append_literal(headers, &headers_len, sizeof(headers), ":path", method) ||
        append_literal(headers, &headers_len, sizeof(headers), ":authority", "bench") ||
        append_literal(headers, &headers_len, sizeof(headers), "content-type", "application/grpc") ||
        append_literal(headers, &headers_len, sizeof(headers), "te", "trailers"))
        return -1;

    frame_header(header, (uint32_t)headers_len, 0x1, 0x4, 1);
    if (append_bytes(out, &off, cap, header, sizeof(header)) ||
        append_bytes(out, &off, cap, headers, headers_len))
        return -1;

    if (append_byte(data, &data_len, sizeof(data), 0x00) ||
        append_byte(data, &data_len, sizeof(data), (unsigned char)((payload_len >> 24) & 0xff)) ||
        append_byte(data, &data_len, sizeof(data), (unsigned char)((payload_len >> 16) & 0xff)) ||
        append_byte(data, &data_len, sizeof(data), (unsigned char)((payload_len >> 8) & 0xff)) ||
        append_byte(data, &data_len, sizeof(data), (unsigned char)(payload_len & 0xff)) ||
        append_bytes(data, &data_len, sizeof(data), payload, payload_len))
        return -1;

    frame_header(header, (uint32_t)data_len, 0x0, 0x1, 1);
    if (append_bytes(out, &off, cap, header, sizeof(header)) ||
        append_bytes(out, &off, cap, data, data_len))
        return -1;

    *out_len = off;
    return 0;
}

static int listen_on(const char *address, int port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int reuse = 1;
    struct sockaddr_in addr = {};
    if (fd < 0)
        return -1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, address, &addr.sin_addr) != 1 ||
        bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(fd, 128) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int serve_one(int fd, int delay_us)
{
    unsigned char header[9];
    unsigned char payload[16384];
    char request_preface[sizeof(preface) - 1];
    int request_done = 0;

    if (read_full(fd, request_preface, sizeof(request_preface)) != 0 ||
        memcmp(request_preface, preface, sizeof(request_preface)) != 0)
        return -1;

    frame_header(header, 0, 0x4, 0x1, 0);
    if (send_full(fd, header, sizeof(header)) != 0)
        return -1;

    while (!request_done) {
        uint32_t len;
        uint8_t type;
        uint8_t flags;
        if (read_full(fd, header, sizeof(header)) != 0)
            return -1;
        len = ((uint32_t)header[0] << 16) |
              ((uint32_t)header[1] << 8) | header[2];
        type = header[3];
        flags = header[4];
        if (len > sizeof(payload) || read_full(fd, payload, len) != 0)
            return -1;
        if ((type == 0x0 || type == 0x1) && (flags & 0x1))
            request_done = 1;
    }

    if (delay_us > 0) {
        struct timespec delay = {
            delay_us / 1000000,
            (delay_us % 1000000) * 1000,
        };
        nanosleep(&delay, NULL);
    }

    {
        unsigned char block[256];
        size_t block_len = 0;
        if (append_byte(block, &block_len, sizeof(block), 0x88) ||
            append_literal(block, &block_len, sizeof(block),
                           "content-type", "application/grpc"))
            return -1;
        frame_header(header, (uint32_t)block_len, 0x1, 0x4, 1);
        if (send_full(fd, header, sizeof(header)) != 0 ||
            send_full(fd, block, block_len) != 0)
            return -1;

        {
            unsigned char data[] = {0x00, 0x00, 0x00, 0x00, 0x02, 0x08, 0x01};
            frame_header(header, sizeof(data), 0x0, 0x0, 1);
            if (send_full(fd, header, sizeof(header)) != 0 ||
                send_full(fd, data, sizeof(data)) != 0)
                return -1;
        }

        block_len = 0;
        if (append_literal(block, &block_len, sizeof(block), "grpc-status", "0"))
            return -1;
        frame_header(header, (uint32_t)block_len, 0x1, 0x5, 1);
        if (send_full(fd, header, sizeof(header)) != 0 ||
            send_full(fd, block, block_len) != 0)
            return -1;
    }
    return 0;
}

static uint64_t monotonic_us(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000ull + now.tv_nsec / 1000ull;
}

static int client_request(const char *address, int port, const char *payload,
                          int *status)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct timeval timeout = {2, 0};
    struct sockaddr_in addr = {};
    unsigned char request[2048];
    unsigned char header[9];
    unsigned char response[16384];
    size_t request_len = 0;
    int got_data = 0;
    int got_status = 0;
    int done = 0;

    *status = 0;

    if (fd < 0)
        return -1;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, address, &addr.sin_addr) != 1 ||
        connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        build_request(request, sizeof(request), payload, &request_len) != 0 ||
        send_full(fd, request, request_len) != 0) {
        close(fd);
        return -1;
    }

    while (!done) {
        uint32_t len;
        uint8_t type;
        uint8_t flags;
        if (read_full(fd, header, sizeof(header)) != 0)
            break;
        len = ((uint32_t)header[0] << 16) |
              ((uint32_t)header[1] << 8) | header[2];
        type = header[3];
        flags = header[4];
        if (len > sizeof(response) || read_full(fd, response, len) != 0)
            break;
        if (type == 0x0 && len >= 7 && response[0] == 0 &&
            response[5] == 8 && (response[6] == 1 || response[6] == 2)) {
            got_data = 1;
            *status = response[6];
        }
        if (type == 0x1 && (flags & 0x1)) {
            got_status = 1;
            done = 1;
        }
    }
    close(fd);
    return got_data && got_status ? 0 : -1;
}

static int run_client(const char *address, int port, int requests, int warmup,
                      const char *payload)
{
    double *samples = calloc((size_t)requests, sizeof(*samples));
    int completed = 0;
    int failed = 0;
    int serving = 0;
    int not_serving = 0;
    uint64_t all_start;
    double elapsed;
    double total = 0;

    if (!samples)
        return 1;
    all_start = monotonic_us();
    for (int i = 0; i < requests + warmup; ++i) {
        uint64_t start = monotonic_us();
        int status = 0;
        int rc = client_request(address, port, payload, &status);
        double latency = (double)(monotonic_us() - start);
        if (rc == 0 && i >= warmup) {
            samples[completed++] = latency;
            if (status == 1)
                serving++;
            else if (status == 2)
                not_serving++;
        } else if (rc != 0)
            failed++;
    }
    elapsed = (double)(monotonic_us() - all_start) / 1000000.0;
    for (int i = 0; i < completed; ++i) {
        for (int j = i + 1; j < completed; ++j) {
            if (samples[j] < samples[i]) {
                double tmp = samples[i];
                samples[i] = samples[j];
                samples[j] = tmp;
            }
        }
        total += samples[i];
    }
    {
        int p50 = completed ? (int)((completed - 1) * 0.50) : 0;
        int p95 = completed ? (int)((completed - 1) * 0.95) : 0;
        int p99 = completed ? (int)((completed - 1) * 0.99) : 0;
        printf("count=%d failed=%d serving=%d not_serving=%d qps=%.2f avg_us=%.2f "
               "p50_us=%.2f p95_us=%.2f p99_us=%.2f\n",
               completed, failed, serving, not_serving,
               elapsed > 0 ? completed / elapsed : 0.0,
               completed ? total / completed : 0.0,
               completed ? samples[p50] : 0.0,
               completed ? samples[p95] : 0.0,
               completed ? samples[p99] : 0.0);
    }
    free(samples);
    return completed == requests ? 0 : 1;
}

static uint64_t fnv1a(const char *value)
{
    uint64_t hash = 1469598103934665603ull;
    for (; *value; ++value) {
        hash ^= (unsigned char)*value;
        hash *= 1099511628211ull;
    }
    return hash;
}

static int bpf_call(enum bpf_cmd command, union bpf_attr *attr)
{
    return (int)syscall(__NR_bpf, command, attr, sizeof(*attr));
}

static int seed_policy(const char *path)
{
    union bpf_attr attr = {};
    uint64_t key = fnv1a(method);
    unsigned char value[8] = {60, 0, 0, 0, 1, 0, 0, 0};
    int map_fd;

    attr.map_type = BPF_MAP_TYPE_HASH;
    attr.key_size = sizeof(key);
    attr.value_size = sizeof(value);
    attr.max_entries = 16;
    map_fd = bpf_call(BPF_MAP_CREATE, &attr);
    if (map_fd < 0) {
        perror("BPF_MAP_CREATE");
        return 1;
    }

    attr = (union bpf_attr){};
    attr.pathname = (uint64_t)(uintptr_t)path;
    attr.bpf_fd = map_fd;
    if (bpf_call(BPF_OBJ_PIN, &attr) < 0) {
        perror("BPF_OBJ_PIN");
        close(map_fd);
        return 1;
    }

    attr = (union bpf_attr){};
    attr.map_fd = map_fd;
    attr.key = (uint64_t)(uintptr_t)&key;
    attr.value = (uint64_t)(uintptr_t)value;
    if (bpf_call(BPF_MAP_UPDATE_ELEM, &attr) < 0) {
        perror("BPF_MAP_UPDATE_ELEM");
        close(map_fd);
        return 1;
    }
    printf("policy map pinned at %s\n", path);
    close(map_fd);
    return 0;
}

struct response_cache_key {
    uint64_t method_hash;
    uint64_t payload_hash;
};

struct response_cache_value {
    uint32_t status;
    uint32_t _pad;
    uint64_t expires_ns;
};

static uint64_t monotonic_ns(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000000ull + now.tv_nsec;
}

static int seed_response(const char *path, const char *payload,
                         const char *status_text, const char *ttl_text)
{
    union bpf_attr attr = {};
    struct response_cache_key key = {
        fnv1a(method),
        fnv1a(payload),
    };
    struct response_cache_value value = {};
    char *end = NULL;
    unsigned long long ttl = strtoull(ttl_text, &end, 10);
    int map_fd;

    if (!*payload || !end || *end != '\0' || ttl == 0 || ttl > 86400) {
        fprintf(stderr, "invalid response cache payload or ttl\n");
        return 1;
    }
    if (strcmp(status_text, "SERVING") == 0 ||
        strcmp(status_text, "serving") == 0)
        value.status = 1;
    else if (strcmp(status_text, "NOT_SERVING") == 0 ||
             strcmp(status_text, "not_serving") == 0)
        value.status = 2;
    else {
        fprintf(stderr, "invalid response cache status: %s\n", status_text);
        return 1;
    }
    value.expires_ns = monotonic_ns() + ttl * 1000000000ull;

    attr.map_type = BPF_MAP_TYPE_LRU_HASH;
    attr.key_size = sizeof(key);
    attr.value_size = sizeof(value);
    attr.max_entries = 4096;
    map_fd = bpf_call(BPF_MAP_CREATE, &attr);
    if (map_fd < 0) {
        perror("BPF_MAP_CREATE response cache");
        return 1;
    }

    attr = (union bpf_attr){};
    attr.pathname = (uint64_t)(uintptr_t)path;
    attr.bpf_fd = map_fd;
    if (bpf_call(BPF_OBJ_PIN, &attr) < 0) {
        perror("BPF_OBJ_PIN response cache");
        close(map_fd);
        return 1;
    }

    attr = (union bpf_attr){};
    attr.map_fd = map_fd;
    attr.key = (uint64_t)(uintptr_t)&key;
    attr.value = (uint64_t)(uintptr_t)&value;
    if (bpf_call(BPF_MAP_UPDATE_ELEM, &attr) < 0) {
        perror("BPF_MAP_UPDATE_ELEM response cache");
        close(map_fd);
        return 1;
    }
    printf("response cache map pinned at %s\n", path);
    close(map_fd);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc >= 5 && strcmp(argv[1], "server") == 0) {
        int listener = listen_on(argv[2], atoi(argv[3]));
        int delay_us = atoi(argv[4]);
        if (listener < 0) {
            perror("listen");
            return 1;
        }
        for (;;) {
            int client = accept(listener, NULL, NULL);
            if (client >= 0) {
                serve_one(client, delay_us);
                close(client);
            }
        }
    }
    if (argc >= 7 && strcmp(argv[1], "client") == 0)
        return run_client(argv[2], atoi(argv[3]), atoi(argv[4]), atoi(argv[5]), argv[6]);
    if (argc >= 3 && strcmp(argv[1], "seed") == 0)
        return seed_policy(argv[2]);
    if (argc >= 6 && strcmp(argv[1], "seed-response") == 0)
        return seed_response(argv[2], argv[3], argv[4], argv[5]);

    fprintf(stderr,
            "usage: %s server IP PORT DELAY_US | client IP PORT REQUESTS "
            "WARMUP PAYLOAD | seed PIN_PATH | seed-response PIN_PATH "
            "PAYLOAD SERVING|NOT_SERVING TTL\n",
            argv[0]);
    return 2;
}
