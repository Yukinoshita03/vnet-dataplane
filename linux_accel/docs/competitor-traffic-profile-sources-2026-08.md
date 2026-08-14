# Xpress DNS、NLnet xdp-dns-cache、BMC 与 TURN 的一手流量比例依据

## 1. 结论与使用边界

本文只回答“后续实际对比实验应按什么比例造流量，以及这些比例来自哪里”。本轮没有修改任何 benchmark、生成器或被测实现。

- **资料捕获日期**：2026-08-13（中国标准时间）；动态 DNS 仪表盘捕获时间约为 `2026-08-13 18:05 +08:00`。
- **来源范围**：官方仪表盘/API 文档、会议/出版社论文页面和 PDF、作者主页、作者或项目官方代码仓库。未采用博客转述、媒体文章或第三方统计。
- **“精确比例”含义**：仪表盘数据按其显示精度原样记录；由论文给出的比例推导出的百分比会标明“推导值”。没有原始计数时，不把显示值或“约”描述伪装成更高精度的观测。
- **联合分布限制**：DNS QTYPE、传输协议和 cache hit 是 Cloudflare 分别公布的边缘分布；论文中的 Memcached 操作比例、对象大小、命中率和 key 热度也大多来自不同表格或模型。除非来源明确给出联合分布，否则把它们合成一个请求流属于人为假设。

本文使用以下证据标签：

| 标签 | 含义 | 可以怎样表述 |
|---|---|---|
| **O（Observed）** | 生产系统或官方仪表盘的观测数据 | “观测到……” |
| **W（Workload）** | 论文实际运行过的评测工作负载 | “论文按……测试”，不能称为生产流量比例 |
| **S（Synthetic）** | 为可复现而人为选择的参数、展开方式或随机种子 | “本实验合成……” |
| **H（Hybrid）** | 把多个 O/W 边缘分布按明确假设合成 | “保留来源边缘比例，但联合关系为合成” |
| **I（Implementation）** | 代码能力、常量或支持边界 | 只能限定可测试路径，不能当流量观测 |

建议实际使用的 profile 如下：

| Profile | 对应对象 | 证据级别 | 用途 | 不能声称什么 |
|---|---|---:|---|---|
| `DNS-RADAR-NL-MARGINALS` | linux_accel 的混合 QTYPE/命中路径 | O + H | 按荷兰 1.1.1.1 的 QTYPE 与 cache-hit 边缘比例测试 | 不能称为原始逐请求 trace，也不能称为 QTYPE×hit 的实测联合分布 |
| `DNS-XPRESS-A-COMMON` | Xpress DNS 与 linux_accel | H | 双方都能处理的 A/IN、单问题、UDP 公平对比 | 不能称为真实 DNS QTYPE 混合 |
| `DNS-NLNET-NS-SMOKE` | NLnet xdp-dns-cache 原型 | I + S | 仅验证论文原型的 `nl. NS` 硬编码路径 | 不能称为真实热缓存负载 |
| `BMC-PAPER-TARGET` | BMC 与 linux_accel/KV fast path | W | 最忠实复现 BMC 论文主工作负载 | 不能称 Zipf 0.99、16/32 B 为 Facebook 实测分布 |
| `FB-ETC-MARGINALS` | BMC 的 Facebook-like 扩展场景 | O + H | 保留 ETC 的 GET/UPDATE、hit 和 size 边缘数据 | 不能称为 Facebook 原始联合 trace |
| TURN | Supercharge WebRTC | 无可接受数值比例 | 暂不纳入“真实比例”综合分数 | 不能把论文中的 “bulk” 翻译成任意百分比 |

### 1.1 关键数字的一手来源审计

| 数字 | 一手出处 | 原始性质 | 本文如何使用 |
|---|---|---|---|
| DNS QTYPE：A 56.6%、AAAA 30.3%、HTTPS 6.3%、PTR 3.6%、NS 0.7%、Other 2.5% | [Cloudflare Radar 荷兰 DNS 官方仪表盘](https://radar.cloudflare.com/dns/nl)，2026-08-13 捕获，页面窗口为 Last 7 days；[官方 API 维度/元数据说明](https://developers.cloudflare.com/api/resources/radar/subresources/dns/methods/summary_v2/) | O；页面舍入到 0.1%，未公开本次快照的原始计数 | 保持该 QTYPE 边际；Other 的具体类型展开为 S |
| DNS resolver cache：hit 78.5%、miss 21.5% | [同一 Cloudflare Radar 官方仪表盘](https://radar.cloudflare.com/dns/nl) | O；这是 1.1.1.1 resolver cache 边际，不是 XDP map 实测 | 映射到预装/未预装名称属于 H |
| Facebook production GET:SET `30:1` | [BMC 官方 NSDI 2021 PDF，§2.1，第 488 页](https://www.usenix.org/system/files/nsdi21-ghigoff.pdf#page=3) | BMC 对生产流量的表述；其依据的原 Facebook trace 把写操作称为 UPDATE，并聚合 SET、REPLACE 等 | 只用于 `FB-ETC-MARGINALS`；不冒充 BMC timed target mix |
| Zipf exponent/skewness `0.99` | [BMC 官方 NSDI 2021 PDF，§5.1/Table 3，第 493 页](https://www.usenix.org/system/files/nsdi21-ghigoff.pdf#page=7) | W；论文明确说与 YCSB 所用值相同，不是 Facebook trace 的拟合结果 | `BMC-PAPER-TARGET` 的 key rank 分布 |
| 16 B key、32 B value、100M key population | [BMC 官方 NSDI 2021 PDF，§5.1/Table 3，第 493 页](https://www.usenix.org/system/files/nsdi21-ghigoff.pdf#page=7) | W | 原样用于 `BMC-PAPER-TARGET` |
| BMC:Memcached cache size ratio `25%`；对应默认配置 BMC 2.5 GB、Memcached 10 GB | [BMC 官方 NSDI 2021 PDF，§5.1/Table 3，第 493 页](https://www.usenix.org/system/files/nsdi21-ghigoff.pdf#page=7) | W；是论文评测配置，不是生产比例 | 原样记录；运行时还需记录实际代码版本的 map capacity |

这里最重要的联合分布声明是：**Cloudflare 只分别公布了 QTYPE 与 cache-hit 边际，未公布 `QTYPE × hit/miss` 联合表；本文表 2.4 的交叉配额是在“两个边际独立”假设下合成的 H。** 同理，BMC 的 Zipf 0.99、16/32 B、100M、25% 属于论文 W；`30:1` 属于论文引用的生产 workload 背景。把 `30:1` 与前述 W 参数拼成同一请求流同样是 H，而不是 BMC 论文原 timed workload 的逐项复刻。

## 2. DNS：Xpress DNS 与 NLnet xdp-dns-cache

### 2.1 可采用的生产观测

[Cloudflare Radar 荷兰 DNS 页面](https://radar.cloudflare.com/dns/nl)说明其数据来自 1.1.1.1 公共递归解析器的匿名化 DNS 查询日志，地点为 Netherlands，选择窗口为 `Last 7 days`。2026-08-13 捕获到的页面显示值如下。

#### QTYPE 边缘分布（O）

| QTYPE | 页面显示占比 | 每 100,000 请求的精确配额 |
|---|---:|---:|
| A | 56.6% | 56,600 |
| AAAA | 30.3% | 30,300 |
| HTTPS | 6.3% | 6,300 |
| PTR | 3.6% | 3,600 |
| NS | 0.7% | 700 |
| Other | 2.5% | 2,500 |
| **合计** | **100.0%** | **100,000** |

这些百分比是仪表盘显示的一位小数值，不是未经舍入的原始计数。官方 [Radar DNS summary API](https://developers.cloudflare.com/api/resources/radar/subresources/dns/methods/summary_v2/)支持按 `QUERY_TYPE` 和 `CACHE_HIT` 查询，并会在响应 `meta.dateRange` 中返回精确窗口，但 API 需要 Cloudflare token；本次没有凭据，因此不能补写页面未显示的原始计数、更多小数位或精确 UTC 起止时间。

#### Cache 状态边缘分布（O）

| 1.1.1.1 响应来源 | 页面显示占比 | 每 100,000 请求的精确配额 |
|---|---:|---:|
| Cache hit | 78.5% | 78,500 |
| Cache miss | 21.5% | 21,500 |
| **合计** | **100.0%** | **100,000** |

这里的 hit 指 Cloudflare 递归解析器从自身缓存提供响应。把它映射成“linux_accel/Xpress 的 BPF map 已命中”需要假设相同对象能够预装并保持热状态，所以该映射是 **H**，不是 XDP 缓存命中率的直接观测。

同一页面还显示传输协议为 UDP 75.5%、DoH 14.2%、DoT 8.6%、TCP 1.7%（O）。Xpress 只支持 plain DNS/UDP；不能把 `75.5% × 56.6% × 78.5%` 当成实测的 UDP+A+hit 比例，因为 Radar 没有在该页面公布这三个维度的联合分布。公平的 XDP 对比应明确写成“**以 UDP 为条件的实验**”，而不是宣称复现了完整 1.1.1.1 流量。

### 2.2 域名流行度与热点：能证明什么

Cloudflare 的[域名排名说明](https://developers.cloudflare.com/radar/investigate/domain-ranking-datasets/)提供全球/国家 top 100 的有序排名，以及 top 200、500、1,000 直至 1,000,000 的无序 bucket。官方[术语说明](https://developers.cloudflare.com/radar/glossary/#domain-rankings)明确将 popularity 描述为一段时间内估算的独立用户数，而不是每个域名的 DNS 请求份额。

因此，一手来源目前能支持：

- 1.1.1.1 的总体 cache hit 边缘比例为 78.5%（本次动态快照）；
- 域名存在 popularity rank/bucket；
- **不能**由 rank 推出 top-10/top-1,000 占全部 DNS 请求的精确百分比；
- **不能**由现有官方数据拟合并声称一个真实 DNS Zipf 指数；
- **不能**得出 Xpress 或 NLnet 原型自身在生产中的命中率。

所以后述 hot-set 大小、组内分布和 qtype×hit 拼接方式都必须标为 S/H。

### 2.3 竞品仓库能提供的边界

#### Xpress DNS（I）

[Xpress DNS 固定提交](https://github.com/zebaz/xpress-dns/tree/312e2a30c7838be0c5b92ab5d302a04a55f5afcd)（2026-08-13 捕获时仓库 HEAD 为 `312e2a30c7838be0c5b92ab5d302a04a55f5afcd`）说明：

- 仅支持 A record；
- 仅支持 UDP/53 的明文 DNS；
- 仅处理 single query；
- map 未匹配时放行到 Linux 网络栈；
- 仓库没有生产 trace、QTYPE 比例、域名 popularity 分布或命中率配置。

这意味着 mixed-QTYPE 测试可衡量“在真实边缘比例下的可加速覆盖率”，但对 Xpress 的机制公平性能对比必须另外运行 A-only common-denominator profile。

#### NLnet xdp-dns-cache（I）

NLnet Labs 发布的 [XDP-based DNS hot cache 报告 PDF](https://www.nlnetlabs.nl/downloads/publications/report_xdp-based-dns-hot-cache_2024-02-14.pdf)和[作者代码固定提交](https://github.com/mozzieongit/xdp-dns-cache/tree/774755c30ff9d83b20bb380575bfcd9ed08c40eb)（2026-08-13 HEAD `774755c30ff9d83b20bb380575bfcd9ed08c40eb`）明确说明：

- 最终原型没有实现 TC 学习响应并填充 cache；
- 没有实现从可由 userspace 填充的 map 返回答案；
- 只能对硬编码域名返回硬编码响应；仓库 README 将其收窄为 `nl.` 的 NS records；
- 论文实验只测试了 `.nl` delegation 的小响应；“支持 most queried domains”被列为 future work；
- 报告和代码均没有 QTYPE 分布、命中率、热域名 trace 或 popularity 参数。

报告引言中的 NXDOMAIN 描述引用了外部材料，不是该项目自己的流量测量；本报告不把它纳入造流量依据。

### 2.4 可复现 DNS 造流量规则

#### Profile A：`DNS-RADAR-NL-MARGINALS`（O + H）

建议基准规模 `N = 100,000`。先按 QTYPE 和 hit/miss 各自建立精确配额。为了生成单一请求流，可采用“QTYPE 与 cache 状态独立”的 H 假设，按最大余数法得到下表：

| QTYPE bucket | Hit | Miss | 总数 |
|---|---:|---:|---:|
| A | 44,431 | 12,169 | 56,600 |
| AAAA | 23,786 | 6,514 | 30,300 |
| HTTPS | 4,946 | 1,354 | 6,300 |
| PTR | 2,826 | 774 | 3,600 |
| NS | 549 | 151 | 700 |
| Other | 1,962 | 538 | 2,500 |
| **合计** | **78,500** | **21,500** | **100,000** |

生成细则：

1. `Other` 不是合法 QTYPE。为产生真实 DNS 报文，把 2,500 个请求按 `[MX, TXT, SRV, SOA, CNAME]` 固定轮转，各 500 个。这是 **S**，不代表 Radar 的 Other 内部分布。
2. 每个 QTYPE 的 hit 请求在 1,000 个预装名称上轮转，例如 `hit-<type>-0000.bench.test.` 至 `...-0999...`；1,000 是 **S**，不是观测到的 hot-set size。
3. miss 请求使用不在 XDP/BPF map 中、但由 userspace backend 正确回答的唯一名称 `miss-<type>-<sequence>.bench.test.`。这样 miss 衡量 pass/fallback，而不是把上游超时混入结果。
4. 先物化上表全部记录，再用 SplitMix64 生成的 Fisher–Yates shuffle 打散；固定种子为 `0x444e535241444152`。随机算法和种子均为 **S**。
5. 对任意 `N`，先计算 `N × p`，取 floor，再按小数余数从大到小补齐；并固定 tie order 为 `A, AAAA, HTTPS, PTR, NS, Other`。报告必须同时保存实际整数计数。
6. 分别报告 supported hit、supported miss、unsupported pass 和总流量结果。不要只给一个总加速比，因为 mixed profile 会把协议覆盖率与单次 fast-path 成本混在一起。

#### Profile B：`DNS-XPRESS-A-COMMON`（H）

这是 Xpress 与 linux_accel 的公平机制对比：

- `N = 100,000`；全部为 IPv4/UDP、single-question、`QCLASS=IN`、`QTYPE=A`；
- 78,500 个请求指向 1,000 个预装 A record，21,500 个请求指向 map 未预装但 userspace 可回答的 A record；
- 名称与打散规则沿用 Profile A；
- 78.5/21.5 来自 Radar 的全体 DNS cache 边缘比例，将其条件化到 A-only 是 **H**，不是 Radar 实测的 A 请求命中率。

应另跑 `100% hit` 和 `100% miss` 两个控制组，以便把 lookup/TX 能力与 78.5/21.5 混合结果分离。

#### Profile C：`DNS-NLNET-NS-SMOKE`（I + S）

- 全部请求为 `nl. NS IN`，报文形态与报告原型支持范围一致；
- 这只能作为 hard-coded response path 的 smoke/microbenchmark；
- 不赋予“真实占比”或“真实命中率”，也不计入 mixed-realistic 总分；
- 若改写原型以支持 map/learning，改写后的结果要与原论文原型分栏，不能仍标为原始 NLnet baseline。

## 3. Memcached：BMC 与 Facebook-like workload

### 3.1 BMC 论文真正运行的工作负载（W）

[BMC: Accelerating Memcached using Safe In-kernel Caching and Pre-stack Processing](https://www.usenix.org/conference/nsdi21/presentation/ghigoff)发表于 NSDI 2021；[官方论文 PDF](https://www.usenix.org/system/files/nsdi21-ghigoff.pdf)给出的主评测配置是：

| 参数 | BMC 论文配置 | 证据性质 |
|---|---:|---|
| Key popularity | finite Zipf，skewness/exponent `0.99` | W；论文说明与 YCSB 所用值相同，不是 Facebook trace 拟合值 |
| Key population | 100,000,000 distinct keys | W |
| Key size | 16 B | W |
| Value size | 32 B | W |
| Memcached cache | 10 GB | W |
| BMC cache | 2.5 GB | W |
| BMC : Memcached cache size | 25% | W |
| Memcached application threads | 8 | W |
| RX cores | 8 | W |
| Offered load | 12,000,000 req/s，open loop | W |
| Simulated clients | 340 | W |
| Prefill | 对 100M 中每个 key 发送一个 SET；不计入测量阶段 | W |
| BMC 初始状态 | prefill 不填充 BMC；BMC 仅从 GET response 学习 | W |

BMC 的 fast path 处理 UDP GET，SET 走 TCP、使 BMC entry 失效后交给 Memcached。论文没有把主吞吐实验的 timed target phase 写成一个数值化 GET/SET 混合；因此，**不要把生产观测中的 30:1 自动写成 BMC 主实验的 timed mix**。最忠实的主 profile 是 prefill SET 之后发送 UDP GET，并观察 BMC 冷启动学习到稳态的过程。

论文另有两个明确的合成变化：

- worst case 把 32 B value 全部改为 8 KiB，使其超过 BMC 可缓存范围；
- size sensitivity 将 32 B target request 的比例按图中 `{0%, 25%, 50%, 75%, 100%}` 扫描，其余请求使用 8 KiB value。

这些都是 W，不是生产 value-size 比例。

[BMC 官方仓库固定提交](https://github.com/Orange-OpenSource/bmc-cache/tree/2997145508e02c55aa92f63a0009ac2a26800810)（2026-08-13 HEAD `2997145508e02c55aa92f63a0009ac2a26800810`）包含实现而没有论文所用的 traffic generator、trace、Zipf 脚本或随机种子。该提交的实现常量包括 key 上限 250 B、value 上限 1,000 B、multi-get 上限 30，以及 `BMC_CACHE_ENTRY_COUNT=3,250,000`。这些是 I；其中 entry count 与论文配置声称可容纳约 6.3M items 不同，实际复现实验必须记录所运行版本的 map capacity。

### 3.2 Facebook 生产观测：操作比例、命中率和热点

#### 2012 大规模 trace（O）

作者提供的 [Workload Analysis of a Large-Scale Key-Value Store PDF](http://frachtenberg.org/eitan/pubs/papers/atikoglu12%3Aworkload.pdf)（[ACM DOI](https://doi.org/10.1145/2254756.2254766)）分析了 Facebook 五个 Memcached pool 的超过 284 billion 请求、合计 58 sample days。论文未公开实际日历采集日期；Figure 1 的 request-type 分布覆盖 exactly 7 days。

最适合作为通用 Facebook-like cache 的 ETC pool 给出：

| 指标 | 一手观测 | 注意事项 |
|---|---:|---|
| GET : UPDATE | 约 `30 : 1` | UPDATE 聚合 SET、REPLACE 等所有非 DELETE 写操作，不是纯 SET |
| 仅在 GET+UPDATE 中归一化的 GET | `30/31 = 96.774193548…%` | 从“约 30:1”推导，生成器可精确实现，观测本身仍是约数 |
| 仅在 GET+UPDATE 中归一化的 UPDATE | `1/31 = 3.225806452…%` | 同上 |
| ETC mean GET hit rate | 81.4% | 整段 trace 的平均值 |
| APP / VAR / SYS / USR hit rate | 92.9% / 93.7% / 98.7% / 98.2% | 不应与 ETC 任意混合 |
| ETC key locality | 约 50% 的 distinct keys 只产生 1% 请求；另约 50% 产生 99% 请求 | 粗粒度热点观测，不提供热点半区内部的 rank CDF |
| ETC last-24h miss 原因 | compulsory 70%、invalidation 8%、eviction 22% | 仅为最后 24 h、且分母是 miss，不是全部请求 |

论文明确把“key reuse 的完整生成模型”列为未来工作；它没有为 Facebook key popularity 拟合 Zipf exponent。因此：

- `Zipf(0.99)` 是 BMC/YCSB 风格的 **W**，不是 Facebook ETC 的 **O**；
- 可以引用“50% keys → 1% requests”作为粗热点约束；
- 不能声称真实 Facebook key rank 完整服从 Zipf 0.99。

#### Facebook NSDI 2013 的独立生产快照（O）

Facebook 作者的 [Scaling Memcache at Facebook](https://www.usenix.org/conference/nsdi13/technical-sessions/presentation/nishtala)（[官方 PDF](https://www.usenix.org/system/files/conference/nsdi13/nsdi13-final170_update.pdf)）给出按 7 天平均的每服务器请求率。论文还说明其每 4 分钟采集平均统计，并在一个月采集期中报告最高平均值；实际日历日期未公开。下表的 GET/SET 百分比仅在 GET+SET 两类中归一化；DELETE 没有被吞掉，而是单独列出，避免把 regional pool 的大量 DELETE 误写成读流量。

| Pool | GET (k/s) | SET (k/s) | DELETE (k/s) | GET/(GET+SET) | SET/(GET+SET) | Miss rate |
|---|---:|---:|---:|---:|---:|---:|
| wildcard | 262 | 8.26 | 21.2 | 96.943684% | 3.056316% | 1.76% |
| app | 96.5 | 11.9 | 6.28 | 89.022140% | 10.977860% | 7.85% |
| replicated | 710 | 1.75 | 3.22 | 99.754127% | 0.245873% | 0.053% |
| regional | 9.1 | 0.79 | 35.9 | 92.012133% | 7.987867% | 6.35% |

归一化百分比是由论文中已舍入的 k/s 数值计算的推导值，不是额外精度的原始观测。该论文还指出单个 key 在某些服务器上可占请求的 20%，但这是热点极端实例，不是可普遍套用的 key-rank 分布。

同一论文的 Table 3 给出 item/value size 分位数（bytes）：

| Pool | Mean | Std dev | p5 | p25 | p50 | p75 | p95 | p99 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| wildcard | 1.11 KiB | 8.28 KiB | 77 | 102 | 169 | 363 | 3.65 KiB | 18.3 KiB |
| app | 881 | 7.70 KiB | 103 | 247 | 269 | 337 | 1.68 KiB | 10.4 KiB |
| replicated | 66 | 2 | 62 | 68 | 68 | 68 | 68 | 68 |
| regional | 31.8 KiB | 75.4 KiB | 231 | 824 | 5.31 KiB | 24.0 KiB | 158 KiB | 381 KiB |

这些分位点不足以唯一确定一个 CDF；若在分位点间做线性插值或分段常量采样，那一部分必须标 S。最稳妥的用法是做固定 size-point sweep，或者采用下节 ETC 作者给出的完整拟合模型。

### 3.3 Key/value size 的一手依据

#### BMC 固定小对象（W）

BMC 主 workload 的 16 B key、32 B value 是精确的论文评测参数。BMC 还援引 Facebook workload analysis 说明“约 95% 的观测 value 小于 1,000 B”，并据此选择 1,000 B 的实现上限；`95%` 是约数/阈值 CDF，不足以重建完整 size distribution。

#### ETC 的作者拟合模型（O-model）

2012 trace 论文为 ETC 提供了可生成的统计模型：

- key length：Generalized Extreme Value，`μ=30.7984, σ=8.20449, k=0.078688`；
- value length `>=15 B`：Generalized Pareto，`θ=0, σ=214.476, k=0.348238`；
- value length `0..14 B` 使用下列离散的无条件概率，其总质量为 `0.44155`，GPD tail 的剩余质量为 `0.55845`。

| Value B | P | Value B | P | Value B | P |
|---:|---:|---:|---:|---:|---:|
| 0 | 0.00536 | 5 | 0.02740 | 10 | 0.00837 |
| 1 | 0.00047 | 6 | 0.00065 | 11 | 0.08989 |
| 2 | 0.17820 | 7 | 0.00606 | 12 | 0.00092 |
| 3 | 0.09239 | 8 | 0.00023 | 13 | 0.00326 |
| 4 | 0.00018 | 9 | 0.00837 | 14 | 0.01980 |

这是对观测数据的拟合，不是逐条原始 trace；论文也提醒少量 outlier 需要另行建模，而公开文本没有给出一个完整可下载 trace。因此基于公式生成的请求应写成“author-fitted synthetic workload”，不能写成 trace replay。

### 3.4 可复现 Memcached 造流量规则

#### Profile D：`BMC-PAPER-TARGET`（W，推荐主 baseline）

1. 定义 rank support `r ∈ [1, 100,000,000]`，概率
   `P(r) = r^-0.99 / Σ(i=1..100,000,000) i^-0.99`。
2. key 编码为 `k` 加 15 位十进制 rank，例如 `k000000000000001`，恰好 16 B。
3. value payload 恰好 32 B；内容可取 rank 的固定编码后补零，不能把 Memcached 文本协议头算进 32 B。
4. 测量前对全部 100M key 各发一个 SET 到 Memcached；不把 prefill 计入吞吐/延迟。按 BMC 设计，BMC map 在此后仍为空。
5. timed phase 使用 UDP GET；key 按上述 finite Zipf 取样。固定 SplitMix64 种子 `0x424d432d4e534449`，把 `u=(next_u64+0.5)/2^64` 映射为满足累计概率首次达到 `u` 的最小 rank。
6. 论文原速率为 12M req/s open loop、340 clients、8 application threads、8 RX cores。若测试机达不到该 offered load，可以做阶梯 sweep，但必须把它标为 scale-down，不能称为数字级论文复现。
7. 单独运行 8,192 B value 的 100% worst-case，以及 target share `{0,25,50,75,100}%` 的 sensitivity；`N` 取 4 的倍数以得到精确配额。
8. 同时报告 cold-learning 段和 steady-state 段。steady-state 切点由本实验定义，属于 S；不能只丢弃冷启动又声称完全复现论文过程。

论文和仓库没有公开原 workload generator/seed，因此第 2、3、5 项的编码和随机序列是为跨实现可复现而新增的 **S**；概率分布及系统配置仍保持 W。

#### Profile E：`FB-ETC-MARGINALS`（O + H，用于路径覆盖，不替代 Profile D）

为精确实现论文给出的边缘比例，可取 `N=3,100,000` operations：

- 3,000,000 GET、100,000 UPDATE；为与 BMC 支持的命令对齐，把 UPDATE 全部编码成 SET。这个收窄是 S，因为原 trace 的 UPDATE 还包含 REPLACE 等写操作；
- GET 中强制 2,442,000 hit、558,000 miss，恰好为 81.4/18.6；
- 先创建精确配额，再用 SplitMix64 + Fisher–Yates 打散，固定种子 `0x4642455443323031`；
- hit key 从预装 hot set 中选择，miss key 在发出时不存在；hot-set 的绝对大小必须在结果中记录，它不是来源给出的观测参数；
- key/value length 按下述 author-fitted 规则生成。

GEV key length 的可复现离散化：对 `u∈(0,1)` 计算

```text
x = μ + (σ/k) * ((-ln(u))^(-k) - 1)
key_len = round(x)
```

若 `key_len` 不在 Memcached 协议允许的 `[1,250]`，重新取样；这是协议适配 S，不能说与原拟合无差别。key 本体使用 rank 十进制串并按指定长度补 ASCII `0`。

Value length 的可复现生成：

1. 先按上表的累计概率选择 `0..14 B`；
2. 余下 `0.55845` 概率进入 GPD tail，重新取 `v∈(0,1)`，计算
   `y=(214.476/0.348238)*((1-v)^(-0.348238)-1)`；
3. 令 `value_len=15+floor(y)`；不要把大于 1,000 B 的对象截断，应该让 BMC 按实现边界 pass/fallback，否则会人为提高可缓存比例。

该 profile 强制边缘 hit 比例，不评估 cache policy 自然形成的命中率。若目标是测热点/容量作用，应另跑下面的 coarse-locality profile。

#### Profile F：`FB-ETC-COARSE-LOCALITY`（O + S）

用 `3,000,000 GET` 和 `60,000 distinct keys` 构造一个可检查的缩放实例：

- cold half：30,000 keys，每个恰好出现一次，共 30,000 请求，即 1%；
- hot half：30,000 keys，共承载 2,970,000 请求，即 99%；
- hot half 内部没有观测 CDF。可以按 uniform 运行一个控制组，并按 Zipf(0.99) 运行一个 BMC-style 组，但两者都标 S；
- 不强制 81.4% hit，让实际 cache size、预热和失效策略产生 emergent hit rate并单独报告。

这只复现“50% keys → 1% requests”的粗约束；60,000 的 distinct-key 规模和 hot-half 内部分布不是 Facebook 观测。

## 4. TURN：没有可写成真实比例的可靠一手数据

[Supercharge WebRTC: Accelerate TURN Services with eBPF/XDP](https://doi.org/10.1145/3609021.3609296)是 ACM SIGCOMM 2023 eBPF Workshop 论文；会议[官方程序](https://conferences.sigcomm.org/sigcomm/2023/workshop-ebpf.html)、[作者出版列表](https://levaitamas.github.io/)和[官方演示 PDF](https://conferences.sigcomm.org/sigcomm/2023/files/workshop-ebpf/5-TURN.pdf)均已核验。演示材料只给出定性描述：TURN traffic 的 “bulk” 是 ChannelData，并称典型负载为 small UDP packets。它没有公布：

- ChannelData 与 Send Indication 的百分比；
- allocation/channel-control 与 relay-data 的包数比例；
- packet-size CDF、session-duration CDF 或并发会话分布；
- 生产 trace 的样本量、服务人口和采集时间。

论文评测拓扑使用 iperf clients、turncat proxy、TURN server 和 iperf server。这是 W/S 的端到端吞吐实验，不是生产流量分布。

[论文 artifact 分支固定提交](https://github.com/l7mp/turn/tree/3c4f115ceff634720d63f0551172bd0710447569)（`server-ebpf-offload`，2026-08-13 捕获 commit `3c4f115ceff634720d63f0551172bd0710447569`）包含 XDP offload、示例和测试，但没有论文生产 trace、比例文件或流量分布生成器。L7mp 的[官方 STUNner eBPF 文档](https://docs.l7mp.io/en/stable/PREMIUM_REFERENCE/)说明 offload 针对 UDP TURN channels，而 Send Indication、TURN/TCP 等路径不在同一 offload 范围；这是 I，不是占比。

**结论：本轮没有找到可接受的一手数值比例，TURN 不应进入“按真实比例加权”的综合 benchmark。** 如果后续只复现论文 iperf/turncat 拓扑，应标成 paper-style synthetic benchmark；在获得运营方匿名化 trace 或论文作者的数值分布前，不设置诸如 80/20、90/10 的伪“真实”比例。

## 5. 实际测试矩阵建议

| 顺序 | 测试 | 请求组成 | 报告目的 |
|---:|---|---|---|
| 1 | DNS capability-weighted | `DNS-RADAR-NL-MARGINALS` 的 100k 精确配额 | 展示面对观测 QTYPE 边缘比例时，总体覆盖率与总体收益 |
| 2 | DNS common denominator | `DNS-XPRESS-A-COMMON`，另加 100% hit / 100% miss | 公平比较 Xpress 与 linux_accel 的 A fast-path lookup/TX 和 miss/pass 成本 |
| 3 | NLnet mechanism smoke | 100% `nl. NS IN` | 只验证原型机制，不进入真实比例综合结论 |
| 4 | BMC paper replication | `BMC-PAPER-TARGET` + 8 KiB worst-case + target-share sweep | 与 BMC 论文方法最接近的 KV baseline |
| 5 | Facebook-like robustness | `FB-ETC-MARGINALS` 和 `FB-ETC-COARSE-LOCALITY` 分开运行 | 分别检验边缘 path mix 与 cache 热点/容量，不伪造联合 trace |
| 6 | TURN | 暂不运行真实比例 profile | 等待可靠一手数值；需要时只运行明确标注的 paper-style synthetic test |

每轮至少保存：profile 名、整数配额、seed、preload/warm-up 边界、offered/achieved QPS、key/value 实际直方图、QTYPE 实际计数、fast-hit/pass/backend/error 计数、丢包和 p50/p95/p99。这样即使生成器实现变化，也能检查实际发出的流量是否满足本文规则。

## 6. 一手来源与捕获清单

| 对象 | 一手来源 | 类型 | 本次捕获日期 | 可用于什么 |
|---|---|---|---|---|
| DNS QTYPE/cache/transport | [Cloudflare Radar — DNS queries to 1.1.1.1 from the Netherlands](https://radar.cloudflare.com/dns/nl) | 官方动态仪表盘，O | 2026-08-13；窗口显示 Last 7 days | QTYPE、cache、transport 的独立边缘比例 |
| DNS API 语义 | [Cloudflare Radar DNS summary API](https://developers.cloudflare.com/api/resources/radar/subresources/dns/methods/summary_v2/) | 官方 API 文档 | 2026-08-13 | 维度、过滤器、百分比 normalization 与 date-range 元数据能力 |
| 域名 popularity | [Cloudflare domain ranking datasets](https://developers.cloudflare.com/radar/investigate/domain-ranking-datasets/)、[Radar glossary](https://developers.cloudflare.com/radar/glossary/#domain-rankings) | 官方文档，O 的 rank/bucket | 2026-08-13 | 只能作为 rank/bucket，不提供 query-share/Zipf |
| Xpress DNS | [zebaz/xpress-dns @ `312e2a3`](https://github.com/zebaz/xpress-dns/tree/312e2a30c7838be0c5b92ab5d302a04a55f5afcd) | 作者代码，I | 2026-08-13 | A/UDP/single-query 支持范围与 miss/pass 行为 |
| NLnet hot cache | [NLnet Labs report PDF](https://www.nlnetlabs.nl/downloads/publications/report_xdp-based-dns-hot-cache_2024-02-14.pdf)、[代码 @ `774755c`](https://github.com/mozzieongit/xdp-dns-cache/tree/774755c30ff9d83b20bb380575bfcd9ed08c40eb) | 正式项目报告 + 作者代码，I/W | 2026-08-13 | `nl. NS` 硬编码原型边界；无真实流量比例 |
| BMC | [USENIX NSDI 2021 页面](https://www.usenix.org/conference/nsdi21/presentation/ghigoff)、[论文 PDF](https://www.usenix.org/system/files/nsdi21-ghigoff.pdf)、[官方代码 @ `2997145`](https://github.com/Orange-OpenSource/bmc-cache/tree/2997145508e02c55aa92f63a0009ac2a26800810) | 同行评审论文 + 官方代码，W/I | 2026-08-13 | BMC workload、系统配置、实现边界 |
| Facebook workload trace | [Atikoglu et al. author PDF](http://frachtenberg.org/eitan/pubs/papers/atikoglu12%3Aworkload.pdf)、[ACM DOI](https://doi.org/10.1145/2254756.2254766) | 同行评审论文，O + fitted model | 2026-08-13；原采集日历日期未披露 | ETC 30:1、hit、locality、key/value 模型 |
| Facebook Memcache production | [USENIX NSDI 2013 页面](https://www.usenix.org/conference/nsdi13/technical-sessions/presentation/nishtala)、[官方 PDF](https://www.usenix.org/system/files/conference/nsdi13/nsdi13-final170_update.pdf) | 同行评审论文，O | 2026-08-13；论文表格为 7-day average，日历日期未披露 | 多 pool 操作率、miss rate、size percentiles/热点实例 |
| TURN | [ACM DOI](https://doi.org/10.1145/3609021.3609296)、[SIGCOMM workshop program](https://conferences.sigcomm.org/sigcomm/2023/workshop-ebpf.html)、[官方演示 PDF](https://conferences.sigcomm.org/sigcomm/2023/files/workshop-ebpf/5-TURN.pdf)、[作者主页](https://levaitamas.github.io/)、[artifact @ `3c4f115`](https://github.com/l7mp/turn/tree/3c4f115ceff634720d63f0551172bd0710447569) | 同行评审 workshop paper/演示 + 作者代码，W/I | 2026-08-13 | 机制与 paper-style 拓扑；没有可用生产比例 |

## 7. 最终可引用表述

答辩或实验报告中可以严谨地写：

> DNS mixed profile 的 QTYPE 和 resolver cache-hit 边缘比例取自 2026-08-13 捕获的 Cloudflare Radar 荷兰 1.1.1.1 最近 7 天仪表盘；由于官方页面未给出 QTYPE×cache 的联合分布，测试流量按独立假设合成并明确标为 hybrid。Xpress 的公平机制对比另用 A-only profile。BMC 主 baseline 严格采用论文的 100M keys、16 B key、32 B value 和 Zipf 0.99 工作负载；Facebook ETC 的约 30:1 GET:UPDATE、81.4% hit 与粗粒度热点数据作为独立生产观测 profile，不把 Zipf 0.99 称为 Facebook 实测。现有 TURN 一手论文、演示和代码没有公开数值化生产流量比例，因此不为 TURN 构造伪真实占比。
