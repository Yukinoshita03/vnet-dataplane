# OpenStack 数据面 Agent

`agent/openstack_dataplane_agent.py` 在每个 OpenStack Compute 节点运行，
自动把指定 VM 的 Neutron 端口解析为本机 OVS 接口，并保持 DNS/gRPC eBPF
程序与当前接口一致。

## 模块接口

Agent 只暴露两个命令：

- `discover`：只读输出 `server -> port -> host -> interface -> ifindex` JSON。
- `watch`：周期执行 reconcile，拥有 monitor 进程，并由 monitor 按程序 ID 清理自己的
  hook。

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

Agent 不会按固定 TC slot 执行 `tc filter del`，也不会执行 `ip link ... xdp off`。
它先结束自己启动的 monitor；monitor 在退出前查询当前 TC/XDP 程序 ID，仅在 ID
仍与本次 attach 一致时才卸载。ID 不匹配或查询失败时保留现状并记录错误。Agent
从不销毁 `clsact`，也不会删除 NetMig 的 `0x65/0x66`。

DNS XDP 退出使用内核的 `old_prog_fd` 条件校验，避免查询后再卸载的替换窗口。当前
legacy `bpf_tc_*` API 的 detach 只能按 `priority + handle` 删除，无法把 program ID
作为内核原子前置条件；现有 readback guard 会在普通所有权变化时 fail-closed，但不能
把非协作外部控制器的极小并发替换窗口描述为原子安全。P1 将在支持的内核上引入 TCX
BPF link 生命周期，或在无法安全恢复时显式进入 `BYPASS`。

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

下列是 2026-07-30 较早时点的历史只读验证；ifindex 随迁移、重挂载和设备重建变化，
不应作为当前值使用。P0 发布时点的 `tap2200c160-c0` 为 ifindex `29`，见
`docs/v0.3-openstack-e2e-release-manifest.md`：

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

`SIGINT` 或 `SIGTERM` 会请求 monitor 进行严格的所有权校验清理。monitor 异常退出
时，下一个 reconcile 周期不会盲删旧 slot，而是重新启动并让新的 attach 失败关闭；
P1 将把这类残留转为显式 `BYPASS` 和可恢复状态。

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

反向迁移首次失败的根因也已定位并修复：`compute2` 的
`/etc/nova/nova-cpu.conf` 仍使用 `virt_type=qemu`，Nova 为迁移目标 XML
重建了 `<driver name="qemu"/>`，而源实例实际以 `type=kvm` 运行，libvirt
因此报告 `Target device virtio options don't match the source`。将
`nova.conf`、`nova-cpu.conf` 和 DevStack `local.conf` 对齐到
`virt_type=kvm`/`LIBVIRT_TYPE=kvm`，重启 `nova-compute` 并硬重启恢复实例后，
真实反向块在线迁移完成：

```text
migration UUID: 3051c9f9-0459-4aeb-a5fe-2cfd97a20043
compute2: tap2200c160-c0 / ifindex 14
  -> missing_grace_1
  -> detach (binding_left_host)

master: tap2200c160-c0 / ifindex 29
  -> attach (binding_local)
  -> DNS/gRPC 进程健康
  -> TC 0x1/0x2 位于 NetMig 0x65/0x66 之前
```

迁移结束时实例和 Neutron 端口均为 `ACTIVE`。停止两端 Agent 后再次验收：
Agent/monitor 进程、Agent pin、XDP 和 TC `0x1/0x2` 均无残留，
NetMig `0x65/0x66` 保留。因此 `master -> compute2 -> master` 往返迁移、
重挂载与双端清理有历史手工执行证据。

这不等同于 P1 的自动闭环验收：当前版本尚无 systemd 部署、多 Neutron 端口健康 API、
双端健康后 epoch 发布、迁移冻结/恢复及异常残留的 `BYPASS` 收敛。这些条件完成前，
不得把上述历史记录写成无人干预的持续控制成功。
