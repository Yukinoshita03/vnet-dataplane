#include <arpa/inet.h>
#include <errno.h>
#include <net/if.h>
#include <linux/if_arp.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
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

struct packet {
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

static int parse_ipv4(const char *text, uint32_t *address)
{
    return inet_pton(AF_INET, text, address) == 1 ? 0 : -1;
}

static int mac_equal(const uint8_t left[ETH_ALEN],
                     const uint8_t right[ETH_ALEN])
{
    return memcmp(left, right, ETH_ALEN) == 0;
}

int main(int argc, char **argv)
{
    uint8_t expected_mac[ETH_ALEN] = {};
    uint8_t source_mac[ETH_ALEN] = {};
    uint32_t source_ipv4;
    uint32_t target_ipv4;
    unsigned int ifindex;
    int socket_fd;
    struct ifreq request = {};
    struct sockaddr_ll bind_address = {};
    struct packet packet = {};
    struct sockaddr_ll destination = {};
    struct pollfd poll_fd = {};

    if (argc != 4 && argc != 5) {
        fprintf(stderr, "Usage: %s <ifname> <source_ipv4> <target_ipv4> [expected_mac]\n",
                argv[0]);
        return 2;
    }
    ifindex = if_nametoindex(argv[1]);
    if (!ifindex || parse_ipv4(argv[2], &source_ipv4) != 0 ||
        parse_ipv4(argv[3], &target_ipv4) != 0 ||
        (argc == 5 && parse_mac(argv[4], expected_mac) != 0)) {
        fprintf(stderr, "invalid probe arguments\n");
        return 2;
    }

    socket_fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ARP));
    if (socket_fd < 0) {
        perror("socket(AF_PACKET)");
        return 1;
    }
    strncpy(request.ifr_name, argv[1], IFNAMSIZ - 1);
    if (ioctl(socket_fd, SIOCGIFHWADDR, &request) != 0) {
        perror("SIOCGIFHWADDR");
        close(socket_fd);
        return 1;
    }
    memcpy(source_mac, request.ifr_hwaddr.sa_data, ETH_ALEN);

    bind_address.sll_family = AF_PACKET;
    bind_address.sll_protocol = htons(ETH_P_ARP);
    bind_address.sll_ifindex = (int)ifindex;
    if (bind(socket_fd, (struct sockaddr *)&bind_address,
             sizeof(bind_address)) != 0) {
        perror("bind(AF_PACKET)");
        close(socket_fd);
        return 1;
    }

    memset(packet.eth.h_dest, 0xff, ETH_ALEN);
    memcpy(packet.eth.h_source, source_mac, ETH_ALEN);
    packet.eth.h_proto = htons(ETH_P_ARP);
    packet.arp.hardware_type = htons(ARPHRD_ETHER);
    packet.arp.protocol_type = htons(ETH_P_IP);
    packet.arp.hardware_length = ETH_ALEN;
    packet.arp.protocol_length = 4;
    packet.arp.operation = htons(ARPOP_REQUEST);
    memcpy(packet.arp.sender_hardware, source_mac, ETH_ALEN);
    packet.arp.sender_ipv4 = source_ipv4;
    packet.arp.target_ipv4 = target_ipv4;

    destination.sll_family = AF_PACKET;
    destination.sll_protocol = htons(ETH_P_ARP);
    destination.sll_ifindex = (int)ifindex;
    destination.sll_halen = ETH_ALEN;
    memset(destination.sll_addr, 0xff, ETH_ALEN);
    if (sendto(socket_fd, &packet, sizeof(packet), 0,
               (struct sockaddr *)&destination, sizeof(destination)) < 0) {
        perror("sendto(ARP request)");
        close(socket_fd);
        return 1;
    }

    poll_fd.fd = socket_fd;
    poll_fd.events = POLLIN;
    for (;;) {
        uint8_t buffer[256];
        ssize_t length;
        struct ethhdr *eth;
        struct arp_ipv4_eth *arp;

        if (poll(&poll_fd, 1, 1000) <= 0)
            break;
        length = recv(socket_fd, buffer, sizeof(buffer), 0);
        if (length < (ssize_t)sizeof(struct packet))
            continue;
        eth = (struct ethhdr *)buffer;
        arp = (struct arp_ipv4_eth *)(buffer + sizeof(*eth));
        if (eth->h_proto != htons(ETH_P_ARP) ||
            arp->operation != htons(ARPOP_REPLY) ||
            arp->sender_ipv4 != target_ipv4 || arp->target_ipv4 != source_ipv4)
            continue;
        if (argc == 5 && !mac_equal(arp->sender_hardware, expected_mac))
            continue;
        printf("ARP reply sender=%02x:%02x:%02x:%02x:%02x:%02x\n",
               arp->sender_hardware[0], arp->sender_hardware[1],
               arp->sender_hardware[2], arp->sender_hardware[3],
               arp->sender_hardware[4], arp->sender_hardware[5]);
        close(socket_fd);
        return 0;
    }

    close(socket_fd);
    return 1;
}
