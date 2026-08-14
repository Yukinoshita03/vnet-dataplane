# src

本目录保存用户态控制面和服务 demo 代码。

主要组件包括：

- `dns_monitor.cpp`：程序入口、tc/XDP 挂载与生命周期控制。
- `dns_monitor_args.cpp`：命令行参数解析和使用说明。
- `dns_monitor_metrics.cpp`：ringbuf 事件处理、pending/timeout 跟踪和每秒指标输出。
- `arp_proxy_control.cpp`：multi-tap/multi-target ARP policy 文件校验、map 下发、generation/lease 续租和退出 disable。
- `policy_reconciler.cpp`：按 `cluster/source` 合并 canonical ARP snapshot，处理 revision、租约和跨 source 冲突。
- `policy_feed.cpp`：本地 AF_UNIX `SOCK_SEQPACKET` v1 feed server；云平台 adapter 不直接触碰 BPF map。
- `grpc_monitor.cpp`：gRPC tc 监控用户态加载器。
- `grpc_fast_cache.cpp`：gRPC h2c fast-cache/proxy 原型。
- `udp_fastpath.cpp`：显式 UDP request/response 策略解析、map 续租、generic/native XDP 所有权挂载和统计。
- `udp_fastpath_policy.cpp`：DNS/UDP 合并 loader 与独立 UDP loader 共用的 policy 解析、map 下发和 lease 时间基准。
- `dns_monitor.cpp` 的 `--udp-policy-file`：同一网卡用一个 `xdp_dispatcher` root hook 组合 DNS/ARP/DHCP 与 UDP；不同网卡保持独立 hook。
- `ldap_sockmap_proxy.cpp`：LDAP/LDAPS 透明 TCP proxy，支持 userspace、`splice(2)` 和 eBPF sockmap 三种转发模式。
- `campus_net_guard.cpp`：校园网连通性探测、Cookie 保持和掉线后的可配置表单/JSON 认证守护程序。
- `include/packet_parser.hpp`：协议解析与服务分类工具的公共数据结构和接口声明。
- `packet_parser.cpp`：用户态 L2-L4 协议解析模块，负责 Ethernet / IPv4 / TCP / UDP 头解析。
- `virt_service_classifier.cpp`：面向 `veth / tap / bridge` 虚拟化路径的原始帧服务分类工具，可识别 DNS / gRPC / other。
- `cache policy manager`：双端缓存策略控制面逻辑。
