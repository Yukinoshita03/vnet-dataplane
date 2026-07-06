# Parallels 测试环境：网络拓扑与操作手册

本文档描述在 macOS Parallels Desktop 上搭建 eBPF/XDP 开发测试环境的网络拓扑、VM 配置和常用操作流程，供 Codex 等自动化工具直接参考。

---

## 1. 网络拓扑

```
macOS Host (tankaiwen's MacBook)
│
├── Parallels 虚拟交换机 (Shared Network, 10.211.55.0/24)
│   └── Ubuntu 24.04 ARM64 / ceph-node1  10.211.55.6   ← 当前可用 VM，先做单机实跑
│
└── Host-Only 网段 (10.37.129.0/24) — 备用，host↔VM 直连调试用
```

当前阶段先以单 VM 实跑为主，后续再扩展到双 VM 拓扑。

---

## 2. VM 基本信息

| 字段 | vm-dev | vm-test |
|------|--------|---------|
| OS | Ubuntu 24.04 LTS | 后续扩展 |
| 内核 | 6.8.0-117-generic | 后续扩展 |
| IP | 10.211.55.6/24 | 后续扩展 |
| 网卡 | bond0 | 后续扩展 |
| 用户 | root / parallels | 后续扩展 |
| SSH | `ssh parallels@10.211.55.6` | 后续扩展 |

---

## 3. eBPF 程序加载流程

### 3.1 编译

在当前 VM 上：

```bash
cd /media/psf/iCloud/Desktop/ebpf-network-service-cache
./scripts/build_linux.sh
```

依赖：`clang-14`, `libbpf-dev`, `linux-headers-$(uname -r)`

### 3.2 挂载 XDP 程序

```bash
# 挂 native XDP（需要驱动支持，virtio-net 支持）
ip link set dev eth0 xdp obj bpf/xdp_prog.o sec xdp

# 验证
bpftool net show
ip -d link show eth0 | grep xdp

# 卸载
ip link set dev eth0 xdp off
```

### 3.3 挂载 TC BPF 程序

```bash
# 建 clsact qdisc
tc qdisc add dev eth0 clsact

# 挂 ingress / egress
tc filter add dev eth0 ingress bpf direct-action obj bpf/tc_ingress.o sec tc
tc filter add dev eth0 egress  bpf direct-action obj bpf/tc_egress.o  sec tc

# 验证
tc filter show dev eth0 ingress
tc filter show dev eth0 egress

# 卸载
tc qdisc del dev eth0 clsact
```

### 3.4 Pin BPF map

```bash
# loader 通常自动 pin，手动 pin 示例
bpftool map pin id <map_id> /sys/fs/bpf/my_map

# dump map 内容
bpftool map dump pinned /sys/fs/bpf/my_map
```

---

## 4. 连通性验证

### 基本 ping

```bash
# vm-dev → vm-test
ping -c 4 10.211.55.11
```

### IPIP 隧道验证

```bash
# vm-dev
ip tunnel add ipip0 mode ipip local 10.211.55.10 remote 10.211.55.11 ttl 64
ip link set ipip0 up
ip addr add 192.168.100.1/30 dev ipip0

# vm-test
ip tunnel add ipip0 mode ipip local 10.211.55.11 remote 10.211.55.10 ttl 64
ip link set ipip0 up
ip addr add 192.168.100.2/30 dev ipip0

# 验证封装
ping 192.168.100.2                          # vm-dev 上
tcpdump -i eth0 proto 4 -n                  # 看到 proto IPIP 外层包
```

### HTTP 连通

```bash
# vm-test 上启 nginx
docker run -d -p 80:80 nginx

# vm-dev 上验证
curl http://10.211.55.11/
```

---

## 5. 性能测试

### TCP 带宽（iperf3）

```bash
# vm-test（server）
iperf3 -s

# vm-dev（client）
iperf3 -c 10.211.55.11 -M 1400 -P 4 -t 30
```

### 短连接 / 往返时延（netperf）

```bash
# vm-test
netserver

# vm-dev
netperf -H 10.211.55.11 -t TCP_RR  -l 30 -- -r 64,64   # 往返时延吞吐
netperf -H 10.211.55.11 -t TCP_CRR -l 30 -- -r 64,64   # 短连接速率
```

### DNS 延迟

```bash
# 单次查询延迟
dig example.com | grep "Query time"

# 批量压测（dnsperf）
dnsperf -s 1.1.1.1 -d query.txt -l 30
```

---

## 6. 调试常用命令

```bash
# 查看所有挂载的 XDP/TC 程序
bpftool net show

# 查看 eBPF 程序列表（含加载时间）
bpftool prog show

# 实时查看 bpf_trace_printk 输出
cat /sys/kernel/debug/tracing/trace_pipe

# 抓包验证转发路径
tcpdump -i eth0 -n -e      # 看 MAC 地址，确认 L2 转发
tcpdump -i eth0 proto 4 -n # 只看 IPIP 包

# 内核日志（verifier 报错看这里）
dmesg | tail -20
```

---

## 7. 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| `xdpgeneric` 性能差 | 走 skb 路径 | 改用 `xdpdrv`（需驱动支持） |
| TC filter 报 "sharing filter block" | 挂在 bond slave 上 | 改挂 bond 主接口或用 shared block |
| BPF verifier 拒绝程序 | 循环上界/未初始化变量/map value 越界 | 看 `dmesg`，加 `volatile` 或显式初始化 |
| `bpftool map dump` 无输出 | map 是 per-CPU 类型 | 加 `--pretty` 或用 `bpftool map dump id <id>` |
| virtio-net 不支持 XDP native | 老版 Parallels 驱动 | 升级 Parallels Tools 或改用 `xdpgeneric` 测功能 |
| ping 通但 eBPF 没走 | XDP 返回了 XDP_PASS | 在 prog 里加 `bpf_trace_printk` 确认是否命中 |
