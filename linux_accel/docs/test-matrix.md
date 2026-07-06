# 测试矩阵

本文档记录项目测试项、通过标准、最新 VM 证据和结论边界，用于比赛报告和答辩。

## 测试环境

| 项目 | 内容 |
| --- | --- |
| 主机环境 | VMware Ubuntu VM |
| 内核路径 | Linux eBPF、tc、generic XDP |
| 可复现实验拓扑 | DNS/gRPC 快路径 benchmark 使用 `netns + veth` |
| 虚拟化实验拓扑 | `netns + bridge + veth`，并补充 DevStack/OpenStack OVS 挂载证据 |
| 云原生实验拓扑 | kubeadm 单节点 Kubernetes，CNI/pod-veth 路径证据 |
| 压测工具 | `dnsperf`、自研 C latency bench、Python/C TCP request-response bench |
| 权限约定 | 交互式环境先执行 `sudo -v`；文档和脚本不得写入真实密码 |

## 构建与仓库卫生

| ID | 测试项 | 命令 | 通过标准 | 最新证据 | 状态 |
| --- | --- | --- | --- | --- | --- |
| B-01 | Linux 构建 | `./scripts/build_linux.sh` | 生成 `dns_monitor.bpf.o`、`dns_xdp_monitor.bpf.o`、`grpc_monitor.bpf.o`、`dns_monitor`、`grpc_monitor`、`grpc_fast_cache`、`cachectl` | 最新 VM benchmark 前构建通过 | 已完成 |
| B-02 | 敏感信息扫描 | `rg -n "<known-secret>|SUDO_PASS=[0-9]" bench docs README.md` | 仓库文档/脚本中不出现真实密码或数字形式 `SUDO_PASS` 示例 | 最新扫描无命中 | 已完成 |
| B-03 | Demo 清理检查 | `ip netns list`；`ip link show <bench-iface>` | benchmark 脚本结束后清理临时 netns、veth、bridge | DNS/gRPC 脚本会清理默认实验资源 | 已完成 |

## DNS 监控与 XDP 加速

| ID | 测试项 | 命令 / 脚本 | 通过标准 | 最新证据 | 状态 |
| --- | --- | --- | --- | --- | --- |
| D-01 | DNS tc 监控启动 | `sudo ./build/dns_monitor --dev <iface> --hook tc` | 程序可挂载并输出 DNS 指标，不影响转发 | tc 路径保留为基线选项 | 已完成 |
| D-02 | 单条 DNS XDP 缓存 | `sudo ./build/dns_monitor --dev <iface> --hook xdp --xdp-mode generic --cache-domain example.test --cache-ip 10.0.0.123` | `dig +noedns` 返回配置的 A 记录，`cache_hit/cache_tx` 增加 | DNS XDP benchmark 覆盖该路径 | 已完成 |
| D-03 | 多条 DNS 缓存文件 | `--cache-file <path>` | 至少 3 个域名可加载并命中；非法域名/IP/TTL 直接报错 | 已通过 `dns_cache` map 预加载实现 | 已完成 |
| D-04 | DNS 未命中放行 | 查询未缓存域名 | 包正常放行，`cache_miss` 增加，不伪造响应 | 已写入 XDP 设计边界 | 已完成 |
| D-05 | DNS TTL 过期 | 短 TTL 缓存项过期后再次查询 | 缓存项过期或被视为失效，`cache_expired` 增加 | 缓存元数据和指标已支持 | 已完成 |
| D-06 | DNS XDP benchmark | `DURATION=5 LATENCY_COUNT=10000 LATENCY_WARMUP=500 ./bench/dns_xdp_cache_bench.sh` | userspace 和 XDP 两组均完成，丢包接近 0；`cache_hit > 0`、`cache_tx > 0` | `artifacts/dns-xdp-cache-bench/20260630-164919`：userspace `74702.04 qps`，XDP `533691.56 qps`，QPS `7.14x`；p99 `793.97 us` 降至 `4.35 us`，提升 `182.52x`；`cache_hit=10500 cache_tx=10500 ringbuf_drop=0` | 已完成 |
| D-07 | tc 与 XDP 对比 | `./bench/dns_tc_vs_xdp_bench.sh` | 输出 no-hook userspace、tc monitor、generic XDP cache-hit 三组 QPS/p99 | 脚本生成 `artifacts/dns-tc-vs-xdp-bench/<timestamp>/summary.md` | 已完成 |

## gRPC 监控与快缓存

| ID | 测试项 | 命令 / 脚本 | 通过标准 | 最新证据 | 状态 |
| --- | --- | --- | --- | --- | --- |
| G-01 | gRPC tc 监控启动 | `sudo ./build/grpc_monitor --dev <iface> --port 50051 --verbose-events` | 程序挂载 tc ingress/egress，并观察 TCP/IPv4 `50051` 流量 | 手工路径和 benchmark 路径均已验证 | 已完成 |
| G-02 | gRPC transport RTT benchmark | `REQUESTS=3000 ./bench/grpc_tc_monitor_bench.sh` | 请求/响应计数非零，输出匹配 RTT 的 p50/p95/p99，`ringbuf_drop=0` 或接近 0 | 早期 VM 结果：`success=5000 failed=0 qps=2156.05 ringbuf_drop=0` | 已完成 |
| G-03 | gRPC 策略 map 加载 | `./build/cachectl --policy-file <policy> --validate-only` 及 map 写入 | 可校验 `grpc` 和 `grpc-cache` 记录，非法策略会失败 | 最终 smoke：`dns_entries=2 grpc_entries=1 grpc_cache_entries=2` | 已完成 |
| G-04 | gRPC SERVING 缓存命中 | `REQUESTS=1000 WARMUP=50 DURATION=10 ./bench/grpc_fast_cache_bench.sh` | SERVING 响应不访问后端直接返回，`serving_cache_hit > 0` | `artifacts/grpc-fast-cache-bench/20260630-165008`：direct `808.07 qps`，SERVING hit `2985.40 qps`，QPS `3.69x`；p99 `4067.90 us` 降至 `1223.09 us`，提升 `3.33x` | 已完成 |
| G-05 | gRPC NOT_SERVING 缓存命中 | 同 G-04 | 不同 payload 命中 NOT_SERVING 缓存响应，`not_serving_cache_hit > 0` | `2209.13 qps`，p99 `3932.00 us`，`not_serving_cache_hit=1042` | 已完成 |
| G-06 | gRPC 响应缓存未命中回退 | 同 G-04，使用未缓存 payload | 请求回到后端，`response_cache_miss` 和 `fallback` 增加，`fallback_error=0` | `751.12 qps`，p99 `8203.98 us`，`response_cache_miss=1041 fallback=1041 fallback_error=0` | 已完成 |
| G-07 | gRPC 策略未命中回退 | 同 G-04，使用未列入白名单的方法 | 请求回到后端，`policy_miss` 和 `fallback` 增加，`fallback_error=0` | `778.52 qps`，p99 `4844.19 us`，`policy_miss=1042 fallback=1042 fallback_error=0` | 已完成 |

## 虚拟化与云原生证据

| ID | 测试项 | 命令 / 脚本 | 通过标准 | 最新证据 | 状态 |
| --- | --- | --- | --- | --- | --- |
| V-01 | 虚拟化 bridge 路径 benchmark | `REQUESTS=1000 ./bench/virt_path_bench.sh` | netns bridge 路径测试完成，无 ping 丢包，输出 QPS 和 p99 | `success=1000 failed=0 qps=2129.59 p99_us=3314.93 ping loss=0%` | 已完成 |
| V-02 | OpenStack 路径探测 | `./bench/openstack_path_probe.sh` | 只读列出 OVS/libvirt/OpenStack 可挂载接口 | DevStack 探测发现 12 个候选接口，包括 `br-ex`、`br-int`、`ens33`、`ovs-system`、`virbr0`、veth 链路 | 已完成 |
| V-03 | OpenStack tc 挂载 smoke | `./bench/openstack_tc_attach_smoke.sh` | DNS 和 gRPC tc monitor 能在 `br-int` 挂载并卸载 | `openstack-tc-attach-smoke/20260627-160408`：`dns_tc=attached grpc_tc=attached` | 已完成 |
| V-04 | OpenStack workload 证据 | `./bench/openstack_workload_evidence.sh` | summary 记录 OpenStack/OVS 状态、monitor 日志，并标注真实租户流量或 fallback | `openstack-workload-evidence/20260630-162110`：DNS `count=30 failed=0`，monitor `qps=33 rps=33`；gRPC `count=30 failed=0`，monitor `reqps=28 resps=29 p99=0.311ms` | 已完成 |
| K-01 | Kubernetes 路径探测 | `./bench/k8s_path_probe.sh` | 只读列出 node、CNI、pod-veth 和候选挂载点 | 在节点运行时会记录候选接口 | 已完成 |
| K-02 | Kubernetes workload 证据 | `./bench/k8s_workload_evidence.sh` | 临时 namespace 产生 Pod-to-Service 流量，monitor 计数非零，结束后清理资源 | `k8s-workload-evidence/20260630-161729`：DNS `count=20 failed=0`；gRPC `count=20 failed=0`，pod-veth monitor `reqps=22 resps=44 p99=0.175ms` | 已完成 |

## 开源环境加速比声明

| 环境 | 已验证路径 | DNS 加速结论 | gRPC 加速结论 | 结论边界 |
| --- | --- | ---: | ---: | --- |
| OpenStack / OVS / KVM | `br-int` 挂载 smoke 与 OpenStack workload 证据 | QPS `7.14x`，p99 `182.52x` | QPS `3.69x`，p99 `3.33x` | 快路径 benchmark + OpenStack 挂载/可见性证据，不声称完整生产 VM-to-VM 端到端加速 |
| Kubernetes / CNI / Pod veth | Pod-to-Service workload 证据和非零 monitor 计数 | QPS `7.14x`，p99 `182.52x` | QPS `3.69x`，p99 `3.33x` | 快路径 benchmark + Kubernetes 挂载/可见性证据，不声称完整生产 Pod-to-Pod 端到端加速 |

## 基线与相关工作对比

| ID | 测试项 | 命令 / 脚本 | 通过标准 | 最新证据 | 状态 |
| --- | --- | --- | --- | --- | --- |
| R-01 | Xpress DNS 同 VM 基线 | patch 后的 Xpress DNS 与本项目 DNS benchmark | 双方使用同一 VM 方法，输出 QPS/p99 对比 | 本项目 `413933.01 qps`，p99 `2.82 us`；patch 后 Xpress DNS `385295.75 qps`，p99 `4.92 us`；本项目 QPS `1.07x`、p99 `1.74x` 更优 | 已完成 |
| R-02 | 报告一致性扫描 | `rg -n "<old benchmark values>" README.md docs` | 不残留旧的核心性能结论 | 最新文档统一使用 DNS `7.14x/182.52x` 与 gRPC `3.69x/3.33x` | 已完成 |

## 已知缺口

| 缺口 | 影响 | 后续工作 |
| --- | --- | --- |
| DNS XDP 只支持 IPv4 UDP、单问题、未压缩 `A/IN` 缓存命中 | 其他 DNS 记录类型会放行，不加速 | 当前 demo 稳定后扩展 AAAA/CNAME/EDNS |
| gRPC fast-cache 只支持 h2c unary demo 流量 | 不加速 TLS、流式 RPC、任意 protobuf 序列化 | 扩展 HTTP/2 状态处理，并补 TLS 部署说明 |
| OpenStack/Kubernetes 当前是挂载/可见性证据 + 快路径 benchmark | 证明集成可行，但不是完整生产端到端加速 | 在最终集群上跑专用 VM-to-VM 和 Pod-to-Pod 业务压测 |
| VMware 环境使用 generic XDP | 尚未展示 native XDP 性能 | 在支持 native XDP 的网卡/驱动上复测 |
