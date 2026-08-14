#define _GNU_SOURCE

#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <net/if.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#include "dhcp_relay.h"

enum {
    TEST_FRAME_CAPACITY = 1024,
    TEST_DHCP_OPTIONS_LENGTH = 4,
    TEST_DHCP_XID = 0x12345678,
};

static uint32_t test_client_ifindex;
static uint32_t test_relay_ifindex;
static uint32_t test_unknown_ifindex;

#define TEST_CLIENT_IFINDEX test_client_ifindex
#define TEST_RELAY_IFINDEX test_relay_ifindex

struct test_bootp_fixed {
    uint8_t op;
    uint8_t htype;
    uint8_t hlen;
    uint8_t hops;
    uint32_t xid;
    uint16_t secs;
    uint16_t flags;
    uint32_t ciaddr;
    uint32_t yiaddr;
    uint32_t siaddr;
    uint32_t giaddr;
    uint8_t chaddr[16];
    uint8_t sname[64];
    uint8_t file[128];
    uint32_t magic_cookie;
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

static const uint8_t client_mac[ETH_ALEN] = {
    0xfa, 0x16, 0x3e, 0x11, 0x22, 0x33,
};
static const uint8_t relay_mac[ETH_ALEN] = {
    0xfa, 0x16, 0x3e, 0xaa, 0xbb, 0xcc,
};
static const uint8_t server_mac[ETH_ALEN] = {
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

static uint16_t ipv4_checksum(const uint8_t *bytes, size_t length)
{
    uint32_t sum = 0;

    while (length >= 2) {
        sum += ((uint16_t)bytes[0] << 8) | bytes[1];
        bytes += 2;
        length -= 2;
    }
    if (length)
        sum += (uint16_t)bytes[0] << 8;
    while (sum >> 16)
        sum = (sum & 0xffffu) + (sum >> 16);
    return htons((uint16_t)~sum);
}

static int ipv4_checksum_valid(const uint8_t *bytes, size_t length)
{
    uint32_t sum = 0;

    while (length >= 2) {
        sum += ((uint16_t)bytes[0] << 8) | bytes[1];
        bytes += 2;
        length -= 2;
    }
    if (length)
        sum += (uint16_t)bytes[0] << 8;
    while (sum >> 16)
        sum = (sum & 0xffffu) + (sum >> 16);
    return sum == 0xffffu;
}

static int parse_ipv4(const char *text, __be32 *address)
{
    return inet_pton(AF_INET, text, address) == 1 ? 0 : -1;
}

static int build_packet(struct packet_fixture *fixture, uint32_t ifindex,
                        int response, uint8_t message_type)
{
    static const uint8_t broadcast_mac[ETH_ALEN] = {
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    };
    struct ethhdr eth = {};
    struct iphdr ip = {};
    struct udphdr udp = {};
    struct test_bootp_fixed bootp = {};
    const size_t payload_length = sizeof(bootp) + TEST_DHCP_OPTIONS_LENGTH;
    const size_t udp_length = sizeof(udp) + payload_length;
    const size_t ip_length = sizeof(ip) + udp_length;
    size_t offset = 0;
    __be32 address;

    if (sizeof(eth) + ip_length > sizeof(fixture->bytes))
        return -1;
    memset(fixture, 0, sizeof(*fixture));
    fixture->ifindex = ifindex;

    memcpy(eth.h_dest, response ? relay_mac : broadcast_mac, ETH_ALEN);
    memcpy(eth.h_source, response ? server_mac : client_mac, ETH_ALEN);
    eth.h_proto = htons(ETH_P_IP);

    ip.version = 4;
    ip.ihl = 5;
    ip.tot_len = htons((uint16_t)ip_length);
    ip.id = htons(0x4142);
    ip.ttl = 64;
    ip.protocol = IPPROTO_UDP;
    if (parse_ipv4(response ? "192.0.2.2" : "0.0.0.0", &ip.saddr) != 0 ||
        parse_ipv4(response ? "192.0.2.1" : "255.255.255.255", &ip.daddr) !=
            0)
        return -1;

    udp.source = htons(response ? 67 : 68);
    udp.dest = htons(67);
    udp.len = htons((uint16_t)udp_length);

    bootp.op = response ? 2 : 1;
    bootp.htype = 1;
    bootp.hlen = 6;
    bootp.xid = htonl(TEST_DHCP_XID);
    bootp.flags = response ? htons(0) : htons(0x8000);
    memcpy(bootp.chaddr, client_mac, ETH_ALEN);
    if (response) {
        if (parse_ipv4("192.0.2.100", &address) != 0)
            return -1;
        bootp.yiaddr = address;
        if (parse_ipv4("192.0.2.1", &address) != 0)
            return -1;
        bootp.giaddr = address;
    }
    bootp.magic_cookie = htonl(0x63825363);

    ip.check = ipv4_checksum((const uint8_t *)&ip, sizeof(ip));
    memcpy(fixture->bytes + offset, &eth, sizeof(eth));
    offset += sizeof(eth);
    memcpy(fixture->bytes + offset, &ip, sizeof(ip));
    offset += sizeof(ip);
    memcpy(fixture->bytes + offset, &udp, sizeof(udp));
    offset += sizeof(udp);
    memcpy(fixture->bytes + offset, &bootp, sizeof(bootp));
    offset += sizeof(bootp);
    fixture->bytes[offset++] = 53;
    fixture->bytes[offset++] = 1;
    fixture->bytes[offset++] = message_type;
    fixture->bytes[offset++] = 255;
    fixture->length = (uint32_t)offset;
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
    LIBBPF_OPTS(bpf_test_run_opts, options,
        .data_in = fixture->bytes,
        .data_out = result->bytes,
        .data_size_in = fixture->length,
        .data_size_out = sizeof(result->bytes),
        .ctx_in = &context,
        .ctx_size_in = sizeof(context),
        .repeat = 1,
    );
    memset(result, 0, sizeof(*result));
    int error = bpf_prog_test_run_opts(program_fd, &options);
    if (error) {
        fprintf(stderr, "bpf_prog_test_run_opts failed: %s\n",
                strerror(error < 0 ? -error : error));
        return -1;
    }
    result->length = options.data_size_out;
    result->action = options.retval;
    return 0;
}

static void raise_memlock_limit(void)
{
    const struct rlimit limit = {RLIM_INFINITY, RLIM_INFINITY};

    if (setrlimit(RLIMIT_MEMLOCK, &limit) && errno != EPERM)
        fprintf(stderr, "warning: setrlimit failed: %s\n", strerror(errno));
}

static int install_policy(int map_fd, uint64_t expires_ns)
{
    struct dhcp_relay_policy_key key = {
        .client_ifindex = TEST_CLIENT_IFINDEX,
    };
    struct dhcp_relay_policy value = {
        .relay_ifindex = TEST_RELAY_IFINDEX,
        .flags = DHCP_RELAY_POLICY_ENABLED,
        .generation = 1,
        .expires_ns = expires_ns,
    };

    if (parse_ipv4("192.0.2.1", &value.relay_ipv4) != 0 ||
        parse_ipv4("192.0.2.2", &value.server_ipv4) != 0)
        return -1;
    memcpy(value.relay_mac, relay_mac, ETH_ALEN);
    memcpy(value.server_mac, server_mac, ETH_ALEN);
    return bpf_map_update_elem(map_fd, &key, &value, BPF_ANY);
}

static int expect_pass_unchanged(const char *name, int program_fd,
                                 const struct packet_fixture *fixture)
{
    struct test_run_result result;

    CHECK(name, run_packet(program_fd, fixture, &result) == 0,
          "program test run failed");
    CHECK(name, result.action == XDP_PASS,
          "expected XDP_PASS (%u), got %u", XDP_PASS, result.action);
    CHECK(name, result.length == fixture->length,
          "expected length %u, got %u", fixture->length, result.length);
    CHECK(name, memcmp(result.bytes, fixture->bytes, fixture->length) == 0,
          "XDP_PASS modified packet");
    printf("ok - %s\n", name);
    return 0;
}

static int test_request_redirect(int program_fd)
{
    const char *name = "DHCPDISCOVER is rewritten and redirected to relay";
    struct packet_fixture fixture;
    struct test_run_result result;
    struct ethhdr eth;
    struct iphdr ip;
    struct udphdr udp;
    struct test_bootp_fixed bootp;
    const size_t ip_offset = sizeof(struct ethhdr);
    const size_t udp_offset = ip_offset + sizeof(struct iphdr);
    const size_t bootp_offset = udp_offset + sizeof(struct udphdr);

    CHECK(name, build_packet(&fixture, TEST_CLIENT_IFINDEX, 0, 1) == 0,
          "failed to build request");
    CHECK(name, run_packet(program_fd, &fixture, &result) == 0,
          "program test run failed");
    CHECK(name, result.action == XDP_REDIRECT,
          "expected XDP_REDIRECT (%u), got %u", XDP_REDIRECT, result.action);
    CHECK(name, result.length == fixture.length, "frame length changed");
    memcpy(&eth, result.bytes, sizeof(eth));
    memcpy(&ip, result.bytes + ip_offset, sizeof(ip));
    memcpy(&udp, result.bytes + udp_offset, sizeof(udp));
    memcpy(&bootp, result.bytes + bootp_offset, sizeof(bootp));
    CHECK(name, memcmp(eth.h_dest, server_mac, ETH_ALEN) == 0,
          "server MAC not installed");
    CHECK(name, memcmp(eth.h_source, relay_mac, ETH_ALEN) == 0,
          "relay MAC not installed");
    CHECK(name, ip.saddr == inet_addr("192.0.2.1") &&
                     ip.daddr == inet_addr("192.0.2.2"),
          "relay/server IPv4 addresses are wrong");
    CHECK(name, udp.source == htons(67) && udp.dest == htons(67),
          "relay UDP ports are wrong");
    CHECK(name, bootp.giaddr == inet_addr("192.0.2.1") && bootp.hops == 1,
          "BOOTP relay fields are wrong");
    CHECK(name, ipv4_checksum_valid(result.bytes + ip_offset, sizeof(ip)),
          "rewritten IPv4 checksum is invalid");
    printf("ok - %s\n", name);
    return 0;
}

static int test_response_redirect(int program_fd, int transaction_map_fd,
                                  uint8_t message_type, const char *name)
{
    struct packet_fixture fixture;
    struct test_run_result result;
    struct ethhdr eth;
    struct iphdr ip;
    struct udphdr udp;
    struct test_bootp_fixed bootp;
    struct dhcp_relay_transaction_key key = {
        .relay_ifindex = TEST_RELAY_IFINDEX,
        .xid = htonl(TEST_DHCP_XID),
    };
    const size_t ip_offset = sizeof(struct ethhdr);
    const size_t udp_offset = ip_offset + sizeof(struct iphdr);
    const size_t bootp_offset = udp_offset + sizeof(struct udphdr);
    uint8_t value[sizeof(struct dhcp_relay_transaction)];

    memcpy(key.client_mac, client_mac, ETH_ALEN);
    CHECK(name, build_packet(&fixture, TEST_RELAY_IFINDEX, 1, message_type) ==
                     0,
          "failed to build response");
    CHECK(name, run_packet(program_fd, &fixture, &result) == 0,
          "program test run failed");
    CHECK(name, result.action == XDP_REDIRECT,
          "expected XDP_REDIRECT (%u), got %u", XDP_REDIRECT, result.action);
    memcpy(&eth, result.bytes, sizeof(eth));
    memcpy(&ip, result.bytes + ip_offset, sizeof(ip));
    memcpy(&udp, result.bytes + udp_offset, sizeof(udp));
    memcpy(&bootp, result.bytes + bootp_offset, sizeof(bootp));
    CHECK(name, memcmp(eth.h_dest, client_mac, ETH_ALEN) == 0,
          "client MAC not restored");
    CHECK(name, memcmp(eth.h_source, relay_mac, ETH_ALEN) == 0,
          "relay source MAC not restored");
    CHECK(name, ip.daddr == inet_addr("192.0.2.100"),
          "yiaddr was not selected as response destination");
    CHECK(name, udp.source == htons(67) && udp.dest == htons(68),
          "client UDP ports are wrong");
    CHECK(name, bootp.giaddr == 0 && bootp.hops == 0,
          "BOOTP relay fields were not cleared");
    CHECK(name, ipv4_checksum_valid(result.bytes + ip_offset, sizeof(ip)),
          "response IPv4 checksum is invalid");
    if (message_type == 5) {
        CHECK(name, bpf_map_lookup_elem(transaction_map_fd, &key, value) != 0 &&
                         errno == ENOENT,
              "ACK did not remove transaction state");
    } else {
        CHECK(name, bpf_map_lookup_elem(transaction_map_fd, &key, value) == 0,
              "OFFER removed transaction state too early");
    }
    printf("ok - %s\n", name);
    return 0;
}

static int test_broadcast_response(int program_fd, const char *name)
{
    static const uint8_t broadcast_mac[ETH_ALEN] = {
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    };
    struct packet_fixture fixture;
    struct test_run_result result;
    struct test_bootp_fixed bootp;
    struct ethhdr eth;
    struct iphdr ip;
    const size_t bootp_offset = sizeof(struct ethhdr) + sizeof(struct iphdr) +
                                sizeof(struct udphdr);

    CHECK(name, build_packet(&fixture, TEST_CLIENT_IFINDEX, 0, 1) == 0,
          "failed to build request");
    CHECK(name, run_packet(program_fd, &fixture, &result) == 0,
          "request program test run failed");
    CHECK(name, result.action == XDP_REDIRECT,
          "request did not install a transaction");

    CHECK(name, build_packet(&fixture, TEST_RELAY_IFINDEX, 1, 2) == 0,
          "failed to build broadcast response");
    memcpy(&bootp, fixture.bytes + bootp_offset, sizeof(bootp));
    bootp.flags = htons(DHCP_RELAY_BOOTP_BROADCAST);
    memcpy(fixture.bytes + bootp_offset, &bootp, sizeof(bootp));
    CHECK(name, run_packet(program_fd, &fixture, &result) == 0,
          "response program test run failed");
    CHECK(name, result.action == XDP_REDIRECT,
          "expected broadcast response redirect");
    memcpy(&eth, result.bytes, sizeof(eth));
    memcpy(&ip, result.bytes + sizeof(struct ethhdr), sizeof(ip));
    CHECK(name, memcmp(eth.h_dest, broadcast_mac, ETH_ALEN) == 0,
          "broadcast response did not use broadcast Ethernet destination");
    CHECK(name, ip.daddr == inet_addr("255.255.255.255"),
          "broadcast response did not use IPv4 broadcast destination");
    printf("ok - %s\n", name);
    return 0;
}

int main(int argc, char **argv)
{
    struct bpf_object *object;
    struct bpf_program *program;
    struct bpf_map *policy_map;
    struct bpf_map *transaction_map;
    struct packet_fixture fixture;
    int program_fd;
    int policy_map_fd;
    int transaction_map_fd;

    if (argc != 2) {
        fprintf(stderr, "usage: %s dns_xdp_monitor.bpf.o\n", argv[0]);
        return 2;
    }
    test_client_ifindex = if_nametoindex("lo");
    test_relay_ifindex = if_nametoindex("enp3s0");
    if (!test_relay_ifindex)
        test_relay_ifindex = test_client_ifindex;
    test_unknown_ifindex = test_relay_ifindex;
    if (test_unknown_ifindex == test_client_ifindex)
        test_unknown_ifindex = if_nametoindex("br-int");
    if (test_unknown_ifindex == test_client_ifindex)
        test_unknown_ifindex = if_nametoindex("ovs-system");
    if (!test_client_ifindex || !test_relay_ifindex ||
        !test_unknown_ifindex || test_unknown_ifindex == test_client_ifindex) {
        fprintf(stderr, "failed to resolve test redirect interfaces\n");
        return 1;
    }
    raise_memlock_limit();
    libbpf_set_strict_mode(LIBBPF_STRICT_ALL);
    object = bpf_object__open_file(argv[1], NULL);
    if (!object) {
        fprintf(stderr, "failed to open BPF object: %s\n", argv[1]);
        return 1;
    }
    program = bpf_object__find_program_by_name(object, "dns_xdp_monitor");
    policy_map =
        bpf_object__find_map_by_name(object, "dhcp_relay_policies");
    transaction_map =
        bpf_object__find_map_by_name(object, "dhcp_relay_transactions");
    if (!program || !policy_map || !transaction_map) {
        fprintf(stderr, "DHCP program or maps are missing\n");
        bpf_object__close(object);
        return 1;
    }
    bpf_program__set_type(program, BPF_PROG_TYPE_XDP);
    if (bpf_object__load(object) != 0) {
        fprintf(stderr, "failed to load BPF object\n");
        bpf_object__close(object);
        return 1;
    }
    program_fd = bpf_program__fd(program);
    policy_map_fd = bpf_map__fd(policy_map);
    transaction_map_fd = bpf_map__fd(transaction_map);
    if (install_policy(policy_map_fd, monotonic_ns() + 30ull * 1000000000ull) !=
        0) {
        fprintf(stderr, "failed to install DHCP test policy: %s\n",
                strerror(errno));
        bpf_object__close(object);
        return 1;
    }

    if (test_request_redirect(program_fd) != 0 ||
        test_broadcast_response(
            program_fd, "DHCP broadcast response uses broadcast L2/L3") != 0 ||
        test_response_redirect(program_fd, transaction_map_fd, 2,
                               "DHCPOFFER is redirected back to client") != 0 ||
        test_response_redirect(program_fd, transaction_map_fd, 5,
                               "DHCPACK is redirected and retires transaction") !=
            0 ||
        build_packet(&fixture, test_unknown_ifindex, 0, 1) != 0 ||
        expect_pass_unchanged("unknown client interface fails open", program_fd,
                              &fixture) != 0 ||
        build_packet(&fixture, TEST_CLIENT_IFINDEX, 0, 1) != 0) {
        bpf_object__close(object);
        return 1;
    }
    fixture.bytes[sizeof(struct ethhdr) + sizeof(struct iphdr) +
                  sizeof(struct udphdr) + offsetof(struct test_bootp_fixed,
                                                   magic_cookie)] = 0;
    if (expect_pass_unchanged("invalid DHCP cookie fails open", program_fd,
                              &fixture) != 0) {
        bpf_object__close(object);
        return 1;
    }
    if (install_policy(policy_map_fd, 1) != 0 ||
        build_packet(&fixture, TEST_CLIENT_IFINDEX, 0, 1) != 0 ||
        expect_pass_unchanged("expired relay policy fails open", program_fd,
                              &fixture) != 0) {
        bpf_object__close(object);
        return 1;
    }
    printf("DHCP XDP tests passed\n");
    bpf_object__close(object);
    return 0;
}
