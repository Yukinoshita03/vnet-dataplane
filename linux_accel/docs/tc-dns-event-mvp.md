# tc DNS 性能监控 V1

## 目标

使用 tc ingress/egress 捕获 DNS 数据包，关联 DNS query/response 事件，并按 1 秒窗口输出服务性能指标。所有流量仍返回 `TC_ACT_OK`，不 drop、不 redirect、不改包。

## 事件字段

`dns_event` 记录以下字段：

- `timestamp_ns`
- `direction`：`1 ingress`，`2 egress`
- `ifindex`
- `packet_len`
- `src_ip`
- `dst_ip`
- `src_port`
- `dst_port`
- `dns_id`
- `is_response`
- `rcode`
- `matched`
- `latency_ns`

当前 MVP 仅支持 IPv4 UDP DNS。

## 指标

用户态 reader 按 1 秒窗口聚合：

- `qps`：每秒 DNS query 事件数
- `rps`：每秒 DNS response 事件数
- `pending`：尚未匹配到响应的 query 数
- `timeout`：超过 `--timeout-ms` 的 query 数
- `avg`、`p95`、`p99`：已匹配 query/response 的响应延迟
- `rcode_*`：DNS response code 计数
- `ringbuf_drop`：BPF ring buffer 满导致丢失的事件数
- `alerts`：`traffic_spike`、`latency_spike`、`ringbuf_drop` 或 `none`

Query/response 匹配 key：

```text
client_ip + server_ip + client_port + server_port + dns_id
```

BPF 程序把 query 时间戳记录到 LRU hash map `dns_query_start`。响应包查询同一 key，计算 `latency_ns`，删除 key，并通过 ring buffer 输出事件。

## Linux 构建

安装依赖：

```bash
sudo apt-get update
sudo apt-get install -y clang llvm bpftool libbpf-dev libelf-dev zlib1g-dev linux-headers-$(uname -r)
```

构建：

```bash
./scripts/build_linux.sh
```

macOS 仅作为编辑环境。可以用仓库内 header shim 做语法检查：

```bash
clang -fsyntax-only -I third_party/bpf-headers -I include bpf/dns_monitor.c
clang -target bpf -D__BPF_TARGET__ -fsyntax-only -I third_party/bpf-headers -I include bpf/dns_monitor.c
```

## 运行

挂载到接口：

```bash
sudo ./build/dns_monitor --dev eth0
```

tc 路径仍是默认路径，用作功能完整的监控基线和后续性能对比。运行 XDP 路径：

```bash
sudo ./build/dns_monitor --dev eth0 --hook xdp --xdp-mode native
sudo ./build/dns_monitor --dev eth0 --hook xdp --xdp-mode generic
```

XDP 模式只观察 ingress 包，目标是快速监控和缓存快路径；tc ingress/egress 仍适合做双向延迟对比。

XDP 也可以预加载静态 DNS 缓存条目。缓存命中时，程序在 XDP 内构造 IPv4 UDP DNS A 响应并通过 `XDP_TX` 回包。

```bash
sudo ./build/dns_monitor --dev eth0 --hook xdp --xdp-mode generic \
  --cache-domain example.test --cache-ip 10.0.0.123 --cache-ttl 60
```

多条缓存使用空白分隔的缓存文件：

```text
example.test 10.0.0.123 60
api.test 10.0.0.124 60
db.test 10.0.0.125 60
```

```bash
sudo ./build/dns_monitor --dev eth0 --hook xdp --xdp-mode generic \
  --cache-file dns-cache.txt
```

当前 XDP 加速路径故意收窄：IPv4 UDP DNS、单问题、`A/IN`、未压缩 QNAME、仅缓存命中。未命中、非支持类型、DNS 响应包、分片、IPv6、TCP DNS、复杂 EDNS 包和不可缓存包都会放行。

生成可缓存标准 DNS 查询：

```bash
dig +noedns example.test
```

期望指标字段：

```text
cache_hit=1 cache_miss=0 cache_expired=0 cache_tx=1
```

## 可复现 XDP Cache Benchmark

benchmark runner 创建 Linux `netns + veth` 拓扑，对比用户态 UDP DNS stub 与 XDP cache，并记录 `dnsperf` 和 p99 latency bench 结果：

```bash
./bench/dns_xdp_cache_bench.sh
```

脚本依赖 `dnsperf`、`gcc`、`ip` 和预构建的 `./build/dns_monitor`，不会自动安装包。结果写入：

```text
artifacts/dns-xdp-cache-bench/<timestamp>/summary.md
```

VMware Ubuntu VM 中 `netns + veth`、generic XDP、`dnsperf` 和 C latency bench 的最新实测：

```text
artifact:  artifacts/dns-xdp-cache-bench/20260630-164919/summary.md
userspace: 74702.04 qps, p99 793.97 us
xdp-cache: 533691.56 qps, p99 4.35 us
speedup:   qps 7.14x, p99 182.52x
metrics:   cache_hit=10500 cache_tx=10500 ringbuf_drop=0
```

这些数字来自 Linux VM benchmark 路径，不是 Windows PowerShell RTT。运行产物写入 `artifacts/dns-xdp-cache-bench/<timestamp>/summary.md`。

## tc 监控与 generic XDP 缓存对比

需要同一 `netns + veth` 拓扑下的 hook 级对比时运行：

```bash
DURATION=5 LATENCY_COUNT=10000 ./bench/dns_tc_vs_xdp_bench.sh
```

脚本运行三组：

- 无 eBPF hook 的 userspace DNS stub；
- 挂载 tc ingress/egress monitor 的 userspace DNS stub；
- 不启动 userspace DNS stub、直接命中 generic XDP cache 的路径。

结果表输出每条路径的 QPS 和 p99，并给出 generic XDP 相对 userspace 与 tc-monitor 的加速比。产物写入：

```text
artifacts/dns-tc-vs-xdp-bench/<timestamp>/summary.md
```

常用选项：

```bash
sudo ./build/dns_monitor --dev eth0 --timeout-ms 2000
sudo ./build/dns_monitor --dev eth0 --verbose-events
sudo ./build/dns_monitor --dev eth0 --qps-spike-factor 3 --latency-spike-factor 3
```

Parallels VM 单次 demo：

```bash
sudo ./scripts/parallels_dns_v1_demo.sh --vm "Ubuntu 24.04 ARM64" --dev bond0
```

期望产物：

- `artifacts/dns-v1-demo/<timestamp>/host-env.log`
- `artifacts/dns-v1-demo/<timestamp>/demo.log`
- `artifacts/dns-v1-demo/<timestamp>/tc-before.log`
- `artifacts/dns-v1-demo/<timestamp>/tc-after.log`
- `artifacts/dns-v1-demo/<timestamp>/dns_monitor.log`
- `artifacts/dns-v1-demo/<timestamp>/tcpdump.log`

生成 DNS 流量：

```bash
dig example.com
```

用 tcpdump 验证：

```bash
sudo tcpdump -i eth0 udp port 53 -nn
```

期望输出：

```text
dns_metrics dev=eth0 qps=120 rps=118 pending=4 timeout=2 avg=1.800ms p95=5.400ms p99=12.900ms rcode_noerror=116 rcode_nxdomain=2 ringbuf_drop=0 alerts=none
```

开启 `--verbose-events` 后，也会打印逐事件输出：

```text
[ingress] 192.168.1.10:53000 -> 8.8.8.8:53 id=1234 query rcode=0 matched=0 latency_ms=0.000 len=...
[egress] 8.8.8.8:53 -> 192.168.1.10:53000 id=1234 response rcode=0 matched=1 latency_ms=1.800 len=...
```

## 测试场景

基本 query/response：

```bash
dig example.com
```

rcode：

```bash
dig nonexistent-domain-for-test.example
```

timeout：

```bash
dig @192.0.2.1 example.com +time=1 +tries=1
```

负载：

```bash
for i in $(seq 1 100); do dig example.com >/dev/null & done; wait
```

## 清理

reader 退出时会卸载 ingress 和 egress 程序。

demo runner 也会记录 tc 前后状态，便于在 artifact bundle 中确认清理结果。

如需手动清理：

```bash
sudo tc qdisc del dev eth0 clsact
```

查看已挂载程序：

```bash
sudo tc filter show dev eth0 ingress
sudo tc filter show dev eth0 egress
sudo bpftool prog list
sudo bpftool map list
```

## 非目标

- 不支持 IPv6；
- 不支持 TCP DNS；
- 不加速 AAAA/CNAME/EDNS；
- 不加速压缩 QNAME；
- 除缓存命中 `XDP_TX` 外，不 drop、不 redirect 数据包。
