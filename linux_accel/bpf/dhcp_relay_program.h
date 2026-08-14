#ifndef YUKINONET_DHCP_RELAY_PROGRAM_H
#define YUKINONET_DHCP_RELAY_PROGRAM_H

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>

#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

#include <dhcp_relay.h>

enum {
    DHCP_CLIENT_PORT = 68,
    DHCP_SERVER_PORT = 67,
    DHCP_OP_BOOTREQUEST = 1,
    DHCP_OP_BOOTREPLY = 2,
    DHCP_HTYPE_ETHERNET = 1,
    DHCP_HLEN_ETHERNET = 6,
    DHCP_MAGIC_COOKIE = 0x63825363,
    DHCP_OPTION_PAD = 0,
    DHCP_OPTION_END = 255,
    DHCP_OPTION_MESSAGE_TYPE = 53,
    DHCP_MESSAGE_OFFER = 2,
    DHCP_MESSAGE_ACK = 5,
    DHCP_MESSAGE_NAK = 6,
    /* Keep the combined DNS/ARP/DHCP XDP object below the verifier limit. */
    DHCP_MAX_OPTIONS = 4,
};

struct dhcp_bootp_fixed {
    __u8 op;
    __u8 htype;
    __u8 hlen;
    __u8 hops;
    __be32 xid;
    __be16 secs;
    __be16 flags;
    __be32 ciaddr;
    __be32 yiaddr;
    __be32 siaddr;
    __be32 giaddr;
    __u8 chaddr[16];
    __u8 sname[64];
    __u8 file[128];
    __be32 magic_cookie;
} __attribute__((packed));

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, DHCP_RELAY_MAX_POLICY_ENTRIES);
    __type(key, struct dhcp_relay_policy_key);
    __type(value, struct dhcp_relay_policy);
} dhcp_relay_policies SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, DHCP_RELAY_MAX_TRANSACTION_ENTRIES);
    __type(key, struct dhcp_relay_transaction_key);
    __type(value, struct dhcp_relay_transaction);
} dhcp_relay_transactions SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, DHCP_RELAY_STAT_COUNT);
    __type(key, __u32);
    __type(value, __u64);
} dhcp_relay_stats SEC(".maps");

static __always_inline void dhcp_relay_stat_inc(__u32 key)
{
    __u64 *value = bpf_map_lookup_elem(&dhcp_relay_stats, &key);

    if (value)
        *value += 1;
}

static __always_inline int dhcp_relay_mac_is_unicast(const __u8 *mac)
{
    __u8 all_zero = 1;

#pragma unroll
    for (int i = 0; i < ETH_ALEN; i++) {
        if (mac[i] != 0)
            all_zero = 0;
    }

    return !all_zero && !(mac[0] & 1);
}

static __always_inline int dhcp_relay_mac_equal(const __u8 *left,
                                                const __u8 *right)
{
#pragma unroll
    for (int i = 0; i < ETH_ALEN; i++) {
        if (left[i] != right[i])
            return 0;
    }

    return 1;
}

static __always_inline __u16 dhcp_relay_ipv4_checksum(const struct iphdr *ip,
                                                       __u32 header_length)
{
    __u32 sum = 0;
    const __u8 *bytes = (const __u8 *)ip;

#pragma unroll
    for (int i = 0; i < 30; i++) {
        if ((__u32)(i * 2) < header_length)
            sum += ((__u16)bytes[i * 2] << 8) | bytes[i * 2 + 1];
    }
    sum = (sum & 0xffff) + (sum >> 16);
    sum = (sum & 0xffff) + (sum >> 16);
    return bpf_htons((__u16)~sum);
}

static __always_inline int dhcp_relay_message_type(
    const __u8 *options, void *data_end, __u8 *message_type)
{
    __u8 found = 0;

#pragma unroll
    for (int i = 0; i < DHCP_MAX_OPTIONS; i++) {
        __u8 code;
        __u8 length;

        if ((void *)(options + 1) > data_end)
            return -1;
        code = *options++;
        if (code == DHCP_OPTION_PAD)
            continue;
        if (code == DHCP_OPTION_END)
            break;
        if ((void *)(options + 1) > data_end)
            return -1;
        length = *options++;
        if (code == DHCP_OPTION_MESSAGE_TYPE) {
            if (length != 1)
                return -1;
            if ((void *)(options + 1) > data_end)
                return -1;
            *message_type = options[0];
            found = 1;
        } else if ((void *)(options + length) > data_end) {
            return -1;
        }
        options += length;
    }

    return found ? 0 : -1;
}

static __always_inline void dhcp_relay_make_transaction_key(
    struct dhcp_relay_transaction_key *key, __u32 relay_ifindex,
    const struct dhcp_bootp_fixed *bootp)
{
    __builtin_memset(key, 0, sizeof(*key));
    key->relay_ifindex = relay_ifindex;
    key->xid = bootp->xid;
    __builtin_memcpy(key->client_mac, bootp->chaddr, ETH_ALEN);
}

static __always_inline int dhcp_relay_rewrite_client_request(
    struct ethhdr *eth, struct iphdr *ip, struct udphdr *udp,
    struct dhcp_bootp_fixed *bootp, const struct dhcp_relay_policy *policy,
    __u32 ip_header_length)
{
    if (bootp->hops == 255)
        return -1;
    bootp->hops += 1;
    bootp->giaddr = policy->relay_ipv4;

    __builtin_memcpy(eth->h_dest, policy->server_mac, ETH_ALEN);
    __builtin_memcpy(eth->h_source, policy->relay_mac, ETH_ALEN);
    ip->saddr = policy->relay_ipv4;
    ip->daddr = policy->server_ipv4;
    ip->check = 0;
    ip->check = dhcp_relay_ipv4_checksum(ip, ip_header_length);
    udp->source = bpf_htons(DHCP_SERVER_PORT);
    udp->dest = bpf_htons(DHCP_SERVER_PORT);
    udp->check = 0;
    return 0;
}

static __always_inline __be32 dhcp_relay_response_destination(
    const struct dhcp_bootp_fixed *bootp)
{
    if (bpf_ntohs(bootp->flags) & DHCP_RELAY_BOOTP_BROADCAST)
        return bpf_htonl(0xffffffff);
    if (bootp->ciaddr)
        return bootp->ciaddr;
    if (bootp->yiaddr)
        return bootp->yiaddr;
    return bpf_htonl(0xffffffff);
}

static __always_inline int dhcp_relay_rewrite_server_response(
    struct ethhdr *eth, struct iphdr *ip, struct udphdr *udp,
    struct dhcp_bootp_fixed *bootp,
    const struct dhcp_relay_transaction *transaction, __u32 ip_header_length)
{
    if (bpf_ntohs(bootp->flags) & DHCP_RELAY_BOOTP_BROADCAST) {
#pragma unroll
        for (int i = 0; i < ETH_ALEN; i++)
            eth->h_dest[i] = 0xff;
    } else {
        __builtin_memcpy(eth->h_dest, transaction->client_mac, ETH_ALEN);
    }
    __builtin_memcpy(eth->h_source, transaction->relay_mac, ETH_ALEN);
    ip->saddr = transaction->server_ipv4;
    ip->daddr = dhcp_relay_response_destination(bootp);
    ip->check = 0;
    ip->check = dhcp_relay_ipv4_checksum(ip, ip_header_length);
    udp->source = bpf_htons(DHCP_SERVER_PORT);
    udp->dest = bpf_htons(DHCP_CLIENT_PORT);
    udp->check = 0;
    bootp->giaddr = 0;
    bootp->hops = 0;
    return 0;
}

static __always_inline int dhcp_relay_handle(struct xdp_md *ctx, void *data,
                                              void *data_end,
                                              struct ethhdr *eth,
                                              struct iphdr *ip,
                                              struct udphdr *udp,
                                              __u32 ip_header_length)
{
    __u16 source_port = bpf_ntohs(udp->source);
    __u16 destination_port = bpf_ntohs(udp->dest);
    __u16 udp_length;
    __u16 ip_length;
    struct dhcp_bootp_fixed *bootp;
    __u8 message_type = 0;
    __u64 now;

    if (!((source_port == DHCP_CLIENT_PORT &&
           destination_port == DHCP_SERVER_PORT) ||
          (source_port == DHCP_SERVER_PORT &&
           destination_port == DHCP_SERVER_PORT)))
        return XDP_PASS;

    if (ip_header_length < sizeof(*ip) || ip_header_length > 60) {
        dhcp_relay_stat_inc(DHCP_RELAY_STAT_FORMAT_INVALID);
        return XDP_PASS;
    }
    ip_length = bpf_ntohs(ip->tot_len);
    udp_length = bpf_ntohs(udp->len);
    if (ip_length < ip_header_length + sizeof(*udp) + sizeof(*bootp) ||
        udp_length < sizeof(*udp) + sizeof(*bootp) ||
        udp_length != ip_length - ip_header_length)
        {
            dhcp_relay_stat_inc(DHCP_RELAY_STAT_FORMAT_INVALID);
            return XDP_PASS;
        }

    bootp = (void *)udp + sizeof(*udp);
    if ((void *)(bootp + 1) > data_end ||
        bootp->magic_cookie != bpf_htonl(DHCP_MAGIC_COOKIE) ||
        bootp->htype != DHCP_HTYPE_ETHERNET ||
        bootp->hlen != DHCP_HLEN_ETHERNET ||
        (bootp->op != DHCP_OP_BOOTREQUEST &&
         bootp->op != DHCP_OP_BOOTREPLY)) {
        dhcp_relay_stat_inc(DHCP_RELAY_STAT_FORMAT_INVALID);
        return XDP_PASS;
    }
    if (dhcp_relay_message_type((const __u8 *)(bootp + 1), data_end,
                                &message_type) != 0) {
        dhcp_relay_stat_inc(DHCP_RELAY_STAT_FORMAT_INVALID);
        return XDP_PASS;
    }

    now = bpf_ktime_get_ns();
    if (source_port == DHCP_CLIENT_PORT &&
        destination_port == DHCP_SERVER_PORT &&
        bootp->op == DHCP_OP_BOOTREQUEST) {
        struct dhcp_relay_policy_key policy_key = {
            .client_ifindex = ctx->ingress_ifindex,
        };
        struct dhcp_relay_policy *policy =
            bpf_map_lookup_elem(&dhcp_relay_policies, &policy_key);
        struct dhcp_relay_transaction_key transaction_key = {};
        struct dhcp_relay_transaction transaction = {};

        if (!policy || !(policy->flags & DHCP_RELAY_POLICY_ENABLED)) {
            dhcp_relay_stat_inc(DHCP_RELAY_STAT_POLICY_MISS);
            return XDP_PASS;
        }
        if (!policy->expires_ns || now >= policy->expires_ns) {
            dhcp_relay_stat_inc(DHCP_RELAY_STAT_POLICY_EXPIRED);
            return XDP_PASS;
        }
        if (!dhcp_relay_mac_is_unicast(policy->relay_mac) ||
            !dhcp_relay_mac_is_unicast(policy->server_mac) ||
            !dhcp_relay_mac_equal(eth->h_source, bootp->chaddr)) {
            dhcp_relay_stat_inc(DHCP_RELAY_STAT_FORMAT_INVALID);
            return XDP_PASS;
        }
        if (bootp->giaddr) {
            dhcp_relay_stat_inc(DHCP_RELAY_STAT_UNSUPPORTED);
            return XDP_PASS;
        }

        dhcp_relay_make_transaction_key(&transaction_key,
                                         policy->relay_ifindex, bootp);
        transaction.client_ifindex = ctx->ingress_ifindex;
        transaction.relay_ipv4 = policy->relay_ipv4;
        transaction.server_ipv4 = policy->server_ipv4;
        __builtin_memcpy(transaction.relay_mac, policy->relay_mac,
                         ETH_ALEN);
        __builtin_memcpy(transaction.client_mac, bootp->chaddr, ETH_ALEN);
        transaction.generation = policy->generation;
        transaction.expires_ns = now + DHCP_RELAY_TRANSACTION_TTL_NS;
        if (transaction.expires_ns > policy->expires_ns)
            transaction.expires_ns = policy->expires_ns;
        if (bpf_map_update_elem(&dhcp_relay_transactions, &transaction_key,
                                &transaction, BPF_ANY) != 0) {
            dhcp_relay_stat_inc(DHCP_RELAY_STAT_TRANSACTION_UPDATE_FAIL);
            return XDP_PASS;
        }
        if (dhcp_relay_rewrite_client_request(
                eth, ip, udp, bootp, policy, ip_header_length) != 0) {
            bpf_map_delete_elem(&dhcp_relay_transactions, &transaction_key);
            dhcp_relay_stat_inc(DHCP_RELAY_STAT_UNSUPPORTED);
            return XDP_PASS;
        }
        dhcp_relay_stat_inc(DHCP_RELAY_STAT_REQUEST);
        dhcp_relay_stat_inc(DHCP_RELAY_STAT_REDIRECT);
        return bpf_redirect(policy->relay_ifindex, 0);
    }

    if (source_port == DHCP_SERVER_PORT &&
        destination_port == DHCP_SERVER_PORT &&
        bootp->op == DHCP_OP_BOOTREPLY) {
        struct dhcp_relay_transaction_key transaction_key = {};
        struct dhcp_relay_transaction *transaction;

        dhcp_relay_make_transaction_key(&transaction_key,
                                         ctx->ingress_ifindex, bootp);
        transaction = bpf_map_lookup_elem(&dhcp_relay_transactions,
                                          &transaction_key);
        if (!transaction) {
            dhcp_relay_stat_inc(DHCP_RELAY_STAT_TRANSACTION_MISS);
            return XDP_PASS;
        }
        if (!transaction->expires_ns || now >= transaction->expires_ns) {
            bpf_map_delete_elem(&dhcp_relay_transactions, &transaction_key);
            dhcp_relay_stat_inc(DHCP_RELAY_STAT_TRANSACTION_EXPIRED);
            return XDP_PASS;
        }
        if (bootp->giaddr != transaction->relay_ipv4 ||
            !dhcp_relay_mac_equal(bootp->chaddr, transaction->client_mac)) {
            dhcp_relay_stat_inc(DHCP_RELAY_STAT_UNSUPPORTED);
            return XDP_PASS;
        }
        if (dhcp_relay_rewrite_server_response(
                eth, ip, udp, bootp, transaction, ip_header_length) != 0)
            return XDP_PASS;
        if (message_type == DHCP_MESSAGE_ACK ||
            message_type == DHCP_MESSAGE_NAK)
            bpf_map_delete_elem(&dhcp_relay_transactions, &transaction_key);
        dhcp_relay_stat_inc(DHCP_RELAY_STAT_RESPONSE);
        dhcp_relay_stat_inc(DHCP_RELAY_STAT_REDIRECT);
        return bpf_redirect(transaction->client_ifindex, 0);
    }

    return XDP_PASS;
}

#endif
