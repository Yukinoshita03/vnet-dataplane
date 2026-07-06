# gRPC tc 监控 MVP

该 MVP 为赛题项目增加第二种网络服务监控能力。它使用 tc ingress/egress 观察 gRPC transport 流量，并与 DNS XDP cache 加速路径保持解耦。

## 范围

当前 gRPC monitor 故意限定在 transport 层：

- 仅支持 IPv4 TCP。
- 默认服务端口：`50051`。
- 仅使用 tc ingress 和 egress。
- 请求侧包定义为目的端口 `50051` 且带 TCP payload 的包。
- 响应侧包定义为源端口 `50051` 且带 TCP payload 的包。
- RTT 使用同一 flow 中首个 client-to-server payload 到首个 server-to-client payload 的时间差估算。
- 不解析 TLS payload。
- 当前里程碑不实现完整 HTTP/2 和 gRPC message 解析。

对于明文 h2c 流量，eBPF 程序会 best-effort 标记看起来包含 HTTP/2 client preface 或 HEADERS frame 的包。这些标记用于 demo，不作为指标正确性的必要条件。

## 构建

```bash
./scripts/build_linux.sh
```

期望 gRPC 产物：

```text
build/grpc_monitor.bpf.o
build/grpc_monitor
```

同一次构建仍应生成 DNS 产物：

```text
build/dns_monitor.bpf.o
build/dns_xdp_monitor.bpf.o
build/dns_monitor
```

## 运行

```bash
sudo ./build/grpc_monitor --dev eth0 --port 50051
sudo ./build/grpc_monitor --dev eth0 --port 50051 --verbose-events
sudo ./build/grpc_monitor --dev eth0 --port 50051 --timeout-ms 2000
```

示例输出：

```text
grpc_metrics dev=eth0 port=50051 reqps=120 resps=120 active_flows=0 pending=0 timeout=0 unmatched=0 avg=0.842ms p50=0.801ms p95=1.441ms p99=1.770ms h2_preface=1 h2_headers=120 ringbuf_drop=0
```

指标含义：

- `reqps`：最近一个报告窗口中看到的请求侧 TCP payload 包数。
- `resps`：最近一个报告窗口中看到的响应侧 TCP payload 包数。
- `active_flows` / `pending`：已看到请求 payload、尚未匹配响应 payload 的 flow。
- `timeout`：用户态过期清理的 pending flow。
- `unmatched`：没有匹配 pending request 的响应 payload 包。
- `avg/p50/p95/p99`：已匹配 flow 的 transport-level RTT 估算值。
- `h2_preface` / `h2_headers`：明文 HTTP/2 best-effort 标记。
- `ringbuf_drop`：BPF ring buffer 满导致丢失的事件数。

## 真实 h2c gRPC Demo Benchmark

需要真实 gRPC 流量而不是简化 TCP stub 时，使用该 runner。它会在 `/tmp/grpc_h2c_demo` 下生成临时 Go module，启动明文 h2c `grpc.health.v1.Health/Check` server，从 network namespace 中运行 client，并在服务端 veth 上记录 `grpc_monitor` 输出。

```bash
./bench/grpc_h2c_monitor_bench.sh
REQUESTS=1000 ./bench/grpc_h2c_monitor_bench.sh
```

脚本依赖 `go`、`ip`、`awk`、`sudo` 和预构建的 `./build/grpc_monitor`。它通过 Go module cache 下载依赖，不安装系统包。如果 VM 无法访问 `proxy.golang.org` 或 `google.golang.org`，需要提前填充 Go module cache，或在可下载 `google.golang.org/grpc` 的网络环境中运行。结果写入：

```text
artifacts/grpc-h2c-monitor-bench/<timestamp>/summary.md
```

该路径证明第二服务 demo 是真实 gRPC/h2c 流量；它本身仍不实现 gRPC 加速或响应缓存，这些由后续 method whitelist 和 cache-key 设计后的 fast-cache 原型承担。

## h2c gRPC 快缓存原型

`grpc_fast_cache` 是第一版 gRPC 加速原型。它刻意收窄范围：h2c、unary 流量、面向 demo 方法的缓存 health-check 响应。它解析请求 HEADERS frame，提取 h2c `:path`，对真实方法名做 hash，并检查 pinned `grpc_policy_map`。方法必须先由 `cachectl` 加载并标记为 idempotent，缓存路径才会直接返回响应。策略未命中和解析失败都会通过 `--backend` 回退到后端 TCP 服务。

响应缓存 key：

```text
method_hash + payload_hash
```

`payload_hash` 从 5 字节 gRPC message prefix 之后的 gRPC DATA message 字节计算。原型从统一策略文件接收响应缓存条目：

```text
grpc /grpc.health.v1.Health/Check 60 idempotent
grpc-cache /grpc.health.v1.Health/Check demo SERVING 60
grpc-cache /grpc.health.v1.Health/Check down NOT_SERVING 60
```

这支持同一方法对应多个缓存响应；如果方法允许缓存但请求 payload 未缓存，则仍回退到后端。

```bash
./scripts/build_linux.sh
REQUESTS=1000 ./bench/grpc_fast_cache_bench.sh
```

benchmark 会创建 `netns + veth`，启动带延迟的 h2c backend，启动 `grpc_monitor` pin 住 `grpc_policy_map`，用 `cachectl` 写入 gRPC 策略，启动 `grpc_fast_cache`，并对比 direct backend、两个 cache-hit payload、response-cache miss fallback 和 policy-miss fallback 延迟。结果写入：

```text
artifacts/grpc-fast-cache-bench/<timestamp>/summary.md
```

VMware Ubuntu VM 中 `netns + veth` 的最新实测：

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

这还不是通用 gRPC cache。TLS、streaming RPC、任意 protobuf payload 序列化和完整 HTTP/2 状态机仍是后续工作。

## 验证

在 `50051` 端口启动任意 TCP 或 gRPC 服务，运行 `grpc_monitor`，并向该端口发送流量。monitor 应显示请求和响应计数增加。如果选中接口能看到两个方向的包，RTT 分位数应变为非零。

monitor 只观察。eBPF 程序始终返回 `TC_ACT_OK`，不 drop、不 redirect、不修改数据包。

## 可复现 tc Monitor Benchmark

benchmark runner 创建 Linux `netns + veth` 拓扑，在 `50051` 端口启动小型 TCP request/response 服务，把 `grpc_monitor` 挂到服务端 veth，并从客户端 namespace 运行 C latency bench：

```bash
./bench/grpc_tc_monitor_bench.sh
```

常用选项：

```bash
REQUESTS=3000 ./bench/grpc_tc_monitor_bench.sh
OUT_DIR=/tmp/grpc-bench REQUESTS=10000 PORT=50051 ./bench/grpc_tc_monitor_bench.sh
```

脚本依赖 `gcc`、`ip`、`python3` 和预构建的 `./build/grpc_monitor`，不会自动安装包。结果写入：

```text
artifacts/grpc-tc-monitor-bench/<timestamp>/summary.md
```

该 benchmark 只验证 monitor 可见性和 transport-level RTT，不声称应用层 gRPC handler latency。正式 demo 避免使用 loopback，因为 `lo` 会看到同一本地 flow 的 ingress 和 egress 副本；`netns + veth` runner 的服务端侧数字更干净。

VMware Ubuntu VM 中 `netns + veth` 的最新实测：

```text
latency bench: count=3000 failed=0 qps=2066.04 avg_us=442.63 p50_us=262.61 p95_us=876.27 p99_us=4017.88
grpc monitor:  reqps=840 resps=840 avg=0.290ms p50=0.161ms p95=0.592ms p99=3.513ms ringbuf_drop=0
```

monitor 行是 `grpc_monitor` 输出的最后一个报告窗口；latency bench 行覆盖完整客户端运行过程。
