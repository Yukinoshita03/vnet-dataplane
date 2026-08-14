#include <linux/bpf.h>

#include <bpf/bpf_helpers.h>

#include "ldap_sockmap.h"

struct {
    __uint(type, BPF_MAP_TYPE_SOCKHASH);
    __uint(max_entries, LDAP_SOCKMAP_MAX_CONNECTIONS);
    __type(key, __u64);
    __type(value, __u32);
} ldap_sockets SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, LDAP_SOCKMAP_MAX_CONNECTIONS);
    __type(key, __u64);
    __type(value, __u64);
} ldap_peers SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, LDAP_SOCKMAP_STAT_COUNT);
    __type(key, __u32);
    __type(value, __u64);
} ldap_sockmap_stats SEC(".maps");

static __always_inline void ldap_stat_inc(__u32 key)
{
    __u64 *value = bpf_map_lookup_elem(&ldap_sockmap_stats, &key);

    if (value)
        *value += 1;
}

SEC("sk_skb/stream_parser")
int ldap_stream_parser(struct __sk_buff *skb)
{
    return skb->len;
}

SEC("sk_skb/stream_verdict")
int ldap_stream_verdict(struct __sk_buff *skb)
{
    __u64 cookie = bpf_get_socket_cookie(skb);
    __u64 *peer_cookie = bpf_map_lookup_elem(&ldap_peers, &cookie);
    int action;

    if (!peer_cookie) {
        ldap_stat_inc(LDAP_SOCKMAP_STAT_PEER_MISS);
        return SK_PASS;
    }

    action = bpf_sk_redirect_hash(skb, &ldap_sockets, peer_cookie, 0);
    if (action == SK_PASS)
        return SK_PASS;

    /*
     * A peer can disappear between the hash lookup and redirect while a TCP
     * connection is closing. Never turn that lifecycle race into data loss:
     * leave the skb on the proxy socket so the userspace relay can forward it.
     */
    ldap_stat_inc(LDAP_SOCKMAP_STAT_REDIRECT_FAIL);
    return SK_PASS;
}

char LICENSE[] SEC("license") = "GPL";
