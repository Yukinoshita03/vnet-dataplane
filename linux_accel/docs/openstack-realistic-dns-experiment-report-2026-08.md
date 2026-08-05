# OpenStack TAP XDP 偏真实 DNS 流量实验报告

实验日期：2026-08-05

实验编号：`openstack-realistic-dns/20260805-203633`

实验状态：完成，实验后 TAP XDP、DNS backend 和 OpenStack VM 均已恢复正常；Kubernetes 保持关闭。

## 结论摘要

在跨宿主机 OpenStack VM 路径上，TAP generic XDP 将满足本轮 SLO 门槛的测试容量从 **40k QPS 提高到 80k QPS，容量提升 2.00×**。20k QPS 稳态三轮均为零丢失，平均延迟从 **82µs 降到 49µs**，p50 从 **79µs 降到 12µs**；后端 DNS 请求和 Geneve 包量均减少约 **60.6%**。

收益主要集中在缓存命中请求。混合流量的 p99 没有同步改善：稳态中位数由 **123µs 变为 203µs**，对应 `baseline / TAP-XDP = 0.61×`。这说明当前实现已经明显降低了中位延迟和后端压力，但未命中、短 TTL、非 A 类型和 CNAME 等仍走完整 overlay 路径，尾部仍需单独优化。

## 1. 实验目标与对照

本实验回答两个问题：

1. 将 DNS client cache 挂在 OpenStack VM 的 Neutron TAP 后，是否能降低跨节点 overlay 流量和 resolver backend 压力；
2. 在混合 DNS 流量下，吞吐、延迟、丢包和缓存命中是否同时改善。

对照模式如下：

| 模式 | TAP 状态 | 含义 |
| --- | --- | --- |
| `no_hook` | client TAP 无项目 XDP/tc | OpenStack/OVS/OVN/Geneve 完整路径 baseline |
| `tap_xdp` | client TAP generic XDP + tc egress | 当前 OpenStack 加速实现 |

node1 物理 `enp3s0` 上原有 native XDP 在整个 A/B 实验期间保持不变，因此本报告的加速结果是 **OpenStack TAP generic XDP**，不冒充物理 native XDP 结果。

## 2. 拓扑和环境

```text
node1                                         node2
linux-accel-client VM                         linux-accel-backend VM
192.168.110.18                                192.168.110.13:53
    |                                             |
    v                                             v
TAP tap96696c4a-57                         TAP tapaa5e3ccb-96
generic XDP/tc -> OVS br-int -> OVN/Geneve -> OVS/TAP
```

- client VM 固定在 node1，backend VM 固定在 node2；两台 VM 均为 2 vCPU、约 4 GiB 内存；
- OpenStack network：`linux-accel-net`；
- client TAP：`tap96696c4a-57`；当前挂载点为 generic XDP ingress 和 `dns_client_cache_egress` tc；
- backend 是离线 closed-world DNS 服务，直接统计收到的 query 数和响应类别；
- Kubernetes 的 `kubelet`、`containerd`、`kubernetes-haproxy` 在 node1/node2/node3 均保持 `inactive`；
- benchmark 使用 `dnsperf 2.15.0` 做固定语料稳态/容量测试，使用 `resperf 2.15.0` 做 ramp 预扫描。

## 3. 流量模型

本轮没有生产 dnstap/pcap，因此使用可复现的 50k 行 bootstrap corpus，不能称为生产分布。语料按以下比例混合并用固定 seed `20260805` 打乱：

| 类别 | 比例 | 预期行为 |
| --- | ---: | --- |
| 热门重复 A | 45% | warm 后主要由 client XDP 命中 |
| 中等热度、短 TTL A | 20% | 学习、命中和过期交替 |
| 一次性冷 A | 10% | 主要穿透到 backend |
| AAAA | 10% | 当前实现 fail-open |
| 不支持类型 TXT | 5% | 作为 per-query EDNS 的第一轮 stand-in |
| NXDOMAIN | 5% | 不学习，穿透 |
| CNAME + A 多答案 | 3% | 不学习，穿透 |
| 截断响应 | 2% | 验证非快路径行为 |

dnsperf 每一行不能单独切换 EDNS，因此 TXT 类别只用于模拟“当前快路径不处理”的旁路流量；后续接入真实 trace 时需要用 dnstap/DNS Shotgun/dnsjit 替换该 bootstrap profile。

## 4. 测试流程和采信门槛

- 正确性：9 类查询各发送两次，共 18 个 query；检查 RCODE、answer count、A/AAAA/CNAME、截断标记和缓存响应内容；
- 容量扫描：5k、10k、20k、40k、80k、120k QPS，每个点运行 5s，并交替执行 `no_hook` 和 `tap_xdp`；
- 稳态：选 baseline 可持续拐点的约 60%，即 20k QPS，两个模式各 3 轮、每轮 8s；
- spike：80k QPS，每个模式 3s；
- 每轮保存 dnsperf latency histogram、backend counter、TAP/BPF counter、Geneve/TAP/NIC 计数和 node1/node2 perf stat。

本轮 SLO gate：发生器实际发送速率达到目标的 99%，完成率至少 99.9%，p99 不超过 10ms，TAP/softnet 不出现 drop/error 增量。稳态结论使用三轮中位数。

## 5. 结果

### 5.1 容量扫描

| 目标 QPS | no-hook 完成率 | no-hook p50/p99 | TAP XDP 完成率 | TAP XDP p50/p99 | gate |
| ---: | ---: | ---: | ---: | ---: | --- |
| 5k | 100.000% | 179 / 295µs | 100.000% | 29 / 271µs | 两者通过 |
| 10k | 100.000% | 81 / 207µs | 100.000% | 16 / 211µs | 两者通过 |
| 20k | 100.000% | 87 / 751µs | 100.000% | 11 / 591µs | 两者通过 |
| 40k | 99.968% | 83 / 335µs | 100.000% | 13 / 623µs | 两者通过 |
| 80k | 99.467% | 101 / 1343µs | 99.986% | 13 / 1375µs | baseline 失败，XDP 通过 |
| 120k | 91.950% | 1567 / 5631µs | 97.907% | 16 / 3071µs | 两者失败 |

按该 gate，baseline 的最高通过点是 40k，TAP XDP 的最高通过点是 80k，得到容量提升 **2.00×**。如果改用“零丢失”这一更严格口径，20k 稳态是两边都稳定通过的点；80k spike 中 TAP XDP 仍然零丢失，而 no-hook 已明显过载。

### 5.2 20k QPS 稳态（三轮中位数）

| 指标 | no-hook | TAP XDP | 变化 |
| --- | ---: | ---: | ---: |
| completed QPS | 20,000 | 20,000 | 持平 |
| 平均延迟 | 82µs | 49µs | `1.67×` |
| p50 | 79µs | 12µs | `6.58×` |
| p95 | 99µs | 103µs | `0.96×` |
| p99 | 123µs | 203µs | `0.61×` |
| backend query | 160,000 | 63,105 | 减少 60.6% |
| Geneve packet | 640,004 | 252,424 | 减少 60.6% |
| XDP TX | 0 | 96,895 | 观察到快路径命中 |
| DNS 丢失 | 0 | 0 | 均为零 |

这里的延迟比值均按 `no-hook / TAP-XDP` 计算；小于 1 表示 TAP XDP 在该分位数上反而更慢。

### 5.3 80k spike

| 指标 | no-hook | TAP XDP |
| --- | ---: | ---: |
| 完成率 | 98.972% | 100.000% |
| 丢失 query | 2,466 | 0 |
| 平均延迟 | 153µs | 107µs |
| p50 | 99µs | 15µs |
| p99 | 1,919µs | 1,631µs |
| backend query | 237,532 | 94,386 |
| XDP TX | 0 | 145,611 |

## 6. 结果解释

当前实现的收益是明确的：缓存命中请求在 TAP 上直接返回，约六成 query 不再经过 OVN/Geneve 和 backend；因此 p50、平均延迟、backend 压力和可持续容量均有明显改善。

但 p99 没有改善，数据更支持以下判断：尾部主要由未命中和不支持类型构成，它们仍要走完整 overlay 路径，同时还承担 TAP XDP/tc 的解析、pending 和学习开销；加速器没有缩短这部分路径。这个判断需要下一轮按 query category 分桶采样验证，不能简单把 p99 退化归因于某一个内核组件。

下一轮建议按以下顺序推进：

1. 对 hot-hit、warm-hit、cold-miss、AAAA、NXDOMAIN、CNAME 分开统计 p50/p95/p99；
2. 记录 map eviction、learn reject、TTL expire 和 miss-path CPU cycles，确认是否存在缓存污染；
3. 对 miss path 做 pass-through 降开销优化，并把 XDP/tc hook overhead 与真实 cache hit 收益分开报告；
4. 用脱敏 dnstap/pcap 接入 DNS Shotgun 或 dnsjit，再补一轮真实 inter-arrival replay；
5. 最后再用 k6 DNS+HTTP journey 测量用户可感知的端到端收益。

## 7. 控制面和恢复检查

- Horizon、Keystone、Glance、Nova、Placement、Neutron API 在实验前后均返回正常状态码；
- node1/node2/node3 的核心 OpenStack 服务和 OVN controller/metadata agent 保持 active/up；
- 实验后 `linux-accel-openstack-tap-accel@96696c4a-5746-43ab-8137-241952309dac.service` 为 active，TAP 上 generic XDP 和 tc egress 均已挂回；
- backend VM 服务 `linux-accel-openstack-dns-backend.service` 为 active；
- Kubernetes 三台节点的 kubelet、containerd、kubernetes-haproxy 均为 inactive；
- `openstack-status.sh` 的 legacy Open vSwitch agent 行仍显示 node1 `False`，但本次 OVN controller/metadata、VM 跨节点 DNS 路径和 API 均正常；该项仍应作为控制面遗留项单独处理；
- 实验前一次 `openstack server list --long` inventory 查询曾触发 20s 超时保护，实验后再次查询成功返回 VM 清单；这属于健康检查命令稳定性问题，不影响本轮已完成的数据面结果。

## 8. 可复现入口和证据

```bash
bash bench/openstack_realistic_dns_bench.sh \
  artifacts/openstack-realistic-dns/<timestamp> quick
```

入口脚本会生成固定 seed 的语料，执行 correctness、resperf、dnsperf 容量扫描、稳态和 spike，并保存原始计数器。实验原始 artifact 因仓库的 `artifacts/` 忽略规则未提交，当前工作区证据位于：

`artifacts/openstack-realistic-dns/20260805-203633/`

本报告对应的精简逐轮数据见 `docs/benchmarks/openstack-realistic-dns-20260805-results.csv`。
