#pragma once

#include <linux/types.h>

struct udphdr {
    __be16 source;
    __be16 dest;
    __be16 len;
    __be16 check;
};
