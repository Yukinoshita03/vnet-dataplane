#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define DNS_MAX_PACKET 512

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static int encode_name(uint8_t *packet, size_t cap, const char *name)
{
    size_t offset = 0;
    const char *label = name;

    while (*label) {
        const char *dot = strchr(label, '.');
        size_t length = dot ? (size_t)(dot - label) : strlen(label);
        if (length == 0 || length > 63 || offset + length + 2 > cap)
            return -1;
        packet[offset++] = (uint8_t)length;
        memcpy(packet + offset, label, length);
        offset += length;
        if (!dot)
            break;
        label = dot + 1;
    }
    if (offset + 1 > cap)
        return -1;
    packet[offset++] = 0;
    return (int)offset;
}

static int build_query(uint8_t *packet, size_t cap, uint16_t id,
                       const char *domain)
{
    if (cap < 12)
        return -1;
    memset(packet, 0, cap);
    packet[0] = (uint8_t)(id >> 8);
    packet[1] = (uint8_t)id;
    packet[4] = 0;
    packet[5] = 1;
    int name_len = encode_name(packet + 12, cap - 12, domain);
    if (name_len < 0 || (size_t)(12 + name_len + 4) > cap)
        return -1;
    size_t offset = 12 + (size_t)name_len;
    packet[offset++] = 0;
    packet[offset++] = 1;
    packet[offset++] = 0;
    packet[offset++] = 1;
    return (int)offset;
}

static int read_u16(const uint8_t *packet, size_t length, size_t offset,
                    uint16_t *value)
{
    if (offset + 2 > length)
        return -1;
    *value = (uint16_t)(((uint16_t)packet[offset] << 8) | packet[offset + 1]);
    return 0;
}

static int response_matches(const uint8_t *packet, size_t length, uint16_t id,
                            const struct in_addr *expected)
{
    uint16_t packet_id;
    uint16_t flags;
    uint16_t answers;
    if (read_u16(packet, length, 0, &packet_id) != 0 || packet_id != id ||
        read_u16(packet, length, 2, &flags) != 0 ||
        read_u16(packet, length, 6, &answers) != 0 || answers == 0)
        return 0;
    if ((flags & 0x8000u) == 0 || (flags & 0x000fu) != 0)
        return 0;
    if (length < 4)
        return 0;
    return memcmp(packet + length - 4, &expected->s_addr, 4) == 0;
}

static int parse_name_end(const uint8_t *packet, size_t length, size_t offset,
                          size_t *end)
{
    size_t cursor = offset;
    unsigned int labels = 0;
    while (cursor < length && labels++ < 128) {
        uint8_t label = packet[cursor++];
        if (label == 0) {
            *end = cursor;
            return 0;
        }
        if ((label & 0xc0u) == 0xc0u) {
            if (cursor >= length)
                return -1;
            *end = cursor + 1;
            return 0;
        }
        if (label > 63 || cursor + label > length)
            return -1;
        cursor += label;
    }
    return -1;
}

static int build_response(const uint8_t *query, size_t query_len,
                          uint8_t *response, size_t cap,
                          const struct in_addr *answer, unsigned int ttl,
                          int nxdomain)
{
    size_t question_end;
    if (query_len < 16 || parse_name_end(query, query_len, 12, &question_end) != 0 ||
        question_end + 4 > query_len || cap < question_end + 16)
        return -1;
    memset(response, 0, cap);
    memcpy(response, query, 2);
    response[2] = 0x81;
    response[3] = nxdomain ? 0x83 : 0x80;
    response[4] = 0;
    response[5] = 1;
    response[6] = nxdomain ? 0 : 0;
    response[7] = nxdomain ? 0 : 1;
    memcpy(response + 12, query + 12, question_end + 4 - 12);
    size_t offset = question_end + 4;
    if (nxdomain)
        return (int)offset;
    response[offset++] = 0xc0;
    response[offset++] = 0x0c;
    response[offset++] = 0;
    response[offset++] = 1;
    response[offset++] = 0;
    response[offset++] = 1;
    response[offset++] = (uint8_t)(ttl >> 24);
    response[offset++] = (uint8_t)(ttl >> 16);
    response[offset++] = (uint8_t)(ttl >> 8);
    response[offset++] = (uint8_t)ttl;
    response[offset++] = 0;
    response[offset++] = 4;
    memcpy(response + offset, &answer->s_addr, 4);
    return (int)(offset + 4);
}

static int run_server(const char *bind_ip, int port, const char *domain,
                      const char *answer_ip, unsigned int ttl,
                      const char *count_file, int nxdomain)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return 2;
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, bind_ip, &address.sin_addr) != 1 ||
        bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0)
        return 2;
    struct in_addr answer = {0};
    if (inet_pton(AF_INET, answer_ip, &answer) != 1)
        return 2;
    FILE *counter = fopen(count_file, "w");
    if (!counter)
        return 2;
    unsigned long long requests = 0;
    uint8_t query[DNS_MAX_PACKET];
    uint8_t response[DNS_MAX_PACKET];
    for (;;) {
        struct sockaddr_in peer = {0};
        socklen_t peer_len = sizeof(peer);
        ssize_t received = recvfrom(fd, query, sizeof(query), 0,
                                    (struct sockaddr *)&peer, &peer_len);
        if (received < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        requests++;
        fprintf(counter, "%llu\n", requests);
        fflush(counter);
        int response_len = build_response(query, (size_t)received, response,
                                          sizeof(response), &answer, ttl,
                                          nxdomain);
        if (response_len > 0)
            sendto(fd, response, (size_t)response_len, 0,
                   (struct sockaddr *)&peer, peer_len);
    }
    fclose(counter);
    close(fd);
    (void)domain;
    return 0;
}

static int compare_u64(const void *lhs, const void *rhs)
{
    uint64_t a = *(const uint64_t *)lhs;
    uint64_t b = *(const uint64_t *)rhs;
    return a > b ? 1 : a < b ? -1 : 0;
}

static uint64_t percentile(uint64_t *samples, int count, double fraction)
{
    if (count == 0)
        return 0;
    int index = (int)(fraction * (double)(count - 1));
    if (index < 0)
        index = 0;
    if (index >= count)
        index = count - 1;
    return samples[index];
}

static int workload_domain(char *out, size_t out_len, const char *base_domain,
                           const char *pattern, int index, int requests,
                           int warmup, int measured, int key_count)
{
    int written;
    if (strcmp(pattern, "fixed") == 0)
        written = snprintf(out, out_len, "%s", base_domain);
    else if (strcmp(pattern, "hot") == 0)
        written = snprintf(out, out_len, "hot.%s", base_domain);
    else if (strcmp(pattern, "stable") == 0)
        written = snprintf(out, out_len, "key-%d.%s",
                           index % key_count, base_domain);
    else if (strcmp(pattern, "shifting") == 0)
        written = snprintf(out, out_len, "shift-%c.%s",
                           measured && index >= requests / 2 ? 'b' : 'a',
                           base_domain);
    else if (strcmp(pattern, "low-hit-rate") == 0)
        written = snprintf(out, out_len, "unique-%d.%s",
                           measured ? warmup + index : index, base_domain);
    else
        return -1;
    return written > 0 && (size_t)written < out_len ? 0 : -1;
}

static int run_client_workload(const char *server_ip, int port,
                               const char *domain, const char *expected_ip,
                               int requests, int warmup, const char *pattern,
                               int key_count)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return 2;
    struct timeval timeout = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_in server = {0};
    server.sin_family = AF_INET;
    server.sin_port = htons((uint16_t)port);
    struct in_addr expected = {0};
    if (inet_pton(AF_INET, server_ip, &server.sin_addr) != 1 ||
        inet_pton(AF_INET, expected_ip, &expected) != 1)
        return 2;
    uint8_t query[DNS_MAX_PACKET];
    uint8_t response[DNS_MAX_PACKET];
    char request_domain[256];
    if (requests <= 0 || warmup < 0 || key_count <= 0)
        return 2;
    for (int i = 0; i < warmup; ++i) {
        uint16_t id = (uint16_t)(0x1000u + (unsigned int)i);
        if (workload_domain(request_domain, sizeof(request_domain), domain,
                            pattern, i, requests, warmup, 0,
                            key_count) < 0)
            return 2;
        int query_len =
            build_query(query, sizeof(query), id, request_domain);
        if (query_len < 0)
            return 2;
        sendto(fd, query, (size_t)query_len, 0,
               (struct sockaddr *)&server, sizeof(server));
        recvfrom(fd, response, sizeof(response), 0, NULL, NULL);
    }
    uint64_t *samples = calloc((size_t)requests, sizeof(*samples));
    if (!samples)
        return 2;
    int success = 0;
    int failed = 0;
    uint64_t total_ns = 0;
    uint64_t start = now_ns();
    for (int i = 0; i < requests; ++i) {
        uint16_t id = (uint16_t)(0x4000u + (unsigned int)i);
        if (workload_domain(request_domain, sizeof(request_domain), domain,
                            pattern, i, requests, warmup, 1,
                            key_count) < 0) {
            free(samples);
            close(fd);
            return 2;
        }
        int query_len =
            build_query(query, sizeof(query), id, request_domain);
        uint64_t request_start = now_ns();
        ssize_t received = query_len > 0
                               ? sendto(fd, query, (size_t)query_len, 0,
                                        (struct sockaddr *)&server, sizeof(server))
                               : -1;
        if (received < 0) {
            failed++;
            continue;
        }
        received = recvfrom(fd, response, sizeof(response), 0, NULL, NULL);
        uint64_t latency = now_ns() - request_start;
        if (received > 0 && response_matches(response, (size_t)received, id,
                                             &expected)) {
            samples[success++] = latency;
            total_ns += latency;
        } else {
            failed++;
        }
    }
    uint64_t elapsed = now_ns() - start;
    qsort(samples, (size_t)success, sizeof(*samples), compare_u64);
    double qps = elapsed ? (double)requests * 1000000000.0 / (double)elapsed : 0.0;
    double avg_us = success ? (double)total_ns / (double)success / 1000.0 : 0.0;
    printf("success=%d failed=%d qps=%.2f avg_us=%.2f p50_us=%.2f "
           "p95_us=%.2f p99_us=%.2f workload=%s keys=%d\n",
           success, failed, qps, avg_us,
           (double)percentile(samples, success, 0.50) / 1000.0,
           (double)percentile(samples, success, 0.95) / 1000.0,
           (double)percentile(samples, success, 0.99) / 1000.0,
           pattern, key_count);
    free(samples);
    close(fd);
    return failed == 0 && success == requests ? 0 : 1;
}

static int run_client(const char *server_ip, int port, const char *domain,
                      const char *expected_ip, int requests, int warmup)
{
    return run_client_workload(server_ip, port, domain, expected_ip,
                               requests, warmup, "fixed", 1);
}

int main(int argc, char **argv)
{
    if (argc >= 2 && strcmp(argv[1], "server") == 0 && argc >= 8) {
        return run_server(argv[2], atoi(argv[3]), argv[4], argv[5],
                          (unsigned int)strtoul(argv[6], NULL, 10), argv[7],
                          argc > 8 && strcmp(argv[8], "nxdomain") == 0);
    }
    if (argc >= 2 && strcmp(argv[1], "client") == 0 && argc >= 8)
        return run_client(argv[2], atoi(argv[3]), argv[4], argv[5],
                          atoi(argv[6]), atoi(argv[7]));
    if (argc >= 2 && strcmp(argv[1], "client-workload") == 0 && argc >= 10)
        return run_client_workload(
            argv[2], atoi(argv[3]), argv[4], argv[5], atoi(argv[6]),
            atoi(argv[7]), argv[8], atoi(argv[9]));
    fprintf(stderr,
            "usage: %s server <bind-ip> <port> <domain> <answer-ip> <ttl> <count-file> [nxdomain]\n"
            "       %s client <server-ip> <port> <domain> <answer-ip> <requests> <warmup>\n"
            "       %s client-workload <server-ip> <port> <base-domain> <answer-ip> "
            "<requests> <warmup> <fixed|hot|stable|shifting|low-hit-rate> <keys>\n",
            argv[0], argv[0], argv[0]);
    return 2;
}
