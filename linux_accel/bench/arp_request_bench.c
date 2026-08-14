#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <poll.h>
#include <linux/if_arp.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

struct arp_ipv4_eth {
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

struct arp_packet {
    struct ethhdr eth;
    struct arp_ipv4_eth arp;
} __attribute__((packed));

static int parse_mac(const char *text, uint8_t mac[ETH_ALEN])
{
    unsigned int bytes[ETH_ALEN] = {};
    char tail = '\0';

    if (sscanf(text, "%2x:%2x:%2x:%2x:%2x:%2x%c", &bytes[0], &bytes[1],
               &bytes[2], &bytes[3], &bytes[4], &bytes[5], &tail) != 6)
        return -1;
    for (size_t i = 0; i < ETH_ALEN; ++i) {
        if (bytes[i] > 0xff)
            return -1;
        mac[i] = (uint8_t)bytes[i];
    }
    return 0;
}

static uint64_t now_ns(void)
{
    struct timespec ts;

    if (clock_gettime(CLOCK_MONOTONIC_RAW, &ts) != 0)
        return 0;
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static int address_matches(const struct arp_ipv4_eth *arp,
                           uint32_t source_ipv4, uint32_t target_ipv4,
                           const uint8_t expected_mac[ETH_ALEN],
                           int check_mac)
{
    if (arp->operation != htons(ARPOP_REPLY) ||
        arp->sender_ipv4 != target_ipv4 || arp->target_ipv4 != source_ipv4)
        return 0;
    return !check_mac ||
           memcmp(arp->sender_hardware, expected_mac, ETH_ALEN) == 0;
}

static int percentile_index(size_t count, unsigned percentile)
{
    size_t rank = (count * percentile + 99) / 100;

    if (rank == 0)
        rank = 1;
    return (int)(rank - 1);
}

static int compare_u64(const void *left, const void *right)
{
    const uint64_t a = *(const uint64_t *)left;
    const uint64_t b = *(const uint64_t *)right;

    return a < b ? -1 : a > b ? 1 : 0;
}

int main(int argc, char **argv)
{
    const char *ifname;
    uint32_t source_ipv4;
    uint32_t target_ipv4;
    unsigned long requested;
    char *end = NULL;
    uint8_t expected_mac[ETH_ALEN] = {};
    int check_mac = 0;
    unsigned int ifindex;
    int socket_fd;
    struct ifreq request = {};
    struct sockaddr_ll bind_address = {};
    struct sockaddr_ll destination = {};
    struct arp_packet packet = {};
    uint64_t *latencies = NULL;
    size_t success = 0;
    size_t timeout = 0;
    uint64_t start_run;
    uint64_t end_run;

    if (argc != 5 && argc != 6) {
        fprintf(stderr,
                "Usage: %s <ifname> <source_ipv4> <target_ipv4> <count> "
                "[expected_target_mac]\n",
                argv[0]);
        return 2;
    }
    ifname = argv[1];
    if (inet_pton(AF_INET, argv[2], &source_ipv4) != 1 ||
        inet_pton(AF_INET, argv[3], &target_ipv4) != 1) {
        fprintf(stderr, "invalid IPv4 address\n");
        return 2;
    }
    requested = strtoul(argv[4], &end, 10);
    if (!end || *end != '\0' || requested == 0 || requested > 1000000) {
        fprintf(stderr, "count must be between 1 and 1000000\n");
        return 2;
    }
    if (argc == 6) {
        if (parse_mac(argv[5], expected_mac) != 0) {
            fprintf(stderr, "invalid expected target MAC\n");
            return 2;
        }
        check_mac = 1;
    }

    ifindex = if_nametoindex(ifname);
    if (!ifindex) {
        perror("if_nametoindex");
        return 1;
    }
    socket_fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ARP));
    if (socket_fd < 0) {
        perror("socket(AF_PACKET)");
        return 1;
    }
    {
        int receive_buffer = 4 * 1024 * 1024;
        (void)setsockopt(socket_fd, SOL_SOCKET, SO_RCVBUF, &receive_buffer,
                         sizeof(receive_buffer));
    }

    strncpy(request.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(socket_fd, SIOCGIFHWADDR, &request) != 0) {
        perror("SIOCGIFHWADDR");
        close(socket_fd);
        return 1;
    }
    memcpy(packet.eth.h_source, request.ifr_hwaddr.sa_data, ETH_ALEN);
    memset(packet.eth.h_dest, 0xff, ETH_ALEN);
    packet.eth.h_proto = htons(ETH_P_ARP);
    packet.arp.hardware_type = htons(ARPHRD_ETHER);
    packet.arp.protocol_type = htons(ETH_P_IP);
    packet.arp.hardware_length = ETH_ALEN;
    packet.arp.protocol_length = 4;
    packet.arp.operation = htons(ARPOP_REQUEST);
    memcpy(packet.arp.sender_hardware, packet.eth.h_source, ETH_ALEN);
    packet.arp.sender_ipv4 = source_ipv4;
    packet.arp.target_ipv4 = target_ipv4;

    bind_address.sll_family = AF_PACKET;
    bind_address.sll_protocol = htons(ETH_P_ARP);
    bind_address.sll_ifindex = (int)ifindex;
    if (bind(socket_fd, (struct sockaddr *)&bind_address,
             sizeof(bind_address)) != 0) {
        perror("bind(AF_PACKET)");
        close(socket_fd);
        return 1;
    }
    destination.sll_family = AF_PACKET;
    destination.sll_protocol = htons(ETH_P_ARP);
    destination.sll_ifindex = (int)ifindex;
    destination.sll_halen = ETH_ALEN;
    memset(destination.sll_addr, 0xff, ETH_ALEN);

    latencies = calloc(requested, sizeof(*latencies));
    if (!latencies) {
        perror("calloc");
        close(socket_fd);
        return 1;
    }

    start_run = now_ns();
    for (unsigned long index = 0; index < requested; ++index) {
        uint64_t start = now_ns();
        int received = 0;

        if (sendto(socket_fd, &packet, sizeof(packet), 0,
                   (struct sockaddr *)&destination, sizeof(destination)) < 0) {
            perror("sendto(ARP request)");
            free(latencies);
            close(socket_fd);
            return 1;
        }
        for (;;) {
            struct pollfd poll_fd = {.fd = socket_fd, .events = POLLIN};
            int poll_result = poll(&poll_fd, 1, 1000);

            if (poll_result <= 0)
                break;
            if (poll_fd.revents & POLLIN) {
                uint8_t buffer[256];
                ssize_t length = recv(socket_fd, buffer, sizeof(buffer), 0);
                struct ethhdr *eth;
                struct arp_ipv4_eth *arp;

                if (length < (ssize_t)sizeof(struct arp_packet))
                    continue;
                eth = (struct ethhdr *)buffer;
                arp = (struct arp_ipv4_eth *)(buffer + sizeof(*eth));
                if (eth->h_proto != htons(ETH_P_ARP) ||
                    !address_matches(arp, source_ipv4, target_ipv4,
                                     expected_mac, check_mac))
                    continue;
                latencies[success++] = now_ns() - start;
                received = 1;
                break;
            }
        }
        if (!received)
            timeout++;
    }
    end_run = now_ns();
    qsort(latencies, success, sizeof(*latencies), compare_u64);

    printf("count=%lu success=%zu timeout=%zu loss_pct=%.3f elapsed_ms=%.3f "
           "p50_us=%.3f p95_us=%.3f p99_us=%.3f min_us=%.3f max_us=%.3f "
           "reply_qps=%.3f\n",
           requested, success, timeout,
           requested ? 100.0 * (double)timeout / (double)requested : 0.0,
           (double)(end_run - start_run) / 1000000.0,
           success ? (double)latencies[percentile_index(success, 50)] / 1000.0
                   : -1.0,
           success ? (double)latencies[percentile_index(success, 95)] / 1000.0
                   : -1.0,
           success ? (double)latencies[percentile_index(success, 99)] / 1000.0
                   : -1.0,
           success ? (double)latencies[0] / 1000.0 : -1.0,
           success ? (double)latencies[success - 1] / 1000.0 : -1.0,
           (end_run > start_run)
               ? (double)success * 1000000000.0 / (double)(end_run - start_run)
               : 0.0);

    free(latencies);
    close(socket_fd);
    return success == requested ? 0 : 1;
}
