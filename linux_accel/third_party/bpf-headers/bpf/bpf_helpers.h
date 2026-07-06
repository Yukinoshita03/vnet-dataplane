#pragma once

#if defined(__APPLE__) && !defined(__BPF_TARGET__)
#define SEC(name) __attribute__((used))
#else
#define SEC(name) __attribute__((section(name), used))
#endif

#define __uint(name, val) int (*name)[val]
#define __type(name, val) typeof(val) *name

static void *(*bpf_map_lookup_elem)(void *map, const void *key) = (void *)1;
static long (*bpf_map_update_elem)(void *map, const void *key, const void *value, unsigned long long flags) = (void *)2;
static long (*bpf_map_delete_elem)(void *map, const void *key) = (void *)3;
static long (*bpf_skb_load_bytes)(const void *skb, unsigned int offset, void *to, unsigned int len) = (void *)26;
static unsigned long long (*bpf_ktime_get_ns)(void) = (void *)5;
static void *(*bpf_ringbuf_reserve)(void *ringbuf, unsigned long long size, unsigned long long flags) = (void *)131;
static void (*bpf_ringbuf_submit)(void *data, unsigned long long flags) = (void *)132;
static long (*bpf_xdp_adjust_tail)(struct xdp_md *ctx, int delta) = (void *)65;
