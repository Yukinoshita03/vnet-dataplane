# linux_accel 协议感知 eBPF/XDP 相关工作与基线

更新时间：2026-08-13

## 1. 范围、方法与证据等级

本文研究整个 `linux_accel`，而不只研究 DNS。项目当前包含七类路径：DNS/XDP
缓存、通用 UDP 确定性 request-response 快路径、TCP/LDAP/LDAPS sockmap 透明代理、
ARP proxy 与 DHCP relay、gRPC/微服务路径、Kubernetes CNI/Pod 生命周期集成，以及
OpenStack/OVS/TAP 数据面集成。

本文只采用以下一手来源：会议或出版社页面、论文作者/研究机构提供的论文、正式
技术报告、会议官方论文/演讲材料，以及作者或项目组织的官方代码仓库。证据等级为：

- **P：同行评审论文**——可用于学术 related work 和机制/结果对照；
- **R：正式技术报告**——可用于设计与可行性对照，但不能冒充同行评审论文；
- **T：会议技术论文或演讲**——可用于数据面工程对照，引用时须注明其性质；
- **G：普通官方 GitHub 工程项目**——适合复现实验 baseline，不代表论文结论。

“直接竞品”指同样在早期数据路径解析业务请求，命中后直接回复、未命中后放行或
回退；“同构思想”指同样把频繁、可验证的协议操作移入 eBPF，但协议或 hook 不同；
“基础设施邻近工作”指优化 CNI、overlay、OVS 或 socket 路径，不缓存业务响应。

## 2. 总体结论

1. **DNS 最接近的论文级工作是 hyDNS，最接近的正式报告是 NLnet Labs 的
   XDP-based DNS hot cache；最容易同机复现的工程 baseline 是 Xpress DNS。**
2. **通用 UDP 的最强同构证据是 BMC 与 Supercharge WebRTC TURN。** 前者证明
   “请求命中后 XDP 直接回复、否则回用户态”的通用价值，后者证明协议状态建立后
   可以把高频 UDP relay 数据面下沉到 XDP；二者都不能直接替代本项目的任意
   request-bytes → response-bytes 映射。
3. **LDAP 没有检索到同类的协议语义加速论文。** 本项目对 LDAP/LDAPS 采用
   sockmap 透明字节流转发而不伪造响应是合理边界；service-mesh network shortcut
   是最接近的转发机制论文，MiddleCache 和 IBM socket replacement 则是邻近路线。
4. **Kubernetes 与 OpenStack 的直接对照不应使用 DNS 论文。** K8s/CNI 应比较
   ONCache、IBM socket replacement 和标准 overlay；OpenStack/OVS/TAP 应比较
   OVS kernel datapath、AF_XDP/DPDK 与 Faster OVS Datapath with XDP。
5. **项目的可辩护创新点不是“第一个 XDP cache”，而是统一控制面下的多协议、
   fail-open、生命周期感知加速，并在既有 CNI/OVS/VM 路径上增量部署。** 学术报告
   必须按协议分别选 baseline，不能用一个 nohook 数字概括所有路径。

### 2.1 最新筛选：真正值得放进对比矩阵的候选

补充筛选后，最接近本项目的方案可以按“是否能在相同语义和相同挂载层运行”分为
三档。这里的“能比较”不等于一定要把所有项目拉下来；只有同一档、同一协议和同一
流量语义的结果才适合计算加速比。

| 候选 | 重合点 | 不同点 | 建议用途 |
| --- | --- | --- | --- |
| [Xpress DNS](https://github.com/zebaz/xpress-dns) | XDP 解析 DNS、BPF map 命中、直接构造响应、miss 放行 | 只支持静态 A/IN、明文 UDP/53、单查询 | **DNS 同机直接 baseline**；当前 BMC 之外最适合跑的竞品 |
| [hyDNS](https://jianchang.su/uploads/hyDNS_eBPF_Workshop.pdf) | XDP 内核 DNS cache + userspace resolver，支持 miss 回退和 pending 状态 | 论文原型依赖 SmartNIC/per-core 设计，未核验到官方可复现实验仓库 | **DNS 论文级机制对照**；引用论文结果，不把异机数字算成同机加速比 |
| [NLnet Labs XDP hot-cache](https://nlnetlabs.nl/downloads/publications/report_xdp-based-dns-hot-cache_2024-02-14.pdf) | DNS 响应学习、BPF map、XDP 直接回包、TTL/扩包限制 | 学生研究原型，代码标注 unmaintained，覆盖面和运维控制面较窄 | **DNS 设计/限制对照**；可单独验证，但不宜作为主论文级竞品 |
| [NSD AF_XDP](https://nsd.docs.nlnetlabs.nl/en/latest/xdp.html) | 同样在 XDP 入口截获 DNS，减少内核网络栈开销 | 是 UDP/53 的 AF_XDP 用户态 fast path，不是在 XDP 中生成缓存响应；官方文档标为 experimental | **DNS I/O 基线**：隔离“绕过网络栈”与“内核内直接命中回包”的收益 |
| [BMC](https://www.usenix.org/conference/nsdi21/presentation/ghigoff) | XDP pre-stack 解析业务请求、命中直接响应、miss 回 Memcached、TC egress 更新 | 只做 Memcached，缓存一致性和 response 格式是专用逻辑 | **Memcached/通用 request-response 主竞品**；当前最公平的论文级可运行对手 |
| [Katran](https://github.com/facebookincubator/katran) | native/generic XDP、BPF map 状态、早期 L2-L4 处理 | 是 L4 DSR/LB，不做应用响应缓存或协议内容学习 | **L4/VM 转发对照**；比较 PPS、p99、CPU 和丢包，不与 DNS hit QPS 混算 |
| [Cilium kube-proxy replacement](https://docs.cilium.io/en/latest/network/kubernetes/kubeproxy-free/) | socket/tc/XDP 多 hook、Service backend map、工作负载生命周期 | 是完整 K8s CNI/Service LB，BPF owner 和控制面远大于本项目 | **K8s 数据面/生命周期上界**；当前 K8s 保持关闭，只做架构对照，后续隔离环境再跑 |
| [ONCache](https://www.usenix.org/conference/nsdi25/presentation/lin-shengkai) | 既有 overlay 上的增量 cache、fast path、miss 回原路径、容器网络场景 | 缓存 overlay 处理结果，不缓存 DNS/UDP 业务响应；集成 Antrea | **CNI/overlay 生命周期主学术对照**；测 Pod 变化、TCP/UDP RR、miss 和恢复 |
| [Faster OVS Datapath with XDP](https://netdevconf.info/0x14/pub/papers/41/0x14-paper41-talk-paper.pdf) | OVS flow hit 在 XDP，miss/upcall 回原 OVS slow path | 缓存的是 flow/action，不解析业务协议；属于技术论文/原型路线 | **OpenStack VM/TAP 数据面机制对照**；比较 PVP/PVVP、PPS、loss、CPU |
| [StackMap](https://www.usenix.org/conference/atc16/technical-sessions/presentation/yasukata) | 面向小消息事务和 Memcached，减少 socket/内核 I/O 开销 | 修改 Linux/netmap 和应用，不是 XDP/eBPF 增量 attach，部署模型不同 | **kernel-bypass/改栈替代路线**；可作为 Memcached 参考，不列为 XDP 直接竞品 |

因此目前没有发现一个同时覆盖“DNS/ARP/UDP/LDAP/gRPC + XDP/tc/sockmap + OpenStack
TAP + CNI 生命周期”的一站式公开方案。最接近的关系是：Xpress/hyDNS/NLnet
覆盖 DNS，BMC 覆盖业务响应缓存，Katran/Cilium/OVS-XDP 覆盖转发，ONCache 覆盖
overlay 生命周期；`linux_accel` 的组合面正好跨越这些边界，但每条能力都必须按
各自的语义单独证明，不能把跨协议结果合并成一个“总加速比”。

本项目后续最值得实际跑的新增候选排序为：

1. **NSD AF_XDP**：DNS 用户态绕栈基线，和现有 `nohook/Xpress/linux_accel` 形成
   清晰四组；不需要打开 Kubernetes。
2. **Katran 或等价的纯 L4 XDP 转发器**：只在隔离 netns/veth 或 OpenStack TAP
   做 forwarding benchmark，避免与现有协议 cache 结果混淆。
3. **StackMap/OVS-DPDK/AF_XDP**：作为“改 I/O 模型”的替代路线，资源和环境允许
   时再做；不宜与协议命中路径并列宣传。
4. **ONCache/Cilium**：留到独立 Kubernetes 环境；当前集群明确保持关闭，不能
   为了跑竞品改变现场状态。

## 3. 核心工作比较矩阵

| 工作 | 类型、场所、年份 | 核心机制 | 与 linux_accel 的关系 | 官方代码 | baseline 价值 |
| --- | --- | --- | --- | --- | --- |
| [hyDNS](https://doi.org/10.1145/3672197.3673439)（[作者 PDF](https://jianchang.su/uploads/hyDNS_eBPF_Workshop.pdf)） | P；ACM SIGCOMM eBPF Workshop，2024 | XDP 内核 DNS cache；命中在内核解析，miss/不支持流量交给 userspace resolver；提出 per-core map 与 NIC steering | **DNS 直接竞品**；混合 kernel/userspace 架构最接近。论文实验为 A 记录、100% hit，并非本项目的 Radar 混合 QTYPE、客户端学习或 OpenStack TAP | 本次核验未发现论文官方代码链接，**不得声称已开源** | 学术主 baseline；若无代码，用论文指标作机制对照，不能冒充同机结果 |
| [XDP-based DNS hot cache](https://nlnetlabs.nl/downloads/publications/report_xdp-based-dns-hot-cache_2024-02-14.pdf)（[NLnet Labs 项目页](https://nlnetlabs.nl/research/student-projects/)） | R；University of Amsterdam/NLnet Labs，2024 | 探索 XDP 扩包、BPF map、从 userspace DNS 响应学习并直接回包；系统记录 driver/verifier 限制 | **DNS 直接同构报告**；与本项目学习、TTL 和 `bpf_xdp_adjust_tail` 问题高度一致，但它是学生研究报告 | [报告对应原型](https://github.com/mozzieongit/xdp-dns-cache)，仓库已标注 unmaintained | 可运行的设计、限制与正确性 baseline；不作为论文级性能竞品 |
| [Xpress DNS](https://github.com/zebaz/xpress-dns) | G；普通开源项目，2021 | XDP 解析 UDP DNS A/IN；BPF map 命中直接回包，miss `XDP_PASS`；userspace 管理静态记录 | **DNS 最直接工程竞品**；能力窄于本项目的 A/AAAA/HTTPS、学习与生命周期控制 | 有，GPL-2.0；旧 libbpf/内核上可能需要兼容补丁 | 最适合同机、同流量、同 hook 的可运行 baseline；报告必须标注 patched 版本及 commit |
| [BMC](https://www.usenix.org/conference/nsdi21/presentation/ghigoff) | P；USENIX NSDI，2021 | XDP pre-stack Memcached UDP GET cache；hit 直接回复，miss 到 Memcached；TC egress 观察更新以维持一致性 | **通用 UDP 与 DNS 的最强同构思想**；请求/响应映射和 hit/miss 结构近似，但 BMC 解析 Memcached 并处理一致性 | [官方仓库](https://github.com/Orange-OpenSource/bmc-cache) | 可运行的学术 baseline；适合增加 Memcached 协议实验，不可直接拿其论文 18× 与本项目 DNS 数字横比 |
| [MiddleCache](https://doi.org/10.1109/ICPADS60453.2023.00324) | P；IEEE ICPADS，2023，pp. 2428–2435 | 面向 TCP 内存 KV 的 eBPF 中间缓存，扩展 UDP-only pre-stack cache 思路到 TCP 数据路径 | **TCP/LDAP 的结构同构工作**；说明 TCP 业务可在内核缓存，但 LDAP 有认证、message ID、目录状态，不能据此安全缓存 | 本次一手来源核验未确认官方代码仓库，**不得声称有代码** | 论文 related-work baseline；不宜作为当前 LDAP sockmap 的直接可运行对手 |
| [Network shortcut in data plane of service mesh with eBPF](https://doi.org/10.1016/j.jnca.2023.103805) | P；Journal of Network and Computer Applications 222，2024 | 在 Istio 数据面使用 eBPF socket redirection 与 tc redirection 缩短代理通信路径；保留原 service-mesh 语义 | **TCP/LDAP sockmap 与微服务路径最接近的论文之一**；同样优化透明转发路径，但不是 LDAP 语义缓存，也不直接生成目录响应 | 本次未核实官方 artifact | LDAP/sockmap 的首选机制对照；同机性能仍应以 direct/userspace/splice/sockmap 四组为准 |
| [Supercharge WebRTC: Accelerate TURN Services with eBPF/XDP](https://doi.org/10.1145/3609021.3609296)（[作者出版列表](https://levaitamas.github.io/)） | P；ACM SIGCOMM eBPF Workshop，2023，pp. 70–76 | 把 TURN 中高频 UDP forwarding/relay 操作卸载到 eBPF/XDP，控制面保留复杂会话管理 | **通用 UDP 同构思想**；同为“控制面建状态、数据面 fast path、异常回退”，但它做 relay/forward，不是直接生成固定响应 | 本次核验未确认与 2023 论文对应的官方 artifact 仓库 | UDP relay 论文 baseline；建议按 TURN 原语另做 forwarding 实验，不能与 exact-hit 回包混为一列 |
| [Electrode](https://www.usenix.org/conference/nsdi23/presentation/zhou) | P；USENIX NSDI，2023 | 在 XDP/eBPF 中执行 Multi-Paxos 的广播、快速 ACK 和 quorum 汇聚，正确性核心留在 userspace | **gRPC/分布式协议同构思想**；证明应下沉机械性频繁操作，而不是把完整 gRPC/HTTP2 状态机塞入 XDP | [官方 artifact](https://github.com/Electrode-NSDI23/Electrode) | gRPC 快路径的首选学术思想 baseline；可复现固定 UDP 协议，但不是 gRPC wire-compatible baseline |
| [DINT](https://www.usenix.org/conference/nsdi24/presentation/zhou-yang) | P；USENIX NSDI，2024 | eBPF 下沉锁、KV、日志等分布式事务频繁路径，保留 kernel-stack 的隔离和可运维性 | **微服务/分布式操作同构思想**；比本项目的固定响应更深、更状态化，但目标不是 gRPC 缓存 | [官方 artifact](https://github.com/DINT-NSDI24/DINT) | 高价值研究上界与方法 baseline；部署复杂，不适合答辩现场的主可运行 baseline |
| [SPRIGHT](https://conferences.sigcomm.org/sigcomm/2022/program.html) | P；ACM SIGCOMM，2022 | 使用 eBPF socket-message 与共享内存构建事件驱动 serverless function chain，减少重复协议处理与序列化 | **gRPC/微服务基础设施邻近工作**；同样削减 sidecar/function-chain 开销，但不做 XDP 内容命中回包 | 本次核验未确认官方 artifact 链接，故不声称代码可用 | 与 Knative/sidecar 对照的论文 baseline；不应替代 DNS/UDP baseline |
| [ONCache](https://www.usenix.org/conference/nsdi25/presentation/lin-shengkai) | P；USENIX NSDI，2025 | 缓存 overlay 中 conntrack、过滤、路由和外层封装等重复结果；hit 绕过标准慢路径，失效时无缝回退；集成为 Antrea plugin | **K8s/CNI 最接近的系统工作**；同样增量附着既有 overlay 和 fail-safe，但缓存网络路径结果而非协议响应 | [作者公开实现](https://github.com/shengkai16/ONCache) | Kubernetes 数据面主学术 baseline；比较 Pod 生命周期、miss、功能兼容和 TCP/UDP RR，而非 DNS 命中率 |
| [Bypass Container Overlay Networks with Transparent BPF-driven Socket Replacement](https://research.ibm.com/publications/bypass-container-overlay-networks-with-transparent-bpf-driven-socket-replacement) | P；IEEE CLOUD 2022（IBM 页面标注初稿日期 2021） | 安全 node control agent 利用 BPF tracing 透明替换容器 socket，使其绕过 overlay，应用和 Pod manifest 无需修改 | **K8s 生命周期与 TCP/LDAP 邻近工作**；控制代理自动处理 workload 的思想接近，但它替换 socket 路径，不解析业务协议 | IBM 论文页未给出官方代码，本次未核实 artifact | 对“自动识别、零应用修改、native-like 路径”作设计 baseline；不是协议缓存 baseline |
| [A Framework for eBPF-Based Network Functions in an Era of Microservices（Polycube）](https://doi.org/10.1109/TNSM.2021.3055676)（[作者论文页](https://sebymiano.github.io/publication/2021-polycube/)） | P；IEEE Transactions on Network and Service Management，2021 | 基于 eBPF/XDP 构建可组合、服务无关的内核网络功能，并用用户态控制/管理平面组织网络服务 | **全项目控制面/组合基础设施邻近工作**；支持模块化 NF，但不提供本项目的 DNS/LDAP 语义 | [官方仓库](https://github.com/polycube-network/polycube) | 控制面、程序组合和生命周期 baseline；不适合作协议性能直接对手 |
| [Faster OVS Datapath with XDP](https://netdevconf.info/0x14/pub/papers/41/0x14-paper41-talk-paper.pdf) | T；Netdev 0x14，2020 | 用 native in-kernel XDP 实现 OVS datapath 子集；flow hit 在 XDP，miss/upcall 到 `ovs-vswitchd`；比较 kernel OVS、AF_XDP/DPDK 路径 | **OpenStack/OVS 最直接的数据面邻近工作**；fast/slow path 结构同构，但缓存 flow action，不解析 DNS/UDP 内容 | 属于 OVS/XDP 原型路线；本次未确认可独立复现的稳定官方 artifact | OpenStack 数据面主机制 baseline；应测 PVP/VM/TAP、PPS、loss、CPU，不与协议 hit 直接混算 |
| [Scaling Open vSwitch with a Computational Cache](https://www.usenix.org/conference/nsdi22/presentation/rashelbach) | P；USENIX NSDI，2022 | 在 OVS 大规则集分类前加入 computational cache，降低 packet classification 成本 | **OpenStack/OVS 的替代加速路线**；加速 flow/rule lookup，不做协议响应缓存 | 会议页未给出可直接替代 OVS 的独立 artifact | 用于说明“OVS 自身也可被缓存加速”；不是 DNS/UDP 加速比的直接对手 |
| [Design and Implementation of eBPF-based Virtual TAP for Inter-VM Traffic Monitoring](https://dl.ifip.org/db/conf/cnsm/cnsm2018/1570493112.pdf) | P；CNSM/HiPNet Workshop，2018 | 在虚拟机网络接口附近用 eBPF 实现 inter-VM 流量监控型 vTAP，并与虚拟交换机侧监控路径比较 | **OpenStack/TAP 的挂载与可见性直接邻近工作**；证明 VM 接口侧 eBPF vTAP 的可行性，但目标是监控而非加速 | 本次未核实官方代码 | TAP attach/observability 设计对照；不作为吞吐加速竞品 |
| [Demystifying Performance of eBPF Network Applications](https://doi.org/10.1145/3749216)（[开放论文与 artifact 记录](https://zenodo.org/records/17553686)） | P；Proceedings of the ACM on Networking / CoNEXT，2025 | 系统评测 eBPF 应用在 hit/miss、资源竞争、隔离和 AF_XDP 等场景下的收益与反效果 | **跨全项目的方法论/反证基线**；直接支持必须报告 miss path、混合命中率、tail、CPU 和隔离，而不能只报 100% hit | [官方测量代码](https://github.com/bpf-endeavor/bpf-app-offload-measurement) | 每类实验都应遵循的评测基线，尤其用于解释 LDAP 变慢和尾延迟退化 |

## 4. 分协议分析与 baseline 建议

### 4.1 DNS / XDP cache

**直接竞品：** hyDNS、NLnet Labs hot-cache、Xpress DNS。三者都体现“早期解析、
map 命中、原包改写/扩包、直接回复、miss 回用户态”。区别是 hyDNS 面向 recursive
resolver 并提出 per-core 扩展；NLnet 报告集中记录响应学习与 driver 限制；Xpress
只支持静态 A 记录，但代码最容易作为同机竞品。BMC 是跨协议的强同构思想，而非
DNS 竞品。

建议实验组：

1. nohook userspace resolver；
2. patched Xpress DNS（固定 commit，保持仅 A 能力）；
3. linux_accel generic XDP；
4. linux_accel native XDP（硬件支持时）；
5. 分别测试 100% hot hit、100% miss/unsupported，以及 Cloudflare Radar QTYPE
   混合场景；报告 QPS、p50/p95/p99、loss、backend fraction、cycles/packet。

hyDNS 的 100% A-hit 论文结果只能用于外部参照；不能与不同机器上的 linux_accel
数字直接算“胜出倍数”。

### 4.2 通用 UDP request-response fast path

本项目是控制面显式下发、带租约和接口隔离的确定性 request bytes → response bytes
映射，hit 后 `XDP_TX`，miss/过期/不支持包 fail-open。BMC 最接近“内容命中直接
回复”；TURN 工作最接近“控制面建立状态后把高频 UDP 数据路径下沉”。DINT 和
Electrode 则证明更复杂的固定格式 UDP 操作可以内核化，但不等价于通用缓存。

建议 baseline：userspace UDP server、XDP attached-but-miss、XDP exact-hit；若扩展
relay，再加入 Linux userspace relay 与 Supercharge TURN 式 XDP forwarding。
必须分别报告 hit ratio、response size、map working set、expired/miss 成本和后端
卸载率，不能只使用 64-byte 100% hit 微基准。

### 4.3 TCP / LDAP / LDAPS sockmap 透明代理

本项目没有在 XDP 中缓存 LDAP Bind/Search，也没有伪造 LDAP 响应；它使用
userspace copy、`splice(2)` 或 `SK_SKB` parser/verdict + SOCKHASH redirect 做透明
TCP 字节流代理。LDAP 的认证状态、message ID、StartTLS、目录更新和连接状态使
“命中回包”不具备默认安全语义。

已核验候选中，`Network shortcut in data plane of service mesh with eBPF` 使用
socket/tc redirection 缩短 Istio 代理路径，是当前 LDAP sockmap 最接近的机制论文；
MiddleCache 是 TCP KV 内容缓存，IBM 工作是透明 socket replacement。三者只能证明
TCP 内核路径可以优化。**本轮未检索到专门针对 LDAP/LDAPS、同时
采用 eBPF sockmap 透明代理并提供可复现实验的同行评审论文或正式技术报告。**

LDAP baseline 应保持：direct backend、userspace `recv/send` proxy、`splice` proxy、
sockmap proxy；测试真实 Bind/Search/StartTLS/LDAPS，报告 QPS、p99、代理进程 CPU、
整机 cycles、softirq 和 redirect/fallback。当前 sockmap 若只降低代理进程 CPU 而
吞吐/延迟变差，应如实定位为 CPU-offload 模式，不能称为延迟加速。

### 4.4 ARP proxy 与 DHCP relay

本项目 ARP 路径依据显式 IP→MAC 策略在 XDP 生成 ARP reply；DHCP 路径依据配置
执行受控 relay/转发。它们属于 L2/L3 控制协议，不应借用 DNS/KV cache 论文宣称
“协议缓存创新”。Polycube 可作为可编程网络服务框架参照，ONCache/OVS 可作为
虚拟网络生命周期参照，但都不是 ARP/DHCP 直接竞品。

**在已核验的一手来源集合中，没有找到与本项目“XDP ARP proxy + DHCP relay +
统一生命周期控制面”直接同类的同行评审论文或正式技术报告。** 这是检索缺口，
不是“全球不存在”的证明。

建议 baseline：Linux neighbor/proxy ARP 或原网络的 ARP responder、传统 userspace/
kernel DHCP relay、XDP attached-but-pass，以及 linux_accel；指标包括 ARP reply PPS/
RTT、DHCP transaction completion、CPU、错误包、租户/接口隔离与 fail-open 正确性。

### 4.5 gRPC、微服务与分布式协议

Electrode 给出最重要的设计边界：把广播、快速 ACK、quorum 汇聚等机械操作下沉，
把协议正确性留在 userspace。DINT 进一步展示 transaction fast path 的内核化上界；
SPRIGHT 使用 socket-message 和共享内存削减 serverless function chain 的协议处理与
序列化开销。这些都是同构思想，不是可直接替换的 gRPC server。

本项目若继续做 gRPC，不应声称在 XDP 中完整解析通用 HTTP/2 + HPACK + protobuf。
可辩护方向是：对明确定义的 h2c unary、固定方法和受限帧序列做 fast-cache；TLS、
流式 RPC、动态表、乱序、多帧和不支持状态全部回退。

建议 baseline：direct gRPC server、userspace proxy/sidecar、tc observe-only、受限
fast-cache；以 ghz/自有持久多路复用客户端测试不同 payload、并发 stream、hit/miss、
p99、CPU 和正确回退。Electrode、DINT、SPRIGHT用于机制和规模趋势对照，不应把
其论文数值与本项目直接算倍数。

### 4.6 Kubernetes CNI / container overlay lifecycle

ONCache 是本类最强学术 baseline：它作为现有 overlay 的增量 plugin，缓存重复的
网络处理结果，fast path 不可用时回标准 overlay。IBM socket replacement 则证明
node agent 可以在不修改应用容器/manifest 的前提下自动改变 socket 数据路径。
Polycube提供可组合 eBPF 网络服务的控制面参照。

linux_accel 与它们的差异是：项目不替换 CNI/IPAM/路由/NetworkPolicy，而是识别
CNI 和 Pod host-veth 生命周期，只对选中的协议策略 attach；对于 Cilium/Calico 等
已有 BPF owner 必须链式共存或 observe-only，不能覆盖其程序。

建议 baseline：原 CNI/overlay、linux_accel agent observe-only、attach-but-pass、
协议 fast path；在环境允许时再部署作者公开的 Antrea/ONCache artifact。必须测试 Pod 创建、
扩缩容、重建、接口 ifindex 复用、策略撤销、agent 重启和 CNI coexistence，并同时
报告 TCP/UDP RR、DNS mixed workload、CPU 与第一包/miss 成本。

### 4.7 OpenStack / OVS / VM / TAP dataplane

Faster OVS Datapath with XDP 与本项目共享经典两层模型：XDP/内核 fast path 命中后
处理，未知状态回 OVS userspace slow path。但 OVS 缓存 flow action，本项目缓存
协议响应或执行协议代理，研究对象不同。eBPF-based Virtual TAP 则是 VM/TAP 挂载与
可观测性的直接邻近证据，但不做加速。Polycube 是 NF 组合参照；ONCache 是容器
overlay 参照，不能直接代表 VM/TAP。

OpenStack 主 baseline 应是：

1. OVS/OVN kernel datapath nohook；
2. attach-but-pass/miss，量化 XDP 自身开销；
3. linux_accel generic XDP on TAP；
4. 若真实物理入口包含该流量，再测 native XDP；
5. 有资源时增加 OVS-AF_XDP、OVS-DPDK 或 OVS hardware offload，明确它们是通用
   dataplane 替代路线，不是协议缓存竞品。

必须区分 netns/veth、host TAP、`br-int` 和物理 NIC 的 hook 位置。正式 OpenStack
证据至少应包含 VM→TAP→OVS/OVN→backend 的真实路径、PVP/PVVP、IMIX/PPS、NDR/PDR、
loss、p99、CPU/softirq、后端卸载率，以及实验前后的 Neutron/OVN agent 和原 hook
恢复证据。不能把 netns/veth 结果写成 OpenStack 加速结果。

## 5. 答辩与论文中的推荐 baseline 组合

| 项目能力 | 必跑本地 baseline | 可运行外部 baseline | 学术 related-work 对照 |
| --- | --- | --- | --- |
| DNS | nohook、pass/miss、generic、native | patched Xpress DNS | hyDNS、NLnet hot-cache、BMC |
| 通用 UDP | userspace、pass/miss、exact-hit | BMC（增加 Memcached 场景时） | BMC、Supercharge TURN、DINT |
| TCP/LDAP | direct、userspace、splice、sockmap | 暂无同协议外部实现 | service-mesh network shortcut、MiddleCache、IBM socket replacement；明确 LDAP 缺口 |
| ARP/DHCP | 原网络 responder/relay、pass、linux_accel | 暂无已核验直接实现 | Polycube/ONCache 仅作邻近框架；明确检索缺口 |
| gRPC/微服务 | direct、userspace proxy、tc、受限 fast-cache | 暂无 wire-compatible 外部实现 | Electrode、DINT、SPRIGHT |
| K8s/CNI | 原 CNI、observe-only、pass、fast path | ONCache（环境与依赖允许时） | ONCache、IBM socket replacement、Polycube |
| OpenStack/OVS/TAP | OVS nohook、pass/miss、TAP generic、物理 native | OVS AF_XDP/DPDK（资源允许时） | Faster OVS Datapath with XDP、OVS computational cache、eBPF virtual TAP、Polycube |

跨所有实验都采用 `Demystifying Performance of eBPF Network Applications` 强调的
审慎口径：至少同时测 100% hit、真实混合、100% miss/unsupported；报告 throughput、
p50/p95/p99、loss、CPU/cycles、softirq、context switch、backend fraction 和资源
隔离；固定 CPU/IRQ affinity，重复多轮并给出离散程度或置信区间。

## 6. 可用于最终论文的准确定位

建议表述：

> `linux_accel` 是一个可与现有 Linux、Kubernetes CNI 和 OpenStack/OVS 数据面
> 共存的多协议 eBPF 加速层。它将可验证、可撤销的频繁协议操作下沉到 XDP、tc
> 或 sockmap；命中时短路常规路径，不支持、过期或异常状态 fail-open 到原有
> userspace/网络栈；node-local 控制面负责策略、租约和接口生命周期。

不应表述为“首个 XDP DNS cache”“首个内核 KV cache”或“替代 CNI/OVS”。更有力的
贡献组合是：

- 一个控制面覆盖多种 hook 和不同安全语义：DNS/UDP 直接回复、LDAP 字节流转发、
  ARP reply、DHCP relay、gRPC 受限快路径；
- 在既有 CNI、OVS/OVN、TAP 和物理接口上按 owner-aware 策略增量部署；
- 对 hit、miss、unsupported、生命周期撤销和现场恢复进行统一、可复现的验证；
- 不把所有 eBPF 路径都宣传成加速：对 LDAP sockmap 等结果同时报告 CPU offload
  与可能的吞吐/尾延迟退化。

这一区分让项目相对单协议原型的优势成立，同时不夸大与成熟 CNI、OVS、hyDNS、
BMC、ONCache 等工作的关系。
