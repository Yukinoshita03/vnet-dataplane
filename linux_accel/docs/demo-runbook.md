# 演示手册

本文档给出当前项目状态下推荐的现场演示顺序。

推荐顺序：构建、DNS XDP 加速、gRPC 监控、gRPC fast-cache 加速、统一策略 CLI、虚拟化路径基准测试、OpenStack/Kubernetes 挂载探测、OpenStack/Kubernetes workload 证据、基线对比。

## 1. 构建

需要 root 权限的命令建议先在交互式 shell 中执行：

```bash
sudo -v
```

非交互式运行可使用 `SUDO_PASS=<sudo-password>`，但真实密码不能提交到仓库文档或脚本。

```bash
./scripts/build_linux.sh
```

期望产物：

```text
build/dns_monitor.bpf.o
build/dns_xdp_monitor.bpf.o
build/grpc_monitor.bpf.o
build/dns_monitor
build/grpc_monitor
build/grpc_fast_cache
build/cachectl
```

## 2. DNS XDP Cache 加速

```bash
DURATION=5 LATENCY_COUNT=10000 LATENCY_WARMUP=500 ./bench/dns_xdp_cache_bench.sh
```

期望证据：

- userspace DNS stub 的 QPS 和 p99。
- XDP cache 的 QPS 和 p99。
- speedup 行。
- `cache_hit > 0`、`cache_tx > 0`、`ringbuf_drop=0`。

近期结果：

```text
artifact: artifacts/dns-xdp-cache-bench/20260630-164919/summary.md
userspace: 74702.04 qps / p99 793.97 us
XDP cache: 533691.56 qps / p99 4.35 us
speedup: qps 7.14x / p99 182.52x
cache_hit=10500 cache_tx=10500 ringbuf_drop=0
```

可选 hook 对比：

```bash
DURATION=5 LATENCY_COUNT=10000 ./bench/dns_tc_vs_xdp_bench.sh
```

期望证据：

- userspace baseline QPS 和 p99。
- tc-monitor QPS 和 p99。
- generic XDP cache-hit QPS 和 p99。
- XDP 相对 userspace 和 tc-monitor 的加速比。

## 3. gRPC tc Monitor

```bash
REQUESTS=5000 WARMUP=200 ./bench/grpc_tc_monitor_bench.sh
```

期望证据：

- `success > 0` 且 `failed=0`。
- `grpc_metrics` 行中 `reqps > 0`、`resps > 0`。
- `ringbuf_drop=0`。

近期结果：

```text
success=5000 failed=0 qps=2156.05 ringbuf_drop=0
```

## 4. 运行时策略 CLI

创建示例文件：

```bash
cat > /tmp/cache-policy.txt <<'EOF'
dns example.test 10.0.0.123 60
dns api.test 10.0.0.124 30
grpc /grpc.health.v1.Health/Check 60 idempotent
grpc-cache /grpc.health.v1.Health/Check demo SERVING 60
grpc-cache /grpc.health.v1.Health/Check down NOT_SERVING 60
EOF
```

校验：

```bash
./build/cachectl --policy-file /tmp/cache-policy.txt --validate-only
```

期望输出：

```text
Validated cache policy file /tmp/cache-policy.txt dns_entries=2 grpc_entries=1 grpc_cache_entries=2
```

## 5. 虚拟化路径基准测试

```bash
REQUESTS=1000 WARMUP=50 ./bench/virt_path_bench.sh
```

期望证据：

- `topology=netns+bridge+veth`。
- `success > 0` 且 `failed=0`。
- ping 丢包率为 `0%`。

近期结果：

```text
success=1000 failed=0 qps=2129.59 p99_us=3314.93 ping loss=0%
```

可选真实 OpenStack/KVM 路径发现：

```bash
cd /opt/stack/devstack
source openrc admin admin
cd /path/to/ebpf-network-service-cache
./bench/openstack_path_probe.sh
DURATION=2 IFACES='br-int br-ex ens33' ./bench/openstack_tc_attach_smoke.sh
```

期望证据：

- `artifacts/openstack-path-probe/<timestamp>/summary.md`。
- `candidate-ifaces.txt` 列出 bridge、veth、tap、OVS 或物理接口作为 tc/XDP 候选挂载点。
- `artifacts/openstack-tc-attach-smoke/<timestamp>/summary.md`。
- VMware DevStack VM 中，`br-int` smoke 产生 `dns_tc=attached grpc_tc=attached`。
- 脚本只读，不修改 OpenStack、libvirt、bridge 或 eBPF 状态。

可选 Kubernetes 节点路径发现：

```bash
./bench/k8s_path_probe.sh
```

期望证据：

- `artifacts/k8s-path-probe/<timestamp>/summary.md`。
- 存在候选接口时，`candidate-ifaces.txt` 列出 CNI、pod veth、bridge、overlay 或 node NIC。
- 脚本只读，不修改 Kubernetes、CNI、container runtime、tc、XDP 或 eBPF 状态。

## 6. OpenStack 与 Kubernetes workload 证据

OpenStack/OVS 证据：

```bash
./bench/openstack_workload_evidence.sh
```

期望证据：

- `artifacts/openstack-workload-evidence/<timestamp>/summary.md`。
- OpenStack、OVS、libvirt、Linux interface、tc qdisc 日志。
- DNS 与 gRPC monitor 日志。
- `workload_mode` 明确标注 `external-openstack-workload` 或 `ovs-host-netns-fallback`。

近期 VM 证据：

```text
artifacts/openstack-workload-evidence/20260630-162110/summary.md
dns monitor: qps=33 rps=33 ringbuf_drop=0
grpc monitor: reqps=28 resps=29 p99=0.311ms ringbuf_drop=0
```

如需真实 VM 流量，在 monitor 挂载时传入驱动实例产生流量的命令：

```bash
OPENSTACK_TRAFFIC_CMD='<commands that generate VM DNS/gRPC traffic>' IFACE=br-int ./bench/openstack_workload_evidence.sh
```

如果 Cirros VM 可通过 floating IP 访问：

```bash
OPENSTACK_TARGET_IP=<floating-ip> GRPC_PORT=22 IFACE=br-int ./bench/openstack_workload_evidence.sh
```

Kubernetes Pod 证据：

```bash
./bench/k8s_workload_evidence.sh
```

期望证据：

- `artifacts/k8s-workload-evidence/<timestamp>/summary.md`。
- 临时 namespace、Pod、Service、node/interface 日志。
- CoreDNS 可用时的 DNS Pod-to-Service 结果。
- gRPC Pod-to-Service client 结果。
- DNS/gRPC monitor 日志行。

当前 DevStack+kubeadm VM 中，运行 Kubernetes 证据前需要停止 `devstack@etcd`，因为 kubeadm etcd 使用相同 `2379/2380` 端口。Kubernetes 运行结束后再启动 `devstack@etcd`。

近期 VM 证据：

```text
artifacts/k8s-workload-evidence/20260630-161729/summary.md
dns client: count=20 failed=0 qps=20.00
grpc client: count=20 failed=0 qps=20.00
grpc pod-veth monitor: reqps=22 resps=44 p99=0.175ms ringbuf_drop=0
```

交互式 shell 运行前执行 `sudo -v`。非交互式运行可使用 `SUDO_PASS=<sudo-password>`；不要提交真实密码。

## 7. gRPC 快缓存原型

```bash
REQUESTS=1000 ./bench/grpc_fast_cache_bench.sh
```

期望证据：

- backend gRPC QPS 和 p99。
- `grpc_fast_cache` QPS 和 p99。
- SERVING 和 NOT_SERVING cache-hit 计数。
- 同方法、未缓存 payload 的 response-cache miss fallback。
- policy-miss fallback QPS 和 p99。
- cache stats 行中 `cache_hit > 0`。
- fallback stats 行中 `fallback > 0` 且 `fallback_error=0`。
- 流量开始前通过 `cachectl` 加载 `grpc_policy_map`。
- `grpc-cache` 响应条目由 `grpc_fast_cache --cache-file` 从同一策略文件加载。
- cache-hit 和 fallback 使用 h2c `:path` 与 DATA payload hash，证明 cache key 是“方法 + 请求体”。

近期结果：

```text
artifact: artifacts/grpc-fast-cache-bench/20260630-165008/summary.md
direct backend: 808.07 qps / p99 4067.90 us
cache hit SERVING: 2985.40 qps / p99 1223.09 us
cache hit NOT_SERVING: 2209.13 qps / p99 3932.00 us
response cache miss fallback: 751.12 qps / p99 8203.98 us
policy miss fallback: 778.52 qps / p99 4844.19 us
speedup: qps 3.69x / p99 3.33x
cache_hit=2092 fallback_error=0 tx_error=0
```

这是窄范围 h2c unary cache/proxy demo。它证明 `grpc_policy_map` 已接入真实快速响应路径，方法选择来自请求 `:path`，响应缓存 key 包含请求 payload，未命中仍能到达后端。

## 8. 可选 h2c gRPC Monitor Demo

```bash
REQUESTS=1000 ./bench/grpc_h2c_monitor_bench.sh
```

该命令需要访问 Go module `google.golang.org/grpc`。当前 VM 曾拒绝访问 Go module 源，因此在依赖缓存前，该命令只作为文档化路径，不作为稳定现场 demo。

## 清理检查

benchmark 脚本结束后，检查默认 namespace 或 bridge 是否残留：

```bash
ip netns list | grep -E 'dnsbench|grpcbench|grpch2cbench|virtcli|virtsrv' || true
ip link show br_virt_bench 2>/dev/null || true
```

## 9. gRPC 策略在线更新

```bash
sudo ./build/grpc_monitor --dev eth0 --port 50051 --pin-dir /sys/fs/bpf/ebpf-network-service-cache
sudo ./build/cachectl --policy-file cache-policy.txt --grpc-map /sys/fs/bpf/ebpf-network-service-cache/grpc_policy_map
sudo bpftool map dump pinned /sys/fs/bpf/ebpf-network-service-cache/grpc_policy_map
```

monitor 会 pin 住 `grpc_policy_map`；`cachectl` 可以在 monitor 保持运行时更新同一个 map。

## 10. 基线对比证据

答辩中被问到“DNS XDP cache 是否已有工作”时，使用本节材料。

主文档：

```text
docs/related-work-and-baselines.md
```

同 VM 短对比：

```text
userspace DNS stub:      65771.87 qps, p99 381.44 us
patched Xpress DNS:     385295.75 qps, p99 4.92 us
this project XDP cache: 413933.01 qps, p99 2.82 us
```

答辩表述：

```text
本项目不声称自己是第一个 DNS XDP cache。项目贡献在于：
实现 DNS + gRPC 双服务 eBPF 监控与加速原型，提供统一运行时缓存策略、
可复现 benchmark，以及虚拟化/云原生挂载点验证。
```
