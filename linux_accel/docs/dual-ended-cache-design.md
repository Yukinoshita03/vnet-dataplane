# 双端缓存设计

本文档定义赛题项目的缓存架构：基于 eBPF 的网络服务加速，并支持客户端侧与服务端侧缓存。当前已实现的快路径包括 DNS XDP cache，以及接入 `grpc_policy_map` 的窄范围 gRPC h2c unary fast-cache/proxy。

## 目标

- 使用 eBPF 监控服务流量，使缓存策略能基于实时流量、延迟和 hit/miss 数据调整。
- 将安全的缓存命中尽量前移到数据包入口处处理。
- 保留 tc 基线，便于可观测性和性能对比。
- 用户态控制面可配置哪些记录、方法和策略允许缓存。

## 架构

```text
Client
  |
  | request
  v
+----------------------------+
| client-side eBPF hook      |
| - observe request rate     |
| - optional local cache hit |
| - pass misses              |
+----------------------------+
  |
  v
Network / VM path
  |
  v
+----------------------------+
| server-side eBPF hook      |
| - observe service latency  |
| - fast response on hit     |
| - update metrics maps      |
+----------------------------+
  |
  v
Service process

Userspace control plane:
- loads cache entries and policies into eBPF maps;
- reads metrics and hit/miss counters;
- changes cache policy without recompiling eBPF programs.
```

## DNS 缓存路径

已实现范围：

- 服务：UDP/IPv4 DNS。
- Hook：XDP 用于缓存快路径，tc 用于双向监控基线。
- 缓存 key：编码后的 QNAME + QTYPE + QCLASS。
- 缓存 value：IPv4 A 记录 + TTL + 过期时间戳。
- 快路径：缓存命中时在 XDP 内构造 DNS 响应并返回 `XDP_TX`。
- 未命中路径：返回 `XDP_PASS` 放行。

当前限制：

- 仅支持 `A/IN` 单问题查询。
- 仅支持未压缩 QNAME。
- 暂不加速 IPv6、TCP DNS、AAAA、CNAME、EDNS 和多问题查询。

这已经足够展示核心价值：重复且安全的查询可以绕过用户态 DNS 服务，直接在内核快路径返回。

## gRPC 缓存路径

已实现范围：

- 服务：TCP/IPv4 上的 gRPC transport。
- Hook：tc ingress/egress monitor + 用户态 h2c fast-cache/proxy。
- 指标：请求包、响应包、transport RTT、pending flows、timeout、ring buffer drop、best-effort h2c 标记。
- 仅支持 h2c，不支持 TLS。
- 仅支持 unary RPC，不支持 streaming。
- 用户态通过 pinned `grpc_policy_map` 配置方法白名单。
- 缓存 key 来自 h2c `:path` 方法 hash 与 gRPC DATA payload hash。
- 缓存响应条目从 `grpc-cache` 策略记录加载。
- 只有显式标记为 idempotent 的方法才允许缓存响应。

这样可以避免把任意 gRPC 调用错误描述成“都能安全缓存”。

## 策略模型

用户态控制面负责缓存策略，eBPF map 负责快路径数据面。

策略字段：

- 服务类型：`dns` 或 `grpc`；
- hook 位置：`client`、`server` 或 `both`；
- 可缓存规则：DNS 域名或 gRPC 方法白名单；
- TTL 秒数；
- 最大条目数；
- 淘汰策略：第一阶段使用 LRU map 行为；
- 是否启用快速响应。

策略使用的指标：

- cache hit、miss、expired、快速发送响应数；
- 请求/响应速率；
- p50/p95/p99 延迟；
- timeout 和 unmatched response 数；
- ring buffer drop 数。

## 客户端侧与服务端侧角色

客户端侧缓存：

- 对重复安全请求避免网络与服务端处理；
- 最适合 DNS 和明确可缓存的 unary RPC；
- TTL 和失效规则应更严格。

服务端侧缓存：

- 在保持集中策略的同时降低服务进程负载；
- 不需要给所有客户端部署 hook；
- 可与虚拟化 demo 中的 VM host-side interception 配合。

当前里程碑中，DNS XDP cache 作为服务端侧快路径。相同的 map 驱动策略模型后续可以镜像到客户端侧。

## 基准测试证据

VMware Ubuntu VM 中 `netns + veth` 拓扑下的 DNS XDP cache 最新 benchmark：

```text
artifact:           artifacts/dns-xdp-cache-bench/20260630-164919/summary.md
userspace DNS stub: 74702.04 qps, p99 793.97 us
XDP cache:          533691.56 qps, p99 4.35 us
speedup:            qps 7.14x, p99 182.52x
cache_hit=10500 cache_tx=10500 ringbuf_drop=0
```

VMware Ubuntu VM 中的 gRPC fast-cache 最新 benchmark：

```text
artifact:                    artifacts/grpc-fast-cache-bench/20260630-165008/summary.md
direct backend:              808.07 qps, p99 4067.90 us
cache hit SERVING:          2985.40 qps, p99 1223.09 us
speedup:                    qps 3.69x, p99 3.33x
cache_hit=2092 serving_cache_hit=1050 not_serving_cache_hit=1042
response_cache_miss=1041 fallback=1041 fallback_error=0 tx_error=0
policy_miss=1042 fallback=1042 fallback_error=0 tx_error=0
```

DNS 证明了内核 XDP 加速路径。gRPC 证明了第二类服务的监控路径，以及对安全 idempotent h2c unary 方法进行策略控制的快缓存路径。

## 下一步实现

1. 将 gRPC response-cache 条目从 `grpc_fast_cache` 进程内存迁移到 pinned、运行时可更新的 map。
2. 增强 HTTP/2 frame 处理，并补充 TLS 部署说明。
3. 增加客户端侧缓存实验，复用当前服务端侧策略模型。
4. 在 OpenStack `br-int` 路径生成真实 VM-to-VM workload 流量。
