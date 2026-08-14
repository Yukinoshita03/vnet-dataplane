# 与 linux_accel 高重合的 XDP/eBPF 加速方案调研

研究日期：2026-08-14

范围：协议感知 fast path（DNS、Memcached、UDP/TCP）、XDP/TC/sockmap、以及 OpenStack TAP/OVS 或等价虚拟数据面。来源只采用方案作者/维护者的官方论文、官方仓库和官方文档；论文中的性能数字不能直接与本项目数字横向拼接，正式比较必须在同一机器、同一负载和同一 hook 模式下重跑。

## 结论先行

有，而且存在两类比 BMC 更值得加入答辩对比的对象：

1. **协议级最高重合：KFlex。** 它公开实现了 Memcached 的 GET/SET XDP 卸载，并实现了 Redis GET/SET/ZADD 的 `sk_skb` 卸载；它比 BMC 覆盖更多请求类型，尤其适合回答“我们的 miss/SET/TCP 路径和更强的内核扩展方案相比如何”。但它需要自定义 Linux 内核和 LLVM，仓库已经标注为 unmaintained，不能直接在当前生产 OpenStack 节点上装。
2. **DNS 最高重合：Xpress DNS 与 NLnet Labs 的 XDP-based DNS hot cache。** Xpress 是可直接构建、可在 veth 上挂载的 A/UDP/53 XDP DNS server；NLnet Labs 原型的研究问题和我们的 DNS cache 几乎一致，但其论文明确说明最终 prototype 没有完成 tc 学习缓存和用户态可填充 map，因此只能作为设计/可行性对照，不能把它当作完成的高吞吐竞品。
3. **OpenStack 数据面最高重合：OVS-AF_XDP。** 它保留 OVS userspace datapath，通过 XDP + XSKMAP 把包交给 `ovs-vswitchd`，官方文档还给了 netns/veth 复现实例；这是和 TAP/OVS 路径最适合做同拓扑对比的方案。OVS-DPDK 则适合做通用 PPS/吞吐上界，不是协议 cache 的同类 baseline。
4. **通用 UDP/L4 对照：TURN eBPF/XDP、Katran、XDP Proxy、Polycube。** 它们分别代表协议头改写/中继、L4 DSR 负载均衡、NAT-like 转发和可组合 XDP/TC 网络功能，能与我们的通用 UDP/ARP/TCP 转发路径比较，但不能据此宣称比 DNS/Memcached 内容命中更快。

目前没有发现一个公开、可直接运行、同时覆盖“DNS/Memcached/通用 UDP/TCP + 协议内容缓存 + OpenStack TAP/OVS + Kubernetes 生命周期”的一站式方案。因此 linux_accel 的可辩护差异仍然是：**在既有 CNI/OVS/OVN 路径上增量挂载、按协议选择性短路、未命中 fail-open，并同时覆盖多个协议**。

## 候选矩阵

| 候选 | 与 linux_accel 的重合 | Hook / 数据面 | 协议范围 | 当前可复现性 | 公平比较方式 |
|---|---|---|---|---|---|
| **KFlex** | **最高：协议级内核卸载** | Memcached 用 XDP；Redis 用 `sk_skb`；扩展拥有自己的 heap | Memcached GET/SET；Redis GET/SET/ZADD；TCP fast path | **需要移植**：官方 repo 要求 LLVM >18 和自定义 v6.9 kernel，并标注 unmaintained | 同一物理/虚拟机上跑 userspace、BMC、linux_accel、KFlex；统一 32B key/32B value、Zipf 0.99、GET:SET=`90:10/50:50/10:90`，报告 QPS、p99、CPU、命中/慢路径比例 |
| **Xpress DNS** | **DNS 语义几乎重合** | XDP；`ip link ... xdp obj`，未命中 `XDP_PASS` | A、UDP/53、单 query、基础 EDNS | **直接可运行**：官方 repo 自带 build/test，要求 kernel ≥5.8 | 同一 veth/TAP、同一 A 记录 corpus；分别测 hot hit、miss、AAAA/NXDOMAIN/CNAME 等放行流量，分 generic/native，记录后端查询、XDP TX、p50/p95/p99、丢包 |
| **NLnet Labs XDP-based DNS hot cache** | **设计问题最接近** | 计划中的 XDP ingress + TC egress 学习 + BPF map；Rust/Aya | DNS 小响应、hot cache | **部分原型/需补全**：论文明确写出最终 prototype 仍是 hard-coded domain/response，没有完成 tc 缓存填充和用户态 map 更新 | 只能做“可行性/验证器/响应尺寸”对照；要成为正式性能 baseline，必须先补齐实际 cache 和 control plane，不能直接拿论文原始 prototype 与我们比 QPS |
| **TURN eBPF/XDP offload** | **UDP 应用代理高重合** | XDP 对 TURN ChannelData 增删头、更新 checksum；官方代码在 `server-ebpf-offload` 分支 | TURN/STUN 关联的 UDP relay，5-tuple session | **需移植/隔离运行**：论文和代码分支公开，但需要单独 TURN testbed | 同一 TURN server/peer、同一 session 数和包长；Pion TURN userspace、eBPF/XDP、linux_accel UDP relay 三组，测 goodput、pps、p99、CPU、checksum/正确性 |
| **OVS-AF_XDP** | **OpenStack/OVS 路径最高重合** | XDP + XSKMAP → AF_XDP userspace → OVS `dpif-netdev`；支持 `native-with-zerocopy`、`native`、`generic`、`best-effort` | L2-L4、OVS flow、隧道/虚拟端口 | **隔离环境直接可运行；OpenStack 集成需移植/重部署** | 同一 VM/TAP 或 netns/veth 拓扑，比较 OVS kernel/nohook、OVS-AF_XDP、linux_accel generic/native；固定 PMD/RX queue/CPU affinity，测 PPS、p99、softirq、OVS flow、VM-to-VM 丢包 |
| **OVS-DPDK** | **虚拟数据面性能替代路线** | userspace OVS + DPDK PMD/vhost-user，非 eBPF | 通用 L2-L4/隧道/VM I/O | **需要专用节点**：hugepages、VFIO、DPDK NIC/vhost-user | 只作为通用 dataplane 上界：同一 VM 流量和包长比较 PPS、吞吐、CPU、p99；不要把它写成 DNS/Memcached 内容 cache 竞品 |
| **Katran** | **XDP L4 快路径重合** | XDP native/driver mode；也支持 generic；BPF map、per-CPU 状态、IP-in-IP/DSR | TCP/UDP 五元组、VIP→real server | **直接可运行**：官方 repo 给出 Ubuntu/kernel 要求和 examples | 用相同 VIP、后端数、MTU、5-tuple 流和 RX queues，对比 L4 forward/DSR；只比较转发成本，不比较 L7 命中 |
| **XDP Proxy** | **通用 TCP/UDP/ICMP 转发重合** | XDP DRV/native、SKB/generic，另有 offload 尝试；BPF pinned maps | L3/L4 NAT-like proxy，TCP/UDP/ICMP | **直接可运行**：官方 repo 有 build、config、`--skb` 和规则 CLI | 两个 veth/netns 做静态 NAT/forward，分别测 native/generic；再测 OpenStack TAP 只能作为额外实验，不覆盖其控制面差异 |
| **Cilium eBPF datapath** | **云原生生命周期/服务 LB 重合** | Pod veth 上 TC；socket send/recv；NodePort/LoadBalancer 可用 XDP native/best-effort；可 overlay VXLAN/Geneve | L3/L4 service LB、L7 policy/proxy、DNS-aware policy | **K8s 直接可运行；当前 OpenStack 现场不应启用** | 在独立 K8s 集群做 Pod-to-Service/NodePort 对比；把 CNI/Service LB 与 linux_accel 的协议 cache 分开，不比较 DNS/Memcached payload hit |
| **Polycube** | **虚拟拓扑和 hook 组合重合** | 同一 cube 可选 `TC`、`XDP_SKB` 或 `XDP_DRV`；可连接 netdev/veth/VM | bridge、router、NAT、LB、firewall、DDoS | **隔离 netns 直接可运行；生产集群需单独部署** | 同一 veth/bridge/router/NAT/LB 流量比较三种 hook；重点是 forwarding PPS、p99、CPU 和可组合性，不宣称协议 cache 优势 |
| **Linux sockmap/sk_msg/sk_skb** | **TCP/LDAP/gRPC relay 原语重合** | `BPF_MAP_TYPE_SOCKMAP/SOCKHASH`，`sk_skb`/`sk_msg` socket redirect | TCP stream redirect、socket policy、relay | **直接可运行为机制 baseline**；不是独立产品 | 对 LDAP/LDAPS/gRPC 使用持久连接、相同 payload/并发和 backend；比较 userspace proxy、splice、sockmap、linux_accel 的 throughput、p99、CPU、context switch；不和 XDP UDP cache 混表 |

来源： [KFlex 官方仓库](https://github.com/rs3lab/KFlex) / [KFlex SOSP’24 论文](https://rs3lab.github.io/assets/papers/2024/dwivedi%3Akflex.pdf)；[Xpress DNS 官方仓库](https://github.com/zebaz/xpress-dns)；[NLnet Labs XDP-based DNS hot cache 报告](https://www.nlnetlabs.nl/downloads/publications/report_xdp-based-dns-hot-cache_2024-02-14.pdf)；[TURN eBPF/XDP 官方演示论文](https://conferences.sigcomm.org/sigcomm/2023/files/workshop-ebpf/5-TURN.pdf) / [公开代码分支](https://github.com/l7mp/turn/tree/server-ebpf-offload)；[OVS AF_XDP 官方文档](https://docs.openvswitch.org/en/stable/intro/install/afxdp/) / [OVS DPDK 官方文档](https://docs.openvswitch.org/en/latest/intro/install/dpdk/)；[Katran 官方仓库](https://github.com/facebookincubator/katran)；[XDP Proxy 官方仓库](https://github.com/gamemann/xdp-proxy)；[Cilium 官方 eBPF datapath 文档](https://docs.cilium.io/en/stable/network/ebpf/intro/) / [NodePort XDP 文档](https://docs.cilium.io/en/latest/network/kubernetes/kubeproxy-free/)；[Polycube 官方 hook 文档](https://polycube.readthedocs.io/en/latest/cubes.html)；[Linux sockmap 官方文档](https://docs.kernel.org/6.4/bpf/map_sockmap.html)。

## 最值得下一轮做的三组

### A. KFlex：正式的“协议级强竞品”

这是最值得补上的对照。BMC 主要是 UDP GET look-aside cache，而 KFlex 公开实现了 Memcached GET/SET，并把 Redis TCP 请求放到 `sk_skb`；论文还给出了与 userspace 和 BMC 的同机实验方法。公平实验应使用 KFlex 论文的三种 GET/SET 比例和 key/value 大小，再增加 linux_accel 的 miss、TCP、OpenStack TAP 两个扩展维度。KFlex 的自定义 kernel/LLVM 依赖必须单独放在隔离 VM，不能改变当前 OpenStack 节点的内核。

### B. OVS-AF_XDP：正式的“OpenStack 数据面强对照”

先在独立 netns/veth 复现官方 OVS AF_XDP 示例，再迁移到一组非生产 OpenStack VM。实验矩阵固定为：

```text
O0  OVS kernel datapath / nohook
O1  OVS userspace netdev
O2  OVS-AF_XDP generic
O3  OVS-AF_XDP native
O4  linux_accel generic/native（只在设备能力通过时）
```

每组保持同一 TAP、OVS flow、Geneve/VM 路径、PMD/RX queue 和 CPU affinity；同时测普通 UDP、DNS hot/miss、Memcached hit/miss。这样能回答“我们的优势来自协议短路，还是仅仅来自换成了更快的 vSwitch”。

### C. TURN eBPF/XDP：正式的“真实 UDP 应用”对照

TURN 的 ChannelData 路径需要实际增删头部并维护 UDP checksum，和我们当前通用 UDP 的“确定性请求/响应交换”相比更接近真实应用 relay。可以用公开 `server-ebpf-offload` 分支和 Pion TURN userspace baseline，使用持久 UDP session、不同 payload 大小、不同 session 数，报告 goodput、pps、p99、CPU 和错误率。该实验不能转述成 DNS 或 Memcached 加速，只能作为 UDP 协议代理能力对比。

## 公平实验规则

- **不拼论文原始数字。** KFlex 论文使用 96-core/10GbE/Ubuntu 24.04/custom Linux 6.9；我们的 OpenStack VM/TAP 和 netns/veth 硬件、路径完全不同。只能在同一环境重跑后取相对 nohook 的比值。
- **按 hook 分层。** `XDP_DRV/native`、`XDP_SKB/generic`、TC、`sk_skb/sk_msg`、AF_XDP 和 DPDK 分开报；不能把“用了 eBPF”当成相同路径。
- **按语义分层。** hit/直接回包、miss/放行、需要 backend 的请求、错误/不支持 qtype 必须分开；尤其不能用全 hit 结果代表混合流量。
- **固定流量生成器。** DNS 使用同一混合 qtype/命中率/并发矩阵；KV 使用持久多线程 client、Zipf、GET/SET 比例；UDP/TURN 使用持久 session 和固定 payload；TCP/LDAP/gRPC 使用持久连接，不能把每请求 `socket()` 的结果当作协议能力。
- **固定系统条件。** CPU/RSS/IRQ affinity、队列数、MTU、offload、内核版本、libbpf/LLVM、warm-up、运行时间和重复次数都写入 artifact；报告 QPS/PPS、p50/p95/p99、CPU cycles、softirq、context switch、backend request count、丢包和错误。
- **OpenStack 现场保护。** 当前集群保持 Kubernetes 关闭；OVS/OVN/Neutron 控制面继续拥有 `br-int` 和 TAP；新方案先在隔离 netns/非生产 VM 中验证，再做 TAP 复测；native XDP 必须先通过驱动能力门禁，不能远程重绑管理网卡。

## 一个重要的负结果也要保留

CoNEXT’25 的一手测量专门研究了 eBPF 网络应用的部分卸载：它指出慢路径请求会承担额外的 eBPF 成本，AF_XDP 本身已经很快时再叠加部分 offload 的收益会变小，甚至可能让用户态慢路径的延迟上升。这个结论与我们已经观测到的 Memcached miss、gRPC miss 和 LDAP sockmap 吞吐下降是同方向证据；下一轮应继续报告命中率阈值和 miss-path overhead，而不是只展示 hot-cache 加速比。[论文 PDF：Demystifying Performance of eBPF Network Applications](https://cs.nyu.edu/~apanda/assets/papers/conext25.pdf)

## 推荐答辩表述

> BMC 是我们在 Memcached 上的协议内 baseline；Xpress/NLnet DNS hot-cache 是 DNS 语义 baseline；KFlex 是需要独立 custom-kernel 环境验证的更强协议级竞品；OVS-AF_XDP/OVS-DPDK 是 OpenStack 数据面 baseline；Katran、TURN、Polycube、Cilium 和 sockmap 分别作为 L4、UDP relay、组合网络功能、云原生 Service LB 和 TCP relay 的机制对照。linux_accel 的主张不是在所有层面替代这些系统，而是在既有 CNI/OVS/OVN 路径上，以可撤销、fail-open 的方式对多个已知协议交换做选择性快路径。
