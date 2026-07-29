#pragma once

#include <linux/types.h>

enum cache_runtime_mode {
    CACHE_RUNTIME_BYPASS = 1,
    CACHE_RUNTIME_SERVER = 2,
    CACHE_RUNTIME_CLIENT = 3,
    CACHE_RUNTIME_DUAL = 4,
};

enum cache_runtime_role {
    CACHE_RUNTIME_ROLE_SERVER = 1,
    CACHE_RUNTIME_ROLE_CLIENT = 2,
};

enum cache_runtime_flags {
    CACHE_RUNTIME_COMMITTED = 1u << 0,
};

struct cache_runtime_control {
    __u64 epoch;
    __u32 mode;
    __u32 flags;
};

static __inline __u8 cache_runtime_mode_allows(__u32 mode, __u32 role)
{
    if (mode == CACHE_RUNTIME_DUAL)
        return 1;
    if (role == CACHE_RUNTIME_ROLE_SERVER)
        return mode == CACHE_RUNTIME_SERVER;
    if (role == CACHE_RUNTIME_ROLE_CLIENT)
        return mode == CACHE_RUNTIME_CLIENT;
    return 0;
}

static __inline __u8 cache_runtime_control_allows(
    const struct cache_runtime_control *control, __u32 role)
{
    if (!control)
        return 1;
    if (!(control->flags & CACHE_RUNTIME_COMMITTED))
        return control->epoch == 0;
    return cache_runtime_mode_allows(control->mode, role);
}
