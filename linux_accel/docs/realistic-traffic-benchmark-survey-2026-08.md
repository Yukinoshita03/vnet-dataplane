# 类真实流量 Benchmark 调研

日期：2026-08-06

## 结论

网上确实有比 `pktgen`、`xdp-bench` 更接近真实业务的方案，但它们解决的问题不同：

1. **TRex ASTF/EMU**：最适合模拟有状态的用户流量和多协议终端行为。ASTF 可生成 TCP/UDP 及 L7 profile，EMU 覆盖 ARP、DHCP、DNS、ICMP 等终端协议行为；适合作为独立流量发生器，压测 OpenStack VM/TAP/OVS/OVN 链路。
2. **NFVBench + TRex**：最适合验证 OpenStack/NFV 数据面本身，支持 PVP/PVVP/多服务链、IMIX、固定速率、NDR/PDR、丢包和时延统计。它更偏“真实 OpenStack 转发路径”，而不是完整的应用层业务仿真。
3. **tcpreplay**：最适合重放真实抓包，保留原始包的协议组合和时间间隔，也可以改写二层/三层地址。它是无状态重放，不能自然处理 ARP 学习、TCP 会话建立和业务响应，因此适合做流量形状验证，不适合作为唯一的端到端 benchmark。
4. **dnsperf/resperf**：适合 DNS 应用层基准。它比单纯发 UDP 包更接近真实 DNS 请求/响应，但仍然主要覆盖 DNS 业务，不代表完整的 VM 外联流量。
5. **MoonGen**：适合需要精确时间戳、可编程报文和高 PPS 的实验。它本身不是现成的“真实业务模型”，通常需要自己用 Lua 编写协议/流模型。

## 对比表

| 工具 | 流量真实性 | 是否有状态 | OpenStack 适配 | ARP/DNS 适配 | 主要限制 |
|---|---|---:|---:|---:|---|
| TRex ASTF/EMU | 高 | 是 | 中/高 | 高 | 通常需要独立 DPDK 网卡和流量发生器主机 |
| NFVBench + TRex | 高（数据面） | 主要是转发流 | 高 | 中 | 需要外部双口 DPDK 测试机，当前集群没有现成条件 |
| tcpreplay | 高（包形状） | 否 | 高 | 低/中 | 不会自动完成真实会话、ARP 学习和响应 |
| dnsperf/resperf | 中/高（DNS） | 请求级 | 中 | 高 | 只代表 DNS 工作负载 |
| MoonGen | 可编程 | 由脚本决定 | 中 | 可编程 | 需要 DPDK、绑核、hugepages 和专用端口 |
| pktgen/xdp-bench | 低（微基准） | 否 | 低 | 低 | 适合测 PPS/路径开销，不像业务流量 |

## 对当前三节点集群的判断

当前节点上已有 `dnsperf/resperf` 所需的 DNS 测试路径和自定义 UDP/ARP client；没有现成的 TRex、NFVBench、MoonGen、`xdp-bench` 或 `pktgen`。集群节点是离线环境，且当前物理链路没有专门的双口 DPDK 流量发生器。

因此分两层做最合适：

- **近期、无需新增硬件**：继续使用 `dnsperf/resperf` 做真实 DNS 请求分布，同时把现有 `physical_xdp_burst_client` 扩展为持久 socket、多线程、固定 CPU、批量收发、混合 qtype/命中率/并发度；ARP 单独使用持久 AF_PACKET client。这样能直接比较 userspace、generic XDP、native XDP 在当前 OpenStack/物理路径上的真实效果。
- **后续、需要更接近生产流量**：在集群外准备一台至少双口、支持 DPDK 的流量发生器，优先部署 TRex；若要系统化测 OpenStack PVP/PVVP/服务链，再用 NFVBench 调度 TRex。流量发生器通过专用端口接入测试网络，不应与管理 SSH 链路共用。

## 推荐的测试组合

```text
DNS 业务真实性：dnsperf/resperf
        + 热缓存 / 冷缓存 / NXDOMAIN / AAAA / CNAME / 混合 qtype

OpenStack 转发真实性：NFVBench + TRex（需要外部双口 DPDK 主机）
        + PVP / PVVP / IMIX / 多流 / NDR-PDR / 时延 / 丢包

真实包形状回放：tcpreplay（隔离测试网）
        + 真实 pcap / 原始时间间隔 / 指定速率

XDP 本身的极限：xdp-bench / pktgen / MoonGen
        + 只用于拆分 datapath 上限，不作为最终业务结论
```

## 本轮建议

对我们当前问题，最有价值的不是直接装一个 PPS 工具，而是先做一套“业务流量 + 数据面路径”的组合基线：

1. 使用现有 `dnsperf/resperf` 生成多种 DNS 分布，测 p50/p95/p99、QPS、丢包、CPU、softirq 和上下文切换。
2. 使用持久 AF_PACKET/UDP client 对 ARP 和 DNS miss path 做并发测试，避免每请求 `socket()` 带来的额外噪声。
3. 把 userspace、generic XDP、native XDP 三种模式放在同一物理入口、同一 CPU/IRQ 亲和性、同一流量分布下比较。
4. 有专用测试机后，再用 TRex ASTF/EMU 生成有状态混合流量；不要把 `xdp-bench` 的结果直接当成业务加速比。

## 官方资料

- [TRex 官方主页](https://trex-tgn.cisco.com/)
- [TRex ASTF 文档](https://trex-tgn.cisco.com/trex/doc/trex_astf.html)
- [TRex 用户手册](https://trex-tgn.cisco.com/trex/doc/trex_manual.html)
- [NFVBench Testing User Guide](https://artifacts.opnfv.org/nfvbench/docs/testing_user_userguide/index.html)
- [tcpreplay Quick Start](https://tcpreplay.appneta.com/getting-started/quickstart/)
- [MoonGen 官方仓库](https://github.com/emmericp/MoonGen)
- [xdp-tools 官方仓库](https://github.com/xdp-project/xdp-tools)
- [Linux kernel pktgen 文档](https://docs.kernel.org/networking/pktgen.html)
