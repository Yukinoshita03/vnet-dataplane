# OpenStack 数据面 Agent

`agent/openstack_dataplane_agent.py` 在每个 OpenStack Compute 节点运行，
自动把指定 VM 的 Neutron 端口解析为本机 OVS 接口，并保持 DNS/gRPC eBPF
程序与当前接口一致。

## 模块接口

Agent 只暴露两个命令：

- `discover`：只读输出 `server -> port -> host -> interface -> ifindex` JSON。
- `watch`：周期执行 reconcile，拥有 monitor 进程并在退出时清理自己的 hook。

实现内部使用三层信息，不根据 UUID 前缀猜 tap 名称：

1. `openstack port list/show` 确认端口属于目标实例、状态为 `ACTIVE`、
   `binding_host_id` 为本机且 `binding_vif_type=ovs`。
2. OVSDB `Interface.external_ids:iface-id` 精确解析 Linux 接口。
3. `ip -j link` 回读接口和 ifindex。

如果 OVSDB 返回零个或多个接口，Agent 拒绝挂载。OpenStack/OVS 查询暂时失败时，
Agent 保留现有挂载并重试，不会把控制面故障误判为迁移。

## Reconcile 语义

```text
Neutron binding 在本机 + OVS interface 存在
  -> 首次 attach DNS client XDP/TC + gRPC TC
  -> 同一 port/interface/ifindex 重复轮询不操作

ifindex 或 interface 改变
  -> detach 旧 hook
  -> attach 新接口

binding 移出本机
  -> 等待 missing_grace_cycles
  -> detach 源端

binding 迁入本机且接口就绪
  -> attach 目标端
```

因此真实迁移需要在每个可能的 Compute 节点都运行同一 Agent 配置。源端 Agent
看到端口离开后卸载，目标端 Agent 看到端口和 OVS 接口出现后重挂载。接口名称
相同但 ifindex 变化也会触发重挂载。

Agent 只删除自己使用的 TC pref 1 handle `0x1/0x2` 和自己的 XDP/pin 路径，
不会删除 clsact，也不会删除 NetMig 的 `0x65/0x66`。

## 只读发现

先进入包含 OpenStack `OS_*` 认证变量的 root 环境：

```bash
sudo -s
source /opt/stack/devstack/openrc admin admin
```

然后执行：

```bash
python3 agent/openstack_dataplane_agent.py discover \
  --server-id <server-uuid> \
  --local-host "$(hostname -s)"
```

2026-07-30 的 Shuka1 只读验证得到：

```text
server 5d983776-e49c-4320-b038-f720df01ace6
  -> port 2200c160-c07d-43ea-9cda-5aabd4e54d37
  -> host master
  -> tap2200c160-c0
  -> ifindex 14
```

## 持续运行

```bash
python3 agent/openstack_dataplane_agent.py watch \
  --server-id <server-uuid> \
  --dns-monitor "$PWD/build/dns_monitor" \
  --dns-bpf "$PWD/build/dns_client_cache.bpf.o" \
  --grpc-monitor "$PWD/build/grpc_monitor" \
  --grpc-bpf "$PWD/build/grpc_monitor.bpf.o" \
  --trusted-dns <backend-ip> \
  --grpc-port 50052 \
  --audit-log /var/log/vnet-dataplane-agent/audit.jsonl
```

默认状态文件为 `/run/vnet-dataplane-agent/state.json`，pin 根目录为
`/sys/fs/bpf/vnet-dataplane-agent`。状态文件使用临时文件加 `os.replace`
原子更新。审计日志记录 attach、detach、等待、失败和原因。

`SIGINT` 或 `SIGTERM` 会触发严格清理。monitor 异常退出时，下一个 reconcile
周期会先清理旧 hook，再启动新进程。

## 验证

用户态测试：

```bash
python3 -m unittest tests.test_openstack_dataplane_agent -v
```

测试覆盖：

- 只解析本机 ACTIVE OVS 端口。
- OVS 多映射时拒绝挂载。
- 重复 reconcile 幂等。
- 同名接口 ifindex 变化后重挂载。
- 迁移离开宽限、源端卸载和再次出现后重挂载。
- monitor 失活后重启。

Shuka1 的两周期真实 watch smoke 已完成 attach/detach。结束后：

```text
agent process = none
agent pin root = none
XDP = detached
TC 0x1/0x2 = none
NetMig ingress 0x65 = present
NetMig egress 0x66 = present
```

随后在 `master` 与 `compute2` 同时运行 Agent，完成了真实
`master -> compute2` 块在线迁移：

```text
master:  tap2200c160-c0 / ifindex 14
  -> missing_grace_1
  -> detach (binding_left_host)

compute2: tap2200c160-c0 / ifindex 11
  -> attach (binding_local)
  -> DNS/gRPC 进程健康
  -> TC 0x1/0x2 位于 NetMig 0x65/0x66 之前
```

这证明 Neutron binding 变化、源端卸载及目标端按新 ifindex 重挂载已经贯通。
反向 `compute2 -> master` 迁移目前由 Nova/libvirt 报
`Target device virtio options don't match the source`，属于虚拟化配置问题，
尚未计为 Agent 往返迁移验证完成；修复后还需补做反向重挂载和双端清理验收。
