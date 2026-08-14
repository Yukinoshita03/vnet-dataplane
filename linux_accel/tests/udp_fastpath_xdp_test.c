#define _GNU_SOURCE

#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <net/if.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#include "udp_fastpath.h"

enum {
    TEST_FRAME_CAPACITY = 256,
};

static uint32_t test_ifindex_a;
static uint32_t test_ifindex_b;

#define TEST_IFINDEX_A test_ifindex_a
#define TEST_IFINDEX_B test_ifindex_b

struct packet_fixture {
    uint8_t bytes[TEST_FRAME_CAPACITY];
    uint32_t length;
    uint32_t ifindex;
};

struct test_run_result {
    uint8_t bytes[TEST_FRAME_CAPACITY];
    uint32_t length;
    uint32_t action;
};

static const uint8_t client_mac[ETH_ALEN] = {
    0x02, 0x00, 0x00, 0x00, 0x00, 0x11,
};
static const uint8_t server_mac[ETH_ALEN] = {
    0x02, 0x00, 0x00, 0x00, 0x00, 0x22,
};

#define CHECK(test_name, condition, ...)                                  \
    do {                                                                  \
        if (!(condition)) {                                               \
            fprintf(stderr, "not ok - %s: ", (test_name));              \
            fprintf(stderr, __VA_ARGS__);                                \
            fputc('\n', stderr);                                         \
            return -1;                                                    \
        }                                                                 \
    } while (0)

static uint64_t monotonic_ns(void)
{
    struct timespec ts;

    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return 0;
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void raise_memlock_limit(void)
{
    const struct rlimit limit = {RLIM_INFINITY, RLIM_INFINITY};

    if (setrlimit(RLIMIT_MEMLOCK, &limit) && errno != EPERM)
        fprintf(stderr, "warning: setrlimit failed: %s\n", strerror(errno));
}

static uint32_t resolve_second_ifindex(uint32_t first)
{
    uint32_t preferred = if_nametoindex("enp3s0");
    if (preferred && preferred != first)
        return preferred;
    struct if_nameindex *interfaces = if_nameindex();
    if (!interfaces)
        return 0;
    uint32_t result = 0;
    for (struct if_nameindex *entry = interfaces; entry->if_index != 0;
         entry++) {
        if (entry->if_index != first) {
            result = entry->if_index;
            break;
        }
    }
    if_freenameindex(interfaces);
    return result;
}

static int parse_ipv4(const char *text, __be32 *address)
{
    return inet_pton(AF_INET, text, address) == 1 ? 0 : -1;
}

static int build_udp_request(struct packet_fixture *fixture, uint32_t ifindex,
                             const uint8_t *payload, uint16_t payload_len)
{
    struct ethhdr *eth;
    struct iphdr *ip;
    struct udphdr *udp;
    uint8_t *output;
    uint32_t length = sizeof(*eth) + sizeof(*ip) + sizeof(*udp) + payload_len;

    if (length > sizeof(fixture->bytes))
        return -1;
    memset(fixture, 0, sizeof(*fixture));
    fixture->length = length;
    fixture->ifindex = ifindex;

    eth = (struct ethhdr *)fixture->bytes;
    ip = (struct iphdr *)(eth + 1);
    udp = (struct udphdr *)(ip + 1);
    output = (uint8_t *)(udp + 1);

    memcpy(eth->h_source, client_mac, ETH_ALEN);
    memcpy(eth->h_dest, server_mac, ETH_ALEN);
    eth->h_proto = htons(ETH_P_IP);
    ip->version = 4;
    ip->ihl = sizeof(*ip) / 4;
    ip->ttl = 64;
    ip->protocol = IPPROTO_UDP;
    ip->tot_len = htons(sizeof(*ip) + sizeof(*udp) + payload_len);
    if (parse_ipv4("192.0.2.10", &ip->saddr) != 0 ||
        parse_ipv4("192.0.2.53", &ip->daddr) != 0)
        return -1;
    udp->source = htons(41000);
    udp->dest = htons(9000);
    udp->len = htons(sizeof(*udp) + payload_len);
    if (payload_len)
        memcpy(output, payload, payload_len);
    return 0;
}

static int run_packet(int program_fd, const struct packet_fixture *fixture,
                      struct test_run_result *result)
{
    struct xdp_md context = {
        .data = 0,
        .data_end = fixture->length,
        .ingress_ifindex = fixture->ifindex,
    };
    struct bpf_test_run_opts options = {};
    int error;

    memset(result, 0, sizeof(*result));
    options.sz = sizeof(options);
    options.data_in = fixture->bytes;
    options.data_out = result->bytes;
    options.data_size_in = fixture->length;
    options.data_size_out = sizeof(result->bytes);
    options.ctx_in = &context;
    options.ctx_size_in = sizeof(context);
    options.repeat = 1;
    error = bpf_prog_test_run_opts(program_fd, &options);
    if (error) {
        fprintf(stderr, "bpf_prog_test_run_opts failed: %s\n",
                strerror(error < 0 ? -error : error));
        return -1;
    }
    result->length = options.data_size_out;
    result->action = options.retval;
    return 0;
}

static int install_entry(int map_fd, uint32_t ifindex, const char *request,
                         const char *response, uint64_t expires_ns)
{
    struct udp_fastpath_key key = {};
    struct udp_fastpath_value value = {};

    key.ifindex = ifindex;
    if (parse_ipv4("192.0.2.53", &key.server_ipv4) != 0)
        return -1;
    key.server_port = htons(9000);
    key.request_len = (uint16_t)strlen(request);
    memcpy(key.request, request, key.request_len);
    value.expires_ns = expires_ns;
    value.response_len = (uint16_t)strlen(response);
    value.flags = UDP_FASTPATH_ENTRY_ENABLED;
    memcpy(value.response, response, value.response_len);
    return bpf_map_update_elem(map_fd, &key, &value, BPF_ANY);
}

static int expect_pass_unchanged(const char *name, int program_fd,
                                 const struct packet_fixture *fixture)
{
    struct test_run_result result;

    CHECK(name, run_packet(program_fd, fixture, &result) == 0,
          "program test run failed");
    CHECK(name, result.action == XDP_PASS, "expected XDP_PASS, got %u",
          result.action);
    CHECK(name, result.length == fixture->length, "frame length changed");
    CHECK(name, memcmp(result.bytes, fixture->bytes, fixture->length) == 0,
          "pass path modified packet");
    printf("ok - %s\n", name);
    return 0;
}

static int test_hit(int program_fd)
{
    static const char *name = "exact UDP request returns configured response";
    const uint8_t request[] = "ping";
    const char response[] = "pong-ok";
    struct packet_fixture fixture;
    struct test_run_result result;
    struct ethhdr *eth;
    struct iphdr *ip;
    struct udphdr *udp;
    uint8_t *payload;

    CHECK(name, build_udp_request(&fixture, TEST_IFINDEX_A, request,
                                  sizeof(request) - 1) == 0,
          "failed to build packet");
    CHECK(name, run_packet(program_fd, &fixture, &result) == 0,
          "program test run failed");
    CHECK(name, result.action == XDP_TX, "expected XDP_TX, got %u",
          result.action);
    CHECK(name,
          result.length == sizeof(*eth) + sizeof(*ip) + sizeof(*udp) +
                               sizeof(response) - 1,
          "unexpected response frame length %u", result.length);
    eth = (struct ethhdr *)result.bytes;
    ip = (struct iphdr *)(eth + 1);
    udp = (struct udphdr *)(ip + 1);
    payload = (uint8_t *)(udp + 1);
    CHECK(name, memcmp(eth->h_source, server_mac, ETH_ALEN) == 0 &&
                    memcmp(eth->h_dest, client_mac, ETH_ALEN) == 0,
          "Ethernet addresses were not swapped");
    CHECK(name, udp->source == htons(9000) && udp->dest == htons(41000),
          "UDP ports were not swapped");
    CHECK(name, ntohs(udp->len) == sizeof(*udp) + sizeof(response) - 1,
          "wrong UDP response length");
    CHECK(name, memcmp(payload, response, sizeof(response) - 1) == 0,
          "wrong UDP response payload");
    printf("ok - %s\n", name);
    return 0;
}

static int test_miss(int program_fd)
{
    static const char *name = "unconfigured UDP payload is fail-open";
    const uint8_t request[] = "miss";
    struct packet_fixture fixture;

    CHECK(name, build_udp_request(&fixture, TEST_IFINDEX_A, request,
                                  sizeof(request) - 1) == 0,
          "failed to build packet");
    return expect_pass_unchanged(name, program_fd, &fixture);
}

static int test_ifindex_isolation(int program_fd)
{
    static const char *name = "UDP cache entry is isolated by ingress ifindex";
    const uint8_t request[] = "ping";
    struct packet_fixture fixture;

    CHECK(name, build_udp_request(&fixture, TEST_IFINDEX_B, request,
                                  sizeof(request) - 1) == 0,
          "failed to build packet");
    return expect_pass_unchanged(name, program_fd, &fixture);
}

static int test_expired(int program_fd, int map_fd)
{
    static const char *name = "expired UDP response is fail-open";
    const uint8_t request[] = "old";
    struct packet_fixture fixture;

    CHECK(name, install_entry(map_fd, TEST_IFINDEX_A, "old", "stale", 1) == 0,
          "failed to install expired entry");
    CHECK(name, build_udp_request(&fixture, TEST_IFINDEX_A, request,
                                  sizeof(request) - 1) == 0,
          "failed to build packet");
    return expect_pass_unchanged(name, program_fd, &fixture);
}

static int test_oversized(int program_fd)
{
    static const char *name = "oversized UDP request is fail-open";
    uint8_t request[UDP_FASTPATH_MAX_REQUEST + 1];
    struct packet_fixture fixture;

    memset(request, 'x', sizeof(request));
    CHECK(name, build_udp_request(&fixture, TEST_IFINDEX_A, request,
                                  sizeof(request)) == 0,
          "failed to build packet");
    return expect_pass_unchanged(name, program_fd, &fixture);
}

static int test_malformed_length(int program_fd)
{
    static const char *name = "malformed UDP length is fail-open";
    const uint8_t request[] = "ping";
    struct packet_fixture fixture;
    struct ethhdr *eth;
    struct iphdr *ip;
    struct udphdr *udp;

    CHECK(name, build_udp_request(&fixture, TEST_IFINDEX_A, request,
                                  sizeof(request) - 1) == 0,
          "failed to build packet");
    eth = (struct ethhdr *)fixture.bytes;
    ip = (struct iphdr *)(eth + 1);
    udp = (struct udphdr *)(ip + 1);
    udp->len = htons(ntohs(udp->len) + 1);
    return expect_pass_unchanged(name, program_fd, &fixture);
}

int main(int argc, char **argv)
{
    struct bpf_object *object;
    struct bpf_program *program;
    struct bpf_map *map;
    int program_fd;
    int map_fd;
    int failures = 0;
    int error;

    if (argc != 2) {
        fprintf(stderr, "Usage: %s <bpf_object>\n", argv[0]);
        return 2;
    }
    raise_memlock_limit();
    test_ifindex_a = if_nametoindex("lo");
    test_ifindex_b = resolve_second_ifindex(test_ifindex_a);
    if (!test_ifindex_a || !test_ifindex_b) {
        fprintf(stderr, "need two test interfaces\n");
        return 1;
    }
    object = bpf_object__open_file(argv[1], NULL);
    if (!object) {
        fprintf(stderr, "failed to open %s: %s\n", argv[1], strerror(errno));
        return 1;
    }
    program = bpf_object__find_program_by_name(object, "udp_fastpath_xdp");
    map = bpf_object__find_map_by_name(object, "udp_fastpath_entries");
    if (!program || !map) {
        fprintf(stderr, "UDP program or map not found\n");
        bpf_object__close(object);
        return 1;
    }
    bpf_program__set_type(program, BPF_PROG_TYPE_XDP);
    error = bpf_object__load(object);
    if (error) {
        fprintf(stderr, "failed to load BPF object: %s\n", strerror(-error));
        bpf_object__close(object);
        return 1;
    }
    program_fd = bpf_program__fd(program);
    map_fd = bpf_map__fd(map);
    if (install_entry(map_fd, TEST_IFINDEX_A, "ping", "pong-ok",
                      monotonic_ns() + 60000000000ull) != 0) {
        fprintf(stderr, "failed to install UDP test entry: %s\n",
                strerror(errno));
        bpf_object__close(object);
        return 1;
    }

    failures += test_hit(program_fd) != 0;
    failures += test_miss(program_fd) != 0;
    failures += test_ifindex_isolation(program_fd) != 0;
    failures += test_expired(program_fd, map_fd) != 0;
    failures += test_oversized(program_fd) != 0;
    failures += test_malformed_length(program_fd) != 0;

    bpf_object__close(object);
    if (failures) {
        fprintf(stderr, "%d/6 UDP fast-path tests failed\n", failures);
        return 1;
    }
    printf("6/6 UDP fast-path tests passed\n");
    return 0;
}
