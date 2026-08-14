# linux_accel 与 BMC/Xpress 可复现对比实验报告

> 实验日期：2026-08-13 至 2026-08-14  
> 主竞品：Orange-OpenSource/bmc-cache，NSDI'21，固定提交 `2997145508e02c55aa92f63a0009ac2a26800810`  
> 主结论统计口径：每个场景 6 次重复的中位数；所有加速比均使用同一场景、同一客户端下的直接比值  
> 环境约束：Kubernetes 全程保持关闭；正式 OpenStack 实验后移除临时 XDP/TC hook，并验证虚机定义、TAP qdisc 与既有 OVN namespace 未改变

## 1. 答辩先讲的结论：相对 BMC，我们强在哪里

### 1.1 直接对 BMC，不拿 nohook 混淆结论

下表的吞吐提升是 `linux_accel QPS / BMC QPS - 1`。延迟改善是
`(BMC latency - linux_accel latency) / BMC latency`；正数表示 linux_accel
更低，负数表示 linux_accel 更差。`offload Δ` 是 linux_accel 相对 BMC
少进入 userspace backend 的百分点变化。

| 拓扑与流量 | BMC QPS | linux_accel QPS | linux_accel 相对 BMC | p50 改善 | p95 改善 | p99 改善 | offload Δ |
|---|---:|---:|---:|---:|---:|---:|---:|
| netns，BMC 论文 Zipf(0.99) 缩放混合负载 | 949,402 | 1,183,045 | **+24.61%** | +2.36% | **+19.45%** | -18.24% | **+12.362 pp** |
| netns，同名义槽位压力 | 819,620 | 986,680 | **+20.38%** | +4.71% | -2.95% | -12.52% | **+13.892 pp** |
| netns，100% hot hit | 1,708,120 | 1,749,955 | +2.45% | +1.48% | +3.14% | **+9.98%** | 0 pp |
| netns，100% miss/pass | 577,527 | 585,092 | +1.31% | +0.41% | +0.78% | **+19.71%** | 0 pp |
| netns，Facebook ETC 粗粒度 locality | 588,234 | 594,292 | +1.03% | +1.55% | +0.43% | -0.37% | +0.132 pp |
| OpenStack TAP，4:1 同容量混合负载 | 142,676 | 156,989 | **+10.03%** | **+7.40%** | **+6.22%** | **+18.97%** | **+12.913 pp** |
| OpenStack TAP，100% hot hit | 178,849 | 180,590 | +0.97% | +1.12% | +1.26% | +0.42% | 0 pp |
| OpenStack TAP，100% miss/pass | 97,595 | 100,710 | +3.19% | +0.57% | +2.46% | **+33.29%** | 0 pp |

这组数据支持四个有边界的优势结论：

1. **混合热点和冲突压力下，linux_accel 的有效命中率更高。** BMC 使用
   `FNV hash -> direct-mapped array slot`，不同 key 映射到同一槽位时会覆盖；
   linux_accel 使用包含 ingress ifindex、服务端 IP/端口、请求长度和请求字节的
   exact hash key。BMC 论文缩放负载中 linux_accel 比 BMC 多卸载
   `12.362 pp`，吞吐高 `24.61%`；同槽位压力下多卸载 `13.892 pp`，吞吐高
   `20.38%`；OpenStack TAP 同容量混合负载中多卸载 `12.913 pp`，吞吐高
   `10.03%`。这是本轮最扎实的相对 BMC 优势。
2. **纯命中时两者核心包处理能力接近，但 linux_accel 仍小幅领先。** 双方都是
   100% offload 时，linux_accel 吞吐仅高 `2.45%`，p99 低 `9.98%`。因此不能
   宣称我们的单包 XDP_TX 比 BMC 快一个数量级；真正拉开混合吞吐的是 cache
   组织和有效命中率。
3. **miss/pass 路径更克制。** netns 全 miss 时 linux_accel 比 BMC 高
   `1.31%`、p99 低 `19.71%`；OpenStack TAP 全 miss 时高 `3.19%`、p99 低
   `33.29%`。不过 netns 中两者都低于 nohook，所以这只能叫“更低的 miss
   额外开销”，不能叫 miss 加速。
4. **系统能力比 BMC 更通用。** BMC 是 Memcached UDP GET 的专用 cache，依靠
   TC 学习 GET response，并通过受限 TCP SET parser 做失效；linux_accel 的
   fast-path/control-plane 模型还覆盖 DNS、ARP、DHCP、通用 UDP 与 LDAP
   路径，支持 tenant/interface 作用域、TTL/expiry、policy feed、OpenStack
   TAP owner-safe attach/cleanup 和性能模式 telemetry。这里是架构/工程覆盖面
   优势，不应与 Memcached QPS 混成一个数值。

### 1.2 我们目前不能声称强于 BMC 的地方

- **纯命中单包路径没有数量级优势。** OpenStack 100% hit 时 linux_accel 只比
  BMC 高 `0.97%`，netns 也只有 `2.45%`；混合负载领先主要来自更高的有效
  offload，而不是一条明显更短的 XDP_TX 指令路径。
- **netns 混合吞吐领先不等于所有尾延迟都领先。** BMC 论文缩放场景中
  linux_accel p95 更好，但 p99 更差 `18.24%`；同槽位压力下 p95/p99 分别差
  `2.95%/12.52%`。批次调度、fallback 请求与高并发闭环客户端共同影响尾部，
  后续仍需 perf/trace 分解。
- **BMC 有动态学习优势。** BMC 从真实 GET response 学习 cache，并在 SET 时
  失效；当前通用 UDP 对比由控制面预装 request/response policy。我们的优点是
  精确、可分租户、易管控，但不能把预装策略说成比动态学习更自动。
- **这不是原论文硬件和 12 Mpps open-loop 的复刻。** 本轮保留了 Zipf、key/value
  大小和 4:1 keyspace/cache 比例，但把 population 缩到 `16,384`，使用 8 线程
  持久 UDP socket 的闭环客户端。报告称其为 `BMC-PAPER-TARGET-scaled`。
- **OpenStack 是同计算节点路径。** 路径包含 VM virtio/TAP、OVS br-int/OVN 和
  既有 OVN metadata localport backend，但不包含跨计算节点 Geneve；不能将结果
  宣称为 cross-host OpenStack overlay 加速。

## 2. 三个 baseline 分别回答什么

| 名称 | 含义 | 用途 |
|---|---|---|
| `nohook` | 不挂 XDP/TC，所有请求进入原 userspace backend | 共同系统基线，回答“挂 fast path 是否值得” |
| `BMC` | 官方 NSDI'21 BMC 固定提交，加当前内核/libbpf/TAP 所需的审计兼容补丁 | 主竞品，回答“相对高质量专用 XDP cache 是否更强” |
| `linux_accel` | 本项目 exact-key 通用 UDP fast path | 被测实现 |

答辩主表应优先给 `linux_accel / BMC`；`linux_accel / nohook` 用来解释整体收益，
不能用 nohook 的大倍数替代竞品结论。

## 3. BMC 可审计复现身份与兼容边界

### 3.1 固定来源

- 官方仓库：<https://github.com/Orange-OpenSource/bmc-cache>
- 固定提交：`2997145508e02c55aa92f63a0009ac2a26800810`
- 离线 Git bundle：
  `artifacts/competitor-bench/competitor-preflight-20260813-173626/sources/bmc-cache-2997145508e0.bundle`
- bundle SHA-256：
  `0c8e85ff5da691fdb1ed21445102072dac9cef066b0cb2c01f0d0db5ea219076`
- 兼容补丁：
  [`patches/competitors/0001-bmc-linux7-libbpf16-tap-compat.patch`](../patches/competitors/0001-bmc-linux7-libbpf16-tap-compat.patch)
- 补丁 SHA-256：
  `2f98ade68f9253b960d2abb82f07857d5a206a5cc4102f5135168dce5fdd4a77`
- 复现说明：[`patches/competitors/README.md`](../patches/competitors/README.md)

最终源文件和二进制身份：

| 对象 | SHA-256 |
|---|---|
| `bmc_common.h` | `03fabf2a4f645675c00b9a7d605700eb3a192697aef406ed450dbc1a8d94fe36` |
| `bmc_kern.c` | `5ccacdf0ef8cb72658eb9a301eca4830572992b2c38a21c63bf22cd3f360de09` |
| loader source | `dc31ed6b8be19663ea1d4c2a28d01b7fa4a65a5e3904562f98f29c4e875abe47` |
| 正式运行 `bmc_kern.o` | `1f827df54cf24472b169de209333df5826af509b7c78dfadac544800b672aa74` |
| 正式运行 `bmc_loader` | `618e6598d833e61d06b5445515bc5a977de67021b046fbe4fd775c3afcaa05d0` |

### 3.2 兼容补丁改了什么，没有改什么

补丁只处理 Linux 7.0/libbpf 1.6 和 OpenStack TAP 所需的可运行性：legacy map
声明、现代 verifier bounds、GPL license、canonical TCP SET 失效解析、TAP
tailroom、late-mismatch 恢复和 IPv4 checksum carry。它保留了 BMC 的 FNV、
direct-mapped array、entry spin lock、XDP response、TC response learning 与测试
范围内的 TCP invalidation。

OpenStack 诊断还发现了一个会污染竞品结果的上游边界 bug：原 checksum helper
只 fold 一次 one's-complement carry。修复前 200,000 次 BMC all-hit 中的 2 次
客户端超时，精确对应虚机 `Ip.InHdrErrors +2` 和 `IpExt.InCsumErrors +2`；增加
第二次 carry fold 后，同规模 `failed=0` 且两个计数增量都为 0。正式表格全部来自
修复后的对象，未利用竞品 bug 制造优势。

## 4. Memcached 正式实验

### 4.1 netns/veth：机制与压力对比

环境为 node2：Linux `7.0.0-14-generic`，`x86_64`。拓扑是 client namespace
经 veth/bridge 到 userspace Memcached backend，generic XDP 挂在 client-side
host veth。每个场景 3 个 mode、每个 mode 6 次重复，使用平衡的 6 排列顺序，
客户端/loader/server 固定 CPU 集合。

完整中位数如下：

| 场景 | mode | QPS | vs nohook | p50 us | p95 us | p99 us | backend offload | failures |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| BMC paper scaled | nohook | 572,067 | 1.000x | 12.943 | 18.393 | 26.075 | 0.000% | 0 |
|  | BMC | 949,402 | 1.660x | 3.219 | 27.709 | 48.766 | 73.489% | 0 |
|  | linux_accel | **1,183,045** | **2.068x** | 3.143 | 22.319 | 57.662 | **85.851%** | 0 |
| same-slot pressure | nohook | 570,842 | 1.000x | 13.026 | 18.416 | 24.970 | 0.000% | 0 |
|  | BMC | 819,620 | 1.436x | 3.333 | 26.690 | 42.486 | 61.198% | 0 |
|  | linux_accel | **986,680** | **1.728x** | 3.176 | 27.478 | 47.805 | **75.090%** | 0 |
| all hit | nohook | 582,494 | 1.000x | 12.933 | 18.011 | 23.995 | 0.000% | 0 |
|  | BMC | 1,708,120 | 2.932x | 3.172 | 3.276 | 3.667 | 100.000% | 0 |
|  | linux_accel | **1,749,955** | **3.004x** | 3.125 | 3.173 | **3.301** | 100.000% | 0 |
| all miss | nohook | 598,016 | 1.000x | 12.500 | 17.540 | 24.725 | 0.000% | 0 |
|  | BMC | 577,527 | 0.966x | 12.709 | 18.047 | 32.442 | 0.000% | 0 |
|  | linux_accel | 585,092 | 0.978x | 12.657 | 17.907 | **26.047** | 0.000% | 0 |
| Facebook ETC | nohook | 579,110 | 1.000x | 13.030 | 18.087 | 21.782 | 0.000% | 0 |
|  | BMC | 588,234 | 1.016x | 13.774 | 19.990 | 26.551 | 13.365% | 0 |
|  | linux_accel | **594,292** | **1.026x** | 13.560 | 19.904 | 26.648 | 13.497% | 0 |

五个 profile 共 `90` 个正式 case、`111,600,000` 个 timed request：请求失败、
内容/长度不匹配、客户端 checksum/IP/UDP 错误和 host softnet drop 均为 0；BMC
canonical TCP invalidation correctness gate 每个 profile 都通过。

原始数据：
[`bmc-formal-matrix-20260814-v15-final`](../artifacts/competitor-bench/competitor-preflight-20260813-173626/node2-results/bmc-formal-matrix-20260814-v15-final/)

分析产物：
[`analysis-bmc-v15-final`](../artifacts/competitor-bench/competitor-preflight-20260813-173626/node2-results/analysis-bmc-v15-final/summary.md)

### 4.2 OpenStack VM/TAP/OVS/OVN：部署路径对比

正式路径：

```text
instance-00000012/ens3
  -> host tapaa5e3ccb-96 generic XDP
  -> OVS br-int / OVN
  -> existing OVN metadata localport namespace (192.168.110.1)
  -> Memcached backend
```

主表每个 workload 有 3 个 mode、每个 mode 6 次重复，合计 `54` 个 case、
`2,700,000` 个 timed request。混合负载采用与 BMC object 一致的 `4,096`
cache entries、`16,384` key、Zipf `0.99`；linux_accel 也预装 `4,096` 项。

| 场景 | mode | QPS | vs nohook | p50 us | p95 us | p99 us | backend offload | failures |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| mixed，4:1 同容量 | nohook | 97,220 | 1.000x | 19.354 | 23.246 | 45.441 | 0.000% | 0 |
|  | BMC | 142,676 | 1.468x | 11.693 | 20.602 | 30.242 | 72.841% | 0 |
|  | linux_accel | **156,989** | **1.615x** | **10.828** | **19.321** | **24.505** | **85.754%** | 0 |
| all hit | nohook | 99,214 | 1.000x | 19.096 | 22.885 | 32.317 | 0.000% | 0 |
|  | BMC | 178,849 | 1.803x | 10.675 | 13.274 | 15.563 | 100.000% | 0 |
|  | linux_accel | **180,590** | **1.820x** | **10.555** | **13.107** | **15.497** | 100.000% | 0 |
| all miss | nohook | 99,818 | 1.000x | 18.982 | 22.722 | 48.121 | 0.000% | 0 |
|  | BMC | 97,595 | 0.978x | 19.261 | 22.843 | 51.438 | 0.000% | 0 |
|  | linux_accel | **100,710** | **1.009x** | **19.151** | **22.282** | **34.316** | 0.000% | 0 |

所有正式请求失败数为 0，虚机 checksum 错误增量为 0，host softnet drop 为 0。
同容量混合场景中 linux_accel 相对 nohook 为 `1.615x`、BMC 为 `1.468x`；
linux_accel 相对 BMC 吞吐高 `10.03%`，p50/p95/p99 分别低
`7.40%/6.22%/18.97%`。

首轮 OpenStack mixed pilot 曾得到 `153,422` 对 `153,183 QPS`（`+0.16%`）。
审计后发现 workload 把只预装 `1,024` 项的 linux_accel 与编译为 `4,096`
槽位、且能经 TC 动态学习冷 key 的 BMC object 对比；BMC 的实测 offload 因而
反高 `1.898 pp`。该轮容量口径不对称，保留为审计证据但不进入主结论。harness
现会读取 BMC `BUILD-METADATA.txt`，mixed 场景容量不一致时直接拒跑。100% hit
只访问一个已缓存 key，100% miss 不命中任何缓存，因此两个控制组不受该问题影响。

原始数据与分析：

- [`symmetric mixed raw`](../artifacts/protocol-fastpath/20260814-final/openstack-bmc-linux-symmetric-mixed-v1/)
- [`invalidated asymmetric mixed pilot`](../artifacts/competitor-bench/competitor-preflight-20260813-173626/node2-results/openstack-localport-bmc-v15-final-mixed-formal-20260814/)
- [`all-hit raw`](../artifacts/competitor-bench/competitor-preflight-20260813-173626/node2-results/openstack-localport-bmc-v15-final-all-hit-formal-20260814/)
- [`all-miss raw`](../artifacts/competitor-bench/competitor-preflight-20260813-173626/node2-results/openstack-localport-bmc-v15-final-all-miss-formal-20260814/)
- [`combined symmetric analysis`](../artifacts/protocol-fastpath/20260814-final/analysis-openstack-bmc-linux-symmetric-v1/summary.md)

## 5. DNS 扩展证据：相对 Xpress，而不是拿它冒充 BMC

BMC 只实现 Memcached，因此 DNS 使用 Xpress DNS 固定提交
`312e2a30c7838be0c5b92ab5d302a04a55f5afcd` 作为协议内竞品。流量采用
Cloudflare Radar 荷兰官方快照的 QTYPE 边缘比例和 cache hit 78.5% 边缘比例，
两者联合分布按独立假设合成；它是 O+H profile，不是原始逐请求 trace。

`resperf -L 1` 容量中位数：

| mode | 1% loss capacity QPS | vs nohook | 说明 |
|---|---:|---:|---|
| nohook | 140,834 | 1.000x | userspace baseline |
| Xpress | 246,994 | 1.754x | 35.34% backend bypass |
| linux_accel | **266,548** | **1.893x** | 48.92% bypass；客户端到顶，属于 server capacity 下界 |

因此 linux_accel 相对 Xpress 的已观测 1% loss capacity 高约 `7.92%`，但
linux_accel 点受客户端限制，不能宣称已经测到服务器真实上限。

`dnsperf` 高压点的 completed QPS：

| target | nohook | Xpress | linux_accel | linux_accel / Xpress | linux_accel loss |
|---:|---:|---:|---:|---:|---:|
| 250k | 146,912 | 230,966 | **246,953** | 1.069x | 1.218% |
| 500k | 146,696 | 233,915 | **286,459** | 1.225x | 5.775% |
| 650k | 147,740 | 233,087 | **297,724** | 1.277x | 6.246% |

高 loss 点的 latency 只统计已完成请求，存在 survivor bias，不能把这些 p99
与零丢包点直接混用。20k/100k 两个零丢包点上 Xpress p99 分别为 `58/25.5 us`，
linux_accel 为 `60.5/33.5 us`，所以低负载尾延迟仍是 Xpress 更好。

流量证据与联合分布限制：
[`competitor-traffic-profile-sources-2026-08.md`](competitor-traffic-profile-sources-2026-08.md)

DNS 分析：

- [`dnsperf summary`](../artifacts/competitor-bench/competitor-preflight-20260813-173626/analysis-dnsperf-v12-formal/summary.md)
- [`resperf summary`](../artifacts/competitor-bench/competitor-preflight-20260813-173626/analysis-resperf-v12-formal/summary.md)

## 6. 自有协议性能矩阵：各用各的 baseline

BMC 只支持 Memcached，不能拿它横跨所有协议。下面是在当前代码与同一 Linux
`7.0.0-14-generic` 环境补跑的 6 轮中位数。每一行的 baseline 都由协议语义决定，
不能把这些倍数平均成一个“总体加速比”。

| 协议路径 | baseline | linux_accel | QPS 比 | p99 改善比 | 正确结论 |
|---|---:|---:|---:|---:|---|
| ARP response | kernel ARP `397,623 QPS / 4.597 us` | generic XDP `751,096 QPS / 3.142 us` | **1.889x** | **1.463x** | 配置目标由 XDP 原地应答，server 侧精确 ARP capture 为 0 |
| 通用 UDP exact hit | userspace `297,716 QPS / 32.131 us` | generic XDP `3,514,820 QPS / 2.470 us` | **11.806x** | **13.008x** | 只适用于确定、无副作用的短 UDP exchange |
| LDAP 4 KiB relay | userspace proxy `27,605 QPS / 431.770 us` | sockmap `24,508 QPS / 462.811 us` | **0.888x** | **0.933x** | 吞吐/尾延迟变差，但代理 CPU `21.72 s -> 0.02 s`，属于 CPU offload |
| gRPC h2c unary cache | delayed demo backend `1,759 QPS / 733.850 us` | response cache `22,256 QPS / 54.955 us` | **12.652x** | **13.354x** | 包含 300 us 模拟后端延迟且每请求重连，只证明原型机制 |
| DHCPv4 relay | 正常 relay/forwarding | XDP controlled redirect | — | — | 有状态 relay 不是响应 cache，只报告 Discover/Offer/ACK 等正确性 gate |

LDAP 同时完成 LDAPS opaque TLS smoke：没有 userspace fallback、redirect failure 或
relay error。gRPC 复测发现并修复了 `SIGTERM` 被 `accept()` 的 `SA_RESTART` 行为
吞掉导致 benchmark 无法退出的问题；修复后 lifecycle smoke 和 6 轮矩阵都能正常
输出统计、清理临时资源。完整数据见
[`protocol-fastpath/20260814-final`](../artifacts/protocol-fastpath/20260814-final/summary.md)。

## 7. 正确性 gate 与系统指标

每轮正式测试都先做 correctness gate，再进入 timed phase：

- nohook all-hit 必须全部到 backend；BMC/linux_accel all-hit 必须 backend=0；
- all-miss 三个 mode 都必须 backend=request count；
- mixed 模式记录而不假造实际 offload，由 backend counter 反推；
- 检查发送错误、接收超时、接收错误、长度不匹配、内容不匹配及首个失败样本；
- OpenStack 每个 case 前后读取 guest `Ip.InHdrErrors`、`IpExt.InCsumErrors` 等；
- 记录 host CPU busy、context switch/request、NET_RX softirq/request 和 softnet drop；
- 检查 Kubernetes service 状态，发现启动即中止；
- OpenStack cleanup 采用 owner-checked detach，不覆盖未知 XDP/TC owner。

正式 netns `111.6M` 请求和 OpenStack `2.7M` 请求合计 `114.3M` timed request，
最终 failure、内容错误、checksum error 和 softnet drop 均为 0。

## 8. 复现实验

### 8.1 构建固定 BMC 兼容对象

```bash
git clone artifacts/competitor-bench/competitor-preflight-20260813-173626/sources/bmc-cache-2997145508e0.bundle /tmp/bmc-cache
./scripts/build_bmc_compat.sh /tmp/bmc-cache /tmp/bmc-out
```

脚本从 pinned commit 导出源文件，不信任 checkout working tree；然后应用补丁、
核对源 SHA-256 并构建 BPF object 和 owner-checked libbpf loader。输出目录必须为空，
防止旧 object 混入。

### 8.2 netns/veth 正式矩阵

```bash
sudo env \
  BMC_DIR=/tmp/bmc-out \
  LINUX_DIR=/path/to/linux-accel-build \
  BENCHMARK=/path/to/memcached_udp_zipf_bench \
  ./bench/run_bmc_formal_matrix.sh

python3 tools/analyze_bmc_competitor_bench.py \
  --output /tmp/bmc-analysis \
  /path/to/bmc-formal-matrix/*
```

### 8.3 OpenStack TAP 正式矩阵

```bash
env \
  CLIENT_TAP=tapaa5e3ccb-96 \
  CLIENT_INSTANCE=instance-00000012 \
  BACKEND_NS=ovnmeta-2644af16-f4f0-4f46-9950-8faff490f187 \
  BACKEND_IP=192.168.110.1 \
  BMC_DIR=/tmp/bmc-out \
  LINUX_DIR=/path/to/linux-accel-build \
  POPULATION=16384 HOT_KEYS=4096 CACHE_ENTRIES=4096 \
  PATH_PROFILE=mixed \
  ./bench/openstack_localport_bmc_competitor_bench.sh \
  artifacts/openstack-mixed-formal formal
```

分别以 `PATH_PROFILE=mixed`、`all-hit`、`all-miss` 运行。脚本不依赖 OpenStack
API，但会校验指定实例/TAP/backend namespace 身份、BMC 与 linux_accel 的 mixed
cache 容量一致性，且强制 Kubernetes 保持停止。

### 8.4 DNS 正式矩阵

```bash
sudo ./bench/run_dnsperf_resperf_formal_matrix.sh
python3 tools/analyze_dns_competitor_bench.py \
  --output /tmp/dnsperf-analysis /path/to/dnsperf-results/*
python3 tools/analyze_resperf.py \
  --output /tmp/resperf-analysis /path/to/dnsperf-results/resperf-*
```

## 9. 恢复状态与未完成风险

- Kubernetes 保持关闭，未为测试启动 kubelet/containerd 等服务。
- 正式运行结束后 `bpftool net` 无本实验残留，OpenStack TAP qdisc 恢复 `noqueue`。
- VM XML/hash、既有 XDP/TC attachment 快照前后一致；只保留原有 OVN metadata
  namespace，没有残留 BMC 临时 namespace。
- Horizon、Keystone、Nova、Placement、Neutron 可用；Glance 因 node1 离线返回
  503，属于测试前已存在的控制面问题，本实验未启动或重部署控制服务。
- node1 不可达，因此本轮没有 cross-compute/Geneve 正式复测；这是当前最重要的
  外部有效性缺口。

## 10. 一句话答辩版本

> 相对 NSDI'21 BMC，我们不是靠把纯命中 XDP_TX 做快很多取胜：纯命中只领先
> 2.45%；真正优势是 exact、tenant-scoped cache 在 Zipf 混合和槽位冲突下保持了
> 高 12–14 个百分点的有效卸载率，从而把 netns 吞吐提高 20–25%；在同容量
> OpenStack TAP 混合负载上也保持 `+12.913 pp` offload、`+10.03%` QPS，并同时
> 降低 p50/p95/p99。我们的工程形态还从 Memcached 单协议 cache 扩展为可部署、
> 可管控、可恢复的多协议 fast path。
