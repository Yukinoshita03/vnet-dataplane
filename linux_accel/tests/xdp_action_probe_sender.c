#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <linux/if_ether.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <netpacket/packet.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#include "xdp_action_probe.h"

struct action_probe_frame {
    struct ethhdr eth;
    struct xdp_action_probe_payload payload;
    uint8_t padding[ETH_ZLEN - sizeof(struct ethhdr) -
                    sizeof(struct xdp_action_probe_payload)];
} __attribute__((packed));

_Static_assert(sizeof(struct action_probe_frame) == ETH_ZLEN,
               "probe frame must be an Ethernet minimum frame without FCS");

static void usage(const char *program)
{
    fprintf(stderr,
            "Usage: %s --dev IFACE --dst-mac XX:XX:XX:XX:XX:XX "
            "[--count 1..%d] [--sequence N] [--interval-ms N]\n",
            program, XDP_ACTION_PROBE_MAX_SEND_COUNT);
}

static int parse_u32(const char *text, uint32_t minimum, uint32_t maximum,
                     uint32_t *value)
{
    char *end = NULL;
    unsigned long parsed;

    errno = 0;
    parsed = strtoul(text, &end, 10);
    if (errno || !end || *end != '\0' || parsed < minimum || parsed > maximum)
        return -1;
    *value = (uint32_t)parsed;
    return 0;
}

static int parse_mac(const char *text, uint8_t mac[ETH_ALEN])
{
    unsigned int octets[ETH_ALEN];
    size_t i;

    if (strlen(text) != 17 ||
        sscanf(text, "%2x:%2x:%2x:%2x:%2x:%2x",
               &octets[0], &octets[1], &octets[2], &octets[3],
               &octets[4], &octets[5]) != ETH_ALEN)
        return -1;
    for (i = 0; i < ETH_ALEN; i++)
        mac[i] = (uint8_t)octets[i];
    return 0;
}

static int read_interface(const char *ifname, int *ifindex,
                          uint8_t mac[ETH_ALEN])
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
    if (ioctl(fd, SIOCGIFINDEX, &request))
        goto error;
    *ifindex = request.ifr_ifindex;
    if (ioctl(fd, SIOCGIFHWADDR, &request))
        goto error;
    if (request.ifr_hwaddr.sa_family != ARPHRD_ETHER) {
        errno = EPROTONOSUPPORT;
        goto error;
    }
    memcpy(mac, request.ifr_hwaddr.sa_data, ETH_ALEN);
    close(fd);
    return 0;

error:
    {
        int saved_errno = errno;

        close(fd);
        errno = saved_errno;
        return -1;
    }
}

int main(int argc, char **argv)
{
    static const uint8_t magic[XDP_ACTION_PROBE_MAGIC_LEN] =
        XDP_ACTION_PROBE_MAGIC_INITIALIZER;
    struct sockaddr_ll destination = {};
    struct action_probe_frame frame = {};
    const char *ifname = NULL;
    const char *destination_text = NULL;
    uint8_t source_mac[ETH_ALEN];
    uint8_t destination_mac[ETH_ALEN];
    uint32_t interval_ms = 0;
    uint32_t sequence = 1;
    uint32_t count = 1;
    int ifindex;
    int socket_fd;
    int i;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dev") && i + 1 < argc)
            ifname = argv[++i];
        else if (!strcmp(argv[i], "--dst-mac") && i + 1 < argc)
            destination_text = argv[++i];
        else if (!strcmp(argv[i], "--count") && i + 1 < argc) {
            if (parse_u32(argv[++i], 1, XDP_ACTION_PROBE_MAX_SEND_COUNT,
                          &count)) {
                usage(argv[0]);
                return 2;
            }
        } else if (!strcmp(argv[i], "--sequence") && i + 1 < argc) {
            if (parse_u32(argv[++i], 0, UINT32_MAX, &sequence)) {
                usage(argv[0]);
                return 2;
            }
        } else if (!strcmp(argv[i], "--interval-ms") && i + 1 < argc) {
            if (parse_u32(argv[++i], 0, 10000, &interval_ms)) {
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

    if (!ifname || !destination_text ||
        parse_mac(destination_text, destination_mac)) {
        usage(argv[0]);
        return 2;
    }
    if (read_interface(ifname, &ifindex, source_mac)) {
        fprintf(stderr, "failed to inspect %s: %s\n", ifname,
                strerror(errno));
        return 1;
    }

    socket_fd = socket(AF_PACKET, SOCK_RAW | SOCK_CLOEXEC,
                       htons(XDP_ACTION_PROBE_ETHERTYPE));
    if (socket_fd < 0) {
        fprintf(stderr, "failed to open AF_PACKET socket: %s\n",
                strerror(errno));
        return 1;
    }

    destination.sll_family = AF_PACKET;
    destination.sll_protocol = htons(XDP_ACTION_PROBE_ETHERTYPE);
    destination.sll_ifindex = ifindex;
    destination.sll_halen = ETH_ALEN;
    memcpy(destination.sll_addr, destination_mac, ETH_ALEN);

    memcpy(frame.eth.h_dest, destination_mac, ETH_ALEN);
    memcpy(frame.eth.h_source, source_mac, ETH_ALEN);
    frame.eth.h_proto = htons(XDP_ACTION_PROBE_ETHERTYPE);
    memcpy(frame.payload.magic, magic, sizeof(frame.payload.magic));

    for (i = 0; i < (int)count; i++) {
        ssize_t sent;

        frame.payload.sequence = htonl(sequence + (uint32_t)i);
        sent = sendto(socket_fd, &frame, sizeof(frame), 0,
                      (struct sockaddr *)&destination, sizeof(destination));
        if (sent != (ssize_t)sizeof(frame)) {
            if (sent < 0)
                fprintf(stderr, "AF_PACKET send failed: %s\n", strerror(errno));
            else
                fprintf(stderr, "short AF_PACKET send: %zd/%zu\n", sent,
                        sizeof(frame));
            close(socket_fd);
            return 1;
        }
        if (interval_ms && i + 1 < (int)count)
            usleep(interval_ms * 1000u);
    }

    close(socket_fd);
    printf("sent=%u dev=%s dst=%s ethertype=0x%04x sequence_start=%u\n",
           count, ifname, destination_text, XDP_ACTION_PROBE_ETHERTYPE,
           sequence);
    return 0;
}
