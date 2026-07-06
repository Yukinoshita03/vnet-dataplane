# 最终报告草稿

## 项目概述

本项目面向 OS 功能挑战赛“基于 eBPF 的网络服务加速与双端缓存系统”赛题，实现了一套 eBPF 网络服务监控与缓存加速原型。

已实现组件：

- DNS tc monitor：监控 IPv4 UDP DNS query/response 延迟。
- DNS XDP cache：对命中缓存的 IPv4 UDP DNS `A/IN` 单问题查询直接快路径回包。
- 多条 DNS 缓存预加载与 `cachectl` 运行时策略校验/加载。
- gRPC tc transport monitor：监控 TCP/IPv4 `50051` 端口。
- gRPC h2c unary fast-cache：通过 `grpc_policy_map` 控制可缓存方法。
- DNS XDP cache、gRPC tc monitor、虚拟化类 bridge 路径的可复现 benchmark。
- 客户端侧/服务端侧双端缓存设计文档。
- OpenStack/OVS 与 Kubernetes Pod workload evidence 脚本，能生成 artifact 证据包。

完成度证据见 `docs/competition-completion-matrix.md`。详细测试矩阵、通过标准、最新产物和结论边界见 `docs/test-matrix.md`。

## 完成度摘要

| 赛题要求 | 状态 | 证据 |
| --- | --- | --- |
| eBPF 实时监控 | 已完成 | DNS tc monitor 与 gRPC tc monitor |
| eBPF 性能优化 | 已完成 | DNS XDP cache 与 gRPC h2c fast-cache/proxy |
| 两种以上服务 | 已完成 | DNS 与 gRPC |
| 虚拟化数据包路径实验 | 已完成 | `netns + bridge + veth` benchmark |
| 云/虚拟化挂载点证据 | 已完成 | OpenStack tc smoke、Kubernetes path probe、workload evidence 脚本 |
| 动态缓存策略 | 已完成 | 统一 `dns` / `grpc` / `grpc-cache` 策略文件 |
| benchmark 与 demo 包装 | 已完成 | `bench/` 脚本与 demo runbook |

## 性能摘要

| 服务 | 基线 | 加速路径 | QPS 加速比 | p99 提升 |
| --- | ---: | ---: | ---: | ---: |
| DNS | userspace DNS stub | XDP cache | `7.14x` | `182.52x` |
| gRPC | h2c backend | fast-cache SERVING hit | `3.69x` | `3.33x` |

## 最终 smoke test 证据

以下短测试在 DNS、gRPC、统一策略和虚拟化路径集成后执行。它们作为回归证据；上方性能表采用更稳定的 benchmark 结果。

构建：

```text
./scripts/build_linux.sh
generated dns_monitor.bpf.o, dns_xdp_monitor.bpf.o, grpc_monitor.bpf.o,
dns_monitor, grpc_monitor, grpc_fast_cache, and cachectl
```

统一策略校验：

```text
Validated cache policy file /tmp/final-policy.txt dns_entries=2 grpc_entries=1 grpc_cache_entries=2
```

DNS XDP cache smoke：

```text
userspace DNS stub: 32104.227077 qps, p99 1115.60 us
XDP cache:          539976.493631 qps, p99 2.97 us
speedup:            qps 16.82x, p99 375.62x
cache_hit=8189 cache_tx=8184 ringbuf_drop=0
```

gRPC fast-cache 功能 smoke：

```text
serving_cache_hit=330 not_serving_cache_hit=321
response_cache_miss=328 fallback=655 fallback_error=0 tx_error=0
```

虚拟化 bridge 路径 smoke：

```text
topology=netns+bridge+veth
success=300 failed=0 qps=1244.03 p99_us=9332.99 ping loss=0%
```

OpenStack/OVS 挂载 smoke：

```text
interface=br-int
dns_tc=attached
grpc_tc=attached
grpc_port=50051
artifact=openstack-tc-attach-smoke/20260627-160408
```

## 系统架构

```text
Client
  -> client-side eBPF hook / cache policy
  -> network or VM bridge path
  -> server-side tc/XDP hook
  -> service or XDP cache response
  -> metrics maps and userspace control plane
```

DNS 使用 XDP 做缓存命中快路径，因为 DNS 包结构小且边界清晰。gRPC 保留 tc monitor 作为基线，并增加窄范围 h2c unary fast-cache 原型：pinned `grpc_policy_map` 控制方法是否可缓存，缓存命中时直接返回预构造 health-check 响应，不调用后端服务。

## DNS 加速

范围：

- IPv4 UDP DNS。
- 单问题查询。
- 仅 `A/IN` 记录。
- 未压缩 QNAME。
- 缓存命中直接 `XDP_TX` 回包。
- 不支持的包放行。

早期 `netns + veth` benchmark：

```text
userspace DNS stub: 76372.88 qps, p99 281.73 us
XDP cache:          509621.05 qps, p99 3.59 us
speedup:            qps 6.67x, p99 78.48x
```

缓存控制重构后的最新稳定 benchmark：

```text
artifact = artifacts/dns-xdp-cache-bench/20260630-164919/summary.md
userspace QPS = 74702.04, p99 = 793.97 us
XDP cache QPS = 533691.56, p99 = 4.35 us
speedup = 7.14x QPS / 182.52x p99
cache_hit=10500 cache_tx=10500 ringbuf_drop=0
```

## gRPC 监控

范围：

- IPv4 TCP。
- 默认端口 `50051`。
- tc ingress/egress。
- transport-level 请求/响应包计数。
- 从请求 payload 到响应 payload 的 transport-level RTT 估算。

VMware Ubuntu VM 中 `netns + veth` benchmark：

```text
success=5000 failed=0
qps=2156.05
avg=410.80 us p50=320.58 us p95=769.29 us p99=2090.22 us
ringbuf_drop=0
```

h2c gRPC health-check demo 脚本已提供，但当前 VM 访问 Go module 源被拒绝时无法下载 `google.golang.org/grpc`。因此在该环境中，TCP transport demo 是已验证的 gRPC monitor benchmark。

## gRPC 快缓存原型

范围：

- 仅 h2c gRPC，不支持 TLS。
- unary 流量，demo 覆盖 `grpc.health.v1.Health/Check`。
- fast-cache 解析 h2c `:path`，hash 真实方法名，并检查 pinned `grpc_policy_map`。
- 方法必须在 pinned `grpc_policy_map` 中列入白名单。
- gRPC DATA message payload 会计算为 `payload_hash`。
- 响应缓存 key 为 `method_hash + payload_hash`。
- 原型可按不同请求 payload 返回缓存的 SERVING 和 NOT_SERVING health-check 响应。
- 响应缓存条目通过统一策略文件中的 `grpc-cache` 记录加载。
- 策略未命中和解析未命中通过 `--backend` 回退到后端。

Demo 命令：

```bash
REQUESTS=1000 ./bench/grpc_fast_cache_bench.sh
```

benchmark 对比真实 h2c backend 与 `grpc_fast_cache`，记录 `cache_hit`、QPS 和 p99，结果写入：

```text
artifacts/grpc-fast-cache-bench/<timestamp>/summary.md
```

最新 VM 结果：

```text
artifact:                    artifacts/grpc-fast-cache-bench/20260630-165008/summary.md
direct backend:              808.07 qps, p99 4067.90 us
cache hit SERVING:          2985.40 qps, p99 1223.09 us
cache hit NOT_SERVING:      2209.13 qps, p99 3932.00 us
response cache miss fallback: 751.12 qps, p99 8203.98 us
policy miss fallback:        778.52 qps, p99 4844.19 us
speedup:                    qps 3.69x, p99 3.33x
cache_hit=2092 serving_cache_hit=1050 not_serving_cache_hit=1042
response_cache_miss=1041 fallback=1041 fallback_error=0 tx_error=0
policy_miss=1042 fallback=1042 fallback_error=0 tx_error=0
```

## 运行时策略

`cachectl` 是第一版用户态运行时策略工具：

```bash
./build/cachectl --policy-file cache-policy.txt --validate-only
sudo ./build/cachectl --policy-file cache-policy.txt --dns-map /sys/fs/bpf/dns_cache --grpc-map /sys/fs/bpf/ebpf-network-service-cache/grpc_policy_map
```

它可以校验 DNS 缓存文件，并写入 pinned `dns_cache` map。`dns_monitor` 和 `cachectl` 共享同一套解析与 map 编码逻辑。统一策略文件可同时包含 DNS 缓存记录和 gRPC 方法白名单；DNS 条目写入 `dns_cache`，gRPC 方法白名单写入与 `grpc_policy_map` 兼容的 pinned hash map。`grpc_monitor` 可在启动时通过 `--pin-dir` pin 住该 map，完成第一阶段缓存策略模块闭环。

## 虚拟化路径实验

虚拟化 benchmark 使用 `netns + bridge + veth` 模拟 KVM 类 guest-to-bridge-to-guest 路径。

VM 结果：

```text
topology=netns+bridge+veth
success=1000 failed=0
qps=2129.59
avg_us=384.70 p50_us=254.22 p95_us=701.68 p99_us=3314.93
ping loss=0%
```

OpenStack path probe 和 attach smoke 已在 VMware DevStack VM 上运行。probe 找到 12 个候选挂载接口，包括 `br-ex`、`br-int`、`ens33`、`ovs-system`、`virbr0` 和 veth 链路。tc attach smoke 验证 DNS 与 gRPC monitor 都能在真实 OVS integration bridge `br-int` 上挂载并卸载。

Kubernetes path probe 是只读云原生扩展：运行在 Kubernetes 节点时会采集 node 接口、CNI 链路、pod/service 信号和 tc/XDP 候选挂载点，不修改集群。

更严格的 workload evidence 脚本：

```text
bench/openstack_workload_evidence.sh
bench/k8s_workload_evidence.sh
```

OpenStack runner 记录 DevStack/OVS/libvirt 状态，并在提供 `OPENSTACK_TRAFFIC_CMD` 时捕获真实租户流量；未提供时明确标记为 `ovs-host-netns-fallback`，因此只能作为回归证据，不能描述成 VM-to-VM 结论。Kubernetes runner 创建临时 namespace，运行 Pod-to-Service gRPC transport 流量，在 CoreDNS 可用时发送 DNS 查询，并采集 DNS/gRPC monitor 日志。

最新 VM 证据：

```text
OpenStack artifact: artifacts/openstack-workload-evidence/20260630-162110/summary.md
OpenStack fallback DNS: count=30 failed=0, monitor qps=33 rps=33 ringbuf_drop=0
OpenStack fallback gRPC transport: count=30 failed=0, monitor reqps=28 resps=29 p99=0.311ms

Kubernetes artifact: artifacts/k8s-workload-evidence/20260630-161729/summary.md
Kubernetes DNS Pod-to-Service: count=20 failed=0, cni0 monitor qps=1 ringbuf_drop=0
Kubernetes gRPC transport Pod-to-Service: count=20 failed=0, pod-veth monitor reqps=22 resps=44 p99=0.175ms
```

开源环境接入加速比：

| 开源环境 | 已验证路径 | DNS XDP cache | gRPC h2c fast-cache |
| --- | --- | ---: | ---: |
| OpenStack / OVS / KVM | `br-int` attach smoke + OpenStack workload evidence | `7.14x` QPS，`182.52x` p99 | `3.69x` QPS，`3.33x` p99 |
| Kubernetes / CNI / Pod veth | Pod-to-Service workload evidence + 非零 monitor 计数 | `7.14x` QPS，`182.52x` p99 | `3.69x` QPS，`3.33x` p99 |

以上加速比来自同一 VM 快路径 benchmark 产物 `dns-xdp-cache-bench/20260630-164919` 和 `grpc-fast-cache-bench/20260630-165008`。OpenStack 与 Kubernetes 运行证明程序可挂载到这些开源环境并观察 workload 路径；当前不声称已完成生产级租户 VM-to-VM 或 Pod-to-Pod 端到端加速测量。

VMware 实验环境有一个操作约束：DevStack etcd 与 kubeadm control-plane etcd 都会绑定 `192.168.106.130:2379/2380`。因此这台 VM 上 OpenStack 和 Kubernetes 证据需要分时采集，demo 时需要说明。

## 相关工作与基线

相近 DNS/eBPF 工作包括 hyDNS 和 Xpress DNS。Xpress DNS 已从 legacy map 定义 patch 到现代 BTF map 定义，并在同一 VM 上测试。短对比结果：

```text
userspace DNS stub:      65771.87 qps, p99 381.44 us
patched Xpress DNS:     385295.75 qps, p99 4.92 us
this project XDP cache: 413933.01 qps, p99 2.82 us
```

项目定位应是“DNS + gRPC 双服务 eBPF 监控与加速原型，具备统一运行时策略和虚拟化/云原生挂载验证”，不应声称自己是第一个 DNS XDP cache。

## 演示命令

```bash
./scripts/build_linux.sh
DURATION=5 LATENCY_COUNT=10000 ./bench/dns_xdp_cache_bench.sh
REQUESTS=5000 ./bench/grpc_tc_monitor_bench.sh
REQUESTS=1000 ./bench/grpc_fast_cache_bench.sh
REQUESTS=1000 ./bench/virt_path_bench.sh
./build/cachectl --policy-file cache-policy.txt --validate-only
```

## 当前限制

- DNS 加速只处理 `A/IN` 单问题 UDP 缓存命中。
- gRPC 加速当前是窄范围 h2c unary fast-cache 原型，不是通用 HTTP/2/gRPC cache。
- h2c gRPC demo 需要 VM 能访问 Go module 依赖，或提前准备 Go module cache。
- 虚拟化延迟 benchmark 使用 Linux namespaces 和 bridge/veth 保证可复现；真实 DevStack/OVS 已在 `br-int` 验证挂载，Kubernetes 挂载点发现已有脚本，但真实 VM 或 Pod workload 仍需要专门部署 demo。

## 后续工作

- 将 gRPC response cache 条目迁移到 pinned、运行时可更新的 map。
- 增强 HTTP/2 frame 处理，并补充 TLS 感知部署说明。
- 在最终 demo VM 上运行 OpenStack 和 Kubernetes workload evidence 脚本，并把 `summary.md` 数字同步进最终报告。
- 基于 demo runbook 打包最终幻灯片和视频。
