# Audited competitor compatibility patches

## Orange BMC (NSDI 2021)

The benchmark pins the official Orange-OpenSource/bmc-cache repository to
commit 2997145508e02c55aa92f63a0009ac2a26800810. The compatibility patch is
0001-bmc-linux7-libbpf16-tap-compat.patch.

Apply and build it with:

    ./scripts/build_bmc_compat.sh /path/to/bmc-cache /path/to/empty-output

The script exports the two upstream BMC sources from the pinned commit instead
of trusting the checkout's working tree, applies the patch, verifies the exact
source SHA-256 values used by the experiment, and builds the BPF object and the
owner-checked libbpf loader.

### What the patch changes

- Converts legacy map declarations and integer aliases to modern BTF/libbpf
  forms accepted by Linux 7.0 and libbpf 1.6.
- Adds bounds needed by the current verifier and declares the GPL license
  required by the BPF spin-lock path.
- Completes the IPv4 one's-complement end-around carry. The upstream helper
  folds only once, so a rare folded sum of `0x10000` produces an invalid header
  checksum; on the OpenStack TAP this was observed as exactly matching guest
  `Ip.InHdrErrors`, `IpExt.InCsumErrors`, and client receive timeouts.
- Makes key/value/map limits compile-time overrides. The reported benchmark
  deliberately uses 16-byte keys, 32-byte values, one key per request, 4,096
  direct-mapped physical cache slots, and a 256-byte packet bound. The mixed
  workload warms 1,024 hot keys; that workload cardinality is intentionally
  distinct from the physical map capacity so direct-map collisions do not
  silently change the requested hit/miss mix.
- Replaces the verifier-explosive TCP invalidation scan with a bounded parser
  for the benchmark's canonical set command. Fragmented or coalesced TCP
  commands pass without invalidating; this is a disclosed compatibility-profile
  limitation.
- Reserves response growth in tailroom rather than prepending 128 bytes of
  headroom. The upstream headroom layout works on veth but its final generic-XDP
  XDP_TX frame is silently lost on the tested OpenStack TAP with vnet_hdr. The
  48-byte reservation covers the configured response's measured 46-byte growth.
- Restores the original packet layout before XDP_PASS on a late cache mismatch,
  preserving fail-open behavior on the TAP path.

The patch does not replace BMC's FNV hash, direct-mapped array, per-entry spin
lock, XDP response construction, TC response learning, or TCP invalidation for
the canonical tested command. It is not a claim that this profile supports
arbitrary Memcached key/value sizes or every TCP segmentation pattern.

### Exact source identity

    bmc_common.h  03fabf2a4f645675c00b9a7d605700eb3a192697aef406ed450dbc1a8d94fe36
    bmc_kern.c    5ccacdf0ef8cb72658eb9a301eca4830572992b2c38a21c63bf22cd3f360de09
    loader source dc31ed6b8be19663ea1d4c2a28d01b7fa4a65a5e3904562f98f29c4e875abe47

The object actually used by the OpenStack and final netns runs is also recorded
in each run's metadata.txt. Source identity and binary identity are kept
separate because compiler and debug-path differences may change the object hash.
