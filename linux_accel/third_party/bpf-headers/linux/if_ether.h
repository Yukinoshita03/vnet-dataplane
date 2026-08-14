#pragma once

#include <linux/types.h>

#define ETH_ALEN 6
#define ETH_P_IP 0x0800
#define ETH_P_ARP 0x0806

struct ethhdr {
    __u8 h_dest[6];
    __u8 h_source[6];
    __be16 h_proto;
};
