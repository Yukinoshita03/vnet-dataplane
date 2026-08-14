#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>

#include "dns_event.h"
#include "udp_fastpath.h"
#include "xdp_dispatcher.h"

enum {
    TEST_FRAME_CAPACITY = 512,
    TEST_DNS_PORT = 53,
};

struct packet_fixture {
    uint8_t bytes[TEST_FRAME_CAPACITY];
    uint32_t length;
};

struct test_run_result {
    uint8_t bytes[TEST_FRAME_CAPACITY];
    uint32_t length;
    uint32_t action;
};

struct dns_wire_header {
    uint16_t id;
    uint16_t flags;
    uint16_t qdcount;
    uint16_t ancount;
    uint16_t nscount;
    uint16_t arcount;
} __attribute__((packed));

#define CHECK(test_name, condition, ...)                                    \
    do {                                                                    \
        if (!(condition)) {                                                 \
            fprintf(stderr, "not ok - %s: ", (test_name));                 \
            fprintf(stderr, __VA_ARGS__);                                   \
            fputc('\n', stderr);                                            \
            return -1;                                                       \
        }                                                                   \
    } while (0)

static int build_udp_packet(struct packet_fixture *fixture,
                            uint16_t destination_port,
                            const uint8_t *payload, size_t payload_len)
{
    static const uint8_t destination_mac[ETH_ALEN] = {
        0x02, 0x00, 0x00, 0x00, 0x00, 0x53,
    };
    static const uint8_t source_mac[ETH_ALEN] = {
        0x02, 0x00, 0x00, 0x00, 0x00, 0x02,
    };
    struct ethhdr eth = {};
    struct iphdr ip = {};
    struct udphdr udp = {};
    size_t offset = 0;
    size_t frame_len = sizeof(eth) + sizeof(ip) + sizeof(udp) + payload_len;

    if (frame_len > sizeof(fixture->bytes))
        return -1;
    memset(fixture, 0, sizeof(*fixture));
    memcpy(eth.h_dest, destination_mac, sizeof(destination_mac));
    memcpy(eth.h_source, source_mac, sizeof(source_mac));
    eth.h_proto = htons(ETH_P_IP);
    ip.version = 4;
    ip.ihl = 5;
    ip.tot_len = htons((uint16_t)(sizeof(ip) + sizeof(udp) + payload_len));
    ip.ttl = 64;
    ip.protocol = IPPROTO_UDP;
    if (inet_pton(AF_INET, "192.0.2.10", &ip.saddr) != 1 ||
        inet_pton(AF_INET, "192.0.2.53", &ip.daddr) != 1)
        return -1;
    udp.source = htons(53000);
    udp.dest = htons(destination_port);
    udp.len = htons((uint16_t)(sizeof(udp) + payload_len));

    memcpy(fixture->bytes + offset, &eth, sizeof(eth));
    offset += sizeof(eth);
    memcpy(fixture->bytes + offset, &ip, sizeof(ip));
    offset += sizeof(ip);
    memcpy(fixture->bytes + offset, &udp, sizeof(udp));
    offset += sizeof(udp);
    memcpy(fixture->bytes + offset, payload, payload_len);
    offset += payload_len;
    fixture->length = (uint32_t)offset;
    return 0;
}

static int run_packet(int program_fd, const struct packet_fixture *fixture,
                      struct test_run_result *result)
{
    struct bpf_test_run_opts options = {};
    int error;

    memset(result, 0, sizeof(*result));
    options.sz = sizeof(options);
    options.data_in = fixture->bytes;
    options.data_out = result->bytes;
    options.data_size_in = fixture->length;
    options.data_size_out = sizeof(result->bytes);
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

static uint64_t read_counter(int map_fd, uint32_t key)
{
    int cpu_count = libbpf_num_possible_cpus();
    uint64_t total = 0;
    uint64_t *values;

    if (cpu_count <= 0)
        return 0;
    values = calloc((size_t)cpu_count, sizeof(*values));
    if (!values)
        return 0;
    if (bpf_map_lookup_elem(map_fd, &key, values) == 0) {
        for (int i = 0; i < cpu_count; i++)
            total += values[i];
    }
    free(values);
    return total;
}

static int install_dns_port_udp_entry(int map_fd, const uint8_t *payload,
                                      size_t payload_len)
{
    struct udp_fastpath_key key = {};
    struct udp_fastpath_value value = {};

    key.ifindex = 0;
    if (inet_pton(AF_INET, "192.0.2.53", &key.server_ipv4) != 1)
        return -1;
    key.server_port = htons(TEST_DNS_PORT);
    key.request_len = (__u16)payload_len;
    memcpy(key.request, payload, payload_len);
    value.expires_ns = UINT64_MAX;
    value.response_len = 1;
    value.flags = UDP_FASTPATH_ENTRY_ENABLED;
    value.response[0] = 'x';
    return bpf_map_update_elem(map_fd, &key, &value, BPF_ANY);
}

static int expect_pass(const char *name, int program_fd,
                       const struct packet_fixture *fixture)
{
    struct test_run_result result = {};

    CHECK(name, run_packet(program_fd, fixture, &result) == 0,
          "program test run failed");
    CHECK(name, result.action == XDP_PASS,
          "expected XDP_PASS (%u), got %u", XDP_PASS, result.action);
    CHECK(name, result.length == fixture->length,
          "expected unchanged length %u, got %u", fixture->length,
          result.length);
    CHECK(name, memcmp(result.bytes, fixture->bytes, fixture->length) == 0,
          "XDP_PASS unexpectedly modified packet");
    printf("ok - %s\n", name);
    return 0;
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
    struct bpf_object *dns_object;
    struct bpf_object *udp_object;
    struct bpf_object *dispatcher_object;
    struct bpf_program *dns_program;
    struct bpf_program *udp_program;
    struct bpf_program *dispatcher_program;
    struct bpf_map *programs_map;
    struct bpf_map *config_map;
    struct bpf_map *udp_stats_map;
    struct bpf_map *dns_stats_map;
    uint32_t slot;
    uint32_t program_fd;
    uint32_t config_key = 0;
    struct xdp_dispatch_config config = {};
    struct packet_fixture fixture;
    struct test_run_result result;
    const uint8_t ping[] = {'p', 'i', 'n', 'g'};
    const uint8_t qname[] = {1, 'a', 4, 't', 'e', 's', 't', 0};
    uint8_t dns_payload[sizeof(struct dns_wire_header) + sizeof(qname) + 4];
    struct dns_wire_header dns = {};
    uint64_t udp_requests_before;
    uint64_t udp_requests_after;
    uint64_t dns_misses;
    int error;

    if (argc != 4) {
        fprintf(stderr,
                "Usage: %s <dns_xdp_monitor.bpf.o> <udp_fastpath.bpf.o> "
                "<xdp_dispatcher.bpf.o>\n",
                argv[0]);
        return 2;
    }

    raise_memlock_limit();
    dns_object = bpf_object__open_file(argv[1], NULL);
    udp_object = bpf_object__open_file(argv[2], NULL);
    dispatcher_object = bpf_object__open_file(argv[3], NULL);
    if (!dns_object || !udp_object || !dispatcher_object) {
        fprintf(stderr, "failed to open one of the BPF objects\n");
        bpf_object__close(dns_object);
        bpf_object__close(udp_object);
        bpf_object__close(dispatcher_object);
        return 1;
    }

    dns_program =
        bpf_object__find_program_by_name(dns_object, "dns_xdp_monitor");
    udp_program =
        bpf_object__find_program_by_name(udp_object, "udp_fastpath_xdp");
    dispatcher_program = bpf_object__find_program_by_name(
        dispatcher_object, "xdp_dispatcher");
    if (!dns_program || !udp_program || !dispatcher_program) {
        fprintf(stderr, "one of the expected XDP programs was not found\n");
        return 1;
    }
    bpf_program__set_type(dns_program, BPF_PROG_TYPE_XDP);
    bpf_program__set_type(udp_program, BPF_PROG_TYPE_XDP);
    bpf_program__set_type(dispatcher_program, BPF_PROG_TYPE_XDP);

    error = bpf_object__load(dns_object);
    if (!error)
        error = bpf_object__load(udp_object);
    if (!error)
        error = bpf_object__load(dispatcher_object);
    if (error) {
        fprintf(stderr, "failed to load merged XDP objects: %s\n",
                strerror(error < 0 ? -error : error));
        return 1;
    }

    programs_map = bpf_object__find_map_by_name(dispatcher_object,
                                                "xdp_dispatch_progs");
    config_map = bpf_object__find_map_by_name(dispatcher_object,
                                              "xdp_dispatch_config");
    udp_stats_map =
        bpf_object__find_map_by_name(udp_object, "udp_fastpath_stats");
    dns_stats_map = bpf_object__find_map_by_name(dns_object, "dns_cache_stats");
    if (!programs_map || !config_map || !udp_stats_map || !dns_stats_map)
        return 1;

    slot = XDP_DISPATCH_DNS_SLOT;
    program_fd = (__u32)bpf_program__fd(dns_program);
    if (bpf_map_update_elem(bpf_map__fd(programs_map), &slot, &program_fd,
                            BPF_ANY) != 0)
        return 1;
    slot = XDP_DISPATCH_UDP_SLOT;
    program_fd = (__u32)bpf_program__fd(udp_program);
    if (bpf_map_update_elem(bpf_map__fd(programs_map), &slot, &program_fd,
                            BPF_ANY) != 0)
        return 1;
    config.dns_slot = XDP_DISPATCH_DNS_SLOT;
    config.udp_slot = XDP_DISPATCH_UDP_SLOT;
    config.role = XDP_DISPATCH_ROLE_SERVER;
    if (bpf_map_update_elem(bpf_map__fd(config_map), &config_key, &config,
                            BPF_ANY) != 0)
        return 1;

    CHECK("build generic UDP fixture",
          build_udp_packet(&fixture, 9000, ping, sizeof(ping)) == 0,
          "failed to build packet");
    CHECK("generic UDP is tail-called", run_packet(
              bpf_program__fd(dispatcher_program), &fixture, &result) == 0,
          "program test run failed");
    CHECK("generic UDP is tail-called", result.action == XDP_PASS,
          "expected XDP_PASS, got %u", result.action);
    udp_requests_before = read_counter(bpf_map__fd(udp_stats_map),
                                        UDP_FASTPATH_STAT_REQUEST);
    CHECK("generic UDP target increments stats", udp_requests_before >= 1,
          "request counter did not increase");

    memset(&dns, 0, sizeof(dns));
    dns.id = htons(0x1234);
    dns.flags = htons(0x0100);
    dns.qdcount = htons(1);
    memcpy(dns_payload, &dns, sizeof(dns));
    memcpy(dns_payload + sizeof(dns), qname, sizeof(qname));
    dns_payload[sizeof(dns) + sizeof(qname) + 0] = 0;
    dns_payload[sizeof(dns) + sizeof(qname) + 1] = 1;
    dns_payload[sizeof(dns) + sizeof(qname) + 2] = 0;
    dns_payload[sizeof(dns) + sizeof(qname) + 3] = 1;
    CHECK("build DNS fixture",
          build_udp_packet(&fixture, TEST_DNS_PORT, dns_payload,
                           sizeof(dns_payload)) == 0,
          "failed to build packet");
    CHECK("DNS is tail-called to DNS target",
          expect_pass("DNS is tail-called to DNS target",
                       bpf_program__fd(dispatcher_program), &fixture) == 0,
          "DNS dispatcher test failed");
    dns_misses = read_counter(bpf_map__fd(dns_stats_map), DNS_CACHE_STAT_MISS);
    CHECK("DNS target ran", dns_misses >= 1,
          "DNS cache miss counter did not increase");

    CHECK("install DNS-port UDP collision fixture",
          install_dns_port_udp_entry(
              bpf_map__fd(bpf_object__find_map_by_name(
                  udp_object, "udp_fastpath_entries")),
              dns_payload, sizeof(dns_payload)) == 0,
          "failed to install UDP collision fixture");
    udp_requests_after = read_counter(bpf_map__fd(udp_stats_map),
                                      UDP_FASTPATH_STAT_REQUEST);
    CHECK("DNS priority excludes UDP target", run_packet(
              bpf_program__fd(dispatcher_program), &fixture, &result) == 0,
          "program test run failed");
    CHECK("DNS priority excludes UDP target", result.action == XDP_PASS,
          "DNS-port collision was incorrectly served by UDP target");
    CHECK("DNS priority excludes UDP stats", read_counter(
              bpf_map__fd(udp_stats_map), UDP_FASTPATH_STAT_REQUEST) ==
              udp_requests_after,
          "UDP target ran for DNS traffic");

    bpf_object__close(dispatcher_object);
    bpf_object__close(udp_object);
    bpf_object__close(dns_object);
    printf("3/3 XDP dispatcher integration tests passed\n");
    return 0;
}
