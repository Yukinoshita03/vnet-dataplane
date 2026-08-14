# ARP Proxy multi-tap

ARP Proxy 是 `dns_monitor` 里的一个受限 L2 快路径：它只回答控制面明确
下发的 `{tap ifindex, target IPv4}`，不从 ARP reply、邻居表或广播流量自动
学习。默认网关不再是特殊字段，只是最常见的一条 target binding。

## 数据面模型

每个 XDP object 都包含同一个 `bpf/arp_proxy.h` handler 和三张 map：

| map | key | value | 用途 |
| --- | --- | --- | --- |
| `arp_tap_states` | `ifindex` | `generation`, `flags`, `expires_ns` | tap 作用域、开关和整组 lease |
| `arp_bindings` | `ifindex + target_ipv4` | target MAC、generation、lease | 一个 tap 的多个显式 target |
| `arp_proxy_stats` | reason 枚举 | per-CPU counter | request、TX、miss、拒绝和过期计数 |

合法输入必须是 Ethernet/IPv4 ARP broadcast request，Ethernet source 与 ARP
SHA 一致，SPA 非零且不等于 TPA。tap state 和 binding 都存在、启用、同一
generation 且未过期时，程序才会原地改成 reply 并 `XDP_TX`：

```text
Ethernet dst = request source MAC
Ethernet src = configured target MAC
ARP SHA/SPA  = configured target MAC / request TPA
ARP THA/TPA  = request SHA / request SPA
```

其余情况都逐字节保持原包并返回 `XDP_PASS`，不会 `XDP_DROP` 或自动学习。

## 静态控制面

策略文件是一行一条 binding：

```text
# tap_ifname  target_ipv4  target_mac             lease_seconds
tap-vm-a      10.0.0.1     fa:16:3e:aa:bb:cc      30
tap-vm-a      10.0.0.2     fa:16:3e:dd:ee:ff      30
tap-vm-b      10.0.0.1     fa:16:3e:11:22:33      30
```

加载前会校验接口存在、IPv4/MAC 格式、lease 范围（1～86400 秒）以及同一
tap 内的重复 target。`--arp-lease-seconds` 可选地把整个文件的 lease 覆盖
为同一个值：

```bash
sudo ./build/dns_monitor \
  --hook xdp --role server --xdp-mode generic \
  --bpf-object build/dns_xdp_monitor.bpf.o \
  --arp-policy-file /etc/yukinonet/arp-policy.conf \
  --arp-lease-seconds 30
```

没有 `--arp-policy-file` 时，现有单接口 DNS/tc/XDP 行为不变。提供策略文件
后可以省略 `--dev`；如果同时提供 `--dev`，该接口会作为额外的 DNS/XDP
挂载点，但只有策略文件列出的 tap 会有 ARP state。

控制面流程是：

1. 一次 open/load BPF object，解析并校验全部 tap。
2. 先写新 generation 的 binding，再切换 tap state；切换前不挂载任何 tap。
3. 把同一个 XDP program fd 逐个 attach 到所有 tap；中途失败会清理已经
   attach 的接口。
4. 进程运行期间每 10 秒续租。续租失败不切换 generation，旧 tap lease
   到期后自动 fail-open。
5. 正常退出先清零全部 tap state，再执行 owner-FD 保护的 detach。

## OpenStack 静态 Adapter

`scripts/openstack_tap_accel.sh` 仍负责单个 Neutron port 的 TAP identity
校验；如果要同时启用 ARP Proxy，可设置：

```bash
export OPENSTACK_ARP_POLICY_FILE=/etc/yukinonet/arp-policy.conf
export OPENSTACK_ARP_LEASE_SECONDS=30   # 可选
export OPENSTACK_ARP_POLICY_FEED=/run/yukinonet/arp-policy.sock  # 可选
```

Adapter 不查询 Neutron/OVSDB，也不从 `OPENSTACK_EXPECTED_MAC` 推导 binding
字段；操作者生成的静态文件才是 target MAC 的来源。策略中任一 tap 不存在
或内容非法，`dns_monitor` 都会在 attach 前拒绝启动。

需要让 OpenStack 与 Kubernetes 等多个集群共同提供策略时，推荐使用统一的
`YUKINONET_POLICY/1` feed。Adapter 发送自己的完整 snapshot，loader 按
`cluster/source/revision` 做合并、租约和冲突检查；详细 wire format 与权限边界见
[`policy-feed.md`](policy-feed.md)。

## 验证

包级测试加载两个真实生产 object：

```bash
./tests/run_arp_proxy_xdp_prog_test.sh
```

真实 veth 测试建立两个 network namespace，把同一个 server object 挂到两
个 host-side veth，验证同一个 target IP 在不同 tap 上返回不同 MAC，并在
owner 被 `SIGKILL` 后等待 lease 过期确认不再回复：

```bash
sudo ./tests/run_arp_proxy_veth_test.sh
```

这两个测试只证明 generic XDP 和 Linux veth 路径；不把结果外推成物理 NIC
native XDP 或 OpenStack OVS datapath 的性能结论。OpenStack 环境若已有 OVS
原生 ARP responder，应先记录其配置，避免重复代答。
