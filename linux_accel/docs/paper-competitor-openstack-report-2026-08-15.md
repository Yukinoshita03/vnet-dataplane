# 论文方案在 OpenStack 数据面上的可复现实验（2026-08-15）

## 结论

本轮把最适合当前三节点 OpenStack 环境的论文级数据面方案 OVS AF_XDP 跑通了。正式实验在 node1 的 OpenStack 计算节点上建立了隔离的 netns/veth → OVS userspace `netdev` 拓扑，比较 OVS `system` port 与 OVS `afxdp` port 的持久多线程 UDP 请求/响应。

这条结果属于“OpenStack 计算节点数据面能力对比”，不是 tenant VM/TAP → OVN/OVS 的端到端结果。原因是 OVS AF_XDP 论文方案需要把端口配置成 `type=afxdp`，而当前物理 NIC 和 `br-int` 正被 OpenStack/OVN 使用，不能为了实验接管共享物理网卡或改动现有 tenant TAP。真正的 VM/TAP 端到端论文级应用缓存对比使用同一批次的 BMC OpenStack 实验单独报告。

## 论文/实现对应关系

| 我们的路径 | 公开论文/实现 | 当前结论 |
| --- | --- | --- |
| Memcached UDP 内容缓存 | [BMC, NSDI'21](https://www.usenix.org/system/files/nsdi21-ghigoff.pdf) | 同层直接竞品；已在 OpenStack VM/TAP 跨计算节点实测 |
| OVS/L4 UDP 数据面 | [Revisiting the Open vSwitch Dataplane, SIGCOMM'21](https://conferences.sigcomm.org/sigcomm/2021/files/papers/3452296.3472914.pdf) 与 [OVS AF_XDP 3.7.1 文档](https://docs.openvswitch.org/en/stable/intro/install/afxdp/) | 当前节点可执行；已完成隔离计算节点正式矩阵 |
| DNS XDP 内容缓存 | [Xpress DNS](https://github.com/zebaz/xpress-dns) | 工程 baseline，已跑；不是已确认的顶会论文实现 |
| K8s overlay cache | [ONCache, NSDI'25](https://www.usenix.org/conference/nsdi25/presentation/lin-shengkai) | 代码依赖 Antrea/Kubernetes 和定制 `bpf_redirect_rpeer` 内核；本集群 K8s 明确保持关闭，因此只做可行性记录，不伪造结果 |
| ARP、LDAP/LDAPS、DHCP、透明 gRPC cache | 未找到同层、公开、可复现实验的顶会专用实现 | 使用 Linux/kernel、direct、userspace、splice、sockmap 等 baseline；不把不同语义的系统冒充直接竞品 |

## A. OVS AF_XDP 计算节点数据面矩阵

### 环境与拓扑

- 主机：`node1` / `node1`，Linux `7.0.0-14-generic`，x86-64。
- OVS：`3.7.1`，DB schema `8.8.0`。
- workload：持久 UDP socket，多线程，每个 worker 一个 connected UDP socket；请求为 4-byte `ping`，响应为 7-byte `pong-ok`。
- 参数：5 repetitions，4 client threads，每线程 25,000 timed requests，1,000 warmup requests；每轮 100,000 requests。
- 隔离拓扑：两个 network namespace，两个 veth pair，veth host ends 接入临时 OVS bridge，bridge 使用 userspace `netdev` datapath；没有修改 `br-int`、物理 NIC、OpenStack VM TAP 或 K8s 网络。
- AF_XDP 端确认：OVS Interface `type=afxdp`，`status` 中 `xdp-mode=generic`，host veth 显示 `xdpgeneric`。
- 结果文件：`artifacts/paper-competitors/20260815-node1-v1/ovs-afxdp/`。

### 正式结果（5 轮中位数）

| OVS 模式 | QPS | p50 (µs) | p95 (µs) | p99 (µs) | failed | 相对 system QPS | system p99 / 本模式 p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `system` baseline | 76,250.3 | 40.441 | 77.567 | 90.112 | 0 | 1.0000× | 1.0000× |
| `afxdp` generic | 315,018 | 12.239 | 14.238 | 16.212 | 0 | **4.1314×** | **5.5584×** |
| `linux_accel` generic exact-hit | **2,571,010** | **1.495** | **1.512** | **1.528** | 0 | **33.7180×** | **58.9738×** |

逐轮原始 QPS：

- `system`: 76,739.6、74,980.1、75,744.3、76,678.2、76,250.3。
- `afxdp`: 296,123、303,381、315,018、328,411、327,555。
- `linux_accel`: 2,605,110、2,563,740、2,560,400、2,571,010、2,579,830。

在同一 UDP 请求和同一隔离拓扑下，linux_accel 相对 OVS AF_XDP 为 **8.1615× QPS**；
p50/p95/p99 分别约为 **8.1866×/9.4167×/10.6099×**。但这不是“两个纯
I/O 框架”的同语义对比：AF_XDP 行由 OVS userspace 转发到 server 再回包，
linux_accel 行在 client host veth 的 generic XDP 命中后直接 `XDP_TX` 回包。它
证明的是当前短消息 exact-hit 场景中协议感知的 XDP 直回路径比通用 AF_XDP/OVS
转发路径更快，不能推广为所有 miss、TCP 或其他应用协议的结论。

每一轮都完成 100,000/100,000 请求；实验采集的 veth link 计数与 `softnet_stat` 没有出现新增丢包，且 teardown 后 bridge 列表恢复为实验前状态。

### 一个必须记录的实验坑

第一次 smoke 中，ICMP ping 正常但 UDP 全部 timeout。排查发现 UDP frame 已经到达 server veth，然而 veth/OVS userspace 路径的部分校验和卸载元数据导致接收 namespace 在 UDP 层丢弃。关闭的只是本实验临时 veth 两端的 `tx/rx/tso/gso/gro/ufo` offload，未修改 OpenStack TAP 或物理 NIC；关闭后 `system` 与 `afxdp` 的 UDP correctness 均通过。该处理已固化在 runner，避免把校验和元数据问题误报成 AF_XDP 性能结果。

## B. 真正 OpenStack VM/TAP 的 Memcached 论文竞品

这部分沿用 `20260814-node1-v1` 的正式 cross-compute batch，client VM 在 node1、backend VM 在 node2，流量经过 OpenStack TAP/OVS/OVN 跨计算节点路径。它与 BMC 的协议语义相同，因而是目前最公平的“我们的协议缓存 vs 论文方案”比较：

| 模式 | QPS | p50 (µs) | p95 (µs) | p99 (µs) | 失败/丢包 |
| --- | ---: | ---: | ---: | ---: | ---: |
| nohook | 23,288 | 85.183 | 92.762 | 106.111 | 0 |
| BMC NSDI'21 | 51,546.95 | 11.099 | 90.236 | 97.212 | 0 |
| linux_accel | **68,078** | **10.825** | **88.874** | **95.769** | 0 |

在这个真实 OpenStack VM/TAP workload 上：

- linux_accel / nohook = **2.9233× QPS**；
- linux_accel / BMC = **1.3207× QPS**，即比 BMC 高 **32.07%**；
- p95 比 BMC 低约 **1.51%**，p99 比 BMC 低约 **1.49%**；
- 三种模式均为 0 failure、0 softnet drop。

原始 batch 与 569 项复现校验：

- batch：`artifacts/all-comparisons/20260814-node1-v1/`；
- verifier：`python3 tools/verify_all_comparisons_artifacts.py` → `PASS: 569 reproducibility checks`。

## 如何复现 OVS AF_XDP 矩阵

在 node1 上安装/编译持久 UDP client：

```bash
g++ -std=c++17 -O2 -g -Wall -Wextra -Wpedantic -Werror -pthread \
  bench/udp_fastpath_bench.cpp -o /tmp/ovs-afxdp-paper/udp_fastpath_bench
```

把 `bench/ovs_afxdp_paper_host_bench.sh` 复制到 node1，以 root 执行：

```bash
RUN_LINUX_ACCEL=1 REPETITIONS=5 THREADS=4 REQUESTS=25000 WARMUP=1000 \
OUT_DIR=/tmp/ovs-afxdp-paper/formal-YYYYMMDD-v1 \
bash bench/ovs_afxdp_paper_host_bench.sh
```

`RUN_LINUX_ACCEL=1` 使用 node1 上的固定 linux_accel release 和对应 BPF object；
关闭该变量时 runner 仍只执行 `system`/`afxdp` 两种数据面模式。

辅助 correctness/debug 脚本：

- `bench/ovs_udp_datagram_smoke.sh`：验证 OVS `system`/`afxdp` 的 UDP 收发与校验和卸载处理；
- `bench/udp_direct_veth_smoke.sh`：隔离验证 client 的持久 UDP benchmark 本身。

源文件 SHA-256：

```text
bench/ovs_afxdp_paper_host_bench.sh  3f5f0a3f7be4aeef24fd8e9e1774f7573b8bfa9a5c65ae2fa1706b879d974bef
bench/ovs_udp_datagram_smoke.sh      1ed1b9064e7ddbd4d7a1f30ef183a220b7a70a1c9c38456977c2eadd5418ba0d
bench/udp_direct_veth_smoke.sh       72703cf2be1709e4d56672c45f346c5a49c7f4ed3838ce2bb055ce9fec0ff440
bench/udp_fastpath_bench.cpp         74df8fdbaf88efaaccc74f724b51dc0c39340c925cca58b6607d3e86e455b303
```

## C. 其他已实现协议的结果与竞品边界

协议不能都拿 AF_XDP 做直接横比。AF_XDP/OVS 是通用数据面 I/O 方案，不自带 DNS、
Memcached、ARP、HTTP/2、LDAP 或 DHCP 语义。其他协议使用各自的同语义竞品或
baseline，完整数值见 [`all-comparisons-experiment-report-2026-08-14.md`](all-comparisons-experiment-report-2026-08-14.md)：

| 协议/路径 | 对比 | linux_accel 结果 | 当前结论 |
| --- | --- | ---: | --- |
| DNS | linux_accel vs Xpress | `268,344 / 227,500 = 1.1795×` resperf 1% loss capacity；OpenStack 20k p99 `183/195 µs` | 容量提升约 17.95%，低压 p99 不是所有点都胜 |
| Memcached UDP | linux_accel vs BMC NSDI'21 | netns mixed `1,197,340/970,340 = 1.2339×`；OpenStack `68,078/51,547 = 1.3207×` | 当前最公平的论文级应用协议竞品 |
| ARP | linux_accel generic XDP vs kernel neighbor | `718,033/390,189 = 1.840×` | 没找到同层公开顶会 ARP responder，使用 kernel baseline |
| 通用 UDP | userspace vs linux_accel generic XDP | `3,295,770/292,278 = 11.276×` | 与本轮 OVS AF_XDP 三方结果互补，不混成一个数字 |
| gRPC h2c | direct backend vs linux_accel cache | `22,471/1,777 = 12.645×` | 协议 cache 原型，miss path 不宣称加速 |
| LDAP/LDAPS | userspace/splice/sockmap | sockmap `16,513/18,722 = 0.882×` QPS | CPU offload 约 99.86%，不是 QPS/时延加速 |
| DHCP | relay/control correctness | correctness gate 通过 | 没有伪造 cache 加速比 |

因此，“linux_accel 相比 AF_XDP”的严格答案只适用于上面的同 UDP 隔离矩阵：
QPS `8.1615×`、p99 `10.6099×`；DNS/Memcached/ARP/gRPC/LDAP 必须使用各自的
语义对比行。

## 解释边界

三方正式矩阵中 OVS AF_XDP 相对 system 为 4.1314× QPS，linux_accel exact-hit 相对 AF_XDP 为 8.1615×；BMC 的 1.3207× 是“同一 OpenStack VM/TAP Memcached UDP workload 中 linux_accel → BMC”的应用协议缓存提升。两者不能合并成一个总加速比，也不能据此说 linux_accel 在所有场景都比 OVS AF_XDP 高；它们优化的层次不同：前者是 packet I/O/datapath，后者是协议解析、缓存命中与响应生成。

## 当前现场恢复

- Kubernetes 相关 unit 在 node1/node2/node3 均保持 `inactive`。
- OVS 临时 bridge、namespace、veth 已清理。
- `br-int`、现有 OpenStack TAP 与 linux_accel DNS/gRPC hooks 未被 runner 接管。
- OpenStack client VM 的原始状态是 `SHUTOFF`；本轮 OVS 隔离实验没有改变其 TAP 路径。后续结束 OpenStack live 检查时仍需把已启动的 client VM 恢复为 `SHUTOFF`，并再次执行健康检查。
