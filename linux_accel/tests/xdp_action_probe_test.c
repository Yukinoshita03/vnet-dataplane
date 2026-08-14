#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>

#include "xdp_action_probe.h"

enum { TEST_FRAME_CAPACITY = 128 };

struct packet_fixture {
    uint8_t bytes[TEST_FRAME_CAPACITY];
    uint32_t length;
};

static const uint8_t test_target_mac[ETH_ALEN] = {
    0x02, 0x00, 0x00, 0x00, 0x00, 0x53,
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

static void build_matching_frame(struct packet_fixture *fixture)
{
    static const uint8_t source_mac[ETH_ALEN] = {
        0x02, 0x00, 0x00, 0x00, 0x00, 0x02,
    };
    static const uint8_t magic[XDP_ACTION_PROBE_MAGIC_LEN] =
        XDP_ACTION_PROBE_MAGIC_INITIALIZER;
    struct xdp_action_probe_payload payload = {};
    struct ethhdr eth = {};

    memset(fixture, 0, sizeof(*fixture));
    memcpy(eth.h_dest, test_target_mac, sizeof(eth.h_dest));
    memcpy(eth.h_source, source_mac, sizeof(eth.h_source));
    eth.h_proto = htons(XDP_ACTION_PROBE_ETHERTYPE);
    memcpy(payload.magic, magic, sizeof(payload.magic));
    payload.sequence = htonl(0x01020304);

    memcpy(fixture->bytes, &eth, sizeof(eth));
    memcpy(fixture->bytes + sizeof(eth), &payload, sizeof(payload));
    fixture->length = sizeof(eth) + sizeof(payload);
}

static int run_program(int program_fd, const struct packet_fixture *fixture,
                       uint32_t *action)
{
    uint8_t output[TEST_FRAME_CAPACITY] = {};
    LIBBPF_OPTS(bpf_test_run_opts, options,
        .data_in = fixture->bytes,
        .data_out = output,
        .data_size_in = fixture->length,
        .data_size_out = sizeof(output),
        .repeat = 1,
    );
    int error;

    error = bpf_prog_test_run_opts(program_fd, &options);
    if (error) {
        fprintf(stderr, "bpf_prog_test_run_opts failed: %s\n",
                strerror(error < 0 ? -error : error));
        return -1;
    }
    if (options.data_size_out != fixture->length ||
        memcmp(output, fixture->bytes, fixture->length) != 0) {
        fprintf(stderr, "probe unexpectedly modified the frame\n");
        return -1;
    }

    *action = options.retval;
    return 0;
}

static int program_fd(struct bpf_object *object, const char *name)
{
    struct bpf_program *program = bpf_object__find_program_by_name(object, name);

    if (!program) {
        fprintf(stderr, "BPF program %s was not found\n", name);
        return -1;
    }
    return bpf_program__fd(program);
}

static int expect_action(struct bpf_object *object, const char *test_name,
                         const char *program_name,
                         const struct packet_fixture *fixture,
                         uint32_t expected_action)
{
    uint32_t action = UINT32_MAX;
    int fd = program_fd(object, program_name);

    CHECK(test_name, fd >= 0, "program fd is unavailable");
    CHECK(test_name, run_program(fd, fixture, &action) == 0,
          "program test run failed");
    CHECK(test_name, action == expected_action,
          "expected action %u, got %u", expected_action, action);
    printf("ok - %s\n", test_name);
    return 0;
}

static int install_config(struct bpf_object *object)
{
    struct xdp_action_probe_config config = {};
    struct bpf_map *map;
    uint32_t key = 0;

    map = bpf_object__find_map_by_name(object, "action_probe_config");
    if (!map) {
        fprintf(stderr, "action_probe_config map was not found\n");
        return -1;
    }
    memcpy(config.target_mac, test_target_mac, sizeof(config.target_mac));
    config.armed = 1;
    if (bpf_map_update_elem(bpf_map__fd(map), &key, &config, BPF_ANY)) {
        fprintf(stderr, "failed to install probe config: %s\n",
                strerror(errno));
        return -1;
    }
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
    struct packet_fixture fixture;
    struct bpf_object *object;
    int failures = 0;
    int error;

    if (argc != 2) {
        fprintf(stderr, "Usage: %s <xdp_action_probe.bpf.o>\n", argv[0]);
        return 2;
    }

    raise_memlock_limit();
    object = bpf_object__open_file(argv[1], NULL);
    if (!object) {
        fprintf(stderr, "failed to open BPF object %s: %s\n", argv[1],
                strerror(errno));
        return 1;
    }
    error = bpf_object__load(object);
    if (error) {
        fprintf(stderr, "failed to load BPF object: %s\n", strerror(-error));
        bpf_object__close(object);
        return 1;
    }
    if (install_config(object)) {
        bpf_object__close(object);
        return 1;
    }

    build_matching_frame(&fixture);
    failures += expect_action(object, "matching PASS probe", "xdp_action_pass",
                              &fixture, XDP_PASS) != 0;
    failures += expect_action(object, "matching DROP probe", "xdp_action_drop",
                              &fixture, XDP_DROP) != 0;
    failures += expect_action(object, "matching ABORTED probe",
                              "xdp_action_aborted", &fixture,
                              XDP_ABORTED) != 0;
    failures += expect_action(object, "matching invalid=5 probe",
                              "xdp_action_invalid", &fixture,
                              XDP_ACTION_PROBE_INVALID_ACTION) != 0;

    build_matching_frame(&fixture);
    fixture.bytes[0] ^= 0x01;
    failures += expect_action(object, "target MAC mismatch passes",
                              "xdp_action_invalid", &fixture, XDP_PASS) != 0;

    build_matching_frame(&fixture);
    ((struct ethhdr *)fixture.bytes)->h_proto = htons(ETH_P_IP);
    failures += expect_action(object, "EtherType mismatch passes",
                              "xdp_action_invalid", &fixture, XDP_PASS) != 0;

    build_matching_frame(&fixture);
    fixture.bytes[sizeof(struct ethhdr)] ^= 0x01;
    failures += expect_action(object, "magic mismatch passes",
                              "xdp_action_invalid", &fixture, XDP_PASS) != 0;

    build_matching_frame(&fixture);
    fixture.length = sizeof(struct ethhdr) + 4;
    failures += expect_action(object, "truncated payload passes",
                              "xdp_action_invalid", &fixture, XDP_PASS) != 0;

    bpf_object__close(object);
    if (failures) {
        fprintf(stderr, "%d/8 XDP action probe tests failed\n", failures);
        return 1;
    }
    printf("8/8 XDP action probe tests passed\n");
    return 0;
}
