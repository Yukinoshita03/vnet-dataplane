# linux_accel 竞品与相近方案研究

研究日期：2026-08-13  
范围：只采用项目官方文档、官方源码、官方论文或标准；不把博客、营销材料或二手评测作为事实依据。

## 1. 结论先行

`linux_accel` 目前不是一个“另一个 CNI”，也不是一个通用 L4/L7 负载均衡器。它更像是一个可插入现有 Linux、OVS/OpenStack 或 Kubernetes Pod-veth 路径的**协议感知微型 fast path**：由 XDP/tc/eBPF 负责数据面，由用户态策略、租约和接口生命周期控制面负责配置。

最接近的方案分成四组：

1. **Kubernetes 数据面竞品：Cilium、Calico eBPF dataplane。** 它们和本项目都处理 Pod veth、eBPF hook、服务流量和工作负载生命周期，但它们是完整的 CNI/网络策略/Service LB/可观测性产品，能力和控制面远大于当前项目。
2. **XDP L4 转发相近方案：Katran。** 它和本项目共享“在 XDP 早期处理包、用 BPF map 做状态”的技术路线，但 Katran 的目标是 VIP 到后端的 L4 DSR/负载均衡，不是 DNS 缓存、UDP 精确回包或 LDAP 透明转发。
3. **协议专用相近方案：XDP DNS 实验项目和 Linux sockmap 原语。** Xpress DNS 与 XDP hot-cache 研究原型和本项目的 DNS 命中回包最相似；LDAP/通用 UDP 则更多是 Linux sockmap、普通 TCP/UDP proxy 等底层能力的组合，当前没有发现一个成熟、开箱即用、同时覆盖“LDAP/通用 UDP + 透明 + eBPF/XDP fast path + Kubernetes 自动编排”的一站式竞品。
4. **OpenStack 数据面加速路线：OVS hardware offload、SR-IOV、OVS-DPDK 和 OVN Octavia。** 它们分别从硬件流表下沉、VF 直通、用户态 vSwitch 和 L4 负载均衡解决性能问题，是我们在 OpenStack `br-int`/TAP/OVS 场景下必须区分的替代路线，但不是同一个产品层次。

因此，当前最合理的产品定位是：

> 在既有 CNI、OVS 或虚拟机网络路径上，由策略选择性启用的协议级 eBPF fast path；CNI 负责建网，本项目负责可选的协议加速和透明降级。

“没有发现一站式竞品”是本次检索范围内的结论，不等价于证明全球不存在未公开或未检索到的实现。

## 2. 当前 linux_accel 的边界

项目自己的 README 将其定位为“eBPF 网络服务加速与双端缓存系统”，覆盖 DNS/gRPC 监控、DNS XDP 缓存、通用 UDP exact-hit、LDAP/LDAPS TCP 透明转发、ARP proxy、DHCP relay，以及 OpenStack/Kubernetes 虚拟化路径验证。[项目总览与能力表](../README.md)

当前实现的关键特征：

| 维度 | 当前实现 | 直接代码/文档依据 |
| --- | --- | --- |
| 数据面 hook | DNS/ARP/DHCP/UDP 使用 XDP；DNS/gRPC 监控使用 tc；LDAP 使用 `sk_skb/stream_parser` 与 `sk_skb/stream_verdict` sockmap hook | [BPF 源码目录](../bpf/)、[LDAP BPF 程序](../bpf/ldap_sockmap.c)、[源代码说明](../src/README.md) |
| DNS 快路径 | 对显式缓存命中的 IPv4 DNS `A/IN` 请求在 XDP 中直接构造响应；未命中放行 | [项目 README 的 DNS/UDP 说明](../README.md)、[DNS XDP 程序](../bpf/dns_client_cache.c) |
| 通用 UDP | 只处理显式配置的确定性 request/response exchange；命中后 XDP 回包，其他流量 fail-open | [UDP 快路径说明](../README.md)、[UDP BPF 程序](../bpf/udp_fastpath.c) |
| LDAP/LDAPS | 不解析或缓存目录协议内容；userspace、`splice(2)` 和 sockmap 三种透明 TCP 转发模式 | [LDAP proxy](../src/ldap_sockmap_proxy.cpp)、[LDAP 使用说明](../README.md) |
| 云原生生命周期 | 通过 node-local agent 观察 Kubernetes、解析 sandbox netns 的 `iflink` 到 host-veth，并向 C++ dataplane 下发接口 desired state；不替换现有 CNI | [Kubernetes 说明](../k8s/README.md)、[interface feed 设计](interface-feed.md)、[CNI 适配器](../k8s/linux_accel_agent.py) |
| CNI 兼容策略 | Flannel 高置信度时允许自动挂载；Calico 采用 tc-only；Cilium 默认 observe-only，避免抢占其 BPF 所有权 | [Kubernetes 适配说明](../k8s/README.md)、[CNI 自动识别实现](../k8s/linux_accel_agent.py) |
| 控制面 | AF_UNIX `SOCK_SEQPACKET` feed、source/revision/lease、幂等 reconcile、动态 attach/detach | [interface feed 文档](interface-feed.md)、[interface feed 实现](../src/interface_feed.cpp) |

这意味着本项目的优势不在于“替代所有网络功能”，而在于可以把一个**已知、可验证、适合短路径处理的协议交换**放到内核早期路径，同时把不支持的流量交还给原来的 CNI、OVS 或内核协议栈。

## 3. 竞品和相近方案对比

### 3.1 Cilium / Isovalent eBPF datapath

Cilium 官方数据面文档列出的 hook 包括 XDP、tc ingress/egress、socket operations 以及 socket send/recv。Cilium 将程序挂到容器 veth，并通过 tc 处理工作负载进出节点的流量；XDP 主要用于更早的预过滤和网络入口场景。[Cilium eBPF datapath introduction](https://docs.cilium.io/en/stable/network/ebpf/intro/)

Cilium 的 kube-proxy replacement 还使用 socket-level load balancer：对 TCP `connect`、connected UDP，以及 UDP `sendmsg`/`recvmsg` 做 Service 到 backend 的 socket 层选择，并在需要时回退到 veth 上的 tc load balancer。[Cilium kube-proxy-free 文档](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)

在远端 NodePort/LoadBalancer backend 场景，Cilium 文档明确提供 XDP acceleration；这与本项目的“XDP 上处理外部进入的确定性请求”在 hook 层面相近，但目标是 Service LB/转发，不是 DNS 内容缓存。[Cilium LoadBalancer/NodePort XDP acceleration](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)

Cilium 还支持 CNI chaining：基础 CNI 负责网络连接和 IPAM，Cilium 在基础 CNI 创建的设备上附加 eBPF，以提供 L3/L4 可见性、策略和其他高级能力。[Cilium CNI chaining](https://docs.cilium.io/en/stable/installation/cni-chaining/)

在编排和观测方面，Cilium agent 监听 Kubernetes 等编排系统的工作负载启动/停止事件并管理对应的 eBPF 程序；Hubble 在 Cilium/eBPF 之上提供节点、集群和跨集群流可见性。[Cilium component overview](https://docs.cilium.io/en/stable/overview/component-overview/)、[Hubble observability](https://docs.cilium.io/en/stable/observability/hubble/)

与 linux_accel 的关系：

- **相同点：** 都依赖 Pod veth、XDP/tc/eBPF map、动态工作负载生命周期和 fail-safe 的路径选择；Cilium 的“基础 CNI 建网、后续附加 eBPF”也证明了不必把加速逻辑硬编码进原始 CNI。
- **不同点：** Cilium 是完整 CNI、网络策略、Service LB、加密、路由和可观测性平台；linux_accel 只下发选中的协议策略，当前不会替代 CNI 的 IPAM、路由、策略或 Service LB。
- **直接竞争面：** 如果用户需求是 Kubernetes 通用网络、Service 负载均衡、网络策略或流观测，Cilium 是成熟竞品；如果需求是“已有 Flannel/OVS 不变，只给 DNS/特定 UDP/ARP 等流量增加一个可撤销的协议 fast path”，linux_accel 的切入面更窄但更容易和现有网络共存。
- **主要风险：** Cilium 已经拥有接口程序、dispatcher、socket LB 和 agent 的所有权。linux_accel 不能直接在 Cilium 管理的接口上覆盖或卸载其程序；项目当前将 Cilium 定为 observe-only，除非后续实现显式 chaining/dispatcher 集成。

### 3.2 Calico eBPF dataplane

Calico 官方文档说明，其 eBPF dataplane 在 Calico 接口、数据接口和隧道接口上使用 tc hook，以较早地处理 workload 流量，绕过 iptables 等传统路径；服务 LB 和策略信息存放在 BPF map 中。[Calico eBPF architecture](https://docs.tigera.io/calico/latest/about/kubernetes-training/about-ebpf)

Calico 还支持 connect-time load balancing，通过 socket 层 hook 在连接时直接选择 backend，避免服务连接上的 packet-by-packet NAT；对于外部服务，Calico 支持 Tunnel/DSR 模式，DSR 要求底层网络允许远端节点代表入口节点发送响应。[Calico eBPF use cases](https://docs.tigera.io/calico/latest/operations/ebpf/use-cases-ebpf)、[Calico eBPF enablement and DSR](https://docs.tigera.io/calico/latest/operations/ebpf/enabling-ebpf)

Calico 的官方源码中有独立的 BPF endpoint manager，用于管理 endpoint 的 dataplane 状态和程序编排。[Calico BPF endpoint manager source](https://github.com/projectcalico/calico/blob/master/felix/dataplane/linux/bpf_ep_mgr.go)

Calico 对 fast path 的工程纪律也有明确设计文档：已建立连接上的每个包都会付出 fast-path 成本，因此多次 map lookup、tail call 或复杂计算应尽量放到建流/慢路径，而不是每个包都做。[Calico BPF dataplane design](https://github.com/projectcalico/calico/blob/master/felix/design/bpf-overview.md)

与 linux_accel 的关系：

- **相同点：** 都在 workload veth/host interface 附近做 hook，都需要根据 endpoint 生命周期更新 map/程序，都强调快路径和慢路径分离。
- **不同点：** Calico 的主目标是网络策略、conntrack、NAT、Service LB 和多种网络封装；linux_accel 的主要目标是协议级命中回包、受控 relay、透明转发和服务监控。
- **部署位置：** Calico 是 CNI/dataplane owner；linux_accel 更适合作为现有 CNI 之上的 opt-in node agent。当前项目把 Calico 设为 tc-only，是因为在 Calico 管理的 veth 上直接装自有 XDP 不是安全的默认策略。
- **观测对比：** Calico 有官方 flow logs API/Whisker 体系，可聚合流量、策略 verdict、包和字节计数。[Calico Flow Logs API](https://docs.tigera.io/calico/latest/observability/flow-logs-api) linux_accel 当前是本地 monitor/metrics 和实验报告，尚未达到同等的集群级观测能力。

### 3.3 Katran（Meta/Facebook 开源 XDP L4LB）

Katran 官方仓库将其定义为使用 XDP 的高性能 Layer-4 load balancer，支持 driver/native XDP，也支持 generic XDP（性能会下降）。它以 VIP、五元组、连接表和后端选择为核心，并使用 IP-in-IP 将流量发往真实服务器。[Katran official repository](https://github.com/facebookincubator/katran)

Katran 的官方运行约束包括 DSR、L3 routed topology、不支持分片和 IP options，以及面向“load balancer on a stick”的部署假设。[Katran environment and topology](https://github.com/facebookincubator/katran#environment-requirements-for-katran-to-run)

与 linux_accel 的关系：

- **相同点：** 都在 XDP 早期路径解析 L2-L4 头部，使用 BPF map 保存热状态，native/generic 两种模式都需要按设备能力选择。
- **不同点：** Katran 的状态是连接到 backend 的 L4 forwarding state；linux_accel 的 DNS/UDP fast path 是显式 request bytes 到 response bytes 的短租约映射，DNS 命中可以直接 `XDP_TX`，不需要选择 L7 backend。
- **不是同一类产品：** Katran 不负责 Kubernetes Pod veth 自动发现、CNI 识别或协议内容缓存；linux_accel 也没有 Katran 的成熟 DSR、Maglev、后端池和 L4LB 运维模型。
- **可借鉴点：** per-CPU/lockless map、RX queue 扩展、native/generic fallback、连接/策略状态的生命周期设计，以及明确的 MTU/分片限制说明。

### 3.4 Meta 的 Prox / Proxygen 线

公开的一手论文将 Meta/Facebook 的 L4LB 记为 Katran，将 L7LB 记为内部的 Proxygen；论文描述 Proxygen 作为 reverse proxy、forward proxy 和 HTTP server，覆盖 TCP、UDP、HTTP/1.1、HTTP/2、QUIC、publish/subscribe、缓存、TLS、健康检查和上游监控等职责。[SIGCOMM 2020 official program entry](https://conferences.sigcomm.org/sigcomm/2020/program.html)、[论文 PDF（作者/机构公开版本）](https://cs.brown.edu/people/tab/papers/ZDU-SIGCOMM20.pdf)

Proxygen 的公开官方源码仓库是 Facebook 的 C++ HTTP libraries 项目。[Proxygen official source](https://github.com/facebook/proxygen)

与 linux_accel 的关系：

- **相同点：** 都关注服务流量而不只是裸转发；都涉及缓存/快速响应、健康状态、协议处理和服务端路径。
- **不同点：** Proxygen 是用户态 L7 proxy/应用流量平台，需要终止或管理连接；linux_accel 只把适合的交换放进 XDP/tc/sockmap，LDAP 当前明确不做内容缓存和协议重放。
- **定位判断：** Proxygen/Prox 是 L7 服务代理方向的相近方案，不是 linux_accel 的 XDP 直接竞品；linux_accel 可作为代理前面的“已知命中短路”或作为现有 proxy 的旁路 fast path，但不能替代 TLS、HTTP/QUIC 状态机和完整 L7 routing。

### 3.5 Open vSwitch / OVN / DPDK

Open vSwitch 的内核 datapath 由用户态填充 flow table，按包头和 metadata 匹配 flow 并执行转发等动作。[OVS datapath development guide](https://docs.openvswitch.org/en/latest/topics/datapath/)

OVS 也可以使用 userspace `netdev` datapath；官方文档说明这种模式更容易移植，但对非-DPDK 设备属于实验性路径并有性能成本。[OVS userspace datapath](https://docs.openvswitch.org/en/latest/intro/install/userspace/)

在 DPDK 模式下，OVS 可以完全在 userspace 使用 DPDK；DPDK PMD 直接访问 RX/TX descriptor、默认采用 polling 而不是中断。[OVS with DPDK](https://docs.openvswitch.org/en/latest/intro/install/dpdk/)、[DPDK Poll Mode Driver](https://doc.dpdk.org/guides/24.03/prog_guide/poll_mode_drv.html)

对于虚拟机，OVS 官方支持 DPDK vhost-user/vhost-user-client；vhost-user-client 是更推荐的类型，因为 OVS 重启时不必强制重启所有 VM。[OVS DPDK vhost-user ports](https://docs.openvswitch.org/en/latest/topics/dpdk/vhost-user/)

OVN 位于 OVS 之上，提供逻辑交换机、逻辑路由器、ACL、DHCP 等虚拟网络抽象；`ovn-controller` 将逻辑流翻译为本机 OpenFlow，OVS 再处理 datapath flow。[OVN architecture](https://www.ovn.org/en/architecture/)、[OVN OpenStack tutorial](https://docs.ovn.org/en/stable/tutorials/ovn-openstack.html)

与 linux_accel 的关系：

- **相同点：** 都可以出现在 OpenStack VM/tap/OVS 路径上；都需要关注虚拟接口、vhost/veth/tap 生命周期；OVS/OVN 是 linux_accel 需要共存和观测的真实部署底座。
- **不同点：** OVS/OVN/DPDK 解决的是虚拟交换、逻辑网络、隧道、flow forwarding 和 userspace packet I/O；它们没有把“DNS A 命中直接回包”或“某个 UDP request bytes 精确映射 response bytes”作为产品目标。
- **工程含义：** 在 OpenStack 上，linux_accel 应作为 OVS/OVN datapath 上的选择性加速层，而不是替换 `br-int` 的逻辑流或把 VM 网络整体迁移到 DPDK。比较时要单独区分 OVS kernel datapath、OVS-DPDK、generic XDP、native XDP，不能把它们混为一个 baseline。

### 3.6 OpenStack/Neutron 相关加速路线

OpenStack 侧有相关方案，但需要先区分“网络底座”和“性能替代路线”。Neutron 的 ML2/OVN 驱动负责把 OpenStack 网络模型下发到 OVN/OVS；OVN 再把逻辑网络翻译成节点上的流表。对我们的项目来说，`br-int`、`qvo/qvb/tap`、veth 和物理网卡都是既有数据面产生的挂载路径，Neutron/OVN/OVS 应继续保留网络控制权。[Neutron OVN 安装与 ML2 配置](https://docs.openstack.org/neutron/latest/install/ovn/manual_install.html)、[Neutron OVS 自服务网络](https://docs.openstack.org/neutron/latest/admin/deploy-ovs-selfservice.html)

| OpenStack 方案 | 解决的问题 | 和 linux_accel 的关系 | 判断 |
| --- | --- | --- | --- |
| [Neutron + OVN](https://docs.openstack.org/neutron/latest/install/ovn/manual_install.html) | 虚拟机网络、逻辑交换/路由、Geneve 和分布式流表 | 我们需要共存的网络底座；不应替换 OVN 的逻辑流或 Neutron 控制面 | **底座，不是直接竞品** |
| [OVS hardware offload](https://docs.openstack.org/neutron/latest/admin/config-ovs-offload.html) | 将 OVS 流通过 tc/switchdev/representor 等路径下沉到支持的 NIC/交换硬件 | 是 OpenStack 上最接近“宿主数据面加速”的路线，但主要加速通用 OVS flow，不是 DNS/UDP 内容命中 | **加速替代路线** |
| [Neutron SR-IOV](https://docs.openstack.org/neutron/latest/admin/config-sriov) | 创建 VF 并将 VF 直接分配给 VM，绕过 hypervisor 和虚拟交换层 | 可以作为低延迟/高吞吐对照，但需要 NIC/VF/PCI passthrough，且不再经过完整的 OVS 路径 | **硬件直通替代路线** |
| [OVS-DPDK](https://docs.openvswitch.org/en/latest/intro/install/dpdk/) | 通过 DPDK PMD 在用户态轮询收发包，服务 vhost-user VM | 是通用高 PPS/吞吐 baseline；部署和资源要求比我们增量 attach 更重 | **性能替代路线** |
| [OVN Octavia provider](https://docs.openstack.org/ovn-octavia-provider/latest/admin/driver.html) | 用 OVN flow 提供 OpenStack LoadBalancer，减少 Amphora VM | 和我们的 UDP/TCP 转发有部分交集，但属于 L4 LB，不是 DNS cache 或 XDP TX 短路 | **服务层相邻方案** |
| [Kuryr-Kubernetes](https://docs.openstack.org/kuryr-kubernetes/latest/devref/kuryr_kubernetes_design.html) | 把 Kubernetes Pod 网络映射为 Neutron 网络和端口 | 对我们“OpenStack + Kubernetes 统一路径发现”有参考价值，但不是数据面加速器 | **跨云集成方案** |

其中最需要正面测试的是 OVS hardware offload、SR-IOV 和 OVS-DPDK：

- **OVS hardware offload**：保留 OVS/OpenStack 控制语义，把通用 flow 尽量下沉到 NIC/交换硬件。它通常依赖特定 NIC、驱动、固件、switchdev 和 representor；OpenStack 官方资料还特别提示，某些安全组/port security 组合会限制 flow offload。[Neutron OVS hardware offload](https://docs.openstack.org/neutron/latest/admin/config-ovs-offload.html)
- **SR-IOV**：把 VF 直接交给实例，目标是绕过 hypervisor/vSwitch 以获得低延迟和接近线速的路径；代价是硬件绑定、虚拟交换能力减少、迁移和安全策略约束。[Neutron SR-IOV guide](https://docs.openstack.org/neutron/latest/admin/config-sriov)
- **OVS-DPDK**：把 vSwitch 数据面放到 userspace，以 PMD polling 处理 RX/TX；适合通用大流量吞吐，但需要 hugepage、CPU 绑核、vhost-user/DPDK 设备等额外部署条件。[OVS with DPDK](https://docs.openvswitch.org/en/latest/intro/install/dpdk/)、[DPDK Poll Mode Driver](https://doc.dpdk.org/guides/24.03/prog_guide/poll_mode_drv.html)

我们的优势不应写成“比这三种方案一定快”，而应写成：**不迁移整张 NIC、不直通 VF、不重建整个 OVS userspace datapath，也能对 DNS 热命中、确定性 UDP、ARP/DHCP 等可证明安全的短交换做增量加速**。这更适合现有 OpenStack 集群的渐进式部署。

### OpenStack 竞品 benchmark 分组

OpenStack 报告建议使用以下分组，避免把不同层次的方案混成一个 baseline：

| 组别 | 路径 | 目的 |
| --- | --- | --- |
| O0 | 现有 OVN/OVS，`nohook` | 唯一软件基线 |
| O1 | OVN/OVS + tc monitor | 测量观测开销 |
| O2 | OVN/OVS + `linux_accel` generic XDP | 测量协议命中快路径 |
| O3 | OVN/OVS + `linux_accel` native XDP | 真实 NIC/驱动门槛通过后测量 |
| O4 | OVS hardware offload | 通用 flow 的硬件下沉对照 |
| O5 | SR-IOV VF | 直通路径的延迟、吞吐和迁移约束对照 |
| O6 | OVS-DPDK | 用户态 vSwitch 的吞吐、PPS 和 CPU 对照 |

每组至少覆盖 VM-to-VM、VM-to-external、不同包长/IMIX、DNS hot-cache/miss、UDP exact-hit/miss、LDAP 持久连接和混合流量；记录 QPS/PPS、p50/p95/p99、CPU/softirq、丢包、后端请求数、OVS flow 命中以及 VM 重启/迁移后的恢复时间。

仓库目前已经有 OpenStack `br-int` 的 tc attach smoke 和 workload visibility 证据，但这不等于已经完成 O4/O5/O6 的公平性能比较。下一轮最合理的顺序是 `O0 → O2 → O3`，有合适 NIC 和独立资源后再加入 `O4/O5/O6`。

### 3.7 其他值得关注的加速方案

#### FD.io VPP

[FD.io VPP](https://docs.fd.io/vpp/25.10/index.html) 是完整的用户态 L2-L4 网络栈/包处理框架，支持 DPDK、vhost-user、memif，并提供 OpenStack 和 Kubernetes 集成场景。它和 OVS-DPDK属于同一类“替换或主导整个数据面”的路线，不是一个只挂在现有 `br-int`/TAP 路径上的小型扩展。

VPP 适合在答辩中作为“完整 userspace dataplane”参考；如果实际跑，应比较 VM-to-VM/VM-to-external 的通用转发吞吐、PPS、CPU 和尾延迟，不要拿 VPP 的普通转发结果直接和我们的 DNS hot-cache QPS 比。

#### AF_XDP

[Linux AF_XDP](https://docs.kernel.org/networking/af_xdp.html) 是和本项目最接近、也最值得补测的技术基线之一。XDP 程序可以通过 `XDP_REDIRECT` 把报文送到用户态 AF_XDP socket；用户态通过 RX/TX ring 和 UMEM 收发，支持 copy 或 zero-copy 模式，具体能力取决于网卡/驱动和队列配置。

对我们而言，AF_XDP 可以形成一个很有解释力的对照：

```text
nohook 原始服务
    vs userspace socket/relay
    vs AF_XDP userspace fast response
    vs generic XDP 直接 XDP_TX
    vs native XDP 直接 XDP_TX
```

这能回答评委最容易问的问题：收益究竟来自“绕过普通协议栈”，还是来自“完全在 XDP 中直接回包”。不过 AF_XDP 不是一个独立竞品产品，而是 XDP 的用户态数据面接口。

#### OVS-AF_XDP

Open vSwitch 也有 [AF_XDP datapath/端口支持](https://docs.openvswitch.org/en/stable/intro/install/afxdp/)。它比单独 AF_XDP 更贴近 OpenStack，因为可以把 AF_XDP 作为 OVS 数据面的 I/O 路径来考察。

它适合做 OpenStack 的扩展 baseline，但要注意比较对象已经变成“OVS I/O/backend 路径”，不再只是 DNS 协议命中。建议在同一 VM 拓扑下比较 OVS kernel datapath、OVS-AF_XDP、OVS-DPDK 和我们的协议 fast path 的通用包转发能力。

#### vhost-user / virtio 加速

OVS 的 [DPDK vhost-user/vhost-user-client](https://docs.openvswitch.org/en/latest/topics/dpdk/vhost-user/) 通过共享内存和 virtqueue 连接 QEMU/VM；官方文档将 vhost-user-client 作为更适合常见场景的类型，因为 OVS 重启后 VM 可以重新连接，而不必强制重启所有 VM。

这条路线加速的是 VM vNIC 与宿主 vSwitch 之间的 I/O，不是 DNS/UDP 内容短路。因此它可以作为“虚拟机 I/O 层”对照，但不应该和我们的 DNS XDP 加速比放在同一张表里。

#### vDPA

OpenStack Nova 已支持 `vnic_type=vdpa`。Nova 官方文档将 vDPA 描述为对 virtio 数据面的软/硬件 offload；当前 libvirt/KVM 路径主要通过 `vhost-vdpa` 提供 virtio-net，并且需要相应的硬件/软件 backend。[Nova vDPA 文档](https://docs.openstack.org/nova/latest/admin/vdpa.html)

vDPA 是 OpenStack 里最值得关注的“VM I/O 硬件/软件卸载”方向之一，但它的比较维度是 VM 网络吞吐、CPU、延迟、迁移和设备生命周期，不是协议级 cache hit。没有对应硬件时，答辩只需要做架构说明，不建议为了凑竞品强行部署。

#### 是否还要加入 netmap/Snabb 等方案

可以把 netmap、Snabb、ODP 等放在相关工作附录，但不建议列入主 benchmark：它们更偏通用 kernel-bypass 或用户态 packet I/O，和当前项目的 OpenStack/OVS 共存、协议命中和 Kubernetes 生命周期目标距离较远，而且会显著扩大实验矩阵。

### 3.8 DNS/XDP 专用方案

#### Xpress DNS

Xpress DNS 是公开源码中与本项目 DNS 命中回包最直接的相近实现。其官方 README 描述为“experimental XDP DNS server”：用户态将 DNS records 写入 BPF map，XDP 读取 map 并在内核早期响应，未匹配请求放行到 Linux networking stack；当前限制包括仅支持 A record、明文 UDP/53、单查询和无递归。[Xpress DNS official source](https://github.com/zebaz/xpress-dns)

相对于 Xpress DNS，linux_accel 的差异在于：

- 重点不是静态 DNS server，而是与可信 DNS egress 学习、TTL/租约和缓存控制面联动；
- 同一项目还组合了 ARP/DHCP/UDP dispatcher、OpenStack tap/veth 和 Kubernetes Pod lifecycle；
- 但在 DNS 协议覆盖面上仍然是窄范围 fast path，不能宣称替代递归 DNS、DoT/DoH/DoQ 或完整 authoritative/recursive server。

#### XDP hot-cache 研究原型

NLnet Labs 的一手研究报告描述了基于 XDP 的 DNS hot-cache，并给出了代码来源和项目结构；该工作与 linux_accel 的“缓存命中直接在 XDP 回包”路径高度相似，但属于研究/实验型实现，不是完整 Kubernetes CNI 或通用服务数据面。[NLnet Labs XDP-based DNS hot cache report](https://nlnetlabs.nl/downloads/publications/report_xdp-based-dns-hot-cache_2024-02-14.pdf)、[报告列出的代码仓库](https://github.com/mozzieongit/xdp-dns-cache)

DNS 方向的判断是：存在直接相似的实验/研究项目，但在本次一手资料范围内没有看到一个同时具备生产级 DNS 协议覆盖、Kubernetes/CNI 生命周期、跨 OpenStack/OVS 部署和通用可编排策略的 XDP DNS cache 产品。这个空档正是 linux_accel 可以明确表达的差异化方向。

## 4. Kubernetes Pod-veth 自动编排与网络可观测性

### CNI 不是附加 hook 的同义词

CNI 规范定义了 runtime 调用插件的 `ADD`、`DEL`、`CHECK`、`GC`、`VERSION` 等操作，并通过 `CNI_NETNS`、`CNI_IFNAME` 等参数把网络命名空间和接口传给插件。[CNI specification](https://www.cni.dev/docs/spec/)

Kubernetes 要求使用符合 CNI 规范的网络插件来实现 Pod 网络模型；从 Kubernetes 1.24 起，kubelet 不再负责通过旧的 `cni-bin-dir`/`network-plugin` 参数管理 CNI。[Kubernetes network plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/)

因此，linux_accel 当前的 node-local agent 不应被描述为“CNI 已兼容/已替换”：它观察 Kubernetes/CRI 状态，解析 Pod sandbox 到 host-veth，再把 desired interface 集合发送给已有 dataplane。这个设计和 Cilium chaining 的思路相容，但控制面规模和完整性还不等同于 Cilium/Calico 的 endpoint manager。

### 生命周期和观测能力对比

| 能力 | linux_accel 当前状态 | Cilium / Calico 的官方能力 | 差距 |
| --- | --- | --- | --- |
| Pod 到 host-veth | agent 通过 sandbox netns/`iflink` 解析，并用 lease/reconcile 更新接口 feed | Cilium agent 监听编排事件并管理 endpoint BPF；Calico Felix 有 BPF endpoint manager | linux_accel 是窄功能本地 adapter，缺少成熟 endpoint/IPAM/policy 全量状态机 |
| 自动扩缩容 | Pod/CRD watch + host netlink wakeup + retry | CNI/agent 原生围绕 endpoint 生命周期更新 datapath | 当前实现适合 opt-in 加速；尚未替换 CNI ADD/DEL，也没有完整 EndpointSlice/Service LB 编译器 |
| 多 CNI | Flannel auto attach；Calico tc-only；Cilium observe-only | Cilium chaining 支持基础 CNI 与 Cilium 叠加；Calico 自己拥有其 dataplane | Cilium 需要显式 dispatcher/chaining 合作才能安全共存 |
| 流量观测 | DNS/gRPC tc events、per-CPU counters、本地 benchmark | Hubble 提供节点/集群/跨集群流；Calico Goldmane/Whisker 提供聚合流日志 | linux_accel 目前偏实验和性能验证，不是集群级 observability 产品 |
| 故障策略 | attach 失败、接口消失时 fail-open/重试 | 完整 CNI/agent 负责网络、策略、服务和 endpoint 恢复 | linux_accel 的 fail-open 更简单，但不能承担 CNI 的网络可用性职责 |

Hubble 官方定位是基于 Cilium/eBPF 的分布式网络和安全可观测性，并可提供服务依赖、DNS/TCP/HTTP 问题和延迟等视图。[Hubble introduction](https://docs.cilium.io/en/stable/overview/intro/)

## 5. LDAP 与通用 UDP：有没有成熟竞品？

### LDAP/LDAPS

Linux 内核的 sockmap/sockhash 是一个通用的 socket-level 原语：可以挂 parser/verdict 程序，并通过 `bpf_sk_redirect_map()`、`bpf_sk_redirect_hash()`、`bpf_msg_redirect_*()` 在 socket 之间重定向数据。[Linux kernel sockmap documentation](https://docs.kernel.org/6.4/bpf/map_sockmap.html)

这正是 linux_accel LDAP proxy 当前采用的技术类别：在不理解 LDAP BER、bind、search 或 TLS 内容的情况下，只做已建立 TCP 字节流的透明转发。它的“竞品”更准确地说是：

- Linux sockmap 自己的应用样例和内核 selftests；[Linux BPF sockmap selftests](https://github.com/torvalds/linux/tree/master/tools/testing/selftests/bpf)
- 传统用户态 stream proxy，例如 NGINX stream module；官方文档支持 TCP、UDP 和 UNIX-domain stream proxy，并提供 upstream/health-check 等配置。[NGINX stream proxy module](https://nginx.org/en/docs/stream/ngx_stream_proxy_module.html)、[NGINX stream upstream health checks](https://nginx.org/en/docs/stream/ngx_stream_upstream_hc_module.html)

在本次检索到的一手资料中，没有看到一个像 Cilium/Calico/Katran 那样公开、成熟、专门面向 LDAP/LDAPS 的 eBPF transparent fast-path 产品。原因也比较明确：LDAP over TCP 的主要收益来自连接/字节流转发，而不是像 DNS 那样可以安全地用短报文缓存直接生成响应；TLS 场景还不能在 XDP 中理解或重放应用内容。

### 通用 UDP

NGINX stream 官方模块已经提供成熟的 TCP/UDP proxy、UDP session、upstream 和健康检查配置。[NGINX TCP/UDP stream proxy](https://nginx.org/en/docs/stream/ngx_stream_proxy_module.html)、[NGINX stream core](https://nginx.org/en/docs/stream/ngx_stream_core_module.html)

但普通 UDP 没有统一的连接语义和通用响应边界；这也是为什么成熟用户态 proxy 通常需要为具体协议定义 session、超时、响应个数或健康检查规则。linux_accel 当前采取更保守的策略：只有显式配置的 request bytes/response bytes exact-hit 才在 XDP 中回包，其他 UDP 一律放行。[项目 UDP policy 说明](../README.md)、[UDP policy 实现](../src/udp_fastpath_policy.cpp)

因此可以这样判断：

- **成熟的通用 UDP proxy 有**，例如 NGINX stream；
- **成熟的通用 UDP XDP exact-response cache/transparent fast path 产品没有在本次一手资料检索中发现**；
- linux_accel 的技术差异不是“支持所有 UDP”，而是将可证明为无副作用的少数 request/response 交换下沉到 XDP，并保留 userspace/kernel fallback。

## 6. 竞品成熟度和替代关系

| 类别 | 代表方案 | 成熟度/定位 | 是否直接替代 linux_accel |
| --- | --- | --- | --- |
| Kubernetes 全功能 eBPF CNI/dataplane | Cilium | 成熟的 CNI、策略、Service LB、socket LB、XDP/tc 和 Hubble 平台 | 在通用 K8s 网络场景是直接竞品；不等价于 DNS/LDAP 协议 cache |
| Kubernetes eBPF dataplane | Calico eBPF | 成熟的 endpoint/policy/conntrack/NAT/Service LB 数据面，含 tc/XDP/socket 能力 | 在 CNI/策略场景是直接竞品；协议专用回包不是其主定位 |
| XDP L4 load balancer | Katran | 成熟的公开 XDP L4 DSR/LB 基础库和 dataplane | 只替代 L4 forwarding 需求，不替代协议缓存/Pod agent |
| L7 proxy | Meta Proxygen/内部 Prox 线 | 用户态 L7 proxy、HTTP/QUIC/UDP/缓存/健康检查 | 替代完整代理功能，不替代 XDP micro-fast path |
| 虚拟交换/云数据面 | OVS/OVN/DPDK | 成熟的 OpenStack/VM/容器网络底座、flow、vhost、userspace PMD | 是部署底座或 baseline，不是协议级 cache 竞品 |
| DNS XDP | Xpress DNS、XDP hot-cache research | 有直接相似实现，但功能/编排范围较窄，偏实验或研究 | 是 DNS 子模块的直接相近方案 |
| LDAP/通用 UDP | Linux sockmap、NGINX stream 等 | sockmap 是内核原语，NGINX 是成熟用户态 proxy；没有发现同范围一站式 eBPF 产品 | 没有明确的成熟一对一竞品 |

## 7. 对 linux_accel 的产品和研发建议

1. **明确产品名义：** 对外描述为“CNI-compatible overlay/sidecar fast-path agent”或“protocol-aware eBPF acceleration layer”，不要宣称自己是 CNI。CNI 负责创建网络，linux_accel 负责选择性附加和 fail-open。
2. **优先把 Flannel/普通 veth 做成第一兼容等级：** 这条路径最容易验证自动发现、Pod 扩缩容、veth 重建、租约和回滚。
3. **Calico 做安全的 tc integration：** 复用 Calico 所拥有的 veth/tc 体系，默认只在自有 dispatcher/TCX 链接或明确的链式接口上挂载；不要抢占 Calico 的程序。
4. **Cilium 不要停留在“识别后 observe-only”：** 下一步应设计显式 Cilium chaining/dispatcher 合作接口，至少包含 hook ownership、program order、detach ownership、map namespace 和 rollback contract。没有这些契约，就不应自动加载。
5. **补齐 Service/EndpointSlice 语义：** 当前 `AcceleratedService` 的 Pod selector 和 node-local reconcile 已经能覆盖“选中 Pod 自动挂 host-veth”；若要接近 Cilium/Calico 的服务级能力，需要加入 Service/EndpointSlice、健康状态、generation 和跨节点 backend 变更，而不是继续扩大单包 parser。
6. **DNS 保持专用快路径，扩大协议前先补正确性矩阵：** A/AAAA、NXDOMAIN、CNAME、TTL、EDNS、分片、IPv6、失败回退和缓存一致性应分别测量；不要把 DNS hot-cache 的收益外推到 LDAP 或任意 UDP。
7. **LDAP 的卖点应是 transport fast path，不是 LDAP accelerator：** 公开声明只做 TCP 字节流透明转发、sockmap redirect 和 fallback；不要暗示能加速 BER/TLS 内容处理。
8. **建立分层 baseline：** 在 OpenStack/Kubernetes 报告中分别比较 userspace proxy、kernel TCP/UDP path、generic XDP、native XDP、OVS kernel datapath 和 OVS-DPDK；OVS/DPDK 是不同的数据面模型，不能用单一“baseline”覆盖。

## 8. 最终判断

`linux_accel` 的直接竞争压力主要来自 Cilium/Calico：它们已经解决了更大的 Kubernetes 数据面和生命周期问题。项目不应该和它们比“谁更像完整 CNI”，而应突出两个小而明确的差异：

1. **协议专用短路：** 对 DNS/确定性 UDP/ARP/DHCP 等可证明的短交换做 XDP 级处理；
2. **不改变原有网络 owner：** 通过接口 feed、租约、selector 和 fail-open，把加速作为现有 CNI/OVS 的可撤销附加能力。

DNS 方面已有 Xpress DNS 和研究型 XDP hot-cache 作为直接相近方案，因此应以协议覆盖、学习/租约控制面、云路径和可重复 benchmark 建立差异。LDAP/通用 UDP 方面，公开成熟方案主要是 sockmap 原语或用户态 stream proxy，而不是一套完整的协议级 eBPF 产品；这是当前最有空间、但也最需要谨慎定义边界的扩展方向。
