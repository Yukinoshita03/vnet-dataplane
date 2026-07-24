# OpenStack gRPC E2E Benchmark

`bench/openstack_grpc_e2e.sh` runs a repeatable VM-to-VM comparison inside the
local DevStack/OpenStack lab:

```text
client VM -> cache VM:50052 -> backend VM:50051
```

The script measures the direct backend path and the gRPC cache-hit path with the
same h2c unary Health Check workload. With a guest kernel that has writable
bpffs, it creates pinned policy and response cache maps on the cache VM, loads
them with `cachectl`, and starts `grpc_fast_cache` against the response map. On
minimal images such as CirrOS, `GUEST_BPF=auto` detects the missing bpffs and
uses the same response-cache file in userspace; the summary labels this as
`guest-userspace-fallback` and must not be reported as guest eBPF acceleration.
The script then stops the backend and sends a cache-only probe, followed by a
`SERVING` to `NOT_SERVING` update. When the monitor build and cache tap are
available, it also starts `grpc_monitor` and records its metrics.

## Run

Run on the DevStack controller/compute host after loading OpenStack credentials:

```bash
cd /path/to/vnet-dataplane/linux_accel
source /opt/stack/devstack/openrc admin admin
SUDO_PASS='your-linux-password' CIRROS_PASSWORD=gocubsgo GUEST_BPF=auto \
  bash bench/openstack_grpc_e2e.sh
```

The script creates three temporary CirrOS instances, a temporary security
group, and (only when necessary) a temporary quota increase. All of them are
removed by the exit trap, including failure paths.

Useful overrides:

```bash
REQUESTS=1000 WARMUP=100 BACKEND_DELAY_US=300 \
  OUT_DIR=/tmp/openstack-grpc-e2e \
  bash bench/openstack_grpc_e2e.sh
```

The main variables are `OPENRC`, `OPENRC_USER`, `OPENRC_PROJECT`, `NETWORK`, `IMAGE`, `FLAVOR`, `COMPUTE_HOST`,
`SUBNET_CIDR`, `REQUESTS`, `WARMUP`, `BACKEND_DELAY_US`, `CIRROS_PASSWORD`,
`CIRROS_SUDO_PASSWORD`, `GUEST_USER`, `GUEST_KEY`, `KEY_NAME`, `SUDO_PASS`,
`NETNS`, `GUEST_BPF`, `CACHE_TTL_SEC`, `SSH_WAIT_ATTEMPTS`, `KEEP_RESOURCES`,
and `OUT_DIR`.
`GUEST_BPF=1` requires a writable guest bpffs; `GUEST_BPF=0` forces the
explicit userspace fallback. Set `NETNS=none`
when the host can reach the VM network without entering an OVN metadata
namespace; the default `NETNS=auto` selects the first `ovnmeta-*` namespace.
For a Linux cloud image, set `IMAGE`, `FLAVOR`, `GUEST_USER=ubuntu`,
`GUEST_KEY`, and `KEY_NAME`. `CACHE_TTL_SEC` defaults to 600 seconds so slow
nested-cloud boot time cannot expire the seeded response before the workload
starts. `KEEP_RESOURCES=1` is a diagnostic switch and preserves temporary
servers and security-group resources after the run.

## Output

Each run writes to `artifacts/openstack-grpc-e2e/<timestamp>/` (or `OUT_DIR`):

```text
topology.txt
baseline.log
cache.log
cache-only.log
cachectl.log
cache-process.log
cache-update.log
cache-updatectl.log
cache-update-process.log
response-map.dump
policy-map.dump
grpc-monitor.log
summary.md
openstack_grpc_harness
grpc_fast_cache.static
cachectl.static
```

`summary.md` contains QPS speedup, average-latency reduction, p99-latency
reduction, the cache-only result, the post-run `SERVING` to `NOT_SERVING`
response-map update check, and the last monitor metric lines.

## Evidence boundary

This is an OpenStack/OVN private-network data-path test with real VM-to-VM
traffic. In `guest-ebpf` mode it includes a real `cachectl` map update and a
`grpc_fast_cache` process reading a pinned response map. In
`guest-userspace-fallback` mode only the cache implementation changes; the VM
network path and host-side `grpc_monitor` evidence remain real, but the result
is not an eBPF-in-guest result. The workload generator is a small statically
linked h2c/gRPC Health Check harness so the test does not depend on a language
runtime inside CirrOS. It covers unary h2c cache behavior; TLS, streaming RPCs,
and arbitrary protobuf methods are outside this benchmark.

## Verified OpenStack runs

The Shuka1 DevStack lab was tested on 2026-07-24 with three temporary CirrOS
VMs, public floating IPs for SSH, and private-network addresses for the gRPC
path. The only available image was `cirros-0.6.3`; its guest kernel did not
have a mounted writable bpffs, so these runs use `GUEST_BPF=0`.

| backend delay | direct QPS | cache QPS | QPS ratio | direct p99 | cache p99 | result |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 300 us | 133.60 | 131.46 | 0.98x | 8.888 ms | 21.976 ms | network/proxy overhead dominates |
| 5000 us | 77.65 | 175.68 | 2.26x | 16.034 ms | 9.030 ms | avg latency -55.8%, p99 -43.7% |

Both runs had zero failed requests. The 5000 us run also verified
`cache-only=100/100` after stopping the backend and `NOT_SERVING=20/20` after
the runtime update. Host-side monitor output had `ringbuf_drop=0`; artifacts
were written under
`/home/xuexia/vnet-dataplane-verify/linux_accel/artifacts/openstack-grpc-e2e-final-500-userspace`
and
`/home/xuexia/vnet-dataplane-verify/linux_accel/artifacts/openstack-grpc-e2e-final-5000-userspace`.

The same lab was then rerun with the Ubuntu 24.04 cloud image and
`GUEST_BPF=1`, using real pinned maps inside the cache VM. The formal run used
`CACHE_TTL_SEC=600`, `REQUESTS=50`, `WARMUP=5`, and a 5000 us backend delay:

| mode | direct QPS | cache QPS | QPS ratio | avg reduction | p99 reduction |
| --- | ---: | ---: | ---: | ---: | ---: |
| `guest-ebpf` | 79.88 | 184.49 | 2.31x | 57.5% | 52.5% |

All 50 direct and cache requests succeeded. After stopping the backend,
`cache-only` completed `100/100`; after `cachectl --replace`, the runtime
update completed `NOT_SERVING=20/20`. The cache VM log reported
`cache_hit=49`, `response_cache_miss=0`, and `fallback_error=0` during the
measured cache path. The pinned response map dump contained the expected
method/payload key. The artifact is
`/home/xuexia/vnet-dataplane-verify/linux_accel/artifacts/openstack-grpc-e2e-guest-ebpf-formal`.
The host monitor process loaded on the cache tap with `ringbuf_drop=0`; this
floating-IP run did not decode transport events on that tap, so the monitor
event count is not used as a performance claim.
