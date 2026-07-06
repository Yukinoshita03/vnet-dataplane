# vnet-dataplane

[![CI](https://github.com/Yukinoshita03/vnet-dataplane/actions/workflows/ci.yml/badge.svg)](https://github.com/Yukinoshita03/vnet-dataplane/actions/workflows/ci.yml)

`vnet-dataplane` 是一个围绕 Linux 网络数据面做的系统项目，主线是从虚拟网卡驱动出发，逐步补上用户态报文处理和 Linux 快路径加速能力。

目前仓库分成三部分：

- `kernel/`：虚拟网卡驱动原型
- `userspace/`：C++20 用户态 dataplane 基础组件
- `linux_accel/`：Linux eBPF 加速与观测模块

这三个目录对应三条连续的能力线：设备抽象、报文处理、快路径优化。放在同一个仓库里，是为了把项目做成一个完整的数据面实验环境，而不是互不相关的 demo。

## 项目简介

### 1. `kernel/`

这一部分是最小可运行的虚拟网卡驱动原型，当前负责：

- 注册 `vnet0`
- 处理 up/down 生命周期
- 维护基础 TX 统计
- 为后续 RX/TX ring、NAPI poll 打基础

### 2. `userspace/`

这一部分是用户态 dataplane 基础层，当前保持轻量，主要做：

- Ethernet / IPv4 / UDP / TCP 头部解析
- 简单 CLI 示例
- 单元测试

它和内核驱动主线配套，但不直接承担整套 Linux eBPF 加速逻辑。

### 3. `linux_accel/`

这一部分是独立放进仓库的 Linux/eBPF 加速模块，不是 Git submodule，而是直接纳入当前仓库版本管理。

模块内部主要包括：

- `bpf/`：DNS / gRPC 相关的 `tc` 与 `XDP` 程序
- `src/`：用户态 loader、monitor、cachectl、协议解析工具
- `bench/`：可复现 benchmark 与虚拟化路径脚本
- `docs/`：技术路线、实验说明、测试矩阵、报告草稿
- `scripts/build_linux.sh`：Linux 构建入口

当前重点覆盖：

- DNS `tc` 监控
- DNS `XDP` cache 快路径
- gRPC `tc` 监控
- gRPC fast-cache 原型
- `netns + bridge + veth` 虚拟化路径验证
- OpenStack / Kubernetes 路径探测

更详细的说明见 [linux_accel/README.md](linux_accel/README.md)。

## 仓库结构

```text
.
|-- .github/workflows/ci.yml
|-- CMakeLists.txt
|-- README.md
|-- docs/
|   |-- architecture.md
|   `-- roadmap.md
|-- kernel/
|   |-- Makefile
|   `-- vnetdrv.c
|-- linux_accel/
|   |-- README.md
|   |-- bench/
|   |-- bpf/
|   |-- docs/
|   |-- scripts/
|   |-- src/
|   `-- third_party/
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

## 本地构建

### 用户态 dataplane

```bash
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

### 虚拟网卡内核模块

```bash
make -C kernel
```

Linux 下加载并查看设备：

```bash
sudo insmod kernel/vnetdrv.ko
ip link show vnet0
sudo ip link set vnet0 up
sudo rmmod vnetdrv
```

### Linux 加速模块

这个模块只在 Linux 环境下构建：

```bash
cd linux_accel
./scripts/build_linux.sh
```

构建完成后会生成 DNS / gRPC monitor、fast-cache、cachectl、`virt_service_classifier` 等可执行文件和 BPF 对象。

## CI/CD

主仓库 GitHub Actions 当前分成三类作业：

- `userspace`：在 `Ubuntu` 和 `Windows` 上构建并测试 C++20 用户态代码
- `kernel-module`：在 `Ubuntu` 上编译虚拟网卡模块
- `linux-accel`：在 `Ubuntu` 上构建 `linux_accel/` 内的 Linux/eBPF 加速模块

这样可以保证驱动、用户态组件和 Linux 加速模块各自可验证。

## 当前进展

- `kernel/` 目前完成了虚拟网卡 bootstrap 版本，重点先把设备生命周期和基础统计做稳。
- `userspace/` 目前有可编译的基础协议解析库、CLI 示例和测试。
- `linux_accel/` 目前是一套相对完整的 Linux-only 加速实验模块，已经覆盖 DNS、gRPC 和虚拟化路径相关的观测与验证。

## 路线图

- 主仓库执行计划见 [docs/roadmap.md](docs/roadmap.md)
- 主仓库架构说明见 [docs/architecture.md](docs/architecture.md)
- Linux 加速模块路线与实验说明见 [linux_accel/docs/technical-roadmap.md](linux_accel/docs/technical-roadmap.md) 和 [linux_accel/docs/virtualization-path-benchmark.md](linux_accel/docs/virtualization-path-benchmark.md)
