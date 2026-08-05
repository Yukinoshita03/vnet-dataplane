# OpenStack / XDP 偏真实流量 Benchmark 设计（2026-08）

## 结论

不建议再用一个固定域名、固定包长、固定 QPS 的单一工具作为最终结论。当前项目最合适的是三层组合：

1. **业务收益层**：在 OpenStack client VM 内运行 `k6/x/dns`，每次迭代先显式解析服务名，再向解析出的 IP 发 HTTP 请求，测一次完整“服务发现 + 业务请求”的端到端耗时。
2. **DNS 真实性与容量层**：用真实或脱敏 DNS trace 驱动 DNS Shotgun/dnsjit；用 dnsperf 做同一语料下的稳态容量和延迟，用 resperf 找容量拐点。
3. **物理 native XDP 能力层**：在独立物理路径上用 kxdpgun（条件足够时用专用 TRex 主机）比较 userspace、generic XDP、native XDP。该结果单独报告，不能冒充 OpenStack overlay 的业务收益。

如果只能选一个最接近“真实 DNS 客户端行为”的现成 benchmark，首选 **DNS Shotgun**。它从真实客户端查询流中恢复每个客户端的查询时序，并允许改变 UDP/TCP/DoT/DoH 和连接行为；其目标就是 near-real-world resolver benchmarking。[DNS-OARC 的 DNS Shotgun 介绍](https://indico.dns-oarc.net/event/34/contributions/782/)、[项目仓库](https://gitlab.nic.cz/knot/shotgun/)。

但本项目最终应使用“DNS Shotgun/dnsjit + k6 业务旅程 + dnsperf/resperf 容量曲线”的组合，而不是只报一个 QPS 数字。

## 为什么上一轮不够真实

现有 [`physical_xdp_burst_client.c`](../bench/physical_xdp_burst_client.c) 的价值是测快路径上限：

- 一个固定的 `example.test A/IN`；
- 持久 UDP socket；
- 固定线程、固定 batch；
- 固定 offered QPS；
- node2 物理口直达 node1 物理口。

它没有覆盖真实业务中的域名热度分布、冷启动、TTL、缓存抖动、AAAA/EDNS/NXDOMAIN 等旁路流量、客户端数量差异、突发到达，以及 OpenStack tap/OVS/OVN/Geneve 路径。之前 1M offered QPS 的结果还进入了生成端和共享 1GbE 队列过载区，因此只能解释为饱和现象，不能解释为业务加速比。历史结果见 [`summary.md`](../artifacts/physical-xdp-burst/20260805-175700/summary.md)。

## 轨道 A：OpenStack 业务真实性实验（主结论）

### 拓扑

```text
node2                                      node1
  client-vm-1 -- tap generic XDP --+        resolver-vm
  client-vm-2 -- tap generic XDP --+          + closed-world DNS corpus
                                    |          + DNS request counter
node3                               |          + HTTP service
  client-vm-3 -- tap generic XDP --+          |
  client-vm-4 -- tap generic XDP --+          |
                                    v          v
                           br-int / OVN / Geneve
                              + logical router
```

推荐把四个 client VM 平均放在 node2、node3，把 resolver/HTTP service VM 固定在 node1。client 与 service 使用两个 tenant subnet，通过 OVN logical router 连接。这样一次未命中的请求会真实经过：

```text
VM eth0
-> host TAP
-> OVS br-int
-> OVN logical router
-> Geneve underlay
-> remote OVS/TAP
-> resolver VM
```

缓存命中则在 client host TAP 的 generic XDP 处 `XDP_TX` 返回，不进入 OVS、逻辑路由器、Geneve 和 resolver VM。这个差异正好对应“虚拟机向外解析请求的加速”。

约束：

- Kubernetes 继续保持关闭；
- node1 物理 `enp3s0` 上是否保留现有 native XDP，整个 OpenStack A/B 实验期间必须保持完全相同，不能随模式切换；
- 当前物理 NIC 上看到的是 Geneve 外层 UDP，而当前 DNS BPF 程序不解析 Geneve 内层，因此本轨道只称为 **OpenStack TAP generic XDP**，不称为 native XDP；
- 不在共享管理/OVN NIC 上运行 TRex、任意速率 tcpreplay 或会接管 NIC 的 DPDK 程序。

### 业务旅程

每次 k6 iteration 执行：

```text
选择 service name
-> dns.resolve(name, "A", resolver:53)
-> 校验返回地址
-> HTTP GET http://returned-ip/resource，Host 使用原 service name
-> 校验 HTTP status/body
-> 记录 DNS、HTTP、总 journey latency
```

k6 当前的官方 `k6/x/dns` 模块可以向指定 nameserver 发 A/AAAA 查询并自动记录 `dns_resolution_duration` 等指标；constant/ramping arrival-rate executor 属于 open model，不会因为服务变慢就自动降低新请求到达率，适合避免 coordinated omission。[k6/x/dns 官方文档](https://grafana.com/docs/k6/latest/javascript-api/k6-x-dns/)、[constant-arrival-rate 官方文档](https://grafana.com/docs/k6/latest/using-k6/scenarios/executors/constant-arrival-rate/)。

`k6/x/dns` 是 official extension；常规联网环境可以自动解析和装载 extension，但学校集群离线，不能在 VM 内依赖运行时 provision。应在 Mac staging 侧构建并验证包含固定版本 xk6-dns 的 Linux/amd64 自包含 k6 binary，传入集群后设置 `K6_AUTO_EXTENSION_RESOLUTION=false` 再做 smoke，证明没有隐藏网络依赖。[k6 extension 运行方式](https://grafana.com/docs/k6/latest/extensions/run/)。

这个层面回答两个不同问题：

- DNS 本身的 p99、成功率和最大可持续 QPS 提升多少；
- DNS 加速放进一次真实服务调用后，整个 journey 的 p99、成功率和 CPU 成本改善多少。

第二个数字通常会比 DNS-only 加速比小，但更接近用户真正感知的收益。

### DNS 语料

#### 首选：真实 trace

采集 30–60 分钟有代表性的 DNS client-query 数据，优先使用 dnstap；没有 dnstap 时使用 dnscap/pcap。dnstap 是带 socket family、协议、地址、端口、query/response 时间和 wire-format message 的结构化 DNS 事件格式；dnscap 则专门捕获 UDP/TCP DNS、IPv4/IPv6 和分片。[dnstap 格式与支持情况](https://dnstap.info/)、[dnscap 官方说明](https://www.dns-oarc.net/tools/dnscap)。

脱敏时保留：

- 查询间隔和每个客户端的时间序列；
- 同名关系与域名热度排序；
- QTYPE、EDNS/DNSSEC 标记、UDP/TCP；
- response size、RCODE、TTL bucket；
- client cohort，但不保留真实 client IP；
- query/response 配对和重试关系。

使用固定 HMAC 或稳定映射替换 qname 和 client identity，从而保留“重复查询”和热门程度。原始 trace 不进入仓库，只提交脱敏 corpus、转换程序和字段统计。

集群离线，不能依赖公网递归解析。需要在 resolver VM 内建立 closed-world 数据集：从脱敏 trace 生成确定性的 A、AAAA、CNAME、NXDOMAIN 和不同 TTL 的响应。这样每轮输入和答案完全一致，也能验证加速前后是否返回错误答案。

#### 没有真实 trace 时的 bootstrap profile

以下只是首轮可复现的合成配置，不应在报告中称为“生产流量分布”；拿到 trace 后全部由实测分布替换。

| 流量类别 | 比例 | 期望路径 |
| --- | ---: | --- |
| 热门、重复、无 EDNS 的直接 `A/IN` | 45% | warm 后大部分可在 client XDP 命中 |
| 中等热度、短 TTL 或周期 churn 的直接 `A/IN` | 20% | miss/learn/hit/expire 交替 |
| 一次性冷 `A/IN` | 10% | 主要穿透到 resolver |
| `AAAA/IN` | 10% | 当前实现 fail-open |
| 带 EDNS 的 `A/IN` | 5% | 当前 client learner 拒绝并放行 |
| NXDOMAIN | 5% | 不学习，穿透 |
| CNAME 或多 Answer | 3% | 不学习，穿透 |
| TCP fallback / oversized response | 2% | 不由当前 XDP cache 加速 |

建议使用至少 50k 个脱敏名称，其中 1% hot set 承担 45% 查询；TTL 使用 5s、30s、300s 三档，并每 60s 替换一小部分中等热度名称。这里的数字用于压力敏感性实验，不代表互联网统一分布。

DNS-OARC 提供过 dnsperf/resperf 样例查询集，但仓库已归档，且数据来自较早期 trace，只适合验证工具链，不适合作为 2026 年“真实业务”结论。[DNS-OARC sample-query-data](https://github.com/DNS-OARC/sample-query-data)。

### 到达模型和测试阶段

先用 resperf 在 **no-hook baseline** 下找出容量拐点 `K`。resperf 会按受控速率线性抬升负载，同时记录 query rate、response rate、failure rate 和 latency；它适合找 plateau，而不是直接作为最终稳态结果。[DNS-OARC dnsperf/resperf](https://www.dns-oarc.net/tools/dnsperf)。

随后每个模式执行完全相同的事件序列：

| 阶段 | 负载 | 时长 | 目的 |
| --- | ---: | ---: | --- |
| cold start | `0.2K` | 2 min | 观察学习、首个 miss 和冷缓存体验 |
| steady | `0.6K` | 10 min | 同负载比较 p99、CPU、backend offload |
| microburst | `0.6K` 50s + `1.0K` 10s，循环 5 次 | 5 min | 观察队列、丢包和恢复 |
| spike | `1.2K` | 30s | 观察过载行为，不拿此阶段算正常加速比 |
| recovery | `0.6K` | 2 min | 检查延迟和丢包能否恢复 |
| soak（单独执行） | `0.7K` | 60 min | 查 map、TTL、进程、OpenStack 心跳稳定性 |

若已有真实 trace，优先使用原始 inter-arrival time，并另外做 `0.5x/1x/2x` 时间缩放；上述方波只作为无 trace 时的 fallback。Flamethrower 支持动态 QPS flow、UDP/TCP/DoT/DoH 和 JSON 指标，适合生成方波/协议兼容流量，但它单进程是单线程异步模型，高吞吐时要多进程或多 VM。[Flamethrower 官方仓库](https://github.com/DNS-OARC/flamethrower)。

### OpenStack A/B 模式

所有模式使用同一 VM placement、CPU 配置、query seed、事件文件和后端数据集：

| 模式 | Hook / cache 状态 | 回答的问题 |
| --- | --- | --- |
| O0 no-hook | TAP 无项目 XDP/tc | 完整 userspace + OVS/OVN/Geneve baseline |
| O1 pass-through | generic XDP + tc 已挂载，同一语料但 fast-response 由运行时开关禁用 | 程序挂载、解析和学习本身的开销 |
| O2 realistic-cache | generic XDP + tc 学习，真实/合成混合语料 | 主要业务结论 |
| O3 all-hot ceiling | 100% 重复直接 `A/IN` | 与旧实验衔接的能力上限，不称为真实收益 |

O0/O1/O2 至少做 5 组 paired repetitions，随机化模式顺序。每轮显式重置或预热 cache 到相同状态；不能让总是后跑的模式天然拥有更热的 CPU/cache/ARP/OVN 状态。

当前 client BPF 会在合法响应后自动学习，因此不能靠“先清空 map”维持 O1；它很快会变成 O2。O1 需要增加一个只禁止 `XDP_TX` fast-response、但保留相同解析/学习工作的运行时 flag。若暂时不加该 flag，就先只报告 O0/O2，不能换一套不命中的 query corpus 来伪造同负载 hook-overhead 对照。

至少分别执行：

- 无背景流量；
- 同时存在租户 HTTP 短请求和一个受控长连接的 mixed-traffic；
- 同宿主机路径（控制组）和跨 node2/node3 → node1 Geneve 路径（主结果）。

## 轨道 B：trace-driven DNS 专项

### 推荐工具

DNS Shotgun 最贴近真实 resolver 客户端模型；dnsjit 是更底层、可脚本化的抓取、解析、统计和 replay 引擎。DNS Shotgun 当前可见的最近 tag 是 `v20240219`，而 dnsjit 仍由 DNS-OARC 活跃发布，2026-02-04 发布了 1.5.1。因此应固定 Shotgun 版本先做兼容性 smoke；如果 wrapper 与新系统不兼容，就保留其 trace/client-timing 方法，直接用 dnsjit 1.5.1 编排 replay。[DNS Shotgun tags](https://gitlab.nic.cz/knot/shotgun/-/tags)、[dnsjit 官方页面](https://www.dns-oarc.net/tools/dnsjit)。

推荐用法：

1. 用 dnstap/dnscap 获得 trace；
2. 脱敏并按 client identity 切成四个 shard；
3. 四个 OpenStack client VM 同步启动 Shotgun/dnsjit；
4. 保持原始 client timing、query popularity、协议和重试；
5. 在相同 offered trace 上跑 O0/O1/O2；
6. 使用 dnsperf 在固定 0.2K/0.6K/0.8K/0.95K 点补齐稳态 latency/capacity 曲线。

dnsperf 适合查询文件、受控 QPS、并发/outstanding 和延迟/吞吐统计；DNS-OARC 当前页面列出的最新发布是 2.15.1（2026-04-15）。resperf 用来找容量拐点。两者是本项目最稳妥的标准 DNS 基线，但单独使用查询列表不会恢复真实 client timing，所以不能替代 Shotgun/dnsjit。[DNS-OARC dnsperf 官方页面](https://www.dns-oarc.net/tools/dnsperf)。

PowerDNS `dnsreplay` 可以把 PCAP 中的 query 发给目标 nameserver，并比较新响应与原响应，适合 correctness/regression；其手册也明确提示 timeout handling 不确定且大约只能跟踪 65536 个 outstanding answer，因此不作为主容量发生器。[PowerDNS dnsreplay](https://doc.powerdns.com/authoritative/manpages/dnsreplay.1.html)。

## 轨道 C：物理 native XDP 能力（单独报告）

### 当前集群可做的版本

路径固定为：

```text
node2/node3 physical NIC -> node1 enp3s0 -> userspace/generic/native
```

使用与 OpenStack 轨道相同的 query corpus，但指标标题必须写成 `physical plain-UDP capability`。它回答“native hook 相对 generic hook 的数据面上限”，不回答 VM 业务整体收益。

kxdpgun 是 Knot DNS 的 XDP DNS traffic generator，支持 query file、目标 QPS、batch、CPU affinity、source IP range、UDP/TCP/QUIC，以及 auto/copy/generic XDP socket 模式；但它只统计收到的响应，不把每个响应与 query 做内容匹配，因此必须另外抽样做 correctness。[kxdpgun 官方手册](https://www.knot-dns.cz/docs/3.4/html/man_kxdpgun.html)。

当前 node2 的 r8169、单队列/小 ring 和共享 1GbE 已经在上一轮成为发生端瓶颈。即使换 kxdpgun，也必须满足以下 generator validity gate 才能采信：

- generator 实际发包率达到目标；
- generator qdisc drop、socket error、NIC TX drop 均为 0；
- node1 入口 wire PPS 与 generator 发出 PPS 对得上；
- 结果点位位于 loss knee 之前，而不是 1M offered 的拥塞区；
- response correctness 由独立采样器验证。

更好的最终硬件方案是增加一台专用 traffic-generator 主机和一张受支持的多队列 10GbE NIC，再使用 kxdpgun 或 TRex。TRex 基于 DPDK，支持 stateful/stateless profile 和 PCAP；官方文档说明 DPDK 会接管 traffic port，并明确警告不要把活跃管理接口放进 TRex 配置，所以它不适合当前共享管理/OVN 的 `enp3s0`。[TRex 官方 FAQ](https://trex-tgn.cisco.com/trex/doc/trex_faq.html)。

Linux pktgen 适合测内核 TX/NIC 的人工 PPS 上限，tcpreplay 适合按 PCAP 时间戳重放背景包；二者都不验证 DNS 事务语义，不能单独形成项目业务结论。[Linux pktgen 文档](https://docs.kernel.org/networking/pktgen.html)、[tcpreplay timing 文档](https://tcpreplay.appneta.com/concepts/timing-and-speed/)。

## 指标和加速比口径

### 必采指标链

| 边界 | 指标 |
| --- | --- |
| 发生器 | scheduled/offered、socket accepted、actual sent、dropped iteration/send error |
| client VM | completed、timeout、wrong answer、DNS p50/p95/p99/p99.9、journey p99 |
| client host TAP | RX/TX packet、XDP pass/hit/tx、tc learned/rejected/expired |
| OVS/OVN | br-int/port packet、Geneve underlay packet/byte |
| resolver VM | 实际收到 query 数、RCODE、response size、backend CPU |
| compute host | cycles、instructions、CPU time、NET_RX/TX softirq、context switch |
| NIC/queue | RX/TX packet、qdisc drop/requeue、softnet drop/squeezed、XDP TX full |
| 控制面 | OpenStack API、OVN controller/metadata agent heartbeat；K8s 必须保持 inactive |

每一轮都保存原始输出和 before/after counter snapshot。不能只保存工具最后打印的 QPS。

### 正确的加速比

在同一个 offered QPS `q` 上比较延迟：

```text
p99 speedup(q) = p99_no_hook(q) / p99_realistic_cache(q)
```

在相同 SLO 下比较容量：

```text
capacity speedup = max_sustainable_qps_cache / max_sustainable_qps_no_hook
```

推荐首轮 max-sustainable gate：

```text
completion >= 99.9%
wrong_answer = 0
SERVFAIL 不高于 baseline + 0.05 percentage point
DNS p99 <= 10 ms
generator-side drop = 0
```

这是实验 gate，不是通用生产 SLO；有真实业务 SLO 后替换。

同时报告：

```text
backend offload = 1 - resolver_queries_cache / resolver_queries_no_hook
CPU efficiency = completed_queries / host_CPU_second
underlay offload = 1 - Geneve_packets_cache / Geneve_packets_no_hook
```

必须把以下数字分开：

- `scheduled/offered QPS`；
- generator 实际 `sent QPS`；
- node1/VM 实际收到的 wire QPS；
- 正确完成的 `response QPS`。

不能再用 1M target 直接除以 response 数作为数据面结论。

## 工具选择表

| 工具 | 最适用途 | 优点 | 关键局限 | 本项目结论 |
| --- | --- | --- | --- | --- |
| DNS Shotgun + dnsjit | 真实 trace、client timing、缓存行为 | 最接近真实 DNS client stream；可脚本化 | 部署和 trace 清洗较复杂 | **真实性主工具** |
| k6/x/dns | DNS + HTTP 业务旅程 | open arrival model；直接得到 DNS 与总 journey 指标 | 主要支持 A/AAAA；不是极限 PPS 工具 | **业务价值主工具** |
| dnsperf | 固定语料稳态 QPS/latency | 标准、可控、结果容易对比 | query list 本身没有真实时序 | **容量主工具** |
| resperf | 自动寻找 loss/response plateau | 适合找 knee | ramp 不是稳态业务负载 | **预扫描工具** |
| Flamethrower | 方波、协议兼容、JSON | UDP/TCP/DoT/DoH、动态 QPS | 单进程单线程；不是精确 trace replay | 可选 burst 工具 |
| dnsreplay | PCAP answer regression | 可比较新旧 answer | outstanding/timeout 边界明显 | correctness 辅助 |
| kxdpgun | 物理 DNS 高 PPS | XDP socket、batch、source range | 不逐 query 校验 response | native 能力主工具 |
| tcpreplay | 原时序背景 PCAP | 可保留 inter-packet gaps | 不理解动态 DNS transaction | 背景/回归辅助 |
| TRex | 专用高速发生器 | DPDK、多流、profile/PCAP | 需要专用 NIC；不能碰管理口 | 后续硬件升级后使用 |
| pktgen | NIC/kernel TX ceiling | 简单、内核内发生 | 高度人工、无 DNS 语义 | 仅微基准 |

## 推荐落地顺序

1. 在 Mac 联网 staging 机下载并固化 dnsperf/resperf、dnsjit/DNS Shotgun 的版本和校验和，并构建包含固定 xk6-dns 的 Linux/amd64 自包含 k6；集群节点继续按离线方式接收 artifact。
2. 用四个 client VM + 一个 resolver/HTTP VM 建立跨宿主机、跨 tenant subnet 的 OpenStack 拓扑。
3. 先实现 bootstrap corpus 和 closed-world DNS/HTTP backend；5k QPS 做 correctness gate。
4. 跑 O0/O1/O2 的 resperf knee scan，再按 `K` 生成 steady/burst/soak 调度。
5. 先交付 k6 journey 与 dnsperf 曲线；随后接入真实脱敏 dnstap/pcap 和 DNS Shotgun。
6. 最后在独立物理轨道用 kxdpgun 重跑 userspace/generic/native；没有专用生成器 NIC 时只报告 knee 之前的可信点。

建议新增的仓库入口：

```text
bench/openstack_realistic_dns_bench.sh
bench/k6_dns_http_journey.js
bench/trace_dns_replay.sh
config/bench/realistic-dns-profile.yaml
tools/sanitize_dns_trace.py
```

第一轮最值得产出的三张图：

1. 相同 offered QPS 下 O0/O1/O2 的 DNS p99 与 journey p99；
2. response QPS / loss / wrong-answer 随 offered QPS 的曲线和 SLO knee；
3. XDP hit、resolver query、Geneve packet、host CPU 随时间的联合曲线，标出 cold/steady/burst/recovery 阶段。
