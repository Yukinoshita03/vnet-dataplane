#pragma once

#include <linux/if_ether.h>
#include <linux/ip.h>

#include <bpf/bpf_endian.h>

#include "dns_event.h"

#define DNS_PORT 53
#define DNS_FLAG_RESPONSE 0x8000
#define DNS_FLAG_TRUNCATED 0x0200
#define DNS_OPCODE_MASK 0x7800
#define DNS_RCODE_MASK 0x000f
#define DNS_QTYPE_A 1
#define DNS_QCLASS_IN 1
#define DNS_RESPONSE_NOERROR 0x8180
#define DNS_A_ANSWER_LEN 16
#define DNS_FIXED_ANSWER_WRITER(offset)                                      \
    if (answer_offset == offset) {                                           \
        answer = data + offset;                                              \
        if ((void *)(answer + DNS_A_ANSWER_LEN) > data_end)                  \
            return -1;                                                       \
        goto write_answer;                                                   \
    }

struct dns_hdr {
    __be16 id;
    __be16 flags;
    __be16 qdcount;
    __be16 ancount;
    __be16 nscount;
    __be16 arcount;
};

struct dns_a_answer {
    __be16 name;
    __be16 type;
    __be16 class;
    __be32 ttl;
    __be16 rdlength;
    __be32 addr;
} __attribute__((packed));

static __always_inline __u16 dns_ipv4_header_checksum(struct iphdr *ip)
{
    __u8 *p = (__u8 *)ip;
    __u32 sum = 0;

    sum += ((__u16)p[0] << 8) | p[1];
    sum += ((__u16)p[2] << 8) | p[3];
    sum += ((__u16)p[4] << 8) | p[5];
    sum += ((__u16)p[6] << 8) | p[7];
    sum += ((__u16)p[8] << 8) | p[9];
    sum += ((__u16)p[10] << 8) | p[11];
    sum += ((__u16)p[12] << 8) | p[13];
    sum += ((__u16)p[14] << 8) | p[15];
    sum += ((__u16)p[16] << 8) | p[17];
    sum += ((__u16)p[18] << 8) | p[19];

    sum = (sum & 0xffff) + (sum >> 16);
    sum = (sum & 0xffff) + (sum >> 16);
    return bpf_htons((__u16)(~sum));
}

static __always_inline void dns_swap_eth_addrs(struct ethhdr *eth)
{
    __u8 tmp;

    tmp = eth->h_source[0];
    eth->h_source[0] = eth->h_dest[0];
    eth->h_dest[0] = tmp;
    tmp = eth->h_source[1];
    eth->h_source[1] = eth->h_dest[1];
    eth->h_dest[1] = tmp;
    tmp = eth->h_source[2];
    eth->h_source[2] = eth->h_dest[2];
    eth->h_dest[2] = tmp;
    tmp = eth->h_source[3];
    eth->h_source[3] = eth->h_dest[3];
    eth->h_dest[3] = tmp;
    tmp = eth->h_source[4];
    eth->h_source[4] = eth->h_dest[4];
    eth->h_dest[4] = tmp;
    tmp = eth->h_source[5];
    eth->h_source[5] = eth->h_dest[5];
    eth->h_dest[5] = tmp;
}

static __always_inline int dns_write_a_answer(void *data, void *data_end,
                                                __u32 answer_offset,
                                                __u32 answer_ttl,
                                                __u32 answer_ipv4)
{
    __u8 *answer;

    DNS_FIXED_ANSWER_WRITER(60)
    DNS_FIXED_ANSWER_WRITER(61)
    DNS_FIXED_ANSWER_WRITER(62)
    DNS_FIXED_ANSWER_WRITER(63)
    DNS_FIXED_ANSWER_WRITER(64)
    DNS_FIXED_ANSWER_WRITER(65)
    DNS_FIXED_ANSWER_WRITER(66)
    DNS_FIXED_ANSWER_WRITER(67)
    DNS_FIXED_ANSWER_WRITER(68)
    DNS_FIXED_ANSWER_WRITER(69)
    DNS_FIXED_ANSWER_WRITER(70)
    DNS_FIXED_ANSWER_WRITER(71)
    DNS_FIXED_ANSWER_WRITER(72)
    DNS_FIXED_ANSWER_WRITER(73)
    DNS_FIXED_ANSWER_WRITER(74)
    DNS_FIXED_ANSWER_WRITER(75)
    DNS_FIXED_ANSWER_WRITER(76)
    DNS_FIXED_ANSWER_WRITER(77)
    DNS_FIXED_ANSWER_WRITER(78)
    DNS_FIXED_ANSWER_WRITER(79)
    DNS_FIXED_ANSWER_WRITER(80)
    DNS_FIXED_ANSWER_WRITER(81)
    DNS_FIXED_ANSWER_WRITER(82)
    DNS_FIXED_ANSWER_WRITER(83)
    DNS_FIXED_ANSWER_WRITER(84)
    DNS_FIXED_ANSWER_WRITER(85)
    DNS_FIXED_ANSWER_WRITER(86)
    DNS_FIXED_ANSWER_WRITER(87)
    DNS_FIXED_ANSWER_WRITER(88)
    DNS_FIXED_ANSWER_WRITER(89)
    DNS_FIXED_ANSWER_WRITER(90)
    DNS_FIXED_ANSWER_WRITER(91)
    DNS_FIXED_ANSWER_WRITER(92)
    DNS_FIXED_ANSWER_WRITER(93)
    DNS_FIXED_ANSWER_WRITER(94)
    DNS_FIXED_ANSWER_WRITER(95)
    DNS_FIXED_ANSWER_WRITER(96)
    DNS_FIXED_ANSWER_WRITER(97)
    DNS_FIXED_ANSWER_WRITER(98)
    DNS_FIXED_ANSWER_WRITER(99)
    DNS_FIXED_ANSWER_WRITER(100)
    DNS_FIXED_ANSWER_WRITER(101)
    DNS_FIXED_ANSWER_WRITER(102)
    DNS_FIXED_ANSWER_WRITER(103)
    DNS_FIXED_ANSWER_WRITER(104)
    DNS_FIXED_ANSWER_WRITER(105)
    DNS_FIXED_ANSWER_WRITER(106)
    DNS_FIXED_ANSWER_WRITER(107)
    DNS_FIXED_ANSWER_WRITER(108)
    DNS_FIXED_ANSWER_WRITER(109)
    DNS_FIXED_ANSWER_WRITER(110)
    DNS_FIXED_ANSWER_WRITER(111)
    DNS_FIXED_ANSWER_WRITER(112)
    DNS_FIXED_ANSWER_WRITER(113)
    DNS_FIXED_ANSWER_WRITER(114)
    DNS_FIXED_ANSWER_WRITER(115)
    DNS_FIXED_ANSWER_WRITER(116)
    DNS_FIXED_ANSWER_WRITER(117)
    DNS_FIXED_ANSWER_WRITER(118)
    DNS_FIXED_ANSWER_WRITER(119)
    DNS_FIXED_ANSWER_WRITER(120)
    DNS_FIXED_ANSWER_WRITER(121)
    DNS_FIXED_ANSWER_WRITER(122)
    return -1;

write_answer:
    answer[0] = 0xc0;
    answer[1] = 0x0c;
    answer[2] = 0x00;
    answer[3] = DNS_QTYPE_A;
    answer[4] = 0x00;
    answer[5] = DNS_QCLASS_IN;
    answer[6] = (__u8)(answer_ttl >> 24);
    answer[7] = (__u8)(answer_ttl >> 16);
    answer[8] = (__u8)(answer_ttl >> 8);
    answer[9] = (__u8)answer_ttl;
    answer[10] = 0x00;
    answer[11] = 0x04;
    answer[12] = (__u8)answer_ipv4;
    answer[13] = (__u8)(answer_ipv4 >> 8);
    answer[14] = (__u8)(answer_ipv4 >> 16);
    answer[15] = (__u8)(answer_ipv4 >> 24);
    return 0;
}

static __always_inline int dns_parse_question(void *data, void *data_end,
                                                const struct dns_hdr *dns,
                                                __u8 *qname, __u16 *qtype,
                                                __u16 *qclass,
                                                __u32 *question_end_offset)
{
    int done = 0;
    __u32 qname_len = 0;
    __u8 label_remaining = 0;
    __u8 *field;
    __u8 *question = (__u8 *)(dns + 1);

    __builtin_memset(qname, 0, DNS_XDP_QNAME_SCAN_MAX);

    for (int i = 0; i < DNS_XDP_QNAME_SCAN_MAX; i++) {
        __u8 value;

        if ((void *)(question + i + 1) > data_end)
            return -1;

        value = question[i];
        if (!label_remaining) {
            if (value == 0) {
                qname[i] = value;
                done = 1;
                qname_len = i + 1;
                break;
            }
            if (value > 63)
                return -1;
            label_remaining = value;
        } else {
            if (value >= 'A' && value <= 'Z')
                value += 'a' - 'A';
            label_remaining--;
        }
        qname[i] = value;
    }

    if (!done)
        return -1;

    field = question + qname_len;
    if ((void *)(field + 4) > data_end)
        return -1;

    *qtype = ((__u16)field[0] << 8) | field[1];
    *qclass = ((__u16)field[2] << 8) | field[3];
    *question_end_offset = (__u32)((long)field + 4 - (long)data);
    return 0;
}
