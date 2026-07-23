<p align="center">
  <img src="https://www.guet.edu.cn/_upload/article/images/3e/43/5a207998483bb89ca1065e78a10e/b5914d6b-2c56-4c4a-a3e6-a75a527c8af2.png" alt="桂林电子科技大学" width="760">
</p>

# 基于 eBPF 的网络服务加速与双端缓存系统

这是桂林电子科技大学队伍 **回调鹰佐** 的系统类竞赛项目。仓库目标不是单点 demo，而是做一个围绕 **DNS / gRPC 服务监控、内核快路径加速、虚拟化网络路径验证** 的可复现实验平台。

项目当前已经形成一条比较完整的技术链路：

- 用 `tc` 做 DNS / gRPC 观测，拿到请求、响应、RTT 等指标。
- 用 `XDP` 做 DNS 缓存命中快路径，直接在内核侧回包。
- 用用户态 `grpc_fast_cache` 做面向 h2c unary 场景的快速响应原型。
- 用 `netns + bridge + veth` 复现虚拟化路径，并验证 OpenStack / OVS 挂载点。
- 用新增的 **用户态 L2-L4 协议解析与服务分类模块** 解析原始帧，为后续虚拟化路径调试、流量分类和策略联动打基础。

## 项目定位

这个仓库更接近一个 **eBPF 网络服务加速试验台**，重点解决三类问题：

1. 能不能在 Linux 网络路径里稳定观测服务流量。
2. 能不能把适合缓存的请求做成真正的快路径。
3. 能不能把这些能力迁移到虚拟化和云场景常见的 `veth / bridge / tap / OVS` 路径上。

从工程视角看，它由两部分组成：

- **内核侧 datapath**：XDP / tc eBPF 程序，负责挂载、观测、命中快路径。
- **用户态 control plane**：策略加载、指标输出、gRPC 快缓存原型、协议解析与服务分类工具。

## 当前能力

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| DNS tc 监控 | 已完成 | 监控 IPv4 UDP DNS 请求/响应事件与延迟 |
| DNS XDP 加速 | 已完成 | 对命中缓存的 DNS `A/IN` 查询直接 `XDP_TX` 回包 |
| DNS 客户端自学习缓存 | 已实现，VM 已验证 | host-side veth XDP 命中回包，tc egress 从可信 DNS 响应学习 |
| 多条 DNS 缓存 | 已完成 | 支持 `--cache-file` 批量加载域名、IP、TTL |
| gRPC tc 监控 | 已完成 | 监控 TCP `50051` 端口请求包、响应包和传输层 RTT |
| gRPC 快缓存 | 已完成原型 | 面向 h2c unary 健康检查类请求做快速响应 |
| 统一策略工具 | 已完成 | `cachectl` 支持 DNS、gRPC、gRPC cache 策略校验与加载 |
| 虚拟化路径基线 | 已完成 | 使用 `netns + bridge + veth` 复现虚拟化路径并输出 benchmark |
| OpenStack 挂载验证 | 已完成 smoke test | 可发现 `br-int`、`br-ex`、veth、OVS 等候选接口并完成 tc attach |
| Kubernetes 路径探测 | 已完成脚本 | 只读发现 CNI、pod veth、node NIC 等可挂载位置 |
| 用户态协议解析与服务分类 | 已完成原型 | 解析原始 Ethernet 帧并识别 `dns / grpc / other` |

## 为什么加这个协议解析模块

新增的 `packet_parser + virt_service_classifier` 不是孤立小工具，它补的是虚拟化路径这一块的用户态观察能力。

典型用途是：

- 你在 `veth / tap / bridge` 上抓到一段原始二进制帧。
- 先在用户态把 `Ethernet -> IPv4 -> TCP/UDP` 头解析出来。
- 再快速判断这段流量是不是项目主线里的 DNS 或 gRPC。
- 后续可以继续往上接 ACL、流分类、回放、策略命中验证。

它现在重点识别两类流量：

- UDP `53`：`dns`
- TCP `50051`：`grpc`

## 系统结构

```text
客户端请求
   |
   v
XDP / tc eBPF 程序
   |-- DNS cache 命中：XDP_TX 直接构造响应
   |-- gRPC monitor：观测请求、响应、RTT
   |-- 未命中：放行到后端服务
   |
   v
eBPF maps
   |-- metrics
   |-- dns cache
   |-- grpc policy
   |
   v
用户态控制面
   |-- dns_monitor
   |-- grpc_monitor
   |-- grpc_fast_cache
   |-- cachectl
   |-- virt_service_classifier
   |
   v
benchmark / 文档 / 实验产物
```

## 关键结果

测试环境：VMware Ubuntu VM，`netns + veth` 拓扑，generic XDP，使用 `dnsperf` 与自研 latency bench。

### DNS XDP 缓存

| 测试对象 | QPS | p99 延迟 |
| --- | ---: | ---: |
| 用户态 DNS stub | 74702.04 | 793.97 us |
| DNS XDP cache | 533691.56 | 4.35 us |
| 加速比 | 7.14x | 182.52x |

### gRPC 快缓存

| 测试对象 | QPS | p99 延迟 |
| --- | ---: | ---: |
| 直接访问后端 | 808.07 | 4067.90 us |
| cache hit SERVING | 2985.40 | 1223.09 us |
| 加速比 | 3.69x | 3.33x |

### gRPC tc 监控

```text
success=5000 failed=0
qps=2156.05
avg=410.80 us p50=320.58 us p95=769.29 us p99=2090.22 us
ringbuf_drop=0
```

### 2026-07-23 OpenStack DNS 端到端 A/B

这组数据来自 Shuka1 OpenStack 项目的真实 OVN 租户网络和 tap 接口。服务端是
CirrOS 中的合成 UDP DNS responder，客户端使用持久 UDP benchmark 连续发送 500
次 `A/IN example.test` 查询；两组请求均为 500/500 成功。

| 路径 | 总耗时 | 平均延迟 | 成功率 |
| --- | ---: | ---: | ---: |
| 原始路径，不挂载 DNS 加速 | 4.3695 s | 8.739 ms | 500/500 |
| XDP DNS cache | 0.2907 s | 0.581 ms | 500/500 |
| 加速效果 | 15.03x | 延迟下降 93.35% | - |

XDP 侧观察到首次 `miss + learn`，随后命中 `cache_hit/cache_tx`，没有过期、拒绝
或 ringbuf 丢包。使用 `nslookup` 做进程级测试时只快约 12.8%，主要是每次启动
进程的固定开销稀释了网络路径收益。该结果证明了 OpenStack OVN/tap 路径上的
DNS 快路径，但 DNS responder 是合成服务，不代表生产权威 DNS。

### 2026-07-23 gRPC fast-cache A/B

这组数据使用仓库自带的 `grpc_fast_cache_bench.sh`，拓扑为 `netns + veth`，协议
为 h2c unary `/grpc.health.v1.Health/Check`，每组 500 次请求并带 50 次 warmup。
它验证的是用户态 gRPC 响应缓存，不是 XDP 直接回包。

| 路径 | QPS | 平均延迟 | p99 延迟 | 成功率 |
| --- | ---: | ---: | ---: | ---: |
| 直连后端 | 849.98 | 1.063 ms | 1.703 ms | 500/500 |
| cache hit SERVING | 2614.69 | 0.344 ms | 0.584 ms | 500/500 |
| 加速效果 | 3.08x | 下降 67.6% | 下降 65.7% | - |

缓存统计为 `cache_hit=1094`、`fallback=0`、`tx_error=0`，其中包含 warmup 请求。
对照的 response-cache miss 为 769.34 QPS、p99 1.951 ms，policy miss fallback 为
703.29 QPS、p99 3.035 ms。因此 gRPC 加速依赖幂等方法和重复请求 payload；未命中
时会承担代理和解析开销。由于本次 OpenStack 控制面 MySQL/InnoDB 损坏并持续返回
HTTP 500，这组 gRPC 数据不宣称为 OpenStack VM-to-VM 端到端结果。

### 虚拟化与云场景映射

- `netns + bridge + veth`：可复现的虚拟化路径基线。
- OpenStack / OVS：已验证 `br-int` 等真实候选挂载点上的 tc attach。
- Kubernetes：已提供只读挂载点探测脚本。

需要说明的是，当前仓库已经证明“能挂、能测、能跑 benchmark”，但还没有把 OpenStack VM-to-VM 或 Kubernetes Pod-to-Pod 的完整业务压测做满。

## 快速开始

需要 root 权限的脚本会调用 `sudo`。交互式环境建议先执行：

```bash
sudo -v
```

非交互环境可使用 `SUDO_PASS=<sudo-password>`，但不要把真实密码写进仓库。

### 1. 构建

```bash
./scripts/build_linux.sh
```

构建输出：

```text
build/dns_monitor
build/dns_monitor.bpf.o
build/dns_xdp_monitor.bpf.o
build/grpc_monitor
build/grpc_monitor.bpf.o
build/grpc_fast_cache
build/cachectl
build/virt_service_classifier
```

### 2. 跑用户态原始帧分类工具

直接喂一段十六进制 Ethernet 帧：

```bash
./build/virt_service_classifier \
  --hex-frame "001122334455aabbccddeeff08004500002812340000401100000a0000010a000002c001003500140000"
```

也可以读取原始二进制帧：

```bash
./build/virt_service_classifier --raw-file sample_frame.bin
```

### 3. 跑 benchmark

DNS XDP 缓存：

```bash
DURATION=5 LATENCY_COUNT=10000 ./bench/dns_xdp_cache_bench.sh
```

DNS tc 与 generic XDP 对比：

```bash
DURATION=5 LATENCY_COUNT=10000 ./bench/dns_tc_vs_xdp_bench.sh
```

gRPC tc 监控：

```bash
REQUESTS=5000 ./bench/grpc_tc_monitor_bench.sh
```

gRPC 快缓存：

```bash
REQUESTS=1000 ./bench/grpc_fast_cache_bench.sh
```

虚拟化路径 benchmark：

```bash
REQUESTS=1000 ./bench/virt_path_bench.sh
```

### 4. OpenStack / Kubernetes 路径探测

OpenStack / OVS：

```bash
./bench/openstack_path_probe.sh
./bench/openstack_tc_attach_smoke.sh
```

Kubernetes：

```bash
./bench/k8s_path_probe.sh
```

## 策略配置

项目统一使用文本策略文件描述 DNS 缓存、gRPC 方法白名单和 gRPC 响应缓存：

```text
dns example.test 10.0.0.123 60
grpc /grpc.health.v1.Health/Check 60 idempotent
grpc-cache /grpc.health.v1.Health/Check health-check SERVING 60
```

校验策略文件：

```bash
./build/cachectl --policy-file cache-policy.txt --validate-only
```

加载策略到 eBPF map：

```bash
sudo ./build/cachectl \
  --policy-file cache-policy.txt \
  --dns-map /sys/fs/bpf/dns_cache \
  --grpc-map /sys/fs/bpf/ebpf-network-service-cache/grpc_policy_map
```

## 仓库结构

```text
.
|-- bpf/                 # eBPF 内核态程序
|-- src/                 # 用户态加载器、控制面、协议解析与服务分类
|   `-- include/         # 用户态公共头文件
|-- bench/               # benchmark 与实验脚本
|-- docs/                # 设计文档、实验报告、完成矩阵
|-- scripts/             # 构建脚本
|-- third_party/         # 第三方头文件
`-- README.md            # 项目说明
```

`src/` 里和本次融合最相关的文件有：

- `src/include/packet_parser.hpp`
- `src/packet_parser.cpp`
- `src/virt_service_classifier.cpp`

## 主要文档

| 文档 | 说明 |
| --- | --- |
| `docs/technical-roadmap.md` | 技术路线与阶段拆分 |
| `docs/virtualization-path-benchmark.md` | 虚拟化路径 benchmark 说明 |
| `docs/cloud-native-integration.md` | OpenStack / Kubernetes 接入说明 |
| `docs/dual-ended-cache-design.md` | 双端缓存设计 |
| `docs/cachectl-runtime-policy.md` | 策略工具说明 |
| `docs/related-work-and-baselines.md` | 相关工作与基线对比 |
| `docs/demo-runbook.md` | Demo 演示流程 |
| `docs/test-matrix.md` | 测试矩阵与验证证据 |

## 当前边界

- DNS 加速当前聚焦 IPv4 UDP、单问题、`A/IN`、未压缩 QNAME、缓存命中请求。
- gRPC 快缓存当前聚焦 h2c unary demo，不覆盖 TLS、流式 RPC 和完整 HTTP/2 状态机。
- `virt_service_classifier` 当前只做 L2-L4 解析与基于端口的服务识别，还没有继续上卷到 HTTP/2、DNS payload 语义级解析。
- OpenStack / Kubernetes 方向当前证明了可挂载性和路径可见性，完整业务级端到端压测还需要继续补。

## 下一步

我认为这个仓库后面最值得继续做的，不是再堆新点子，而是把下面三件事做深：

1. 把 gRPC response cache 下沉成运行时可更新的 pinned map。
2. 把用户态协议解析模块继续扩展到 HTTP/2 frame 和更细粒度的服务识别。
3. 在真实 OpenStack/KVM 或 Kubernetes 业务流量上做一轮带指标留痕的完整实验。

## 参考资料

- eBPF 官方文档与 Linux BPF samples
- DNS RFC 1035
- gRPC over HTTP/2 协议说明
- hyDNS: Acceleration of DNS Through Kernel Space Resolution
- Xpress DNS
- BMC: Accelerating Memcached using Safe In-kernel Caching and Pre-stack Processing
