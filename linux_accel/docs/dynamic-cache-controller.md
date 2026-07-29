# DNS/gRPC 动态双端缓存控制器

## 目标

`dynamic_cache_controller` 根据连续指标窗口，在以下四种运行模式之间切换：

| 模式 | 服务端缓存 | 客户端缓存 | 典型用途 |
| --- | --- | --- | --- |
| `BYPASS` | 关闭 | 关闭 | 错误率过高、命中收益不足或故障降级 |
| `SERVER_CACHE` | 开启 | 关闭 | 命中率足够且网络时延、后端压力较低 |
| `CLIENT_CACHE` | 关闭 | 开启 | 网络尾延迟较高，优先在客户端近端响应 |
| `DUAL_CACHE` | 开启 | 开启 | 后端压力较高，双端同时分担请求 |

DNS 的服务端和客户端 XDP 程序直接读取运行时 map。客户端缓存被关闭时仍保留
`dns_client_pending` 请求关联和可信响应学习，只停止直接响应，因此再次启用时不需要
从空缓存开始。gRPC 当前仍是 h2c 用户态 `grpc_fast_cache` 响应路径；它读取同一控制
结构，并按 `--cache-role server|client` 决定命中缓存还是回退后端。TC gRPC 程序负责
观测与 pinned map 生命周期，不应描述为内核态 gRPC 响应。

## 指标接口

控制器从文件或标准输入持续读取 CSV：

```text
timestamp_ms,dns_hits,dns_misses,dns_p95_us,grpc_hits,grpc_misses,grpc_p95_us,backend_qps,error_rate
```

输入可以是有限测试文件，也可以是监控采集器持续写入的管道。时间戳必须单调不减；
延迟和 QPS 不得为负数；错误率必须位于 `[0, 1]`。非法 CSV 会令进程失败，倒序样本
会被标记为 `stale_timestamp` 并忽略。

默认策略参数：

- 滑动窗口：5 个样本。
- 候选稳定窗口：2 个。
- 切换冷却：10 秒。
- 最小窗口请求数：100。
- 缓存进入/退出命中率：0.35 / 0.20。
- 客户端缓存进入/退出 p95：5000 / 3000 微秒。
- 双端缓存进入/退出后端 QPS：1200 / 800。
- `BYPASS` 错误率：0.05。

进入阈值和退出阈值分离形成迟滞；候选模式必须连续稳定，且上次提交后必须经过冷却
时间，才会发布新策略。

## 运行时 map

BPF ELF 中使用不超过内核名称限制的 `cache_rt_ctl`，稳定 pinned 路径为：

```text
<pin-dir>/cache_runtime_control
```

map 类型是单元素 `BPF_MAP_TYPE_ARRAY`，value 为：

```c
struct cache_runtime_control {
    __u64 epoch;
    __u32 mode;
    __u32 flags;
};
```

零初始化的 value 表示未接入动态控制器，保留旧版缓存行为。`epoch > 0` 且没有
`CACHE_RUNTIME_COMMITTED` 的 value 是切换阶段态，所有读取端都 fail-closed 到后端。

发布器对所有端点 map 执行：

1. 打开、校验并快照全部 map。
2. 写入同一 epoch 的未提交阶段态。
3. 回读确认所有端点均进入阶段态。
4. 写入带 `COMMITTED` 标志的完整 value。
5. 回读确认所有端点的 epoch、模式和标志一致。
6. 任一步失败时，将所有已触碰 map 恢复到快照。

单张 map 的完整 value 更新由内核原子完成；跨 map 切换通过“阶段态一律旁路”避免
旧策略和新策略同时服务请求。它不是分布式共识协议，跨主机正式实验仍需由编排脚本
向各主机发布相同 epoch，并保留每个端点的回读证据。

## 启动示例

DNS 服务端：

```bash
sudo ./build/dns_monitor \
  --dev eth0 --hook xdp --role server --xdp-mode generic \
  --cache-file cache.txt \
  --pin-dir /sys/fs/bpf/vnet-cache/server
```

DNS 客户端：

```bash
sudo ./build/dns_monitor \
  --dev eth0 --hook xdp --role client --xdp-mode generic \
  --trusted-dns 10.0.0.53 \
  --pin-dir /sys/fs/bpf/vnet-cache/client
```

gRPC fast cache：

```bash
sudo ./build/grpc_fast_cache \
  --grpc-map /sys/fs/bpf/vnet-cache/grpc/grpc_policy_map \
  --grpc-response-map /sys/fs/bpf/vnet-cache/grpc/grpc_response_cache \
  --runtime-control-map /sys/fs/bpf/vnet-cache/grpc/cache_runtime_control \
  --cache-role server \
  --listen 0.0.0.0:50052 --backend 10.0.0.20:50051
```

控制器：

```bash
sudo ./build/dynamic_cache_controller \
  --control-map /sys/fs/bpf/vnet-cache/server/cache_runtime_control \
  --control-map /sys/fs/bpf/vnet-cache/client/cache_runtime_control \
  --control-map /sys/fs/bpf/vnet-cache/grpc/cache_runtime_control \
  --initial-mode bypass \
  --audit-log artifacts/dynamic-cache-decisions.log \
  < metrics.csv
```

进程启动时会先以 epoch 1 发布 `--initial-mode`，随后每次成功切换递增 epoch。输出的
`dynamic_cache_decision` 行包含窗口指标、当前模式、候选模式、epoch、切换结果和原因。

## 验证

```bash
./scripts/build_linux.sh
sudo ./tests/bpf_runtime_verifier_test.sh
sudo ./tests/runtime_control_bpf_integration_test.sh
sudo ./tests/dns_runtime_mode_integration_test.sh
sudo ./tests/grpc_runtime_mode_integration_test.sh
```

- `bpf_runtime_verifier_test.sh` 将 DNS 服务端、DNS 客户端和 gRPC TC 对象加载进
  内核 verifier，并在退出时删除临时 pin。
- `runtime_control_bpf_integration_test.sh` 使用两张真实 BPF map 验证正常提交，并通过
  freeze 第二张 map 注入发布失败，确认第一张 map 回滚。
- `dns_runtime_mode_integration_test.sh` 在 netns + veth 上验证 DNS 服务端和客户端角色
  对四种模式的执行结果及后端请求计数。
- `grpc_runtime_mode_integration_test.sh` 在真实 h2c 请求上验证 server/client 两种角色
  的缓存命中和后端回退。

这些测试证明运行时控制、内核 map 读取和失败回滚，不替代 OpenStack 五类负载的五轮
正式性能对比。
