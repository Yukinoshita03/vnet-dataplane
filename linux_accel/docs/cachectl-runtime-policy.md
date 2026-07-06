# cachectl 运行时策略工具

`cachectl` 是项目第一版用户态控制面工具，用于管理 DNS 缓存条目、gRPC 方法白名单，以及 `grpc_fast_cache` 使用的统一 `grpc-cache` 响应策略记录。

## 当前范围

- 在不加载 eBPF 的情况下校验 DNS 缓存文件。
- 将 DNS 缓存文件加载到 pinned `dns_cache` BPF map。
- 复用 `dns_monitor` 的 DNS QNAME 编码和 value 校验逻辑。
- 校验统一 `dns` / `grpc` / `grpc-cache` 策略文件。
- 将 gRPC 方法白名单写入 pinned `grpc_policy_map`。
- 与 `grpc_fast_cache --cache-file` 共享 gRPC 响应缓存策略记录。

缓存文件格式：

```text
domain ipv4 ttl
example.test 10.0.0.123 60
api.test 10.0.0.124 60
```

以 `#` 开头的注释和空行会被忽略。

## 构建

```bash
./scripts/build_linux.sh
```

期望产物：

```text
build/cachectl
```

## 校验策略文件

```bash
./build/cachectl --dns-cache-file dns-cache.txt --validate-only
```

期望输出：

```text
Validated DNS cache file dns-cache.txt entries=2
```

## 加载 pinned DNS 缓存 map

`cachectl` 写入 pinned `dns_cache` map 路径：

```bash
sudo ./build/cachectl \
  --dns-cache-file dns-cache.txt \
  --dns-map /sys/fs/bpf/ebpf-network-service-cache/dns_cache
```

`dns_monitor` 的 XDP 预加载路径仍可在启动时通过 `--cache-file` 直接写入缓存条目。`cachectl` 提供面向 pinned map 的外部控制面路径，用于加载和校验策略。

## 后续工作

- 增加 `cachectl dns list/delete`，便于运维 demo。
- 在客户端侧/服务端侧 hook 都实现后，补充对应策略字段。
- 将 gRPC response-cache 条目迁移到 pinned、运行时可更新的 map。

## 统一缓存策略文件

`cachectl` 支持用一个文本策略文件同时描述 DNS 缓存记录、gRPC 方法白名单和 gRPC 响应缓存：

```text
# kind fields...
dns example.test 10.0.0.123 60
dns api.test 10.0.0.124 30
grpc /demo.Cache/Get 60 idempotent
grpc /demo.Cache/List 30 idempotent
grpc-cache /grpc.health.v1.Health/Check demo SERVING 60
grpc-cache /grpc.health.v1.Health/Check down NOT_SERVING 60
```

校验组合策略：

```bash
./build/cachectl --policy-file cache-policy.txt --validate-only
```

期望输出：

```text
Validated cache policy file cache-policy.txt dns_entries=2 grpc_entries=2 grpc_cache_entries=2
```

提供 `--dns-map` 时，策略中的 DNS 条目会加载到 pinned `dns_cache` map。提供 `--grpc-map` 时，gRPC 方法白名单会加载到与 `grpc_policy_map` 兼容的 pinned hash map，key 为 method hash。`grpc-cache` 条目由 `grpc_fast_cache --cache-file` 消费，用于描述用户态响应缓存 key 和响应枚举值。

gRPC 响应缓存条目格式：

```text
grpc-cache /Service/Method payload SERVING|NOT_SERVING ttl
```

fast-cache key 为 `method_hash + payload_hash`：method 来自 h2c `:path`，payload hash 来自 gRPC DATA message 字节。

## 在线更新流程

1. 使用 `--pin-dir /sys/fs/bpf/ebpf-network-service-cache` 启动 `grpc_monitor`。
2. monitor 会把 `grpc_policy_map` pin 到该目录。
3. 使用 `cachectl --policy-file <file> --grpc-map /sys/fs/bpf/ebpf-network-service-cache/grpc_policy_map` 更新策略。
4. 启动 `grpc_fast_cache --cache-file <file>`，加载匹配的 `grpc-cache` 响应条目。
5. 使用 `bpftool map dump pinned ...` 确认新的白名单条目。

这条链路把 DNS 缓存记录、gRPC 方法策略和 gRPC 响应缓存条目统一到一个文本策略文件中，形成控制面交接路径。
