# linux_accel 全协议与竞品对比实验报告

日期：2026-08-14（Asia/Shanghai）  
正式批次：`all-comparisons-20260814-node1-v1`

## 1. 结论摘要

本轮在学校三节点 Linux 7.0/OpenStack 集群上完成了正确性门禁、netns/veth
正式矩阵、三节点 LDAP 路径，以及 client VM 位于 node1、backend VM 位于
node2 的 OpenStack TAP/OVS/OVN/Geneve 跨计算节点复测。Kubernetes 全程保持
关闭。

最重要的结论如下：

1. **相对 NSDI'21 BMC，linux_accel 的优势主要来自更高的有效命中率，而不是
   纯命中 XDP_TX 指令路径快一个数量级。** BMC 论文缩放 Zipf 负载中，
   linux_accel 为 `1,197,340 QPS`，比 BMC 的 `970,340 QPS` 高 `23.39%`；
   backend offload 高 `12.371` 个百分点。100% hot-hit 时两者都完全卸载，
   linux_accel 只高 `3.19%`。
2. **OpenStack 跨计算节点 mixed 场景中优势仍然成立。** linux_accel 为
   `68,078 QPS`，BMC 为 `51,547 QPS`，相对 BMC 高 `32.07%`，相对 nohook
   为 `2.923x`；offload 高 `13.674` 个百分点，三种模式均 0 失败、0
   softnet drop。
3. **DNS 相对 Xpress 的优势在容量而不是所有低压尾延迟点。** `resperf -L 1`
   容量为 `268,344 QPS`，比 Xpress 的 `227,500 QPS` 高 `17.95%`，但该
   linux_accel 点是 client-limited lower bound。20k 低压 netns 点上 Xpress
   p99 更好；100k 零丢包点起 linux_accel p99 更好。
4. **通用 UDP、ARP、gRPC 命中路径有明确加速；LDAP sockmap 是 CPU offload，
   不是 QPS/时延加速。** netns UDP 为 `11.276x`，ARP 为 `1.840x`，gRPC
   cache hit 为 `12.645x`；LDAP sockmap 只有 `0.882x` userspace QPS，但
   node1 proxy CPU 从 `14.02 s` 降到 `0.02 s`，下降约 `99.86%`。
5. **miss/fail-open 不包装成加速。** Memcached 全 miss 中 linux_accel 是
   nohook 的 `0.976x`；OpenStack 通用 UDP miss 是 nohook 的 `1.013x`，可视为
   基本中性。命中率不足时应强调额外开销边界，而不是平均出一个“总体倍数”。

本轮各正式矩阵合计 `207,338,877` 次 timed request；该数字不包含 smoke、
warmup、correctness gate 和自研 burst 补充矩阵。

## 2. 被测对象与 baseline

| 名称 | 固定身份 | 回答的问题 |
|---|---|---|
| `nohook` | 不挂本实验 XDP/TC，进入 kernel/userspace backend | fast path 相对原路径是否值得 |
| BMC | Orange-OpenSource `bmc-cache` NSDI'21，commit `2997145508e02c55aa92f63a0009ac2a26800810` | Memcached 协议内高质量 XDP 竞品 |
| Xpress | DNS XDP 实现，commit `312e2a30c7838be0c5b92ab5d302a04a55f5afcd` | DNS 协议内竞品 |
| `linux_accel` | 本项目 v2 固定 release | 被测实现 |

答辩时不能把不同协议的倍数平均。Memcached 主结论应优先报告
`linux_accel / BMC`，DNS 报告 `linux_accel / Xpress`，ARP/UDP/gRPC/LDAP
则分别使用该协议定义的 baseline。

### 2.1 制品身份

| 制品 | SHA-256 |
|---|---|
| linux_accel source archive | `6e1ead5af3a3b7e5f0c2124e5557ab68b3e3baab4f5878304ac3955728efb1cb` |
| linux_accel all-comparisons v2 release | `277e2a5e1ea99adc4868e0b09aef072acab3800cd9e269a4d5f733a14fc2dc9a` |
| BMC pinned Git bundle | `0c8e85ff5da691fdb1ed21445102072dac9cef066b0cb2c01f0d0db5ea219076` |
| BMC Linux 7/libbpf 1.6 compat patch | `2f98ade68f9253b960d2abb82f07857d5a206a5cc4102f5135168dce5fdd4a77` |
| BMC-target linux_accel `32x96` profile archive | `4f4f98798e15b5a83ad49b6696d2df5ebce44277fdefc74450b1e29c378fc8f0` |
| node2 raw result archive | `1029179fafc5e8638df93216ad2c49bdff91a891195b86a98ae6283975c69555` |
| v2 correctness gate archive | `2c03b4daaccc32b83791938d09042ea1d740d0a44f944c1298ee5d29d1c779df` |

BMC 的兼容补丁只处理当前 Linux 7.0/libbpf 1.6/TAP 所需的可运行性与已审计
checksum 边界，不改变 FNV、direct-mapped array、TC response learning、TCP SET
invalidation 等核心设计。Memcached 固定响应是 76 bytes，因此 linux_accel 使用
显式 `request_max=32`、`response_max=96` profile，避免默认 64-byte response ABI
错误地拒绝 workload。

## 3. 环境与方法

- node1：OpenStack client VM compute host，`10.115.24.245`；
- node2：netns benchmark host、OpenStack backend VM compute host，
  `10.115.24.114`；
- node3：LDAP backend host，`10.115.24.40`；
- 三节点内核均为 `7.0.0-14-generic`；
- 正式矩阵使用交错/平衡 mode 顺序、固定重复次数、correctness gate、backend
  counter、失败计数、p50/p95/p99、softirq/context switch/softnet 记录；
- OpenStack mixed 路径为：

```text
client VM (node1)
  -> client TAP generic XDP
  -> OVS br-int / OVN / Geneve underlay
  -> backend VM (node2)
```

DNS 流量使用 Cloudflare Radar 荷兰快照的 qtype 与 cache-hit 边缘比例，联合分布
按独立假设合成；这是可复现 O+H profile，不是假装成原始逐请求 trace。Memcached
使用 BMC 论文 Zipf `0.99`、4:1 keyspace/cache 缩放负载，以及 Facebook ETC 的
coarse-locality 控制组。流量来源与边界见
[`competitor-traffic-profile-sources-2026-08.md`](competitor-traffic-profile-sources-2026-08.md)。

## 4. Memcached：linux_accel vs BMC

### 4.1 netns/veth 正式六轮

| 场景 | nohook QPS | BMC QPS | linux_accel QPS | linux/BMC | BMC offload | linux offload | 结论 |
|---|---:|---:|---:|---:|---:|---:|---|
| BMC paper scaled | 577,170 | 970,340 | **1,197,340** | **1.234x** | 73.480% | **85.851%** | mixed 主结论 |
| same-slot pressure | 572,858 | 827,996 | **1,004,330** | **1.213x** | 61.186% | **75.090%** | exact-key 冲突优势 |
| all hot hit | 580,581 | 1,712,655 | **1,767,370** | **1.032x** | 100% | 100% | 纯命中路径接近 |
| all backend miss | 600,544 | 582,472 | **586,094** | 1.006x | 0% | 0% | 两者均慢于 nohook |
| Facebook ETC coarse | 578,058 | 590,502 | **598,007** | 1.013x | 13.359% | 13.497% | locality 低，收益小 |

BMC paper scaled 的 tail 需要如实报告：linux_accel p95 为 `22.157 us`，优于
BMC 的 `27.160 us`；但 p99 为 `57.349 us`，差于 BMC 的 `46.999 us`。
same-slot 场景也有类似尾部代价。100% hit 时 linux_accel p99 为 `3.291 us`，
BMC 为 `3.638 us`，linux_accel 低约 `9.54%`。

这说明 mixed 吞吐优势主要来自 exact-key cache 保留了更多有效条目，而不是单包
XDP_TX 比 BMC 快很多。全 miss 时 linux_accel 只比 BMC 高 `0.62%`，且相对
nohook 为 `0.976x`；正确说法是“miss 额外开销较小”，不是“miss 被加速”。

原始与分析数据：

- [`netns BMC raw`](../artifacts/all-comparisons/20260814-node1-v1/node2-results/netns-bmc-formal-v2/)
- [`netns BMC analysis`](../artifacts/all-comparisons/20260814-node1-v1/node2-results/analysis-netns-bmc-formal-v2/summary.md)

### 4.2 OpenStack 跨计算节点正式六轮

| mode | QPS | vs nohook | p50 us | p95 us | p99 us | backend offload | failures |
|---|---:|---:|---:|---:|---:|---:|---:|
| nohook | 23,288 | 1.000x | 85.183 | 92.762 | 106.111 | 0% | 0 |
| BMC | 51,547 | 2.213x | 11.099 | 90.236 | 97.212 | 61.406% | 0 |
| linux_accel | **68,078** | **2.923x** | **10.825** | **88.874** | **95.769** | **75.080%** | 0 |

linux_accel 相对 BMC 的 QPS 高 `32.07%`，p50/p95/p99 分别约低
`2.47%/1.51%/1.48%`，offload 高 `13.674` 个百分点。这个结果来自真实
VM/TAP/OVS/OVN/Geneve/backend VM 路径，不再是旧报告中的同 host localport。

原始与分析数据：

- [`OpenStack BMC raw`](../artifacts/all-comparisons/20260814-node1-v1/openstack-bmc-formal-v1/)
- [`OpenStack BMC analysis`](../artifacts/all-comparisons/20260814-node1-v1/openstack-bmc-formal-v1/analysis/summary.md)

## 5. DNS：linux_accel vs Xpress

### 5.1 dnsperf 零丢包与容量点

| target | nohook completed QPS / loss | Xpress completed QPS / loss | linux_accel completed QPS / loss | linux/Xpress |
|---:|---:|---:|---:|---:|
| 20k | 20,000 / 0% | 20,000 / 0% | 20,000 / 0% | 1.000x |
| 100k | 99,999 / 0% | 99,999 / 0% | 99,999 / 0% | 1.000x |
| 250k | 146,694 / 11.728% | 230,236 / 6.569% | **246,919 / 1.231%** | **1.072x** |
| 500k | 146,648 / 11.756% | 233,076 / 7.821% | **297,475 / 5.927%** | **1.276x** |
| 650k | 147,327 / 11.861% | 217,850 / 8.360% | **297,824 / 6.229%** | **1.367x** |

低压 tail 不是单向胜利：20k p99 为 Xpress `51.5 us`、linux_accel
`64.5 us`，Xpress 更好；100k 零丢包点为 Xpress `28.5 us`、linux_accel
`22.5 us`，linux_accel 更好。250k 以上已经过载，p99 只统计成功请求并受
survivor bias 影响，不能与零丢包时延混在一起宣传。

`resperf -L 1` 三轮中位数：

| mode | 1% loss capacity | vs nohook | backend bypass | limiter |
|---|---:|---:|---:|---|
| nohook | 140,834 | 1.000x | 0% | 65,536 outstanding |
| Xpress | 227,500 | 1.615x | 35.34% | mixed/server |
| linux_accel | **268,344** | **1.905x** | **48.92%** | client lower bound |

linux_accel 相对 Xpress 的已观测 1% loss capacity 高 `17.95%`。由于
linux_accel 的三轮均为 client-limited，该数字是已证明的下界，不是服务器真实
上限。

原始与分析数据：

- [`dnsperf/resperf raw`](../artifacts/all-comparisons/20260814-node1-v1/node2-results/netns-dnsperf-resperf-formal-v1/)
- [`dnsperf analysis`](../artifacts/all-comparisons/20260814-node1-v1/node2-results/analysis-netns-dnsperf-formal-v1/summary.md)
- [`resperf analysis`](../artifacts/all-comparisons/20260814-node1-v1/node2-results/analysis-netns-resperf-formal-v1/summary.md)

### 5.2 OpenStack 20k 零丢包六轮

| mode | completed QPS | completion | p50 us | p95 us | p99 us | backend offload |
|---|---:|---:|---:|---:|---:|---:|
| nohook | 20,000 | 100% | 81 | 105 | 229 | 0% |
| Xpress | 20,000 | 100% | 76 | 103 | 195 | 35.342% |
| linux_accel | 20,000 | 100% | **72** | **99** | **183** | **48.920%** |

该点受 offered rate 限制，不能报告吞吐加速；linux_accel p99 相对 nohook
改善 `1.251x`，相对 Xpress 低约 `6.15%`。

- [`OpenStack DNS raw`](../artifacts/all-comparisons/20260814-node1-v1/openstack-dns-formal-20k-v1/)
- [`OpenStack DNS analysis`](../artifacts/all-comparisons/20260814-node1-v1/analysis-openstack-dns-formal-20k-v1/summary.md)

## 6. 自有协议矩阵

| 协议/路径 | baseline | linux_accel | QPS 比 | p99 改善比 | 正确解释 |
|---|---:|---:|---:|---:|---|
| ARP response，netns | kernel `390,189 QPS / 3.814 us` | generic XDP `718,033 / 3.084 us` | **1.840x** | **1.237x** | server RX/request 从 1 降为 0 |
| 通用 UDP exact hit，netns | userspace `292,278 / 33.145 us` | generic XDP `3,295,770 / 4.854 us` | **11.276x** | **6.829x** | 确定、无副作用的短 UDP exchange |
| gRPC h2c cache hit，netns | backend `1,777 / 682.590 us` | cache `22,471 / 56.740 us` | **12.645x** | **12.030x** | backend 含 300 us 模拟延迟；原型路径 |
| LDAP 4 KiB relay，三节点 | userspace `18,722 / 548.581 us` | sockmap `16,513 / 625.582 us` | **0.882x** | **0.877x** | CPU `14.02 s -> 0.02 s`，不是时延加速 |
| OpenStack UDP exact hit | nohook `137,801 / 166.838 us` | TAP XDP `342,951 / 153.090 us` | **2.489x** | **1.090x** | 避免跨 VM/backend round trip |
| OpenStack UDP miss | nohook `137,801 / 166.838 us` | XDP miss `139,613 / 162.796 us` | **1.013x** | **1.025x** | fail-open 基本中性 |

gRPC 的 response-cache-miss 与 policy-miss 分别只有 direct backend QPS 的
`0.848x` 和 `0.834x`；这再次说明只应对命中路径宣称加速。LDAP/LDAPS、DHCPv4
relay、ARP、多协议 dispatcher/action probe 都完成了 correctness gate；DHCP 是
有状态 relay，不给一个伪造的“cache 加速倍数”。

分析数据：

- [`ARP`](../artifacts/all-comparisons/20260814-node1-v1/node2-results/netns-arp-formal-v1/summary.md)
- [`UDP`](../artifacts/all-comparisons/20260814-node1-v1/analysis-netns-udp-formal-v1/summary.md)
- [`gRPC`](../artifacts/all-comparisons/20260814-node1-v1/analysis-netns-grpc-formal-v2/summary.md)
- [`LDAP`](../artifacts/all-comparisons/20260814-node1-v1/ldap-cluster-formal-v2/summary.md)
- [`OpenStack UDP`](../artifacts/all-comparisons/20260814-node1-v1/openstack-udp-formal-v1/summary.md)

## 7. Native XDP 本轮边界

本轮物理 userspace/generic 测试完成后，native attach 被新的安全 preflight
正确阻断：node1 重启后绑定的是 stock `r8169`，而不是此前验收过的
`r8169_xdp`。现场证据：

- `ethtool -i enp3s0`：`driver: r8169`；
- loader：`Underlying driver does not support XDP in native mode`；
- reviewed unsigned module 仍为
  `7a5f7882545e14f7aba52e259131610ccf0ae37087b98195ec8f30a031bffe58`；
- signed module 为
  `dcf4ae4044be52939999b78d4d2f178e55c638429afe60f301008bfdb9669a3c`；
- signer `r8169 Native XDP node1` 的 MOK 已登记，vermagic 匹配当前内核；
- 模块没有安装到当前 `/lib/modules/7.0.0-14-generic`，因此重启后自动回到
  stock driver。

该网卡同时是唯一管理/underlay 接口。项目安全契约要求从本地/OOB console
运行带 watchdog 的 PCI rebind，不能通过同一 SSH 链路强行切换。本轮没有越过
该边界，也没有把 generic 结果冒充 native。

历史同硬件证据（2026-08-05）可作为独立、非本轮数据引用：500k offered 时
native 完成 `266.6k QPS`，generic 为 `212.0k QPS`，native 高 `25.7%`；但它
必须明确标注为历史批次。当前脚本已加入显式 `r8169_xdp` driver preflight，
避免先跑大量 case 再在 native 阶段失败。

## 8. 正确性、无效样本和恢复审计

### 8.1 正确性门禁

- 正式 benchmark 使用的
  `/opt/competitor-bench/releases/linux-accel-all-comparisons-20260814-v2`
  已在 node2 重新运行完整门禁，`RESULT.txt` 为 `correctness_gate=PASS`；
- DNS XDP：`7/7`；
- 通用 UDP：`6/6`；
- ARP：`13/13` 加真实 veth capture；
- DHCP control/XDP、LDAP/LDAPS、XDP dispatcher/action probe：通过；
- 所有进入主表的 Memcached/OpenStack case：客户端失败、内容/长度错误、
  checksum error 与 host softnet drop 均为 0。

v2 门禁原始归档：
[`correctness-v2-final`](../artifacts/all-comparisons/20260814-node1-v1/node2-results/correctness-v2-final/)
（归档包位于 `packages/correctness-v2-final.tar.gz`）。

### 8.2 明确保留但不进入主表的无效样本

- 第一版 BMC formal 使用默认 64-byte response ABI，拒绝 76-byte Memcached
  响应；已由审计后的 `32x96` profile 修复并重跑；
- 第一版 gRPC 连续复用同一四元组，短连接/TIME_WAIT 导致 fallback 失败；正式
  v2 为每轮独立 IP/port，并强制五条路径全部 `failed=0`；
- physical native 当前批次因 stock driver 被阻断；高压 userspace/generic
  partial case 出现 send/invalid 计数，只保留诊断，不进入正式主表；
- LDAP 第一次前置 OpenStack inventory 遇到瞬时 503，尚未计时时即中止；正式
  v2 跳过与 LDAP 无关的 inventory，但仍校验三节点 release、K8s 与进程清理。

### 8.3 最终集群状态

- 三节点 `kubelet`、`containerd`、`kubernetes-haproxy`、k3s/rke2 均 inactive；
- OpenStack Horizon/Keystone/Nova/Placement/Neutron 正常，Glance root 为预期
  `300`；Nova compute 与 OVN controller/metadata agent 全部 up；
- `linux-accel-client` 恢复为原始 `SHUTOFF`，backend 保持 `ACTIVE`；
- node1 只保留原有 br-int DNS/gRPC TC hooks 和原 service；
- node1 `enp3s0`、node2、node3 无本实验残留 XDP；
- node2 仅保留原有两个 OVN metadata namespace；
- IRQ 148 affinity 与 irqbalance 已恢复。

## 9. 可复现入口

主要脚本：

- `bench/run_bmc_formal_matrix.sh`；
- `bench/run_dnsperf_resperf_formal_matrix.sh`；
- `bench/arp_proxy_bench.sh`；
- `bench/udp_fastpath_bench.sh`；
- `bench/grpc_fast_cache_bench.sh`；
- `bench/ldap_cluster_bench.sh`；
- `bench/openstack_bmc_competitor_bench.sh`；
- `bench/openstack_udp_fastpath_bench.sh`；
- `bench/openstack_dns_xdp_competitor_bench.sh`；
- `bench/run_physical_xdp_burst.sh`。

分析器：

- `tools/analyze_bmc_competitor_bench.py`；
- `tools/analyze_dns_competitor_bench.py`；
- `tools/analyze_resperf.py`；
- `tools/analyze_openstack_dns_competitor_bench.py`；
- `tools/analyze_protocol_repetitions.py`。

完整本地批次：
[`artifacts/all-comparisons/20260814-node1-v1/`](../artifacts/all-comparisons/20260814-node1-v1/)

## 10. 答辩一句话版本

> 相对 NSDI'21 BMC，我们的纯命中 XDP_TX 只快约 3%，真正优势是 exact-key、
> 可分接口/租户的 cache 在 Zipf 混合与槽位冲突下多保留约 12–14 个百分点的
> 有效 offload，因此 netns mixed 吞吐高 23%，真实 OpenStack 跨计算节点 mixed
> 吞吐高 32%；DNS 相对 Xpress 的 1% loss 容量高约 18%，同时系统还覆盖 ARP、
> 通用 UDP、gRPC、LDAP/LDAPS 与 DHCP，并能明确区分命中加速、miss 开销和 CPU
> offload，不把所有协议硬平均成一个失真的“总体加速比”。
