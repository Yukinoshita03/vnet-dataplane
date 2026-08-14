# yukinoNet ARP Policy Feed

`dns_monitor` 的 ARP 控制面现在分成三层：

```text
OpenStack / Kubernetes adapter
          |
          |  AF_UNIX SOCK_SEQPACKET, YUKINONET_POLICY/1
          v
      PolicyFeedServer
          |
          v
      PolicyReconciler  ---- source-scoped revision / lease / conflict
          |
          v
      ArpProxyControl   ---- 唯一允许写 BPF maps 的模块
```

云平台适配器不需要链接 libbpf，也不需要知道 `arp_tap_states` 或
`arp_bindings` 的 map ABI。它只负责把本集群观察到的完整快照发送给
`dns_monitor`。因此 OpenStack Neutron、Kubernetes CNI，甚至离线配置工具
都可以共用同一个 feed 接口。

## 启动

仅使用动态 feed（没有静态文件）时，可以让 feed 自己提供 tap：

```bash
sudo ./build/dns_monitor \
  --hook xdp --role server --xdp-mode generic \
  --bpf-object build/dns_xdp_monitor.bpf.o \
  --arp-policy-feed /run/yukinonet/arp-policy.sock \
  --arp-feed-startup-timeout-ms 5000
```

没有 `--dev` 时，进程会等待第一份非空快照，以便知道应该把 XDP 程序挂到
哪些 tap。若已经有一个固定的监控接口，可以同时指定 `--dev`；这时进程可在
没有初始策略的情况下启动，之后由 feed 动态增加 tap。

静态文件可以和 feed 并存：

```bash
sudo ./build/dns_monitor --hook xdp --role server --dev br-int \
  --arp-policy-file ./config/arp-policy.conf \
  --arp-policy-feed /run/yukinonet/arp-policy.sock
```

静态文件被视为 `local/policy-file` 的持久 source；feed source 仍然受租约
控制。两者若声明同一个 `{tap_ifname, target_ipv4}`，更新会被拒绝，而不是
随机选择某一个 MAC。

## v1 wire format

每次 `send()` 必须发送一整条 `SOCK_SEQPACKET` 消息，不能拆成多次 stream 写入。
消息是 ASCII 文本，最大 64 KiB，字段以空白分隔。

替换某个 source 的完整快照：

```text
YUKINONET_POLICY/1 REPLACE <cluster> <source> <revision> <lease_seconds> <count>
<tap_ifname> <target_ipv4> <target_mac> <binding_lease_seconds>
...
```

例子：

```text
YUKINONET_POLICY/1 REPLACE openstack neutron 42 30 2
tap-vm-a 10.0.0.1 fa:16:3e:aa:bb:cc 30
tap-vm-b 10.0.0.1 fa:16:3e:11:22:33 30
```

删除一个 source：

```text
YUKINONET_POLICY/1 WITHDRAW <cluster> <source> <revision>
```

`cluster + source` 是 source 的稳定身份，`revision` 必须单调递增。重复发送
相同 revision 和相同内容会刷新租约并保持幂等；相同 revision 但内容不同会被
拒绝；更旧的 revision 不会覆盖新状态。source 即使因 lease 过期或 withdraw
而被移除，reconciler 仍保留最后 revision tombstone，防止延迟旧消息复活旧配置。
`lease_seconds` 是 source 快照的存活时间，范围为
1–86400 秒；每条 binding 还有独立的数据面 lease。

## 适配器约定

OpenStack 适配器建议以 `cluster_id=openstack`、`source_id=neutron-<node>`
标识自己。它监听 Neutron port/tap 生命周期，收到变化后重新生成该 source
的完整列表，而不是发送单条增量操作。Kubernetes 适配器可使用
`cluster_id=kubernetes`、`source_id=cni-<node>`，把 pod veth 和目标网关的
映射转换成相同的 canonical binding。

适配器应遵守以下规则：

1. 启动时发送当前完整快照。
2. 每次成功同步后递增 revision；重连后继续使用持久化的 revision。
3. 资源删除后发送空的 `REPLACE`，或者发送更高 revision 的 `WITHDRAW`。
4. 不要直接写 BPF map；所有 map 更新、generation 切换、失效和回滚都由
   `ArpProxyControl` 统一完成。
5. 不同 source 不得争抢同一个 `{tap_ifname, target_ipv4}`。同一私网地址在
   不同 tap 上出现是合法的，因为 tap/ifindex 是 key 的一部分。

## 权限与故障语义

socket 默认只允许 `dns_monitor` 的有效 UID 以及 root 通过 `SO_PEERCRED` 连接。
可以显式指定：

```bash
--arp-policy-feed-uid 1001
```

feed 客户端掉线不会立即清理最后一份策略；source 会在 lease 到期后从
`PolicyReconciler` 移除，随后 `ArpProxyControl` 禁用对应 tap。单条坏消息只会
被记录并丢弃，不会污染当前 snapshot。进程收到 SIGINT/SIGTERM 时先禁用所有
ARP tap，再卸载网络程序。
