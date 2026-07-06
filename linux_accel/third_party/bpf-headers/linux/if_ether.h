#pragma once

#include <linux/types.h>

#define ETH_P_IP 0x0800

struct ethhdr {
    __u8 h_dest[6];
    __u8 h_source[6];
    __be16 h_proto;
};
