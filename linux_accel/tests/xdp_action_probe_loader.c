#define _GNU_SOURCE

#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <linux/if_link.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "xdp_action_probe.h"

static volatile sig_atomic_t exiting;

static void handle_signal(int signal_number)
{
    (void)signal_number;
    exiting = 1;
}

static void usage(const char *program)
{
    fprintf(stderr,
            "Usage: %s --dev IFACE --object FILE --action "
            "pass|drop|aborted|invalid [--duration SEC]\n",
            program);
}

static const char *program_name_for_action(const char *action)
{
    if (!strcmp(action, "pass"))
        return "xdp_action_pass";
    if (!strcmp(action, "drop"))
        return "xdp_action_drop";
    if (!strcmp(action, "aborted"))
        return "xdp_action_aborted";
    if (!strcmp(action, "invalid"))
        return "xdp_action_invalid";
    return NULL;
}

static int parse_duration(const char *text, unsigned int *duration)
{
    char *end = NULL;
    unsigned long value;

    errno = 0;
    value = strtoul(text, &end, 10);
    if (errno || !end || *end != '\0' || value < 1 || value > 300)
        return -1;
    *duration = (unsigned int)value;
    return 0;
}

static int read_interface_mac(const char *ifname, uint8_t mac[6])
{
    struct ifreq request = {};
    int fd;

    if (strlen(ifname) >= sizeof(request.ifr_name)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -1;
    memcpy(request.ifr_name, ifname, strlen(ifname) + 1);
    if (ioctl(fd, SIOCGIFHWADDR, &request)) {
        int saved_errno = errno;

        close(fd);
        errno = saved_errno;
        return -1;
    }
    if (request.ifr_hwaddr.sa_family != ARPHRD_ETHER) {
        close(fd);
        errno = EPROTONOSUPPORT;
        return -1;
    }
    close(fd);
    memcpy(mac, request.ifr_hwaddr.sa_data, 6);
    return 0;
}

static int install_config(struct bpf_object *object, const uint8_t mac[6])
{
    struct xdp_action_probe_config config = {};
    struct bpf_map *map;
    uint32_t key = 0;

    map = bpf_object__find_map_by_name(object, "action_probe_config");
    if (!map) {
        fprintf(stderr, "action_probe_config map was not found\n");
        return -1;
    }
    memcpy(config.target_mac, mac, sizeof(config.target_mac));
    config.armed = 1;
    if (bpf_map_update_elem(bpf_map__fd(map), &key, &config, BPF_ANY)) {
        fprintf(stderr, "failed to arm action probe: %s\n", strerror(errno));
        return -1;
    }
    return 0;
}

static int query_native_program_id(unsigned int ifindex, uint32_t *program_id)
{
    int error = bpf_xdp_query_id((int)ifindex, XDP_FLAGS_DRV_MODE, program_id);

    if (error)
        fprintf(stderr, "failed to query native XDP state: %s\n",
                strerror(-error));
    return error;
}

static int detach_owned_program(unsigned int ifindex, int program_fd,
                                uint32_t expected_program_id)
{
    LIBBPF_OPTS(bpf_xdp_attach_opts, options,
        .old_prog_fd = program_fd,
    );
    uint32_t current_program_id = 0;
    int error;

    error = bpf_xdp_detach((int)ifindex, XDP_FLAGS_DRV_MODE, &options);
    if (error) {
        fprintf(stderr,
                "owned detach failed; a replacement is left untouched: %s\n",
                strerror(-error));
        return error;
    }
    error = query_native_program_id(ifindex, &current_program_id);
    if (error)
        return error;
    if (current_program_id != 0) {
        fprintf(stderr,
                "detach returned success but native XDP id %u remains "
                "(expected removal of %u)\n",
                current_program_id, expected_program_id);
        return -EBUSY;
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *ifname = NULL;
    const char *object_path = NULL;
    const char *action = NULL;
    const char *program_name;
    struct bpf_program *program;
    struct bpf_object *object = NULL;
    struct bpf_prog_info info = {};
    uint8_t target_mac[6];
    uint32_t existing_program_id = 0;
    uint32_t info_length = sizeof(info);
    unsigned int duration = 30;
    unsigned int ifindex;
    bool attached = false;
    int program_fd = -1;
    int exit_code = 1;
    int error;
    int i;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dev") && i + 1 < argc)
            ifname = argv[++i];
        else if (!strcmp(argv[i], "--object") && i + 1 < argc)
            object_path = argv[++i];
        else if (!strcmp(argv[i], "--action") && i + 1 < argc)
            action = argv[++i];
        else if (!strcmp(argv[i], "--duration") && i + 1 < argc) {
            if (parse_duration(argv[++i], &duration)) {
                usage(argv[0]);
                return 2;
            }
        } else if (!strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    program_name = action ? program_name_for_action(action) : NULL;
    if (!ifname || !object_path || !program_name) {
        usage(argv[0]);
        return 2;
    }
    if (geteuid() != 0) {
        fprintf(stderr, "run as root from the guarded physical test console\n");
        return 1;
    }

    ifindex = if_nametoindex(ifname);
    if (!ifindex) {
        fprintf(stderr, "interface %s was not found: %s\n", ifname,
                strerror(errno));
        return 1;
    }
    if (read_interface_mac(ifname, target_mac)) {
        fprintf(stderr, "failed to read %s MAC: %s\n", ifname,
                strerror(errno));
        return 1;
    }
    error = query_native_program_id(ifindex, &existing_program_id);
    if (error)
        return 1;
    if (existing_program_id) {
        fprintf(stderr,
                "refusing to replace existing native XDP program id %u\n",
                existing_program_id);
        return 1;
    }

    object = bpf_object__open_file(object_path, NULL);
    if (!object) {
        fprintf(stderr, "failed to open %s: %s\n", object_path,
                strerror(errno));
        return 1;
    }
    program = bpf_object__find_program_by_name(object, program_name);
    if (!program) {
        fprintf(stderr, "program %s was not found\n", program_name);
        goto out;
    }
    bpf_program__set_type(program, BPF_PROG_TYPE_XDP);
    error = bpf_object__load(object);
    if (error) {
        fprintf(stderr, "failed to load action probe: %s\n", strerror(-error));
        goto out;
    }
    if (install_config(object, target_mac))
        goto out;

    program_fd = bpf_program__fd(program);
    error = bpf_xdp_attach((int)ifindex, program_fd,
                           XDP_FLAGS_DRV_MODE | XDP_FLAGS_UPDATE_IF_NOEXIST,
                           NULL);
    if (error) {
        fprintf(stderr, "native XDP attach failed: %s\n", strerror(-error));
        goto out;
    }
    attached = true;

    if (bpf_obj_get_info_by_fd(program_fd, &info, &info_length)) {
        fprintf(stderr, "failed to read attached program id: %s\n",
                strerror(errno));
        goto out;
    }
    error = query_native_program_id(ifindex, &existing_program_id);
    if (error || existing_program_id != info.id) {
        fprintf(stderr,
                "native XDP ownership mismatch: loader=%u netdev=%u\n",
                info.id, existing_program_id);
        goto out;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    printf("xdp_program_id=%u\n", info.id);
    printf("action=%s\n", action);
    printf("target_mac=%02x:%02x:%02x:%02x:%02x:%02x\n",
           target_mac[0], target_mac[1], target_mac[2], target_mac[3],
           target_mac[4], target_mac[5]);
    fflush(stdout);

    for (i = 0; !exiting && i < (int)duration * 10; i++) {
        struct timespec delay = {.tv_sec = 0, .tv_nsec = 100000000};

        while (nanosleep(&delay, &delay) && errno == EINTR && !exiting)
            ;
    }
    exit_code = 0;

out:
    if (attached && detach_owned_program(ifindex, program_fd, info.id))
        exit_code = 1;
    bpf_object__close(object);
    return exit_code;
}
