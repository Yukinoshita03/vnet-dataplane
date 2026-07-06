# 监控 MVP 的 Hook 选择

## 建议

监控 MVP 先从 **tc ingress/egress** 开始，再为加速快路径补充 XDP。

## 为什么先做 tc

本赛题第一阶段目标不是线速转发，而是：

- 识别服务流量；
- 采集请求计数；
- 采集基础延迟/flow 指标；
- 先验证 DNS；
- 保持对 host、veth、bridge、VM 场景的兼容性。

tc 更适合作为第一阶段 hook：

- 同时支持 ingress 和 egress；
- 基于 `skb`，更适合常规网络路径；
- 更容易挂载到 veth/tap/bridge 类路径；
- 可以在内核元数据更完整的位置检查数据包；
- 相比 XDP，受驱动模式限制更少。

## Hook 选择计划

| 阶段 | Hook | 目的 |
| --- | --- | --- |
| DNS 监控 MVP | tc ingress/egress | 识别 UDP/53 包，统计 query，记录 src/dst/latency 元数据 |
| DNS 缓存原型 | tc ingress/egress + maps | 识别热点 DNS 查询，并把信息交给用户态缓存策略 |
| 快路径加速 | XDP 或 tc | 对比早期 XDP 回包/redirect 是否可行 |
| gRPC 可观测性 | tc + uprobe/kprobe | 包/连接指标 + 用户态 RPC 延迟 |
| 虚拟化实验 | veth/tap/bridge 上的 tc | 测量 host-to-VM 与 VM-to-host 数据包路径 |

## DNS 第一版 MVP

最小 tc 程序：

- 解析 Ethernet；
- 解析 IPv4；
- 解析 UDP；
- 过滤 53 端口；
- 解析 DNS transaction ID 和 flags；
- 统计 query 和 response；
- 将指标存入 eBPF maps；
- 用户态 reader 周期性输出指标。

## 何时使用 XDP

tc 监控稳定后再引入 XDP。

适合 XDP 的场景：

- 早期丢包；
- DNS 缓存命中快速响应；
- redirect；
- 线速数据包处理 benchmark；
- 对比 tc 与 XDP 开销。

不建议一开始就用 XDP：

- 驱动支持差异大；
- generic XDP 可能掩盖真实性能表现；
- 解析与响应构造约束更严格；
- VM/veth/bridge 实验通常用 tc 更容易。

## 第一实现目标

```text
client DNS query
-> tc ingress hook
-> DNS query counter map
-> userspace metrics reader
-> benchmark baseline
```

稳定后再推进：

```text
hot DNS query
-> map lookup
-> cache policy decision
-> tc/XDP fast path experiment
```
