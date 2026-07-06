# vnet-dataplane

[![CI](https://github.com/Yukinoshita03/vnet-dataplane/actions/workflows/ci.yml/badge.svg)](https://github.com/Yukinoshita03/vnet-dataplane/actions/workflows/ci.yml)

A Linux eBPF agent for virtualized network path observability and lightweight service acceleration.

`vnet-dataplane` 面向 KVM、OpenStack 和 Kubernetes 节点，用于发现 `veth`、`tap`、`bridge`、`OVS` 等虚拟化网络路径，观测 DNS、gRPC 和 TCP/UDP 流量，并在可控场景下提供 XDP/tc 快路径优化原型。

这个项目的目标是把虚拟化网络路径里的“包从哪里来、经过哪里、延迟在哪里、能否安全加速”变成可观测、可验证、可复现的工程能力。

## 核心能力

- 自动发现虚拟化网络路径和候选 eBPF 挂载点
- 采集 DNS、gRPC、TCP/UDP 流量指标
- 输出路径、延迟、服务分类和 eBPF 挂载状态
- 提供 DNS XDP cache 与 gRPC fast-cache 原型
- 支持 `netns + bridge + veth` 可复现实验与 benchmark
- 保留虚拟网卡驱动与 C++ userspace dataplane 作为底层实验组件

## 适用场景

`vnet-dataplane` 适合用于以下场景：

- 排查虚拟化或容器网络路径上的流量是否经过预期接口
- 验证 `tc` / `XDP` 程序在 `veth`、`bridge`、`OVS` 等路径上的挂载位置
- 观测 DNS、gRPC 等服务流量的计数、延迟和命中情况
- 在上线内核快路径前，用可复现实验验证协议解析、缓存策略和性能收益
- 学习和验证 Linux 网络数据面、eBPF、虚拟化网络路径相关机制

## 当前状态

当前仓库由三部分组成：

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| `linux_accel/` | 主要模块 | Linux eBPF 观测与轻量加速模块，包含 DNS/gRPC 监控、XDP/tc 快路径、benchmark 和文档 |
| `userspace/` | 基础组件 | C++20 userspace dataplane 原型，包含基础协议解析、CLI 示例和测试 |
| `kernel/` | 实验组件 | 最小虚拟网卡驱动原型，注册 `vnet0` 并维护基础 TX 统计 |

现阶段最完整、最接近实际使用场景的是 `linux_accel/`。`userspace/` 和 `kernel/` 保留为后续连接驱动、用户态处理和快路径模块的实验基础。

## 快速开始

### 构建 Linux 加速模块

`linux_accel/` 需要在 Linux 环境下构建：

```bash
cd linux_accel
./scripts/build_linux.sh
```

构建完成后会生成：

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

### 运行虚拟化路径 benchmark

```bash
cd linux_accel
REQUESTS=1000 ./bench/virt_path_bench.sh
```

该脚本使用 `netns + bridge + veth` 构造可复现路径，用于验证虚拟化网络中的基础转发延迟。

### 探测 OpenStack / OVS 挂载点

```bash
cd linux_accel
./bench/openstack_path_probe.sh
./bench/openstack_tc_attach_smoke.sh
```

这些脚本用于发现 OpenStack / OVS 环境中的候选接口，并验证 DNS / gRPC tc monitor 是否可以挂载。

### 构建 userspace dataplane

```bash
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

### 构建虚拟网卡驱动

```bash
make -C kernel
```

加载并查看设备：

```bash
sudo insmod kernel/vnetdrv.ko
ip link show vnet0
sudo ip link set vnet0 up
sudo rmmod vnetdrv
```

## 仓库结构

```text
.
|-- linux_accel/          # Linux eBPF 观测与轻量加速模块
|   |-- bpf/              # XDP/tc eBPF 程序
|   |-- src/              # 用户态 loader、monitor、cachectl 和协议解析工具
|   |-- bench/            # 可复现实验与虚拟化路径 benchmark
|   |-- docs/             # 设计、测试、Demo 和实验文档
|   |-- scripts/          # Linux 构建与演示脚本
|   `-- third_party/      # BPF 构建所需头文件
|-- userspace/            # C++20 userspace dataplane 基础组件
|-- kernel/               # 虚拟网卡驱动原型
|-- tests/                # userspace 测试
|-- docs/                 # 主仓库路线图和架构说明
`-- .github/workflows/    # CI/CD
```

## 已有验证

- GitHub Actions 覆盖 userspace、kernel module 和 `linux_accel/` 构建
- `linux_accel/` 包含 DNS XDP cache、gRPC fast-cache、tc monitor 和虚拟化路径 benchmark
- `netns + bridge + veth` 用于复现虚拟化路径实验
- OpenStack / OVS probe 用于发现真实环境中的候选挂载点

## 路线图

近期目标：

1. 提供统一的 agent/CLI 入口，收敛现有 probe、monitor、bench、diagnose 脚本
2. 增加 JSON / Prometheus 指标输出
3. 完善只读观测模式，默认不修改数据包
4. 将 DNS XDP cache 和 gRPC fast-cache 标记为可选加速能力
5. 补充 systemd service 与 Kubernetes DaemonSet 部署方式

长期目标：

- 面向虚拟化节点提供稳定的网络路径观测能力
- 为 DNS / gRPC 等可缓存流量提供安全、可回退的轻量快路径
- 将虚拟网卡、userspace dataplane 和 eBPF 加速模块逐步连接成完整的数据面实验平台

## 文档

- [linux_accel/README.md](linux_accel/README.md)：Linux 加速模块说明
- [linux_accel/docs/technical-roadmap.md](linux_accel/docs/technical-roadmap.md)：技术路线
- [linux_accel/docs/virtualization-path-benchmark.md](linux_accel/docs/virtualization-path-benchmark.md)：虚拟化路径 benchmark
- [linux_accel/docs/cloud-native-integration.md](linux_accel/docs/cloud-native-integration.md)：OpenStack / Kubernetes 接入说明
- [docs/architecture.md](docs/architecture.md)：主仓库架构说明
- [docs/roadmap.md](docs/roadmap.md)：主仓库路线图
