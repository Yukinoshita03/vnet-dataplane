# 赛题完成度矩阵

本文档将赛题要求映射到当前项目实现和可复现实验证据。

## 总览

| 赛题要求 | 状态 | 证据 |
| --- | --- | --- |
| 使用 eBPF 实时监控服务性能 | 已完成 | DNS tc monitor 与 gRPC tc monitor |
| 使用 eBPF 实现性能优化 | 已完成 | DNS XDP cache 与 gRPC h2c fast-cache/proxy |
| 支持两种以上网络服务 | 已完成 | DNS 与 gRPC |
| 虚拟化数据包路径优化实验 | 已完成 | `netns + bridge + veth` benchmark |
| OpenStack/Kubernetes 挂载点证据 | 已完成 | OpenStack tc smoke、Kubernetes 路径探测、workload evidence 脚本 |
| 双端缓存设计与动态策略 | 进行中 | 设计文档、统一策略文件、pinned response map 与 `cachectl --replace`；待 Linux/OpenStack 实测 |
| 可复现 benchmark 与 demo | 已完成 | `bench/` 脚本与 demo runbook |

## 需求明细

| 赛题项 | 实现方式 | 主要文件 | benchmark / demo 证据 |
| --- | --- | --- | --- |
| 监控服务性能 | DNS tc ingress/egress 事件与指标；gRPC tc transport 指标 | `bpf/dns_monitor.c`、`src/dns_monitor.cpp`、`bpf/grpc_monitor.c`、`src/grpc_monitor.cpp` | `bench/grpc_tc_monitor_bench.sh`：`success=5000 failed=0 qps=2156.05 ringbuf_drop=0` |
| 加速 DNS | XDP DNS 缓存命中路径直接 `XDP_TX` 回包 | `bpf/dns_xdp_monitor.c`、`src/dns_monitor.cpp`、`src/dns_cache_config.cpp` | `bench/dns_xdp_cache_bench.sh`：QPS `7.14x`，p99 `182.52x`，`cache_hit=10500 cache_tx=10500 ringbuf_drop=0` |
| 对比 tc 与 XDP | 同一拓扑对比 no-hook userspace、tc monitor、generic XDP cache-hit 路径 | `bench/dns_tc_vs_xdp_bench.sh`、`docs/tc-dns-event-mvp.md` | 生成 `artifacts/dns-tc-vs-xdp-bench/<timestamp>/summary.md`，包含 QPS 和 p99 对比 |
| 加速 gRPC | h2c unary fast-cache/proxy 接入 `grpc_policy_map`，用 `method_hash + payload_hash` 做响应缓存 key | `src/grpc_fast_cache.cpp`、`bpf/grpc_monitor.c`、`src/cache_policy.cpp` | `bench/grpc_fast_cache_bench.sh`：QPS `3.69x`，p99 `3.33x`，`fallback_error=0 tx_error=0` |
| OpenStack VM-to-VM gRPC E2E | 临时 backend/cache/client VM，cache VM 通过 pinned policy/response map 提供命中和动态更新 | `bench/openstack_grpc_e2e.sh`、`bench/openstack_grpc_harness.c`、`docs/openstack-grpc-e2e.md` | 脚本已完成；当前等待 Shuka1 SSH 恢复后执行并记录 QPS、cache-only、`SERVING→NOT_SERVING` |
| 支持至少两种服务 | DNS 和 gRPC 都具备监控与加速路径 | `bpf/dns_*`、`src/dns_*`、`bpf/grpc_monitor.c`、`src/grpc_*` | DNS XDP benchmark 与 gRPC fast-cache benchmark |
| 动态缓存策略配置 | 统一策略文件支持 `dns`、`grpc`、`grpc-cache`；`cachectl` 校验并加载 DNS/gRPC BPF map | `src/cachectl.cpp`、`src/cache_policy.cpp`、`src/include/cache_policy.hpp` | `cachectl --policy-file --validate-only` 输出 `dns_entries`、`grpc_entries`、`grpc_cache_entries` |
| 双端缓存架构 | 文档说明客户端/服务端角色、hook 选择、策略模型和 hit/miss 指标 | `docs/dual-ended-cache-design.md` | 作为最终报告和 demo 的设计证据 |
| 虚拟化数据包路径 | bridge/veth namespace 拓扑模拟 KVM/tap 路径；OpenStack/KVM 探测真实挂载点；tc smoke 验证 `br-int` 可挂载 | `bench/virt_path_bench.sh`、`bench/openstack_path_probe.sh`、`bench/openstack_tc_attach_smoke.sh`、`bench/openstack_workload_evidence.sh` | `success=1000 failed=0 qps=2129.59 p99_us=3314.93 ping loss=0%`；DevStack 探测到 12 个候选接口；`br-int` smoke：`dns_tc=attached grpc_tc=attached` |
| 云原生挂载路径 | Kubernetes 脚本枚举 node、CNI、pod-veth、tc/XDP 候选点，并部署临时 Pod 流量采集 DNS/gRPC monitor 计数 | `bench/k8s_path_probe.sh`、`bench/k8s_workload_evidence.sh`、`docs/cloud-native-integration.md` | 生成 `artifacts/k8s-path-probe/<timestamp>/summary.md` 和 `artifacts/k8s-workload-evidence/<timestamp>/summary.md` |
| 相关工作与基线对比 | 文档记录相近 DNS/eBPF 工作，并完成同 VM Xpress DNS 对比 | `docs/related-work-and-baselines.md` | 本项目 DNS XDP cache：`413933.01 qps`，p99 `2.82 us`；patch 后 Xpress DNS：`385295.75 qps`，p99 `4.92 us` |
| 可复现 demo | 一键构建和 benchmark 脚本 | `scripts/build_linux.sh`、`docs/demo-runbook.md`、`bench/*.sh` | 构建生成 DNS/gRPC BPF 对象、loader、`cachectl` 和 `grpc_fast_cache` |

## 最终性能快照

| 服务 | 基线 | 加速路径 | QPS 加速比 | p99 提升 |
| --- | ---: | ---: | ---: | ---: |
| DNS | userspace DNS stub | XDP cache | `7.14x` | `182.52x` |
| gRPC | h2c backend | fast-cache SERVING hit | `3.69x` | `3.33x` |

## 最终 smoke test 快照

这些短测试在最终策略和 gRPC fast-cache 集成后执行，用于证明 demo 路径仍可构建，关键计数器正常变化。

| 检查项 | 证据 |
| --- | --- |
| 构建 | `scripts/build_linux.sh` 生成 DNS BPF、XDP BPF、gRPC BPF、`dns_monitor`、`grpc_monitor`、`grpc_fast_cache`、`cachectl` |
| 统一策略解析 | `dns_entries=2 grpc_entries=1 grpc_cache_entries=2` |
| 最新 DNS benchmark | `dns-xdp-cache-bench/20260630-164919`：userspace `74702.04 qps`，XDP cache `533691.56 qps`，QPS `7.14x`，p99 `182.52x`，`cache_hit=10500 cache_tx=10500 ringbuf_drop=0` |
| 最新 gRPC fast-cache benchmark | `grpc-fast-cache-bench/20260630-165008`：direct `808.07 qps`，SERVING hit `2985.40 qps`，QPS `3.69x`，p99 `3.33x`，`cache_hit=2092 fallback_error=0 tx_error=0` |
| DNS XDP cache smoke | `539976.493631 qps`，p99 `2.97 us`，`cache_hit=8189 cache_tx=8184 ringbuf_drop=0` |
| gRPC fast-cache smoke | `serving_cache_hit=330 not_serving_cache_hit=321 response_cache_miss=328 fallback=655 fallback_error=0 tx_error=0` |
| 虚拟化路径 | `success=300 failed=0 qps=1244.03 p99_us=9332.99 ping loss=0%` |
| OpenStack/KVM 路径探测 | VM 只读探测发现 12 个 tc/XDP 候选接口：`br-ex`、`br-int`、`ens33`、`ovs-system`、`virbr0` 和 veth 链路 |
| OpenStack/OVS tc 挂载 | VM 在 `br-int` 上完成 smoke：`dns_tc=attached grpc_tc=attached`，产物 `openstack-tc-attach-smoke/20260627-160408` |
| Kubernetes 路径探测 | `bench/k8s_path_probe.sh` 在 Kubernetes 节点上记录 node/CNI/pod-veth 候选挂载点 |
| OpenStack workload 证据 | `openstack-workload-evidence/20260630-162110`：DNS `count=30 failed=0`，monitor `qps=33 rps=33`；gRPC transport `count=30 failed=0`，monitor `reqps=28 resps=29 p99=0.311ms` |
| Kubernetes workload 证据 | `k8s-workload-evidence/20260630-161729`：DNS Pod-to-Service `count=20 failed=0`；gRPC transport Pod-to-Service `count=20 failed=0`，pod-veth monitor `reqps=22 resps=44 p99=0.175ms` |
| OpenStack/Kubernetes 加速比 | 两个开源环境在验证挂载点后复用同一套 DNS/gRPC 快路径：DNS QPS `7.14x` / p99 `182.52x`，gRPC QPS `3.69x` / p99 `3.33x`。该结论是“快路径 benchmark + 环境挂载证据”，不是完整生产 VM-to-VM 或 Pod-to-Pod 端到端加速声明 |
| Xpress DNS 基线 | 同 VM 对比中，本项目相对 patch 后 Xpress DNS：QPS `1.07x`，p99 `1.74x` |

## 已知边界

## Latest OpenStack E2E status (2026-07-24)

The OpenStack VM-to-VM gRPC harness now completes baseline, cache hit,
backend-stop cache-only, and runtime `SERVING -> NOT_SERVING` checks. On the
available CirrOS image the guest kernel has no writable bpffs, so the measured
run is `guest-userspace-fallback`, not guest eBPF acceleration. At
`BACKEND_DELAY_US=5000`, it measured `2.26x` QPS, average latency reduction
`55.8%`, and p99 reduction `43.7%`; at `300us` it measured `0.98x`, showing
that OpenStack network/proxy overhead dominates when backend work is small.
The remaining contest evidence is a Linux guest image with writable bpffs and
the same E2E run in `guest-ebpf` mode.

## Guest-eBPF E2E closure (2026-07-24)

The remaining guest-side requirement is now closed. With the Ubuntu 24.04
cloud image, three temporary OpenStack VMs completed a real private-network
`client -> cache -> backend` gRPC path while the cache VM used pinned BPF
policy and response maps:

| check | observed result |
| --- | --- |
| direct baseline | `79.88 qps`, `avg=11054.12 us`, `p99=12367 us` |
| pinned-map cache hit | `184.49 qps`, `avg=4701.18 us`, `p99=5875 us` |
| speedup | `2.31x qps`, average `-57.5%`, p99 `-52.5%` |
| backend stop | `cache-only count=100 failed=0 serving=100` |
| dynamic policy update | `NOT_SERVING=20/20` |
| cache process evidence | `cache_hit=49`, `response_cache_miss=0`, `fallback_error=0` |

The pinned response-map dump contained the expected method/payload key and the
host monitor loaded with `ringbuf_drop=0`. This closes the OpenStack guest-eBPF
acceleration evidence for the gRPC service. The formal artifact is
`/home/xuexia/vnet-dataplane-verify/linux_accel/artifacts/openstack-grpc-e2e-guest-ebpf-formal`.

- DNS 加速当前覆盖 IPv4 UDP DNS、单问题、`A/IN`、未压缩 QNAME、缓存命中请求。
- gRPC 加速当前覆盖 h2c unary demo 流量，不覆盖 TLS、流式 RPC 或任意 protobuf 响应序列化。
- 虚拟化 benchmark 使用 Linux namespaces、bridge 和 veth 保证可复现。在当前 VM 中，DevStack etcd 与 kubeadm etcd 都需要 `2379/2380`，因此 OpenStack 与 Kubernetes workload 证据需要分时采集。
