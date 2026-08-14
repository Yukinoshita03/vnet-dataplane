#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <stdbool.h>

#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

#include "xdp_action_probe.h"

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct xdp_action_probe_config);
} action_probe_config SEC(".maps");

static __always_inline bool action_probe_matches(struct xdp_md *ctx)
{
    const __u8 expected_magic[XDP_ACTION_PROBE_MAGIC_LEN] =
        XDP_ACTION_PROBE_MAGIC_INITIALIZER;
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;
    struct xdp_action_probe_config *config;
    struct xdp_action_probe_payload *payload;
    struct ethhdr *eth = data;
    __u32 key = 0;
    int i;

    if ((void *)(eth + 1) > data_end)
        return false;
    if (eth->h_proto != bpf_htons(XDP_ACTION_PROBE_ETHERTYPE))
        return false;

    payload = (void *)(eth + 1);
    if ((void *)(payload + 1) > data_end)
        return false;

    config = bpf_map_lookup_elem(&action_probe_config, &key);
    if (!config || config->armed != 1)
        return false;

#pragma unroll
    for (i = 0; i < ETH_ALEN; i++) {
        if (eth->h_dest[i] != config->target_mac[i])
            return false;
    }

#pragma unroll
    for (i = 0; i < XDP_ACTION_PROBE_MAGIC_LEN; i++) {
        if (payload->magic[i] != expected_magic[i])
            return false;
    }

    return true;
}

static __always_inline int action_probe_result(struct xdp_md *ctx, int action)
{
    if (!action_probe_matches(ctx))
        return XDP_PASS;
    return action;
}

SEC("xdp")
int xdp_action_pass(struct xdp_md *ctx)
{
    return action_probe_result(ctx, XDP_PASS);
}

SEC("xdp")
int xdp_action_drop(struct xdp_md *ctx)
{
    return action_probe_result(ctx, XDP_DROP);
}

SEC("xdp")
int xdp_action_aborted(struct xdp_md *ctx)
{
    return action_probe_result(ctx, XDP_ABORTED);
}

SEC("xdp")
int xdp_action_invalid(struct xdp_md *ctx)
{
    return action_probe_result(ctx, XDP_ACTION_PROBE_INVALID_ACTION);
}

char LICENSE[] SEC("license") = "GPL";
