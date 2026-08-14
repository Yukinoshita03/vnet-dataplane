# 通用 UDP 与 LDAP/LDAPS 快路径实验报告

日期：2026-08-06  
目标环境：学校三节点 OpenStack 集群，Linux `7.0.0-14-generic`，x86-64

## 结论

本轮新增的两条路径都已实现、构建并在真实集群验证，但它们解决的问题不同：

- 可配置 UDP exact-hit 快路径是明确的延迟和吞吐加速。在 OpenStack 客户端
  TAP 上，最终 v2 的 8 线程 quick 负载吞吐提升 `4.103x`，p99 改善 `2.032x`；16 线程
  full 负载的吞吐提升 `2.535x`。所有命中请求都在 TAP 的 generic XDP 返回，
  后端 VM 未收到这些请求。
- 未配置的 UDP 请求继续走正常 OpenStack/OVS/后端路径。quick 测试中 XDP miss
  的吞吐是 nohook 的 `0.992x`、p99 值是 `1.015x`，属于本轮噪声范围内，没有测到
  可辨识的 pass-path 退化。
- LDAP/LDAPS 不能安全地按内容缓存或伪造响应。本轮实现的是透明 TCP 连接转发：
  userspace copy、Linux `splice(2)` 和 eBPF sockmap 三种模式。
- 跨三台物理节点时，sockmap 将代理进程自身 CPU 从 `8.09` CPU 秒降到
  `0.01` CPU 秒，但吞吐比 userspace 低 `12.1%`，p99 高 `14.2%`。因此它目前是
  CPU offload 模式，不应宣传成低延迟加速；面向延迟/吞吐的默认模式仍应是
  userspace，CPU 预算严格时才选择 sockmap。
- 真实 TLS 握手和加密响应已穿过 sockmap，且无 userspace fallback、redirect
  failure 或 relay error，说明同一实现可透明承载 LDAP 和 LDAPS。

## 实现范围与正确性边界

### UDP exact-hit

UDP map key 包含：

```text
{ ingress ifindex, server IPv4, server UDP port, request length, request bytes }
```

map value 包含有限租约和精确响应 payload。当前约束如下：

- 仅处理无 IPv4 options、未分片的 IPv4 UDP；
- 请求和响应 payload 上限均为 64 字节；
- 只允许控制面显式下发的确定性、无副作用 exchange；
- 命中后交换二层地址、IPv4 地址和 UDP 端口，重算 IPv4 checksum，以
  `XDP_TX` 原路返回；IPv4 UDP checksum 使用协议允许的零值；
- miss、过期、畸形、分片和超长请求全部 fail open；
- key 包含 ingress ifindex，避免不同 OpenStack TAP/租户之间共享私网条目；
- loader 使用 `XDP_FLAGS_UPDATE_IF_NOEXIST`，不会覆盖已有 XDP 程序；退出时按
  program FD 所有权卸载，避免误卸其他程序。

这不是“任意 UDP 代理缓存”。它适合健康探测、固定服务发现应答、短租约
控制响应等语义稳定的 exchange，不适合有 nonce、认证、计数器、事务或副作用的
协议流量。

### LDAP/LDAPS 连接快路径

LDAP Bind、Search、StartTLS、message ID、认证状态和目录更新都具有连接或服务端
状态，因此没有在 XDP 中解析、缓存或重放 LDAP 内容。三种透明模式为：

| 模式 | 数据路径 | 适用场景 |
| --- | --- | --- |
| `userspace` | `recv` + `send` | 当前延迟/吞吐默认基线 |
| `splice` | socket → pipe → socket | 避免用户态 payload copy；需按实际内核复测 |
| `sockmap` | SK_SKB stream parser/verdict + SOCKHASH redirect | 降低代理进程 CPU；数据仍由内核 TCP 栈处理 |

sockmap 使用 `SO_COOKIE` 作为连接键，双向 peer map 只在连接存活期间存在。关闭
竞态中 redirect 失败时返回 `SK_PASS`，让代理线程接管剩余字节，而不是 `SK_DROP`。
性能模式默认不对成功的每个 skb 计数，只保留 pair、fallback、peer miss 和
redirect failure 等低频/异常观测。

## 测试拓扑

### Linux netns UDP

```text
client netns -- veth -- Linux bridge -- veth -- server netns
                       ^
                       generic XDP on client-side host veth
```

每轮 8 个持久 UDP socket，每线程 25,000 次计时请求和 1,000 次 warmup，共三轮。

### OpenStack UDP

```text
linux-accel-client VM (192.168.110.18)
        |
        | TAP tap96696c4a-57: nohook / generic XDP
        v
OVN/OVS overlay
        |
        v
linux-accel-backend VM (192.168.110.13)
```

实验临时停止客户端 TAP 上原有的 DNS XDP+TC systemd 单元，按 nohook、XDP miss、
XDP exact hit 顺序运行，并通过 trap 恢复原单元。物理网卡上的 native DNS XDP
没有改动。

### 跨节点 LDAP

```text
node2 persistent LDAP client
        |
        v
node1 userspace / splice / sockmap proxy
        |
        v
node3 LDAPv3 BER benchmark backend
```

每种代理模式运行三轮；每轮 8 条持久 TCP 连接、每线程 20,000 次 Search、
4 KiB Search entry 响应、pipeline 1。每条连接先执行真实 LDAPv3 anonymous Bind。

## 结果

### UDP：Linux netns 三轮中位数

| 模式 | QPS | p99 | 后端响应包 | QPS 比 | p99 改善比 |
| --- | ---: | ---: | ---: | ---: | ---: |
| userspace backend | 329,821 | 28.294 μs | 约 208k/轮 | 1.000x | 1.000x |
| generic XDP exact hit | 3,242,280 | 2.509 μs | 0 | `9.830x` | `11.277x` |

三轮单独的 QPS 提升为 `10.091x`、`9.689x` 和 `9.806x`；零失败。

### UDP：OpenStack quick，三轮中位数

| 模式 | QPS | p99 | 相对 nohook QPS | p99 值比 |
| --- | ---: | ---: | ---: | ---: |
| nohook → backend VM | 82,349.9 | 130.496 μs | 1.000x | 1.000x |
| generic XDP miss → backend VM | 81,675.9 | 132.509 μs | `0.992x` | `1.015x` |
| generic XDP exact hit | 337,862 | 64.233 μs | `4.103x` | `0.492x` |

nohook 和 miss 各有 252,000 次（包含 warmup）到达后端；exact-hit 的 252,000 次
全部体现在 loader 的 `hit=252000 tx=252000`，后端计数没有继续增长。

### UDP：OpenStack full，五轮中位数

| 模式 | QPS | p50 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: |
| nohook → backend VM | 137,152 | 113.166 μs | 145.803 μs | 164.812 μs |
| generic XDP exact hit | 347,664 | 37.128 μs | 102.887 μs | 149.197 μs |
| 改善比 | `2.535x` | `3.048x` | `1.417x` | `1.105x` |

full 负载使用 16 线程、每线程 50,000 次请求、五轮。更高并发下单队列 TAP 和
客户端调度开始主导尾部，因而 p50 仍有明显收益，但 p99 收敛；不能只用低并发
p99 外推饱和状态。

### LDAP：跨三节点三轮中位数

| 路径 | QPS | p99 | 相对 userspace QPS | userspace p99 / 当前 p99 |
| --- | ---: | ---: | ---: | ---: |
| direct，绕过代理 | 26,386.5 | 411.609 μs | — | — |
| userspace proxy | 18,670.0 | 548.557 μs | 1.000x | 1.000x |
| splice proxy | 18,293.9 | 558.841 μs | `0.980x` | `0.982x` |
| sockmap proxy | 16,415.5 | 626.312 μs | `0.879x` | `0.876x` |

三轮累计转发约 2.04 GB。以 node1 `CLK_TCK=100` 的代理进程 `/proc/PID/stat`
计算：

| 模式 | 代理进程 CPU 时间 | 每个计时请求的代理进程 CPU |
| --- | ---: | ---: |
| userspace | 8.09 s | 16.85 μs |
| splice | 8.34 s | 17.38 μs |
| sockmap | 0.01 s | 0.02 μs |

这里的 CPU 只统计代理进程，不包含 NET_RX/NET_TX softirq、TCP 栈和 BPF 在内核中
消耗的 CPU。因此 `99.876%` 是“代理进程 CPU 降幅”，不是整机 CPU 降幅。下一步
若要把 sockmap 作为容量方案，应补全 node-level cycles、softirq 和每核利用率，
并在代理 CPU 真正成为瓶颈的高连接数场景寻找交叉点。

### LDAPS 透明性

测试生成短期自签证书，通过 sockmap proxy 完成真实 TLS 握手和加密响应。最终
指标为：

```text
sockmap_pairs > 0
fallback_bytes = 0
redirect_fail = 0
relay_error = 0
```

这项测试验证 TLS 字节流透明性，不等价于生产证书、目录 ACL 或真实 LDAP server
兼容性认证。

## 构建、测试与复现

正式 Linux 构建：

```bash
./scripts/build_linux.sh
```

UDP BPF 包级与 netns 测试：

```bash
sudo ./tests/run_udp_fastpath_test.sh
sudo THREADS=8 REQUESTS=25000 WARMUP=1000 \
  ./bench/udp_fastpath_bench.sh
```

LDAP、splice、sockmap 与 LDAPS 测试：

```bash
sudo LDAP_RESPONSE_BYTES=4096 LDAP_TLS_SMOKE=1 \
  ./tests/run_ldap_sockmap_test.sh
./bench/ldap_cluster_bench.sh artifacts/ldap-cluster quick
```

OpenStack TAP quick/full 基准：

```bash
./bench/openstack_udp_fastpath_bench.sh artifacts/openstack-udp-quick quick
./bench/openstack_udp_fastpath_bench.sh artifacts/openstack-udp-full full
```

本轮原始输出位于本地忽略目录：

```text
artifacts/protocol-fastpath/20260806-032040/
```

三节点已校验的制品：

| 制品 | SHA-256 |
| --- | --- |
| `linux-accel-udp-release-v2-linux-amd64.tar.gz` | `6a4177c00b4c2d61da976feae53096a7f805a834425442048d2c3b6efd5d2934` |
| `linux-accel-ldap-release-v4-linux-amd64.tar.gz` | `00a8c985a2d1d09f2f57a27bdc4d0c72b323da7390635674ab8b7442c9a86440` |
| `linux-accel-protocol-fastpath-20260806-v1-linux-amd64.tar.gz` | `f8586b79135b8390f0bc1d57fb120653331a5657b0f8f0316edc541808529cb5` |
| `linux-accel-full-source-v2.tar.gz` | `f198f94431dd175f39ff632fb1fc94df87267b27fc48cdc8230e3da98fe04010` |

合并后的生产制品已安装到三节点：

```text
/opt/linux-accel-protocol-fastpath/releases/linux-accel-protocol-fastpath-20260806-v1
/opt/linux-accel-protocol-fastpath/current -> releases/linux-accel-protocol-fastpath-20260806-v1
```

部署只安装版本化 binary/BPF object、benchmark 和策略样例，不会在没有明确 UDP
policy 或 LDAP backend 的情况下自动挂载 XDP/启动 proxy。

## 集群收尾状态

- OpenStack Horizon、Keystone、Nova、Placement、Neutron API 在实验前后正常；
- OVN Controller/Metadata agents 三节点为 up；
- 原有客户端 TAP DNS generic XDP 和 tc egress 已恢复；
- node1 物理网卡原有 native DNS XDP 保持挂载；
- kubelet、containerd、kubernetes-haproxy 三节点始终为 inactive；
- 既有异常未被本实验改变：node1/node3 的 `nova-scheduler` 仍显示 down，
  Neutron inventory 中 node1 的 legacy Open vSwitch agent 仍为 False，而 OVN agents
  正常。这些是实验前已存在的控制面状态，需在独立维护窗口继续修复。
