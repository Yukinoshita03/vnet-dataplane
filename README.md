# vnet-dataplane

[![CI](https://github.com/Yukinoshita03/vnet-dataplane/actions/workflows/ci.yml/badge.svg)](https://github.com/Yukinoshita03/vnet-dataplane/actions/workflows/ci.yml)

`vnet-dataplane` 是一个面向求职的系统方向项目。现在它不再只是“虚拟网卡驱动 + 一个简单的 C++ 解析器”，而是拆成了三层能力：

- `kernel/`：Linux 虚拟网卡驱动基础
- `userspace/`：C++20 用户态 dataplane 基础组件
- `linux_accel/`：独立的 Linux eBPF 加速与观测模块

这样做的目的很明确：把“驱动、报文处理、Linux 快路径加速”放进同一个仓库里，但又保持边界清楚，方便你在求职时讲成一个完整系统，而不是一堆彼此割裂的小项目。

## 当前结构

### 1. `kernel/`

最小可运行的虚拟网卡内核模块，负责：

- 注册 `vnet0`
- 处理 up/down 生命周期
- 维护基础 TX 统计
- 为后续 RX/TX ring、NAPI poll 打基础

### 2. `userspace/`

一个独立的 C++20 用户态 dataplane 基础层，当前保持轻量：

- Ethernet / IPv4 / UDP / TCP 头部解析
- 简单 CLI 示例
- 单元测试

这部分继续服务于你主仓库的“驱动 + 用户态处理”主线，不直接承载整套 Linux eBPF 加速逻辑。

### 3. `linux_accel/`

这里放的是另一整个 Linux/eBPF 网络加速项目，作为本仓库里的独立模块保留。它不是 Git submodule，而是直接纳入仓库版本管理。

这个模块当前包括：

- `bpf/`：DNS / gRPC 相关的 `tc` 与 `XDP` 程序
- `src/`：用户态 loader、monitor、cachectl、协议解析工具
- `bench/`：可复现 benchmark 与虚拟化路径脚本
- `docs/`：技术路线、实验说明、测试矩阵、报告草稿
- `scripts/build_linux.sh`：Linux 构建入口

它更像一个 Linux-only 的加速实验平台，重点覆盖：

- DNS `tc` 监控
- DNS `XDP` cache 快路径
- gRPC `tc` 监控
- gRPC fast-cache 原型
- `netns + bridge + veth` 虚拟化路径验证
- OpenStack / Kubernetes 路径探测

模块详细说明见 [linux_accel/README.md](linux_accel/README.md)。

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

这样可以保证三个层次各自可验证，而不是互相拖累。

## 现在这个仓库该怎么讲

如果你拿它去讲项目，我建议讲成下面这条线：

1. 我先做一个最小虚拟网卡驱动，证明我理解 `net_device` 这层。
2. 我再做一个 C++ 用户态 dataplane 基础层，处理协议解析和后续数据面逻辑。
3. 我再把 Linux eBPF 加速实验平台并进同一个仓库，作为独立的 `linux_accel/` 模块，覆盖 `XDP/tc`、缓存、监控、虚拟化路径验证。

这条叙事比“我做了两个不相关仓库”强很多。

## 路线图

- 主仓库执行计划见 [docs/roadmap.md](docs/roadmap.md)
- 主仓库架构说明见 [docs/architecture.md](docs/architecture.md)
- Linux 加速模块路线与实验说明见 [linux_accel/docs/technical-roadmap.md](linux_accel/docs/technical-roadmap.md) 和 [linux_accel/docs/virtualization-path-benchmark.md](linux_accel/docs/virtualization-path-benchmark.md)
