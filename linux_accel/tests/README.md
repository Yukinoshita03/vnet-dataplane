# DNS XDP packet-level regression tests

`dns_xdp_prog_test.c` tests the real `dns_xdp_monitor` program through the
kernel's `BPF_PROG_TEST_RUN` interface. It does not attach to a netdev and does
not send traffic through a physical NIC.

The harness loads `dns_xdp_monitor.bpf.o`, installs one `example.test A`
record in the real `dns_cache` map, injects raw Ethernet frames, and checks the
program action and returned frame bytes.

Covered behavior:

- an eligible `A/IN` cache hit returns `XDP_TX`, grows the frame by 16 bytes,
  swaps L2/L3/L4 endpoints, updates lengths and the IPv4 checksum, and writes
  the expected DNS answer;
- a cache miss returns `XDP_PASS` without modifying the frame;
- a packet sourced from UDP port 53 but addressed to another port returns
  `XDP_PASS`;
- a non-QUERY DNS opcode returns `XDP_PASS`;
- inconsistent IPv4 and UDP lengths return `XDP_PASS`.

## Run in a Linux VM

Install the same build dependencies used by the project:

```bash
sudo apt-get install clang gcc libbpf-dev libelf-dev linux-libc-dev pkg-config zlib1g-dev
```

Then run:

```bash
./tests/run_dns_xdp_prog_test.sh
```

The OpenStack adapter has a rootless lifecycle-seam test. It verifies the
Neutron port-to-TAP mapping and refuses stale or mismatched OVS bindings:

```bash
./tests/openstack_tap_accel_test.sh
```

The script builds only the DNS XDP object and the small C harness under
`build/tests/`, then runs the harness as root because loading BPF programs and
creating maps requires BPF privileges on typical kernels.

Expected final line:

```text
5/5 DNS XDP program tests passed
```

This regression proves BPF parsing and packet transformation behavior. It does
not validate a NIC driver's DMA mapping, RX/TX descriptors, tailroom, or
`XDP_TX` completion path; those still require the separate physical-NIC smoke
test.

## ARP Proxy multi-tap tests

`run_arp_proxy_xdp_prog_test.sh` loads both production XDP objects and exercises
the shared ARP handler through `BPF_PROG_TEST_RUN`. It installs two tap states
and multiple `{tap ifindex, target IPv4} -> target MAC` bindings, then checks
the exact `XDP_TX` reply bytes, tap isolation, target misses, generation/lease
guards, malformed requests, and byte-for-byte `XDP_PASS` behavior. The same
script also runs the control-plane parser/map test:

```bash
./tests/run_arp_proxy_xdp_prog_test.sh
```

Expected ARP lines include:

```text
13/13 ARP proxy program tests passed for dns_xdp_monitor
ARP proxy control tests passed
13/13 ARP proxy program tests passed for dns_client_cache_xdp
```

策略控制面还有一个不依赖 BPF_PROG_TEST_RUN 的 Linux 单测，覆盖多 source 合并、
revision/lease/conflict 语义以及 AF_UNIX `SOCK_SEQPACKET` wire round-trip：

```bash
./tests/run_policy_control_feed_test.sh
```

预期输出：

```text
Policy reconciler and feed tests passed
```

Kubernetes Pod 生命周期使用独立的接口 desired-state feed，不伪造 ARP
binding。它覆盖接口名称/稳定身份、空快照、revision/tombstone、租约过期、
冲突和 Linux AF_UNIX server round-trip：

```bash
./tests/run_interface_feed_test.sh
```

预期输出：

```text
Interface feed and reconciler tests passed
```

For real packet delivery, the privileged veth test creates two network
namespaces, attaches one loaded XDP object to both host-side veths, verifies
different target MACs for the same target IP, checks an unconfigured target is
passed through, and kills the owner to verify lease-based fail-open:

```bash
sudo ./tests/run_arp_proxy_veth_test.sh
```

The veth test compiles the small `arp_proxy_veth_probe` raw-ARP sender instead
of depending on a particular `arping` package. It requires the Linux `ip`
command and a kernel with generic XDP and network-namespace support.

The Ubuntu r8169 trial profile also has a rootless static/text contract test:

```bash
./tests/r8169_fault_injection_text_test.sh
```

It checks the load-only master, root-only atomic one-shot budgets, dedicated
ethtool counters, existing TX/refill cleanup-path joins, patch order and pinned
prepared-source hash, rollback budget-clear ordering, and preservation of the
kubelet state guard. It does not build or load a kernel module.

The physical smoke's evidence parsers and counter gates have a rootless local
regression. It verifies that per-second cache deltas are summed even when the
final report is zero, the external-peer ring/sentinel/+16 contract is strict,
counter rollback is rejected, and every driver error counter is available:

```bash
./tests/native_xdp_dns_smoke_test.sh
```

This helper test does not attach XDP or touch a NIC. The real procedure and its
remaining hardware boundary are documented in
`docs/r8169-native-xdp-dns-smoke.md`.

## Generic UDP exact-hit fast path

`run_udp_fastpath_test.sh` loads the production UDP XDP object and exercises it
through `BPF_PROG_TEST_RUN`. It checks exact response synthesis, ifindex
isolation, cache misses, expiry, oversized requests and malformed lengths:

```bash
sudo ./tests/run_udp_fastpath_test.sh
```

Expected final line:

```text
6/6 UDP fast-path XDP tests passed
```

## Same-interface DNS + UDP XDP dispatcher

`run_xdp_dispatcher_test.sh` loads the production DNS target, UDP target and
dispatcher together, wires them through a `BPF_MAP_TYPE_PROG_ARRAY`, and runs
the root program with `BPF_PROG_TEST_RUN`. It covers generic UDP tail-call
routing, DNS tail-call routing, and the rule that a UDP policy entry on port 53
cannot steal DNS traffic from the DNS target:

```bash
sudo ./tests/run_xdp_dispatcher_test.sh
```

The root loader uses one XDP attach per interface and keeps the existing
target maps and fail-open behavior. Only an interface with a UDP policy uses
the dispatcher; other interfaces managed by the same process keep the DNS
target directly. A different `--dev`/policy interface is rejected by the
merged command; use separate loaders when the hooks belong to different NICs.
The rootless source/contract check is:

```bash
./tests/xdp_dispatcher_contract_test.sh
```

The real-packet veth/netns benchmark and OpenStack TAP benchmark are:

```bash
sudo THREADS=8 REQUESTS=25000 WARMUP=1000 \
  ./bench/udp_fastpath_bench.sh
./bench/openstack_udp_fastpath_bench.sh artifacts/openstack-udp quick
```

## DHCP/BOOTP controlled relay

`run_dhcp_relay_xdp_test.sh` loads the production `dns_xdp_monitor` object
through `BPF_PROG_TEST_RUN`. It checks client request rewrite and redirect,
OFFER transaction retention, ACK transaction cleanup, broadcast response
rewriting, and fail-open behavior for unknown interfaces, invalid cookies, and
expired policies:

```bash
./tests/run_dhcp_relay_xdp_test.sh
```

Expected final line:

```text
DHCP XDP tests passed
```

The test uses real local interface ifindices only for the kernel redirect
helper; it does not attach XDP to a netdev or change the OpenStack/Kubernetes
cluster. The production parser intentionally scans a bounded prefix of DHCP
options so the combined DNS/ARP/DHCP object remains below the BPF instruction
limit. Packets outside that prefix pass through.

The policy parser has a separate unprivileged Linux test for valid rows,
duplicate client interfaces, invalid MACs/leases, and extra fields:

```bash
./tests/run_dhcp_relay_control_test.sh
```

## LDAP/LDAPS transparent TCP fast path

`run_ldap_sockmap_test.sh` compiles the production proxy and BPF object, then
runs real LDAPv3 anonymous Bind/Search exchanges through direct, userspace,
splice and sockmap paths. With its default `LDAP_TLS_SMOKE=1`, it also creates a
short-lived certificate and sends a real TLS handshake and encrypted response
through sockmap to validate LDAPS byte-stream transparency:

```bash
sudo LDAP_RESPONSE_BYTES=4096 LDAP_TLS_SMOKE=1 \
  ./tests/run_ldap_sockmap_test.sh
```

The sockmap gates require a real socket pair and reject userspace fallback,
redirect failure or relay error. The test intentionally does not cache, parse
or synthesize LDAP application responses in BPF.
