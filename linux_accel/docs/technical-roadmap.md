# 技术路线

## 建议 MVP

先做窄而可展示的目标：

```text
DNS query
-> tc ingress/egress observability
-> userspace cache control plane
-> XDP/tc fast-path decision
-> benchmark comparison
```

再扩展到：

```text
gRPC request
-> latency tracing
-> hot request detection
-> cache lookup
-> benchmark comparison
```

## 架构

```text
              +--------------------+
Client -----> | XDP/tc eBPF hook   | -----> Service
              +--------------------+
                       |
                       v
              +--------------------+
              | eBPF maps          |
              | metrics/cache keys |
              +--------------------+
                       |
                       v
              +--------------------+
              | userspace control  |
              | policy + telemetry |
              +--------------------+
```

## 阶段 1：可观测性

- 从 tc ingress/egress 做 DNS 监控；
- 跟踪 packet count；
- 跟踪 latency；
- 统计服务请求；
- 从 eBPF maps 导出指标；
- 与 userspace 日志对比。

## 阶段 2：DNS 加速

- 解析 DNS request header；
- 识别重复查询；
- 在 eBPF maps 中维护缓存元数据；
- 评估内核快路径与 userspace 响应路径差异；
- 当前状态：已实现 IPv4 UDP DNS `A/IN` 缓存命中的 XDP cache 快路径，并提供可复现 `netns + veth` benchmark。

## 阶段 3：gRPC 加速

- 从连接级与延迟级可观测性开始；
- 检测重复热点 RPC；
- 基于 method 和 request identity 设计 cache key；
- 明确哪些请求可以安全缓存；
- 当前状态：已实现 TCP/IPv4 `50051` 的 tc transport monitor；
- 当前状态：已实现 h2c unary fast-cache/proxy，面向一个白名单 idempotent health-check 方法，通过 pinned `grpc_policy_map` 和 `grpc-cache` 响应记录控制；
- 下一目标：将 gRPC response-cache 条目迁移到 pinned、运行时可更新的 map，并增强 HTTP/2 frame 处理。

## 阶段 4：双端缓存

- 客户端侧缓存策略；
- 服务端侧缓存策略；
- 动态策略配置；
- 淘汰策略实验；
- cache hit ratio 指标；
- 设计文档：`docs/dual-ended-cache-design.md`。

## 阶段 5：虚拟化优化

- 分析 KVM VM 到 host service 的路径；
- 测量 veth/tap/bridge 数据包路径；
- 原型化 host NIC 侧拦截；
- benchmark host-to-VM 与 VM-to-host 延迟；
- 当前状态：`bench/virt_path_bench.sh` 提供可复现 `netns + bridge + veth` 路径 benchmark；
- 当前状态：VMware DevStack/OVS probe 找到真实候选挂载点，包括 `br-int` 和 `br-ex`；tc attach smoke 验证 DNS 与 gRPC monitor 可挂载到 `br-int`。

## 阶段 6：Demo 与报告

- 可复现脚本；
- benchmark 图表；
- 清晰 demo 流程；
- 架构图；
- 限制与后续工作。
