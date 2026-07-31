# OpenStack 数据面 Agent

`agent/openstack_dataplane_agent.py` 在每个 OpenStack Compute 节点运行，
自动把指定 VM 的 Neutron 端口解析为本机 OVS 接口，并保持 DNS/gRPC eBPF
程序与当前接口一致。它只管理 Compute 侧挂载；VM 内的 DNS server XDP 和
gRPC 用户态快缓存由 `openstack_guest_endpoint_agent.py` 管理。

P1 使用四个参与者：

| 参与者 | 角色与所有权 |
| --- | --- |
| client Compute tap | DNS client XDP cache + TC 学习路径；gRPC TC observability |
| backend Compute tap | DNS/gRPC TC observability，不拥有 Guest 缓存 |
| client Guest `ens3` | gRPC userspace fast-cache client，拥有本地 listener |
| backend Guest `ens3` | DNS server XDP cache + gRPC userspace fast-cache server |

两个 gRPC 端口字段不能合并或相互推断：

- `grpc_observe_port` 是 Compute tap 线上需要被 `grpc_monitor --port` 观测的 TCP
  端口。client 和 backend 的示例值均为 `50052`。
- `guest_grpc_listen_port` 是对应 Guest Agent 自有 listener 的端口，只用于配置、
  状态发布与跨 Agent 门控，不传给 Compute TC monitor。client Guest 示例为
  `50053`，backend Guest 示例为 `50052`。

因此 client Guest 可以在 `50053` 接收本地应用请求，再向 backend Guest 的
`50052` 建立线上连接；client Compute tap 应观测后者，而不是本地 listener
端口。旧字段 `grpc_port` 含义不完整，配置和状态检查都会拒绝它。

宿主机 tap 的 XDP ingress 看到的是 guest 发往宿主机的方向，不能替代 backend
guest `ens3` 上接收 DNS 请求的 server XDP。gRPC `grpc_fast_cache` 是 h2c
用户态代理，TC 只负责观测，不能描述为内核直接响应。

四参与者的数据面与控制面闭环如下：

```text
gRPC application
  -> client Guest listener :50053
  -> Compute tap wire :50052 (TC observation)
  -> backend Guest listener :50052
  -> real backend :50051

DNS/gRPC monitor and fast-cache logs
  -> openstack_metrics_bridge.py
  -> 9-column dynamic_cache_controller input
  -> controller-mode.json (isolated staging)
  -> bridge validates stdout + staging ACK
  -> desired-policy.json (authoritative)
  -> epoch coordinator gates all four participants
  -> stage / verify-staged / commit / verify-committed
  -> Compute and Guest runtime maps
```

策略闭环中的“已发布”必须以 coordinator 的端点回读为准。Metrics bridge 收到的
controller ACK 并回读隔离 staging 文件，只证明该样本对应的 controller 决策已在
本机一致发布；bridge 随后才会刷新 coordinator 可见的权威策略文件。这个本地确认
不能替代四参与者健康门控或远端 map 提交证明。

## 模块接口

Agent 暴露三个命令：

- `discover`：只读输出 `server -> port -> host -> interface -> ifindex` JSON。
- `watch`：周期执行 reconcile，拥有 monitor 进程，并由 monitor 按程序 ID 清理自己的
  hook；attach 阶段在可配置截止时间内轮询进程、所需 pin 与确切 XDP/TC 程序 ID。
- `health`：检查状态文件新鲜度，并确认指定实例至少存在健康本地绑定。

`--server-id` 可以重复传入；常驻服务也可以用 `--server-id-file` 每行配置一个 Nova
server UUID。一次 discovery 会遍历每个实例的全部 Neutron 端口，所以同一 Compute
Agent 可以同时管理多个实例及其多个端口。

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

Agent 先结束自己启动的 monitor；monitor 在退出前查询当前 TC/XDP 程序 ID，仅在 ID
仍与本次 attach 一致时才卸载。若 supervisor 让 monitor 在清理前退出，Agent 会再读
一次程序 ID，只针对仍归属于本次 attach 的 DNS/gRPC hook 做精确清理，并在清理后复核。
ID 不匹配、查询失败或复核仍有残留时，Agent 保留 pin 和 quiesce 状态并记录错误。
Agent 从不销毁 `clsact`，也不会删除 NetMig 的 `0x65/0x66`。

DNS XDP 退出使用内核的 `old_prog_fd` 条件校验，避免查询后再卸载的替换窗口。当前
legacy `bpf_tc_*` API 的 detach 只能按 `priority + handle` 删除，无法把 program ID
作为内核原子前置条件；Agent 的 readback guard 会在普通所有权变化时 fail-closed，
并且不删除未知程序。P1 后续仍应在支持的内核上引入 TCX BPF link 生命周期，消除
非协作外部控制器的极小并发替换窗口。

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
  --endpoint-config /etc/vnet-dataplane-agent/endpoints.json \
  --local-host "$(hostname -s)" \
  --dns-monitor "$PWD/build/dns_monitor" \
  --dns-client-bpf "$PWD/build/dns_client_cache.bpf.o" \
  --dns-tc-bpf "$PWD/build/dns_monitor.bpf.o" \
  --grpc-monitor "$PWD/build/grpc_monitor" \
  --grpc-bpf "$PWD/build/grpc_monitor.bpf.o" \
  --cache-policy-txn "$PWD/build/cache_policy_txn" \
  --command-timeout-seconds 10 \
  --attach-ready-timeout-seconds 10 \
  --audit-log /var/log/vnet-dataplane-agent/audit.jsonl
```

默认状态文件为 `/run/vnet-dataplane-agent/state.json`，pin 根目录为
`/sys/fs/bpf/vnet-dataplane-agent`。状态文件使用临时文件加 `os.replace`
原子更新。schema 3 为每个端口输出 `healthy`、`transition`、`degraded`、`absent`
或 `stopped`，同时记录 binding revision、ifindex、角色、能力、monitor PID 和
缺失 pin。Agent 还记录 attach 时的 XDP/TC 程序 ID，并在每次健康检查和快照发布时
重新读取 hook，确认这些 ID 仍由对应 monitor 进程持有。外部删除、替换或无法读取
hook 时状态会降级，不会仅凭 PID 和 pin 继续报告健康。`client` 角色要求 DNS client
XDP cache 与 gRPC TC；`observer` 角色只要求 DNS/gRPC TC 观测，不发布 Compute
侧缓存 map。发现命令有硬超时，并在发布快照前复核 Neutron binding revision/host
和本地 ifindex；发生变化时不会把旧发现结果伪装成新鲜健康状态。

`SIGINT` 或 `SIGTERM` 会请求 monitor 进行严格的所有权校验清理。monitor 异常退出
时，Agent 会在确认两个进程都已结束后执行一次按程序 ID 守卫的 hook 兜底清理；
所有权异常或复核失败时保留 pin/quiesce，状态转为 `degraded`，由 epoch coordinator
强制收敛到 `BYPASS`，不会盲删外部 slot。

## systemd 部署

仓库提供：

- `deploy/systemd/vnet-dataplane-agent.service`：每个 Compute 节点一个 Agent。
- `deploy/systemd/vnet-dataplane-guest-endpoint.service`：每个业务 VM 一个 Guest
  Agent。
- `deploy/systemd/vnet-dataplane-epoch-coordinator.service`：控制节点上的 epoch 协调器。
- `deploy/systemd/vnet-dataplane-metrics-controller.service`：真实指标桥接与动态控制器。
- `deploy/examples/`：无真实凭据的环境、实例列表和协调器配置样例。

Compute 部署时把 `agent.env`、`openstack.env` 和 `endpoints.json` 放到
`/etc/vnet-dataplane-agent/`。Guest 部署把 `guest-endpoint.env`、`endpoint.json`
和缓存策略文件放到 `/etc/vnet-dataplane-guest/`。真实凭据文件必须由 root 持有并
设为 `0600`，不得提交。动态控制节点还需要
`metrics-bridge.env` 与 `metrics-bridge.json`。Compute 和 Guest supervisor 都按
程序 ID、PID 和 pin 所有权清理；没有通配符式的 TC/XDP 删除命令。

## 跨主机 epoch 门控

`agent/openstack_epoch_coordinator.py` 聚合各 Compute 的 schema 3 状态以及两个
Guest Agent 的 schema 1 状态。配置显式列出必须健康的
`server_id + port_id + compute_role + guest_cache_role`，防止只看到一个非业务
端口或只有宿主机 hook 就错误放行。Compute 状态中的 `grpc_observe_port` 必须在
各状态源之间一致；Guest 实际 listener 端口必须与
`endpoint_config.guest_grpc_listen_port` 一致。两者不要求相等。决策语义：

```text
每个必需端口恰好一个 healthy binding，所有快照新鲜
  -> 允许发布期望模式

任一必需端口仍为 transition
  -> 冻结新的加速策略，立即收敛到 BYPASS

degraded / stopped / stale / 无健康绑定 / 双活歧义
  -> fail-safe BYPASS

源端 absent + 目标端唯一 healthy
  -> 迁移清理完成，恢复发布期望模式并递增 epoch
```

协调器使用 `cache_policy_txn` 对每个端点执行
`stage -> verify-staged -> commit -> verify-committed`。阶段态没有 `COMMITTED` 标志，
数据面会直接旁路。任一端点失败时，协调器对所有可达端点执行同 epoch 的
`force-bypass`；若仍有端点不可达，状态记为 `known=false`，不得宣称策略已一致。
该协议不是跨主机严格原子提交：它依靠 staged epoch 保持提交前旁路，在 stage 后、
commit 后和 committed 回读后重新检查拓扑；commit 中途拓扑变化时，已提交端点可能
短暂先于其他端点生效，协调器会在有界命令超时内对所有可达端点执行补偿
`force-bypass`。本地 publisher 优先执行，SSH publisher 同阶段并发执行，因此多个
失联主机的 timeout 不会按主机数串行累加；记录仍按配置顺序输出。

`desired-policy.json` 是当前策略输入边界。静态部署可以直接写四态模式；动态部署由
metrics bridge 原子替换该文件，不能绕过 coordinator 直接写远端 map。

动态部署使用两个不同的绝对路径。metrics bridge 的 `controller_mode_file` 必须与
其 `controller_command --desired-mode-file` 相同，作为 controller 的隔离 staging
文件；bridge 的 `desired_mode_file` 必须与 staging 路径不同，并与 coordinator 的
`--desired-mode-file`（或 `VNET_DESIRED_MODE_FILE`）相同。仓库样例中的运行目录路径
仅是模板，部署时必须保持这两组对应关系，绝不能让 coordinator 直接读取 staging
文件。

## 真实指标策略闭环

`agent/openstack_metrics_bridge.py` 从 monitor/fast-cache 的真实日志中选择新鲜快照。
每个 source 可以是本地绝对路径，也可以是不经过 shell 的 argv 命令；远端样例通过
SSH 调用 `snapshot-log`，以有界 JSON 返回日志尾部。配置必须至少覆盖：

- `dns_metrics/client` 与 `dns_metrics/server`。
- `grpc_fast_cache/client` 与 `grpc_fast_cache/server`。
- 至少一组 `grpc_metrics` TC 观测。

production Guest Agent 启动 `grpc_fast_cache` 时不传 `--verbose`。进程在启动时以及
之后每秒独立刷新一行累计指标，即使没有请求也保持快照新鲜；`--verbose` 只用于调试，
否则会额外生成逐请求事件与统计日志，给业务热路径带来不必要的日志开销。

同一指标组可以配置迁移前后的多个候选源；bridge 选择最新的新鲜源。只有每个已选组
都产生新 generation 时才消费一个窗口，避免异步日志让累计计数被重复计算。缺失、
过期、未来时间戳、格式错误或 source 命令超时都不会生成策略样本。

bridge 送入 `dynamic_cache_controller` stdin 的格式严格为九列：

```text
timestamp_ms,dns_hits,dns_misses,dns_p95_us,grpc_hits,grpc_misses,grpc_p95_us,backend_qps,error_rate
```

- DNS hit/miss 来自 client DNS monitor 当前窗口的 cache 与 shadow 计数，DNS p95
  取所选 DNS 指标中的最大值。
- gRPC hit/miss 来自 client `grpc_fast_cache` 累计计数的窗口增量，gRPC p95 取所选
  gRPC TC monitor 中的最大值。
- `backend_qps` 由 server DNS miss 与 server gRPC fallback 的窗口量计算。
- `error_rate` 汇总 monitor timeout/unmatched/ring-buffer drop，以及 fast-cache
  `fallback_error`/`tx_error`，并限制在 `[0, 1]`。

controller 继续负责滑动窗口、迟滞、候选稳定窗口与 cooldown，并在
`BYPASS`、`SERVER_CACHE`、`CLIENT_CACHE`、`DUAL_CACHE` 之间决策。bridge 禁止
controller 使用 `--control-map`、`--dry-run` 或 `--metrics-file`；初始模式默认为
`BYPASS`，若显式传入也只能是 `BYPASS`。controller 只写隔离的
`controller_mode_file`，权威 `desired_mode_file` 只能由 bridge 在关联校验通过后
写入，因此 controller 不能绕过 bridge 确认或跨主机门控。

每个九列样本都有相关 ACK：controller 必须返回相同 `timestamp_ms`、合法模式、
`publish_failed=0`，并在返回后仍存活；bridge 还会回读
`controller_mode_file`，确认其模式与 stdout 决策相同。只有这两层校验都通过，
bridge 才会把同一模式及 `updated_ms` heartbeat 原子写入权威
`desired_mode_file`，并提交该窗口的累计计数 baseline。时间戳不匹配、staging
回读不一致、发布失败、超时、进程退出或权威文件写入失败均不确认该窗口。

bridge 启动、停止和降级时都会先尝试原子发布 `BYPASS`。source 或 controller
故障时，它会把权威 desired 和 controller staging 都恢复为 `BYPASS`，停止所拥有的
controller 并清空窗口 baseline；若连权威文件也无法写入，coordinator 还会依靠
`max_desired_mode_age_seconds` 将旧 heartbeat 判为 stale，继续 fail-safe 到
`BYPASS`。因此 ACK 是期望输入确认，最终生效仍需 coordinator 完成四参与者健康
门控和所有 runtime map 回读。

## 验证

用户态测试：

```bash
python3 -m unittest \
  tests.test_openstack_dataplane_agent \
  tests.test_openstack_epoch_gate \
  tests.test_openstack_epoch_coordinator \
  tests.test_openstack_guest_endpoint_agent \
  tests.test_openstack_metrics_bridge -v

bash tests/grpc_fast_cache_metrics_test.sh
```

测试覆盖：

- 只解析本机 ACTIVE OVS 端口。
- OVS 多映射时拒绝挂载。
- 重复 reconcile 幂等。
- 同名接口 ifindex 变化后重挂载。
- 迁移离开宽限、源端卸载和再次出现后重挂载。
- monitor 失活后重启。
- monitor 进程、pinned map 与确切 hook 程序 ID 联合健康检查。
- 多实例 server-id 文件解析。
- 迁移冻结、双活拒绝、快照过期和故障 `BYPASS`。
- 首次 `BYPASS` 引导、epoch 连续恢复和部分发布失败补偿。
- 真实指标行解析、九列聚合、source 新鲜度与 generation 去重。
- controller ACK 关联、原子 desired-policy heartbeat 和故障 `BYPASS`。
- 非 verbose、无请求时的 gRPC fast-cache 周期指标刷新。

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

当前工作树已经完成一次固定在 `master` 的真实 systemd DNS/gRPC 自动闭环 smoke：
两个 Neutron 端口同时健康、动态策略发布 `BYPASS -> SERVER_CACHE -> BYPASS`，
DNS guest XDP 与 gRPC guest userspace fast-cache 各命中 50 次，最终清理和 NetMig
共存检查通过。该结果仍不等同于无人干预的迁移闭环；`master -> compute2 -> master`
期间的 freeze、目标端重挂载、恢复发布、故障注入和请求连续性仍需真实验收。
