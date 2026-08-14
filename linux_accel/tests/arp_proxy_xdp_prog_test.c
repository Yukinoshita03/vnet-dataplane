#define _GNU_SOURCE

#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <net/if.h>
#include <linux/bpf.h>
#include <linux/if_arp.h>
#include <linux/if_ether.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#include "arp_proxy.h"

enum {
    TEST_FRAME_CAPACITY = 128,
};

static uint32_t test_tap_a;
static uint32_t test_tap_b;

#define TEST_TAP_A test_tap_a
#define TEST_TAP_B test_tap_b

struct test_arp_ipv4 {
    uint16_t hardware_type;
    uint16_t protocol_type;
    uint8_t hardware_length;
    uint8_t protocol_length;
    uint16_t operation;
    uint8_t sender_hardware[ETH_ALEN];
    uint32_t sender_ipv4;
    uint8_t target_hardware[ETH_ALEN];
    uint32_t target_ipv4;
} __attribute__((packed));

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

static const uint8_t vm_a_mac[ETH_ALEN] = {
    0xfa, 0x16, 0x3e, 0x11, 0x22, 0x33,
};
static const uint8_t vm_b_mac[ETH_ALEN] = {
    0xfa, 0x16, 0x3e, 0x44, 0x55, 0x66,
};
static const uint8_t target_a_mac[ETH_ALEN] = {
    0xfa, 0x16, 0x3e, 0xaa, 0xbb, 0xcc,
};
static const uint8_t target_b_mac[ETH_ALEN] = {
    0xfa, 0x16, 0x3e, 0xdd, 0xee, 0xff,
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
        fprintf(stderr, "warning: setrlimit(RLIMIT_MEMLOCK) failed: %s\n",
                strerror(errno));
}

static uint32_t resolve_test_ifindex(const char *environment_name,
                                     const char *default_name,
                                     int skip_loopback)
{
    const char *value = getenv(environment_name);
    char *end = NULL;
    unsigned long parsed;

    if (value && *value) {
        parsed = strtoul(value, &end, 10);
        if (end && *end == '\0' && parsed <= UINT32_MAX)
            return (uint32_t)parsed;
    }

    if (default_name) {
        uint32_t ifindex = if_nametoindex(default_name);

        if (ifindex)
            return ifindex;
    }

    struct if_nameindex *interfaces = if_nameindex();
    if (!interfaces)
        return 0;

    uint32_t result = 0;
    for (struct if_nameindex *entry = interfaces; entry->if_index != 0;
         entry++) {
        if (skip_loopback && strcmp(entry->if_name, "lo") == 0)
            continue;
        result = entry->if_index;
        break;
    }
    if_freenameindex(interfaces);
    return result;
}

static int parse_ipv4(const char *text, __be32 *address)
{
    return inet_pton(AF_INET, text, address) == 1 ? 0 : -1;
}

static int install_tap_state(int map_fd, uint32_t ifindex, uint32_t generation,
                             uint32_t flags, uint64_t expires_ns)
{
    struct arp_tap_key key = {.ifindex = ifindex};
    struct arp_tap_state state = {
        .generation = generation,
        .flags = flags,
        .expires_ns = expires_ns,
    };

    return bpf_map_update_elem(map_fd, &key, &state, BPF_ANY);
}

static int install_binding(int map_fd, uint32_t ifindex, const char *target_ip,
                           const uint8_t target_mac[ETH_ALEN],
                           uint32_t generation, uint64_t expires_ns)
{
    struct arp_binding_key key = {.ifindex = ifindex};
    struct arp_binding_value value = {
        .flags = ARP_BINDING_ENABLED,
        .generation = generation,
        .expires_ns = expires_ns,
    };

    if (parse_ipv4(target_ip, &key.target_ipv4) != 0)
        return -1;
    memcpy(value.target_mac, target_mac, ETH_ALEN);
    return bpf_map_update_elem(map_fd, &key, &value, BPF_ANY);
}

static int build_arp_request(struct packet_fixture *fixture, uint32_t ifindex,
                             const uint8_t source_mac[ETH_ALEN],
                             const char *source_ip, const char *target_ip,
                             uint16_t operation)
{
    static const uint8_t broadcast_mac[ETH_ALEN] = {
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    };
    struct ethhdr eth = {};
    struct test_arp_ipv4 arp = {};
    __be32 source_ipv4;
    __be32 target_ipv4;

    memset(fixture, 0, sizeof(*fixture));
    memcpy(eth.h_dest, broadcast_mac, ETH_ALEN);
    memcpy(eth.h_source, source_mac, ETH_ALEN);
    eth.h_proto = htons(ETH_P_ARP);

    arp.hardware_type = htons(ARPHRD_ETHER);
    arp.protocol_type = htons(ETH_P_IP);
    arp.hardware_length = ETH_ALEN;
    arp.protocol_length = 4;
    arp.operation = htons(operation);
    memcpy(arp.sender_hardware, source_mac, ETH_ALEN);
    if (parse_ipv4(source_ip, &source_ipv4) != 0 ||
        parse_ipv4(target_ip, &target_ipv4) != 0)
        return -1;
    arp.sender_ipv4 = source_ipv4;
    arp.target_ipv4 = target_ipv4;

    memcpy(fixture->bytes, &eth, sizeof(eth));
    memcpy(fixture->bytes + sizeof(eth), &arp, sizeof(arp));
    fixture->length = sizeof(eth) + sizeof(arp);
    fixture->ifindex = ifindex;
    return 0;
}

static int run_packet(int program_fd, const struct packet_fixture *fixture,
                      struct test_run_result *result)
{
    struct xdp_md context = {
        .data = 0,
        .data_end = fixture->length,
        .data_meta = 0,
        .ingress_ifindex = fixture->ifindex,
        .rx_queue_index = 0,
        .egress_ifindex = 0,
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

static int expect_pass_unchanged(const char *test_name, int program_fd,
                                 const struct packet_fixture *fixture)
{
    struct test_run_result result;

    CHECK(test_name, run_packet(program_fd, fixture, &result) == 0,
          "program test run failed");
    CHECK(test_name, result.action == XDP_PASS,
          "expected XDP_PASS (%u), got %u", XDP_PASS, result.action);
    CHECK(test_name, result.length == fixture->length,
          "expected length %u, got %u", fixture->length, result.length);
    CHECK(test_name,
          memcmp(result.bytes, fixture->bytes, fixture->length) == 0,
          "XDP_PASS unexpectedly modified the packet");
    printf("ok - %s\n", test_name);
    return 0;
}

static int test_hit(int program_fd, int binding_map_fd)
{
    static const char *test_name =
        "configured target on tap-A returns an exact ARP Reply";
    struct packet_fixture fixture;
    struct test_run_result result;
    struct ethhdr output_eth;
    struct test_arp_ipv4 output_arp;
    __be32 target_ip;
    __be32 source_ip;

    CHECK(test_name,
          build_arp_request(&fixture, TEST_TAP_A, vm_a_mac, "10.0.0.5",
                            "10.0.0.1", ARPOP_REQUEST) == 0,
          "failed to build request");
    CHECK(test_name, run_packet(program_fd, &fixture, &result) == 0,
          "program test run failed");
    CHECK(test_name, result.action == XDP_TX,
          "expected XDP_TX (%u), got %u", XDP_TX, result.action);
    CHECK(test_name, result.length == fixture.length,
          "ARP reply changed frame length");

    memcpy(&output_eth, result.bytes, sizeof(output_eth));
    memcpy(&output_arp, result.bytes + sizeof(output_eth), sizeof(output_arp));
    CHECK(test_name, memcmp(output_eth.h_dest, vm_a_mac, ETH_ALEN) == 0,
          "reply Ethernet destination is not the request source");
    CHECK(test_name, memcmp(output_eth.h_source, target_a_mac, ETH_ALEN) == 0,
          "reply Ethernet source is not the binding MAC");
    CHECK(test_name, output_arp.operation == htons(ARPOP_REPLY),
          "ARP operation is not Reply");
    CHECK(test_name,
          memcmp(output_arp.sender_hardware, target_a_mac, ETH_ALEN) == 0,
          "ARP sender MAC is incorrect");
    CHECK(test_name,
          memcmp(output_arp.target_hardware, vm_a_mac, ETH_ALEN) == 0,
          "ARP target MAC is incorrect");
    CHECK(test_name, parse_ipv4("10.0.0.1", &target_ip) == 0 &&
                         parse_ipv4("10.0.0.5", &source_ip) == 0,
          "failed to parse expected addresses");
    CHECK(test_name, output_arp.sender_ipv4 == target_ip &&
                         output_arp.target_ipv4 == source_ip,
          "ARP sender/target IPs are incorrect");

    (void)binding_map_fd;
    printf("ok - %s\n", test_name);
    return 0;
}

static int test_tap_isolation(int program_fd)
{
    static const char *test_name =
        "same target IP on tap-B uses tap-B binding";
    struct packet_fixture fixture;
    struct test_run_result result;
    struct ethhdr output_eth;

    CHECK(test_name,
          build_arp_request(&fixture, TEST_TAP_B, vm_b_mac, "10.1.0.5",
                            "10.0.0.1", ARPOP_REQUEST) == 0,
          "failed to build request");
    CHECK(test_name, run_packet(program_fd, &fixture, &result) == 0,
          "program test run failed");
    CHECK(test_name, result.action == XDP_TX,
          "expected XDP_TX (%u), got %u", XDP_TX, result.action);
    memcpy(&output_eth, result.bytes, sizeof(output_eth));
    CHECK(test_name, memcmp(output_eth.h_source, target_b_mac, ETH_ALEN) == 0,
          "tap-B used tap-A target MAC");
    printf("ok - %s\n", test_name);
    return 0;
}

static int test_multi_target(int program_fd)
{
    static const char *test_name =
        "tap-A supports a second independently configured target";
    struct packet_fixture fixture;
    struct test_run_result result;
    struct ethhdr output_eth;
    struct test_arp_ipv4 output_arp;

    CHECK(test_name,
          build_arp_request(&fixture, TEST_TAP_A, vm_a_mac, "10.0.0.5",
                            "10.0.0.2", ARPOP_REQUEST) == 0,
          "failed to build request");
    CHECK(test_name, run_packet(program_fd, &fixture, &result) == 0,
          "program test run failed");
    CHECK(test_name, result.action == XDP_TX,
          "expected XDP_TX (%u), got %u", XDP_TX, result.action);
    memcpy(&output_eth, result.bytes, sizeof(output_eth));
    memcpy(&output_arp, result.bytes + sizeof(output_eth), sizeof(output_arp));
    CHECK(test_name, memcmp(output_eth.h_source, target_b_mac, ETH_ALEN) == 0,
          "second target did not use its own binding MAC");
    CHECK(test_name,
          memcmp(output_arp.sender_hardware, target_b_mac, ETH_ALEN) == 0,
          "second target ARP sender MAC is incorrect");
    printf("ok - %s\n", test_name);
    return 0;
}

static int test_target_miss(int program_fd)
{
    static const char *test_name = "unconfigured target returns XDP_PASS";
    struct packet_fixture fixture;

    CHECK(test_name,
          build_arp_request(&fixture, TEST_TAP_A, vm_a_mac, "10.0.0.5",
                            "10.0.0.99", ARPOP_REQUEST) == 0,
          "failed to build request");
    return expect_pass_unchanged(test_name, program_fd, &fixture);
}

static int test_disabled_tap(int program_fd, int tap_map_fd)
{
    static const char *test_name = "disabled tap returns XDP_PASS";
    struct packet_fixture fixture;

    CHECK(test_name,
          install_tap_state(tap_map_fd, TEST_TAP_A, 7, 0,
                            monotonic_ns() + 60000000000ull) == 0,
          "failed to disable tap policy");
    CHECK(test_name,
          build_arp_request(&fixture, TEST_TAP_A, vm_a_mac, "10.0.0.5",
                            "10.0.0.1", ARPOP_REQUEST) == 0,
          "failed to build request");
    return expect_pass_unchanged(test_name, program_fd, &fixture);
}

static int test_expired_tap(int program_fd, int tap_map_fd)
{
    static const char *test_name = "expired tap policy returns XDP_PASS";
    struct packet_fixture fixture;

    CHECK(test_name,
          install_tap_state(tap_map_fd, TEST_TAP_A, 7, ARP_TAP_ENABLED, 1) ==
              0,
          "failed to expire tap policy");
    CHECK(test_name,
          build_arp_request(&fixture, TEST_TAP_A, vm_a_mac, "10.0.0.5",
                            "10.0.0.1", ARPOP_REQUEST) == 0,
          "failed to build request");
    return expect_pass_unchanged(test_name, program_fd, &fixture);
}

static int test_source_mismatch(int program_fd, int tap_map_fd)
{
    static const char *test_name = "Ethernet/ARP source mismatch returns XDP_PASS";
    struct packet_fixture fixture;
    struct test_arp_ipv4 *arp;

    CHECK(test_name,
          install_tap_state(tap_map_fd, TEST_TAP_A, 7, ARP_TAP_ENABLED,
                            monotonic_ns() + 60000000000ull) == 0,
          "failed to restore tap policy");
    CHECK(test_name,
          build_arp_request(&fixture, TEST_TAP_A, vm_a_mac, "10.0.0.5",
                            "10.0.0.1", ARPOP_REQUEST) == 0,
          "failed to build request");
    arp = (struct test_arp_ipv4 *)(fixture.bytes + sizeof(struct ethhdr));
    arp->sender_hardware[0] ^= 1;
    return expect_pass_unchanged(test_name, program_fd, &fixture);
}

static int test_non_request(int program_fd)
{
    static const char *test_name = "ARP Reply input returns XDP_PASS";
    struct packet_fixture fixture;

    CHECK(test_name,
          build_arp_request(&fixture, TEST_TAP_A, vm_a_mac, "10.0.0.5",
                            "10.0.0.1", ARPOP_REPLY) == 0,
          "failed to build packet");
    return expect_pass_unchanged(test_name, program_fd, &fixture);
}

static int test_invalid_source_mac(int program_fd)
{
    static const char *test_name =
        "zero source MAC returns XDP_PASS without modification";
    struct packet_fixture fixture;
    struct ethhdr *eth;
    struct test_arp_ipv4 *arp;

    CHECK(test_name,
          build_arp_request(&fixture, TEST_TAP_A, vm_a_mac, "10.0.0.5",
                            "10.0.0.1", ARPOP_REQUEST) == 0,
          "failed to build request");
    eth = (struct ethhdr *)fixture.bytes;
    arp = (struct test_arp_ipv4 *)(fixture.bytes + sizeof(*eth));
    memset(eth->h_source, 0, ETH_ALEN);
    memset(arp->sender_hardware, 0, ETH_ALEN);
    return expect_pass_unchanged(test_name, program_fd, &fixture);
}

static int test_invalid_sender_ip(int program_fd)
{
    static const char *test_name =
        "zero sender IP returns XDP_PASS without modification";
    struct packet_fixture fixture;
    struct test_arp_ipv4 *arp;

    CHECK(test_name,
          build_arp_request(&fixture, TEST_TAP_A, vm_a_mac, "10.0.0.5",
                            "10.0.0.1", ARPOP_REQUEST) == 0,
          "failed to build request");
    arp = (struct test_arp_ipv4 *)(fixture.bytes + sizeof(struct ethhdr));
    arp->sender_ipv4 = 0;
    return expect_pass_unchanged(test_name, program_fd, &fixture);
}

static int test_non_broadcast_request(int program_fd)
{
    static const char *test_name =
        "non-broadcast ARP request returns XDP_PASS without modification";
    struct packet_fixture fixture;
    struct ethhdr *eth;

    CHECK(test_name,
          build_arp_request(&fixture, TEST_TAP_A, vm_a_mac, "10.0.0.5",
                            "10.0.0.1", ARPOP_REQUEST) == 0,
          "failed to build request");
    eth = (struct ethhdr *)fixture.bytes;
    memcpy(eth->h_dest, target_a_mac, ETH_ALEN);
    return expect_pass_unchanged(test_name, program_fd, &fixture);
}

static int test_invalid_format(int program_fd)
{
    static const char *test_name =
        "non-Ethernet ARP format returns XDP_PASS without modification";
    struct packet_fixture fixture;
    struct test_arp_ipv4 *arp;

    CHECK(test_name,
          build_arp_request(&fixture, TEST_TAP_A, vm_a_mac, "10.0.0.5",
                            "10.0.0.1", ARPOP_REQUEST) == 0,
          "failed to build request");
    arp = (struct test_arp_ipv4 *)(fixture.bytes + sizeof(struct ethhdr));
    arp->hardware_length = 8;
    return expect_pass_unchanged(test_name, program_fd, &fixture);
}

static int test_truncated(int program_fd)
{
    static const char *test_name = "truncated ARP input returns XDP_PASS";
    struct packet_fixture fixture;

    CHECK(test_name,
          build_arp_request(&fixture, TEST_TAP_A, vm_a_mac, "10.0.0.5",
                            "10.0.0.1", ARPOP_REQUEST) == 0,
          "failed to build request");
    fixture.length -= 1;
    return expect_pass_unchanged(test_name, program_fd, &fixture);
}

static int find_map_fd(struct bpf_object *object, const char *name)
{
    struct bpf_map *map = bpf_object__find_map_by_name(object, name);

    if (!map) {
        fprintf(stderr, "map %s was not found\n", name);
        return -1;
    }
    return bpf_map__fd(map);
}

int main(int argc, char **argv)
{
    struct bpf_program *program;
    struct bpf_object *object;
    uint64_t expires_ns;
    int tap_map_fd;
    int binding_map_fd;
    int program_fd;
    int failures = 0;
    int error;

    if (argc != 3) {
        fprintf(stderr, "Usage: %s <bpf_object> <program_name>\n", argv[0]);
        return 2;
    }

    raise_memlock_limit();
    test_tap_a = resolve_test_ifindex("ARP_TEST_IFINDEX_A", "lo", 0);
    test_tap_b = resolve_test_ifindex("ARP_TEST_IFINDEX_B", "eth0", 1);
    if (!test_tap_a || !test_tap_b || test_tap_a == test_tap_b) {
        fprintf(stderr, "need two distinct test interfaces (got %u and %u)\n",
                test_tap_a, test_tap_b);
        return 1;
    }

    object = bpf_object__open_file(argv[1], NULL);
    if (!object) {
        fprintf(stderr, "failed to open BPF object %s: %s\n", argv[1],
                strerror(errno));
        return 1;
    }

    program = bpf_object__find_program_by_name(object, argv[2]);
    if (!program) {
        fprintf(stderr, "program %s was not found\n", argv[2]);
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

    tap_map_fd = find_map_fd(object, "arp_tap_states");
    binding_map_fd = find_map_fd(object, "arp_bindings");
    if (tap_map_fd < 0 || binding_map_fd < 0) {
        bpf_object__close(object);
        return 1;
    }

    expires_ns = monotonic_ns() + 60000000000ull;
    if (install_tap_state(tap_map_fd, TEST_TAP_A, 7, ARP_TAP_ENABLED,
                          expires_ns) != 0 ||
        install_tap_state(tap_map_fd, TEST_TAP_B, 3, ARP_TAP_ENABLED,
                          expires_ns) != 0 ||
        install_binding(binding_map_fd, TEST_TAP_A, "10.0.0.1", target_a_mac,
                        7, expires_ns) != 0 ||
        install_binding(binding_map_fd, TEST_TAP_A, "10.0.0.2", target_b_mac,
                        7, expires_ns) != 0 ||
        install_binding(binding_map_fd, TEST_TAP_B, "10.0.0.1", target_b_mac,
                        3, expires_ns) != 0) {
        fprintf(stderr, "failed to install ARP test policy: %s\n",
                strerror(errno));
        bpf_object__close(object);
        return 1;
    }

    program_fd = bpf_program__fd(program);
    failures += test_hit(program_fd, binding_map_fd) != 0;
    failures += test_tap_isolation(program_fd) != 0;
    failures += test_multi_target(program_fd) != 0;
    failures += test_target_miss(program_fd) != 0;
    failures += test_disabled_tap(program_fd, tap_map_fd) != 0;
    failures += test_expired_tap(program_fd, tap_map_fd) != 0;
    failures += test_source_mismatch(program_fd, tap_map_fd) != 0;
    failures += test_non_request(program_fd) != 0;
    failures += test_invalid_source_mac(program_fd) != 0;
    failures += test_invalid_sender_ip(program_fd) != 0;
    failures += test_non_broadcast_request(program_fd) != 0;
    failures += test_invalid_format(program_fd) != 0;
    failures += test_truncated(program_fd) != 0;

    bpf_object__close(object);
    if (failures) {
        fprintf(stderr, "%d/13 ARP proxy program tests failed\n", failures);
        return 1;
    }

    printf("13/13 ARP proxy program tests passed for %s\n", argv[2]);
    return 0;
}
