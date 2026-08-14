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
| `system` baseline | 76,029.5 | 40.725 | 77.284 | 88.565 | 0 | 1.0000× | 1.0000× |
| `afxdp` generic | 329,764 | 11.732 | 13.896 | 15.035 | 0 | **4.3373×** | **5.8906×** |

逐轮原始 QPS：

- `system`: 77,013.1、76,029.5、76,793.8、75,468.8、75,398.9。
- `afxdp`: 317,045、329,340、334,839、329,764、333,777。

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
REPETITIONS=5 THREADS=4 REQUESTS=25000 WARMUP=1000 \
OUT_DIR=/tmp/ovs-afxdp-paper/formal-YYYYMMDD-v1 \
bash bench/ovs_afxdp_paper_host_bench.sh
```

辅助 correctness/debug 脚本：

- `bench/ovs_udp_datagram_smoke.sh`：验证 OVS `system`/`afxdp` 的 UDP 收发与校验和卸载处理；
- `bench/udp_direct_veth_smoke.sh`：隔离验证 client 的持久 UDP benchmark 本身。

源文件 SHA-256：

```text
bench/ovs_afxdp_paper_host_bench.sh  ad2401200b8e4dd4d5680785fc6596dda6573dc42a4c391ac5fe5f50c9c10c0b
bench/ovs_udp_datagram_smoke.sh      1ed1b9064e7ddbd4d7a1f30ef183a220b7a70a1c9c38456977c2eadd5418ba0d
bench/udp_direct_veth_smoke.sh       72703cf2be1709e4d56672c45f346c5a49c7f4ed3838ce2bb055ce9fec0ff440
bench/udp_fastpath_bench.cpp         74df8fdbaf88efaaccc74f724b51dc0c39340c925cca58b6607d3e86e455b303
```

## 解释边界

OVS AF_XDP 的 4.3373× 是“OVS userspace system port → OVS AF_XDP port”的数据面提升；BMC 的 1.3207× 是“同一 OpenStack VM/TAP Memcached UDP workload 中 linux_accel → BMC”的应用协议缓存提升。两者不能合并成一个总加速比，也不能据此说 linux_accel 在所有场景都比 OVS AF_XDP 高；它们优化的层次不同：前者是 packet I/O/datapath，后者是协议解析、缓存命中与响应生成。

## 当前现场恢复

- Kubernetes 相关 unit 在 node1/node2/node3 均保持 `inactive`。
- OVS 临时 bridge、namespace、veth 已清理。
- `br-int`、现有 OpenStack TAP 与 linux_accel DNS/gRPC hooks 未被 runner 接管。
- OpenStack client VM 的原始状态是 `SHUTOFF`；本轮 OVS 隔离实验没有改变其 TAP 路径。后续结束 OpenStack live 检查时仍需把已启动的 client VM 恢复为 `SHUTOFF`，并再次执行健康检查。
