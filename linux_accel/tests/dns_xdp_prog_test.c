#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>

#include "dns_event.h"

enum {
    TEST_DNS_PORT = 53,
    TEST_CLIENT_PORT = 53000,
    TEST_FRAME_CAPACITY = 512,
    TEST_DNS_ANSWER_LEN = 16,
    TEST_DNS_AAAA_ANSWER_LEN = 28,
    TEST_DNS_HTTPS_ANSWER_LEN = 15,
};

struct dns_wire_header {
    uint16_t id;
    uint16_t flags;
    uint16_t qdcount;
    uint16_t ancount;
    uint16_t nscount;
    uint16_t arcount;
} __attribute__((packed));

struct packet_fixture {
    uint8_t bytes[TEST_FRAME_CAPACITY];
    uint32_t length;
};

struct test_run_result {
    uint8_t bytes[TEST_FRAME_CAPACITY];
    uint32_t length;
    uint32_t action;
};

static const uint8_t example_qname[] = {
    7, 'e', 'x', 'a', 'm', 'p', 'l', 'e',
    4, 't', 'e', 's', 't', 0,
};

static const uint8_t missing_qname[] = {
    7, 'm', 'i', 's', 's', 'i', 'n', 'g',
    4, 't', 'e', 's', 't', 0,
};

static const uint8_t aaaa_qname[] = {
    4, 'i', 'p', 'v', '6',
    4, 't', 'e', 's', 't', 0,
};

static const uint8_t https_qname[] = {
    5, 'h', 't', 't', 'p', 's',
    4, 't', 'e', 's', 't', 0,
};

#define CHECK(test_name, condition, ...)                                    \
    do {                                                                    \
        if (!(condition)) {                                                 \
            fprintf(stderr, "not ok - %s: ", (test_name));                 \
            fprintf(stderr, __VA_ARGS__);                                   \
            fputc('\n', stderr);                                            \
            return -1;                                                      \
        }                                                                   \
    } while (0)

static uint16_t ipv4_checksum_wire(const uint8_t *bytes, size_t length)
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

static int ipv4_checksum_is_valid(const uint8_t *bytes, size_t length)
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

static int build_query_type(struct packet_fixture *fixture,
                            const uint8_t *qname, size_t qname_length,
                            uint16_t qtype, uint16_t source_port,
                            uint16_t destination_port, uint16_t dns_flags,
                            int udp_length_adjustment)
{
    static const uint8_t destination_mac[ETH_ALEN] = {
        0x02, 0x00, 0x00, 0x00, 0x00, 0x53,
    };
    static const uint8_t source_mac[ETH_ALEN] = {
        0x02, 0x00, 0x00, 0x00, 0x00, 0x02,
    };
    const uint8_t question_type_class[4] = {
        (uint8_t)(qtype >> 8), (uint8_t)qtype, 0x00, 0x01,
    };
    const size_t dns_length = sizeof(struct dns_wire_header) + qname_length +
                              sizeof(question_type_class);
    const size_t udp_length = sizeof(struct udphdr) + dns_length;
    const size_t ip_length = sizeof(struct iphdr) + udp_length;
    const size_t frame_length = sizeof(struct ethhdr) + ip_length;
    struct dns_wire_header dns = {};
    struct ethhdr eth = {};
    struct iphdr ip = {};
    struct udphdr udp = {};
    size_t offset = 0;

    if (frame_length > sizeof(fixture->bytes) ||
        (int)udp_length + udp_length_adjustment <= 0)
        return -1;

    memset(fixture, 0, sizeof(*fixture));
    memcpy(eth.h_dest, destination_mac, sizeof(destination_mac));
    memcpy(eth.h_source, source_mac, sizeof(source_mac));
    eth.h_proto = htons(ETH_P_IP);

    ip.version = 4;
    ip.ihl = 5;
    ip.tot_len = htons((uint16_t)ip_length);
    ip.id = htons(0x4242);
    ip.ttl = 64;
    ip.protocol = IPPROTO_UDP;
    if (inet_pton(AF_INET, "192.0.2.10", &ip.saddr) != 1 ||
        inet_pton(AF_INET, "192.0.2.53", &ip.daddr) != 1)
        return -1;
    ip.check = 0;
    ip.check = ipv4_checksum_wire((const uint8_t *)&ip, sizeof(ip));

    udp.source = htons(source_port);
    udp.dest = htons(destination_port);
    udp.len = htons((uint16_t)((int)udp_length + udp_length_adjustment));
    udp.check = 0;

    dns.id = htons(0x1234);
    dns.flags = htons(dns_flags);
    dns.qdcount = htons(1);

    memcpy(fixture->bytes + offset, &eth, sizeof(eth));
    offset += sizeof(eth);
    memcpy(fixture->bytes + offset, &ip, sizeof(ip));
    offset += sizeof(ip);
    memcpy(fixture->bytes + offset, &udp, sizeof(udp));
    offset += sizeof(udp);
    memcpy(fixture->bytes + offset, &dns, sizeof(dns));
    offset += sizeof(dns);
    memcpy(fixture->bytes + offset, qname, qname_length);
    offset += qname_length;
    memcpy(fixture->bytes + offset, question_type_class,
           sizeof(question_type_class));
    offset += sizeof(question_type_class);

    fixture->length = (uint32_t)offset;
    return 0;
}

static int build_query(struct packet_fixture *fixture, const uint8_t *qname,
                       size_t qname_length, uint16_t source_port,
                       uint16_t destination_port, uint16_t dns_flags,
                       int udp_length_adjustment)
{
    return build_query_type(fixture, qname, qname_length, 1, source_port,
                            destination_port, dns_flags,
                            udp_length_adjustment);
}

static int run_packet(int program_fd, const struct packet_fixture *fixture,
                      struct test_run_result *result)
{
    LIBBPF_OPTS(bpf_test_run_opts, options,
        .data_in = fixture->bytes,
        .data_out = result->bytes,
        .data_size_in = fixture->length,
        .data_size_out = sizeof(result->bytes),
        .repeat = 1,
    );
    int error;

    memset(result, 0, sizeof(*result));
    options.data_out = result->bytes;
    options.data_size_out = sizeof(result->bytes);
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

static int install_cache_entry(struct bpf_object *object,
                               const uint8_t *qname, size_t qname_length,
                               uint16_t qtype, const uint8_t *answer,
                               size_t answer_length)
{
    struct dns_cache_key key = {};
    struct dns_cache_value value = {};
    struct bpf_map *map;

    if (answer_length > DNS_CACHE_ANSWER_MAX)
        return -1;
    memcpy(key.qname, qname, qname_length);
    key.qtype = qtype;
    key.qclass = 1;
    value.ttl = 60;
    value.answer_len = answer_length;
    memcpy(value.answer, answer, answer_length);
    value.expires_ns = 0;

    map = bpf_object__find_map_by_name(object, "dns_cache");
    if (!map) {
        fprintf(stderr, "dns_cache map was not found\n");
        return -1;
    }
    if (bpf_map_update_elem(bpf_map__fd(map), &key, &value, BPF_ANY)) {
        fprintf(stderr, "failed to install cache entry: %s\n", strerror(errno));
        return -1;
    }
    return 0;
}

static int install_all_cache_entries(struct bpf_object *object)
{
    static const uint8_t a_answer[TEST_DNS_ANSWER_LEN] = {
        0xc0, 0x0c, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x3c, 0x00, 0x04, 0x0a, 0x00, 0x00, 0x7b,
    };
    static const uint8_t aaaa_answer[TEST_DNS_AAAA_ANSWER_LEN] = {
        0xc0, 0x0c, 0x00, 0x1c, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x3c, 0x00, 0x10, 0x20, 0x01, 0x0d, 0xb8,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x23,
    };
    static const uint8_t https_answer[TEST_DNS_HTTPS_ANSWER_LEN] = {
        0xc0, 0x0c, 0x00, 0x41, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x3c, 0x00, 0x03, 0x00, 0x01, 0x00,
    };

    if (install_cache_entry(object, example_qname, sizeof(example_qname), 1,
                             a_answer, sizeof(a_answer)) != 0)
        return -1;
    if (install_cache_entry(object, aaaa_qname, sizeof(aaaa_qname), 28,
                             aaaa_answer, sizeof(aaaa_answer)) != 0)
        return -1;
    return install_cache_entry(object, https_qname, sizeof(https_qname), 65,
                               https_answer, sizeof(https_answer));
}

static int install_client_cache_entry(struct bpf_object *object,
                                      const uint8_t *qname,
                                      size_t qname_length, uint16_t qtype,
                                      const uint8_t *answer,
                                      size_t answer_length)
{
    struct dns_client_cache_key key = {};
    struct dns_cache_value value = {};
    struct bpf_map *map;

    if (answer_length > DNS_CACHE_ANSWER_MAX)
        return -1;
    if (inet_pton(AF_INET, "192.0.2.53", &key.resolver_ipv4) != 1)
        return -1;
    memcpy(key.qname, qname, qname_length);
    key.qtype = qtype;
    key.qclass = 1;
    value.ttl = 60;
    value.answer_len = answer_length;
    memcpy(value.answer, answer, answer_length);

    map = bpf_object__find_map_by_name(object, "dns_client_cache");
    if (!map) {
        fprintf(stderr, "dns_client_cache map was not found\n");
        return -1;
    }
    if (bpf_map_update_elem(bpf_map__fd(map), &key, &value, BPF_ANY)) {
        fprintf(stderr, "failed to install client cache entry: %s\n",
                strerror(errno));
        return -1;
    }
    return 0;
}

static int install_all_client_cache_entries(struct bpf_object *object)
{
    static const uint8_t a_answer[TEST_DNS_ANSWER_LEN] = {
        0xc0, 0x0c, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x3c, 0x00, 0x04, 0x0a, 0x00, 0x00, 0x7b,
    };
    static const uint8_t aaaa_answer[TEST_DNS_AAAA_ANSWER_LEN] = {
        0xc0, 0x0c, 0x00, 0x1c, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x3c, 0x00, 0x10, 0x20, 0x01, 0x0d, 0xb8,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x23,
    };
    static const uint8_t https_answer[TEST_DNS_HTTPS_ANSWER_LEN] = {
        0xc0, 0x0c, 0x00, 0x41, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x3c, 0x00, 0x03, 0x00, 0x01, 0x00,
    };
    struct bpf_map *trusted_map;
    __u32 resolver = 0;
    __u8 enabled = 1;

    if (inet_pton(AF_INET, "192.0.2.53", &resolver) != 1)
        return -1;
    trusted_map =
        bpf_object__find_map_by_name(object, "dns_client_trusted_servers");
    if (!trusted_map ||
        bpf_map_update_elem(bpf_map__fd(trusted_map), &resolver, &enabled,
                            BPF_ANY)) {
        fprintf(stderr, "failed to install trusted DNS server: %s\n",
                strerror(errno));
        return -1;
    }

    if (install_client_cache_entry(object, example_qname,
                                   sizeof(example_qname), 1, a_answer,
                                   sizeof(a_answer)) != 0)
        return -1;
    if (install_client_cache_entry(object, aaaa_qname, sizeof(aaaa_qname), 28,
                                   aaaa_answer, sizeof(aaaa_answer)) != 0)
        return -1;
    return install_client_cache_entry(object, https_qname, sizeof(https_qname),
                                      65, https_answer, sizeof(https_answer));
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

static int test_valid_typed_cache_hit(int program_fd, const char *test_name,
                                      const uint8_t *qname,
                                      size_t qname_length, uint16_t qtype,
                                      const uint8_t *expected_answer,
                                      size_t expected_answer_length)
{
    struct packet_fixture fixture;
    struct test_run_result result;
    struct dns_wire_header input_dns;
    struct dns_wire_header output_dns;
    struct ethhdr input_eth;
    struct ethhdr output_eth;
    struct iphdr input_ip;
    struct iphdr output_ip;
    struct udphdr input_udp;
    struct udphdr output_udp;
    const size_t ip_offset = sizeof(struct ethhdr);
    const size_t udp_offset = ip_offset + sizeof(struct iphdr);
    const size_t dns_offset = udp_offset + sizeof(struct udphdr);

    CHECK(test_name,
          build_query_type(&fixture, qname, qname_length, qtype,
                           TEST_CLIENT_PORT, TEST_DNS_PORT, 0x0100, 0) == 0,
          "failed to build packet fixture");
    CHECK(test_name, run_packet(program_fd, &fixture, &result) == 0,
          "program test run failed");
    CHECK(test_name, result.action == XDP_TX,
          "expected XDP_TX (%u), got %u", XDP_TX, result.action);
    CHECK(test_name,
          result.length == fixture.length + expected_answer_length,
          "expected output length %zu, got %u",
          fixture.length + expected_answer_length, result.length);

    memcpy(&input_eth, fixture.bytes, sizeof(input_eth));
    memcpy(&output_eth, result.bytes, sizeof(output_eth));
    CHECK(test_name,
          memcmp(output_eth.h_dest, input_eth.h_source, ETH_ALEN) == 0 &&
              memcmp(output_eth.h_source, input_eth.h_dest, ETH_ALEN) == 0,
          "Ethernet source/destination addresses were not swapped");

    memcpy(&input_ip, fixture.bytes + ip_offset, sizeof(input_ip));
    memcpy(&output_ip, result.bytes + ip_offset, sizeof(output_ip));
    CHECK(test_name,
          output_ip.saddr == input_ip.daddr && output_ip.daddr == input_ip.saddr,
          "IPv4 source/destination addresses were not swapped");
    CHECK(test_name,
          ntohs(output_ip.tot_len) ==
              ntohs(input_ip.tot_len) + expected_answer_length,
          "IPv4 total length was not increased by %zu", expected_answer_length);
    CHECK(test_name,
          ipv4_checksum_is_valid(result.bytes + ip_offset, sizeof(output_ip)),
          "IPv4 checksum is invalid");

    memcpy(&input_udp, fixture.bytes + udp_offset, sizeof(input_udp));
    memcpy(&output_udp, result.bytes + udp_offset, sizeof(output_udp));
    CHECK(test_name,
          output_udp.source == input_udp.dest &&
              output_udp.dest == input_udp.source,
          "UDP source/destination ports were not swapped");
    CHECK(test_name,
          ntohs(output_udp.len) ==
              ntohs(input_udp.len) + expected_answer_length,
          "UDP length was not increased by %zu", expected_answer_length);
    CHECK(test_name, output_udp.check == 0,
          "IPv4 UDP checksum should be zero, got 0x%04x",
          ntohs(output_udp.check));

    memcpy(&input_dns, fixture.bytes + dns_offset, sizeof(input_dns));
    memcpy(&output_dns, result.bytes + dns_offset, sizeof(output_dns));
    CHECK(test_name, output_dns.id == input_dns.id,
          "DNS transaction ID changed");
    CHECK(test_name,
          ntohs(output_dns.flags) == 0x8180 &&
              ntohs(output_dns.qdcount) == 1 &&
              ntohs(output_dns.ancount) == 1 &&
              output_dns.nscount == 0 && output_dns.arcount == 0,
          "DNS response header fields are incorrect");
    CHECK(test_name,
          memcmp(result.bytes + fixture.length, expected_answer,
                 expected_answer_length) == 0,
          "DNS answer bytes are incorrect");

    printf("ok - %s\n", test_name);
    return 0;
}

static int test_valid_cache_hit(int program_fd)
{
    static const uint8_t expected_answer[TEST_DNS_ANSWER_LEN] = {
        0xc0, 0x0c, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x3c, 0x00, 0x04, 0x0a, 0x00, 0x00, 0x7b,
    };

    return test_valid_typed_cache_hit(
        program_fd, "valid A/IN cache hit returns XDP_TX and appends one A answer",
        example_qname, sizeof(example_qname), 1, expected_answer,
        sizeof(expected_answer));
}

static int test_valid_aaaa_cache_hit(int program_fd)
{
    static const uint8_t expected_answer[TEST_DNS_AAAA_ANSWER_LEN] = {
        0xc0, 0x0c, 0x00, 0x1c, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x3c, 0x00, 0x10, 0x20, 0x01, 0x0d, 0xb8,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x23,
    };

    return test_valid_typed_cache_hit(
        program_fd,
        "valid AAAA/IN cache hit returns XDP_TX and appends one AAAA answer",
        aaaa_qname, sizeof(aaaa_qname), 28, expected_answer,
        sizeof(expected_answer));
}

static int test_valid_https_cache_hit(int program_fd)
{
    static const uint8_t expected_answer[TEST_DNS_HTTPS_ANSWER_LEN] = {
        0xc0, 0x0c, 0x00, 0x41, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x3c, 0x00, 0x03, 0x00, 0x01, 0x00,
    };

    return test_valid_typed_cache_hit(
        program_fd,
        "valid HTTPS/IN cache hit returns XDP_TX and appends one HTTPS answer",
        https_qname, sizeof(https_qname), 65, expected_answer,
        sizeof(expected_answer));
}

static int test_cache_miss(int program_fd)
{
    static const char *test_name = "cache miss returns XDP_PASS";
    struct packet_fixture fixture;

    CHECK(test_name,
          build_query(&fixture, missing_qname, sizeof(missing_qname),
                      TEST_CLIENT_PORT, TEST_DNS_PORT, 0x0100, 0) == 0,
          "failed to build packet fixture");
    return expect_pass_unchanged(test_name, program_fd, &fixture);
}

static int test_source_port_53_wrong_destination(int program_fd)
{
    static const char *test_name =
        "source port 53 with a non-DNS destination port returns XDP_PASS";
    struct packet_fixture fixture;

    CHECK(test_name,
          build_query(&fixture, example_qname, sizeof(example_qname),
                      TEST_DNS_PORT, 5300, 0x0100, 0) == 0,
          "failed to build packet fixture");
    return expect_pass_unchanged(test_name, program_fd, &fixture);
}

static int test_non_query_opcode(int program_fd)
{
    static const char *test_name = "non-QUERY DNS opcode returns XDP_PASS";
    struct packet_fixture fixture;

    CHECK(test_name,
          build_query(&fixture, example_qname, sizeof(example_qname),
                      TEST_CLIENT_PORT, TEST_DNS_PORT, 0x1100, 0) == 0,
          "failed to build packet fixture");
    return expect_pass_unchanged(test_name, program_fd, &fixture);
}

static int test_ip_udp_length_mismatch(int program_fd)
{
    static const char *test_name =
        "inconsistent IPv4 and UDP lengths return XDP_PASS";
    struct packet_fixture fixture;

    CHECK(test_name,
          build_query(&fixture, example_qname, sizeof(example_qname),
                      TEST_CLIENT_PORT, TEST_DNS_PORT, 0x0100, -1) == 0,
          "failed to build packet fixture");
    return expect_pass_unchanged(test_name, program_fd, &fixture);
}

static void raise_memlock_limit(void)
{
    const struct rlimit limit = {RLIM_INFINITY, RLIM_INFINITY};

    if (setrlimit(RLIMIT_MEMLOCK, &limit) && errno != EPERM)
        fprintf(stderr, "warning: setrlimit(RLIMIT_MEMLOCK) failed: %s\n",
                strerror(errno));
}

int main(int argc, char **argv)
{
    struct bpf_program *program;
    struct bpf_object *object;
    int failures = 0;
    int program_fd;
    int error;

    int client_mode = 0;

    if (argc == 3 && strcmp(argv[2], "--client") == 0)
        client_mode = 1;
    else if (argc != 2) {
        fprintf(stderr,
                "Usage: %s <dns_xdp_monitor.bpf.o> [--client]\n",
                argv[0]);
        return 2;
    }

    raise_memlock_limit();
    object = bpf_object__open_file(argv[1], NULL);
    if (!object) {
        fprintf(stderr, "failed to open BPF object %s: %s\n", argv[1],
                strerror(errno));
        return 1;
    }

    program = bpf_object__find_program_by_name(
        object, client_mode ? "dns_client_cache_xdp" : "dns_xdp_monitor");
    if (!program) {
        fprintf(stderr, "%s program was not found\n",
                client_mode ? "dns_client_cache_xdp" : "dns_xdp_monitor");
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
    if ((client_mode ? install_all_client_cache_entries(object)
                     : install_all_cache_entries(object))) {
        bpf_object__close(object);
        return 1;
    }

    program_fd = bpf_program__fd(program);
    failures += test_valid_cache_hit(program_fd) != 0;
    failures += test_valid_aaaa_cache_hit(program_fd) != 0;
    failures += test_valid_https_cache_hit(program_fd) != 0;
    failures += test_cache_miss(program_fd) != 0;
    failures += test_source_port_53_wrong_destination(program_fd) != 0;
    failures += test_non_query_opcode(program_fd) != 0;
    failures += test_ip_udp_length_mismatch(program_fd) != 0;

    bpf_object__close(object);
    if (failures) {
        fprintf(stderr, "%d/7 DNS XDP program tests failed\n", failures);
        return 1;
    }

    printf("7/7 DNS XDP program tests passed\n");
    return 0;
}
