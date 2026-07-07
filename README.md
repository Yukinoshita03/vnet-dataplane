# vnet-dataplane

[![CI](https://github.com/Yukinoshita03/vnet-dataplane/actions/workflows/ci.yml/badge.svg)](https://github.com/Yukinoshita03/vnet-dataplane/actions/workflows/ci.yml)

**Language:** English | [中文](README.zh-CN.md)

`vnet-dataplane` is a Linux eBPF agent for virtualized network path observability and lightweight service acceleration.

It targets KVM, OpenStack, and Kubernetes nodes. The project discovers virtualized network paths such as `veth`, `tap`, `bridge`, and `OVS`, observes DNS, gRPC, and TCP/UDP traffic, and provides controlled XDP/tc fast-path acceleration prototypes for cacheable service traffic.

The goal is to make virtualized network paths observable, verifiable, and reproducible: where packets enter, which interfaces they cross, where latency appears, and whether a narrow acceleration path can be applied safely.

## Features

- Discover virtualized network paths and candidate eBPF attach points
- Collect DNS, gRPC, TCP, and UDP traffic metrics
- Report path information, latency, service classification, and eBPF attach status
- Provide DNS XDP cache and gRPC fast-cache prototypes
- Reproduce virtualized network experiments with `netns + bridge + veth`
- Keep a virtual NIC driver and C++ userspace dataplane as lower-level experimental components

## Use Cases

`vnet-dataplane` is designed for:

- Checking whether traffic in virtualized or containerized environments crosses the expected interfaces
- Validating `tc` / `XDP` attach points on `veth`, `bridge`, `tap`, and `OVS` paths
- Observing DNS, gRPC, TCP, and UDP traffic with counters, latency, and service classification
- Validating protocol parsing, cache policy, and performance gain before moving logic into kernel fast paths
- Learning and experimenting with Linux networking, eBPF, and virtualized datapaths

## Current Status

| Module | Status | Description |
| --- | --- | --- |
| `linux_accel/` | Main module | Linux eBPF observability and acceleration module with DNS/gRPC monitors, XDP/tc fast paths, benchmarks, and documentation |
| `userspace/` | Base component | C++20 userspace dataplane prototype with basic packet parsing, a CLI example, and tests |
| `kernel/` | Experimental component | Minimal virtual NIC driver prototype that registers `vnet0` and maintains basic TX statistics |

At this stage, `linux_accel/` is the most complete and practical module. `userspace/` and `kernel/` are kept as lower-level experimental components for future integration with the driver, userspace dataplane, and acceleration path.

## Quick Start

### Build the Linux Acceleration Module

`linux_accel/` must be built on Linux:

```bash
cd linux_accel
./scripts/build_linux.sh
```

Build outputs:

```text
linux_accel/build/dns_monitor
linux_accel/build/dns_monitor.bpf.o
linux_accel/build/dns_xdp_monitor.bpf.o
linux_accel/build/grpc_monitor
linux_accel/build/grpc_monitor.bpf.o
linux_accel/build/grpc_fast_cache
linux_accel/build/cachectl
linux_accel/build/virt_service_classifier
```

### Run the Virtualized Path Benchmark

```bash
cd linux_accel
REQUESTS=1000 ./bench/virt_path_bench.sh
```

The benchmark creates a reproducible `netns + bridge + veth` path and measures baseline forwarding latency.

### Probe OpenStack / OVS Attach Points

```bash
cd linux_accel
./bench/openstack_path_probe.sh
./bench/openstack_tc_attach_smoke.sh
```

These scripts discover candidate interfaces in OpenStack / OVS environments and verify whether the DNS / gRPC tc monitors can be attached.

### Build the Userspace Dataplane

```bash
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

### Build the Virtual NIC Driver

```bash
make -C kernel
```

Load and inspect the device:

```bash
sudo insmod kernel/vnetdrv.ko
ip link show vnet0
sudo ip link set vnet0 up
sudo rmmod vnetdrv
```

## Repository Layout

```text
.
|-- linux_accel/          # Linux eBPF observability and acceleration module
|   |-- bpf/              # XDP/tc eBPF programs
|   |-- src/              # Userspace loaders, monitors, cachectl, and packet tools
|   |-- bench/            # Reproducible experiments and virtualized path benchmarks
|   |-- docs/             # Design, test, demo, and experiment documentation
|   |-- scripts/          # Linux build and demo scripts
|   `-- third_party/      # Headers required for BPF builds
|-- userspace/            # C++20 userspace dataplane base component
|-- kernel/               # Virtual NIC driver prototype
|-- tests/                # Userspace tests
|-- docs/                 # Top-level roadmap and architecture notes
`-- .github/workflows/    # CI/CD
```

## Validation

- GitHub Actions builds userspace components, the kernel module, and `linux_accel/`
- `linux_accel/` includes DNS XDP cache, gRPC fast-cache, tc monitors, and virtualized path benchmarks
- `netns + bridge + veth` is used for reproducible virtualized path experiments
- OpenStack / OVS probe scripts discover candidate attach points in real environments

## Roadmap

Near-term goals:

1. Provide a unified `vnet-agent` CLI for probe, monitor, bench, and diagnose workflows
2. Add JSON and Prometheus metrics output
3. Improve the read-only observability mode and keep packet modification disabled by default
4. Mark DNS XDP cache and gRPC fast-cache as optional acceleration capabilities
5. Add systemd service and Kubernetes DaemonSet deployment examples

Long-term goals:

- Provide stable virtualized network path observability for Linux nodes
- Offer safe and reversible lightweight fast paths for cacheable DNS/gRPC traffic
- Connect the virtual NIC, userspace dataplane, and eBPF acceleration module into a complete dataplane lab

## Documentation

- [linux_accel/README.md](linux_accel/README.md): Linux acceleration module
- [linux_accel/docs/technical-roadmap.md](linux_accel/docs/technical-roadmap.md): Technical roadmap
- [linux_accel/docs/virtualization-path-benchmark.md](linux_accel/docs/virtualization-path-benchmark.md): Virtualized path benchmark
- [linux_accel/docs/cloud-native-integration.md](linux_accel/docs/cloud-native-integration.md): OpenStack / Kubernetes integration notes
- [docs/architecture.md](docs/architecture.md): Top-level architecture notes
- [docs/roadmap.md](docs/roadmap.md): Top-level roadmap
