#pragma once

#define ___bpf_swab16(x) ((__u16)((((__u16)(x) & (__u16)0x00ffU) << 8) | (((__u16)(x) & (__u16)0xff00U) >> 8)))
#define ___bpf_swab32(x) ((__u32)((((__u32)(x) & (__u32)0x000000ffUL) << 24) | (((__u32)(x) & (__u32)0x0000ff00UL) << 8) | (((__u32)(x) & (__u32)0x00ff0000UL) >> 8) | (((__u32)(x) & (__u32)0xff000000UL) >> 24)))

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define bpf_htons(x) ___bpf_swab16(x)
#define bpf_ntohs(x) ___bpf_swab16(x)
#define bpf_htonl(x) ___bpf_swab32(x)
#define bpf_ntohl(x) ___bpf_swab32(x)
#else
#define bpf_htons(x) (x)
#define bpf_ntohs(x) (x)
#define bpf_htonl(x) (x)
#define bpf_ntohl(x) (x)
#endif
