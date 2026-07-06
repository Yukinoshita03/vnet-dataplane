# vnet-dataplane

[![CI](https://github.com/Yukinoshita03/vnet-dataplane/actions/workflows/ci.yml/badge.svg)](https://github.com/Yukinoshita03/vnet-dataplane/actions/workflows/ci.yml)

`vnet-dataplane` 是一个面向求职的系统方向项目：实现一个 Linux 虚拟网卡驱动，并配套一个 C++20 用户态 dataplane 与原始帧分析工具。

这个仓库希望集中展示三类能力：

- Linux 网络内核基础：`net_device`、NAPI、RX/TX queue、包路径
- 现代 C++ 工程能力：L2-L4 报文解析、服务分类、队列抽象、测试与构建
- 基础设施研发能力：压测、可观测性、设计文档、可复现构建流程

## 项目范围

当前项目明确分成两部分：

1. `kernel/`
   一个最小可运行的虚拟网卡内核模块，负责注册 `vnet0`、处理 up/down 生命周期、维护基础 TX 统计，并为后续的 RX/TX ring 和 NAPI poll 打基础。

2. `userspace/`
   一个 C++20 用户态 dataplane，当前已经支持 Ethernet / IPv4 / TCP / UDP 头解析，并新增面向虚拟化路径抓包场景的服务分类工具；后续继续负责消费驱动侧数据、执行过滤或转发逻辑，并输出 metrics。

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
|-- tests/
|   |-- CMakeLists.txt
|   `-- packet_test.cpp
`-- userspace/
    |-- CMakeLists.txt
    |-- include/vnet/packet.h
    `-- src/
        |-- main.cpp
        |-- packet.cpp
        `-- virt_service_classifier.cpp
```

## 当前状态

- 内核模块目前是 bootstrap 版本，目标是先把设备生命周期和基础统计做稳。
- 用户态已经具备完整的 L2-L4 头解析能力，可对原始 Ethernet 帧做 `dns / grpc / other` 服务分类。
- 新增 `virt_service_classifier`，适合在 `veth / tap / bridge` 抓包后做快速离线解析与演示。
- 下一阶段是补共享 ring 设计，并把内核到用户态的报文传递路径串起来。

## 本地构建

用户态构建：

```bash
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

运行原始帧分类工具：

```bash
./build/userspace/virt_service_classifier \
  --hex-frame "001122334455aabbccddeeff08004500001c12340000401100000a0000010a000002c001003500080000"
```

或者：

```bash
./build/userspace/virt_service_classifier --raw-file sample_frame.bin
```

Linux 下编译内核模块：

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

## CI/CD

仓库已经配置 GitHub Actions：

- `userspace` 作业：在 `Ubuntu` 和 `Windows` 上构建并测试 C++20 用户态代码
- `virt_service_classifier` 会跟随 `userspace` 作业一起构建
- `kernel-module` 作业：在 `Ubuntu` 上安装通用内核头文件并编译虚拟网卡模块
- 构建产物会作为 workflow artifact 保存，方便后续下载和检查

## 路线图

执行计划见 [docs/roadmap.md](docs/roadmap.md)，架构说明见 [docs/architecture.md](docs/architecture.md)。
