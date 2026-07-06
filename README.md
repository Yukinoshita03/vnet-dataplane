# vnet-dataplane

`vnet-dataplane` is a job-focused systems project: a Linux virtual NIC driver paired with a C++20 userspace dataplane.

The target outcome is a repo that demonstrates:

- Linux networking internals: `net_device`, NAPI, RX/TX queues, packet path
- Modern C++: packet parsing, queue abstractions, metrics, tests, build hygiene
- Infra engineering: benchmarks, observability, design docs, repeatable build steps

## Scope

The project is intentionally split into two parts:

1. `kernel/`
   A minimal virtual NIC kernel module that registers `vnet0`, handles bring-up/tear-down, tracks TX stats, and forms the base for a future RX/TX ring plus NAPI poll loop.

2. `userspace/`
   A C++20 dataplane that will consume packets from the driver side, parse L2/L3/L4 headers, apply filtering or forwarding logic, and expose metrics.

## Repository layout

```text
.
|-- CMakeLists.txt
|-- README.md
|-- docs/
|   |-- architecture.md
|   `-- roadmap.md
|-- kernel/
|   |-- Makefile
|   `-- vnetdrv.c
|-- tests/
|   |-- CMakeLists.txt
|   `-- packet_test.cpp
`-- userspace/
    |-- CMakeLists.txt
    |-- include/vnet/packet.h
    `-- src/
        |-- main.cpp
        `-- packet.cpp
```

## Current status

- The kernel module is a bootstrap implementation, not yet a full data path.
- The userspace library already contains a small Ethernet frame parser with a CLI entry point and a test.
- The next milestone is to add a shared queue design and a packet injection path from the kernel module to userspace.

## Build

Userspace build:

```bash
cmake -S . -B build
cmake --build build
ctest --test-dir build
```

Kernel module build on Linux:

```bash
make -C kernel
```

Load and inspect the device on Linux:

```bash
sudo insmod kernel/vnetdrv.ko
ip link show vnet0
sudo ip link set vnet0 up
sudo rmmod vnetdrv
```

## Roadmap

The execution plan lives in [docs/roadmap.md](docs/roadmap.md). The architecture notes live in [docs/architecture.md](docs/architecture.md).
