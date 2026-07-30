# OpenStack 动态双端缓存实验

`bench/openstack_dynamic_cache_campaign.sh` 在现有 OpenStack Ubuntu
客户端和后端实例之间比较五种策略：

- `bypass`
- `server`
- `client`
- `dual`
- `dynamic`

脚本不会创建或删除实例。运行前必须通过 Neutron 和 OVS 当前状态解析
`CLIENT_IP`、`BACKEND_IP`、`CLIENT_TAP` 和 SSH netns，不得复用历史值。

## 数据路径

```text
DNS:
client VM
  -> host-side client tap: client XDP cache
  -> backend VM ens3: server XDP cache
  -> DNS backend :53

gRPC:
client harness
  -> client VM :50053, grpc_fast_cache role=client
  -> backend VM :50052, grpc_fast_cache role=server
  -> gRPC backend :50051
```

DNS 响应快路位于 XDP。gRPC 两级缓存当前仍是读取 pinned eBPF map 的
用户态 h2c 代理，不能表述为内核态 gRPC 响应快路。客户端 tap 上的 gRPC
TC 程序只负责观测客户端代理向服务端代理转发的流量。

## 负载定义

| 负载 | 定义 |
| --- | --- |
| `stable` | 固定循环访问 8 个可缓存 key |
| `burst` | 多客户端并发访问同一个热 key |
| `hot-key` | 持续访问单个热 key |
| `shifting-hot-key` | 前半窗口访问 A，后半窗口切换到 B |
| `low-hit-rate` | DNS 每窗口使用新域名，gRPC 使用未预置的 payload |

DNS 和 gRPC 在同一窗口并发运行。性能统计排除 harness 内部 warmup 的延迟，
但 eBPF 命中数和回源数包含 warmup，用于保留缓存学习成本。

缓存关闭时，DNS 和 gRPC 都执行 shadow lookup。shadow 命中只说明该请求
若启用缓存可以命中；请求仍然走后端。动态控制器使用客户端实际命中加
shadow 命中作为缓存收益信号，使用服务端代理 fallback 和 DNS 后端计数
计算真实回源压力。

## 策略发布

单台主机上的多张 runtime map 由控制器执行两阶段发布：

1. 快照全部 map。
2. 写入未提交 epoch。
3. 回读全部阶段状态。
4. 写入 committed 状态并再次回读。
5. 任一步失败时恢复快照。

实验脚本把同一个 epoch 依次发布到宿主机、客户端 VM 和后端 VM。跨主机
任一发布失败时，脚本向已触达端点重发上一模式和 epoch，并将本轮判为失败。
这提供实验级失败回滚，但不是分布式共识协议。

## 运行

先构建：

```bash
./scripts/build_linux.sh
```

单策略、单负载冒烟：

```bash
OUT_DIR="$PWD/artifacts/dynamic-smoke-$(date +%Y%m%d-%H%M%S)" \
CLIENT_IP=<current-client-ip> \
BACKEND_IP=<current-backend-ip> \
CLIENT_TAP=<current-host-tap> \
NETNS=<current-ssh-netns> \
GUEST_KEY=<private-key> \
DNS_HARNESS="$PWD/build/openstack_dns_harness" \
GRPC_HARNESS="$PWD/build/openstack_grpc_harness" \
GRPC_CACHE="$PWD/build/grpc_fast_cache" \
CACHECTL="$PWD/build/cachectl" \
OPENSTACK_OPENRC=/opt/stack/devstack/openrc \
OPENSTACK_OPENRC_USER=admin OPENSTACK_OPENRC_PROJECT=admin \
MANAGE_GRPC_SECURITY_GROUP_RULE=1 \
OPENSTACK_GRPC_BACKEND_SECURITY_GROUP_ID=<backend-port-security-group-id> \
ROUNDS=1 WINDOWS=3 REQUESTS_PER_WINDOW=40 WARMUP=8 \
POLICIES=dynamic WORKLOADS=hot-key REQUIRE_NETMIG_TC=0 \
./bench/openstack_dynamic_cache_campaign.sh
```

正式矩阵：

```bash
OUT_DIR="$PWD/artifacts/dynamic-formal-$(date +%Y%m%d-%H%M%S)" \
CLIENT_IP=<current-client-ip> \
BACKEND_IP=<current-backend-ip> \
CLIENT_TAP=<current-host-tap> \
NETNS=<current-ssh-netns> \
GUEST_KEY=<private-key> \
DNS_HARNESS="$PWD/build/openstack_dns_harness" \
GRPC_HARNESS="$PWD/build/openstack_grpc_harness" \
GRPC_CACHE="$PWD/build/grpc_fast_cache" \
CACHECTL="$PWD/build/cachectl" \
OPENSTACK_OPENRC=/opt/stack/devstack/openrc \
OPENSTACK_OPENRC_USER=admin OPENSTACK_OPENRC_PROJECT=admin \
MANAGE_GRPC_SECURITY_GROUP_RULE=1 \
OPENSTACK_GRPC_BACKEND_SECURITY_GROUP_ID=<backend-port-security-group-id> \
ROUNDS=5 WINDOWS=5 REQUESTS_PER_WINDOW=200 WARMUP=20 \
POLICIES="bypass server client dual dynamic" \
WORKLOADS="stable burst hot-key shifting-hot-key low-hit-rate" \
REQUIRE_NETMIG_TC=1 \
./bench/openstack_dynamic_cache_campaign.sh
```

`REQUIRE_NETMIG_TC=1` 会强制验证 ingress 的 DNS/gRPC observer 位于 NetMig
handle `0x65` 之前，egress observer 位于 `0x66` 之前。

脚本默认设置 `REQUIRE_OPENSTACK_EVIDENCE=1`。它会使用当前 `OS_*` 环境，
或者先 source `OPENSTACK_OPENRC`，再采集 server/port 证据。认证失败会在产生
负载前终止；只有明确运行非 OpenStack 调试时才可设置
`REQUIRE_OPENSTACK_EVIDENCE=0`。

现有测试实例若只放通 SSH 与 DNS，客户端 VM 到后端 gRPC proxy 的 `TCP/50052`
会被 Neutron 安全组静默丢弃。为让实验自包含，可显式设置
`MANAGE_GRPC_SECURITY_GROUP_RULE=1` 和后端端口所属的
`OPENSTACK_GRPC_BACKEND_SECURITY_GROUP_ID`。脚本会仅为当前 `CLIENT_IP/32`
创建一条 `TCP/50052` 入站规则，将规则 ID 写入
`grpc-security-group-rule.txt`，并在所有成功或失败退出路径中按该精确 ID
删除并复查。默认值为 `0`，不会修改任何安全组；未启用时，操作者必须自行保证
后端端口的 `TCP/50052` 已对客户端 IP 放通。删除后的 `show` 只有明确的
NotFound/404 才计为已清理；认证、API 或网络错误会让 campaign 以清理失败退出，
并保留规则 ID 与诊断输出。

该开关不管理 guest SSH 控制通道。调用前，`NETNS` 的实际 IPv4 源地址必须已对
两台 guest 的 `TCP/22` 放通；实验引导若临时创建该规则，必须限制为该源 `/32`，
在独立 artifact 中记录规则 ID，并在 run 后按 ID 删除和以 NotFound/404 复查。
不得把这个仅用于部署和回收的 SSH 规则计入业务数据面或性能结果。

## 证据与清理

每次运行保留：

- `windows.csv`：逐窗口性能、决策信号、两端命中，以及产生该窗口数据的
  `applied_mode/epoch` 和供下一窗口使用的 `next_mode/epoch`。
- `runs.csv`：逐轮汇总。
- `summary.csv`、`summary.md`：按策略和负载计算的中位数。
- `raw/`：每个 harness 的原始输出。
- `raw/*.status`：每个窗口的 DNS/gRPC 子任务退出码；子任务失败时仍保留原始输出，
  然后以明确错误退出，不把该窗口喂给动态控制器。
- `decisions/`：动态决策、epoch 发布和回滚日志。
- `monitors/`：DNS、gRPC、TC 顺序及两级 gRPC 缓存日志。
- `cleanup-audit.txt`、`cleanup-status.txt`：进程、pin 和 TC 残留检查。
- `grpc-security-group-rule.txt`：仅启用受管 gRPC 安全组规则时的创建、查询和删除证据。

只要 campaign 自己的 pin、进程或 TC handle `0x1/0x2` 有残留，清理状态就
会失败。NetMig 的 `0x65/0x66` 不属于 campaign，脚本不会删除。

对 TC/XDP monitor hook，当前脚本只通过结束自己启动的 monitor 触发清理；不会使用
固定 handle 的 `tc filter del` 或 `xdp off` 作为兜底。monitor 会先核对程序 ID；
所有权丢失时保留 hook 并让 cleanup audit 失败，而不是删除未知程序。每次 campaign
会生成经过清洗的 `RUN_TOKEN`，将 guest 二进制、日志、PID 文件和 DNS 计数写入私有
目录，并在私有 BPF pin 根目录下工作。helper 以私有 `setsid` 进程组启动；收尾前会
核对 PID、进程组和启动时间，不匹配时拒绝发送信号并保留证据。脚本不再使用
`killall` 或共享的 guest 临时文件名，因此不同运行不会相互删除 helper 进程或
工件。动态 campaign 会对同一个 host tap 使用 `flock` 串行化，并为每次启动追加
不可复用 nonce；它们仍不得绕过该锁并发占用同一个 TC/XDP hook。发生所有权异常时，
脚本拒绝发送信号、保留 run 目录和 pin 根目录，并以非零 cleanup 状态结束供人工审计。

`dynamic_cache_controller --dry-run` 只给出候选模式和 epoch；该 campaign 再以
host、client、server 的串行方式发布 map。它是可审计的实验编排，不是跨主机原子
事务。P1 的 prepare/readback/commit 与失败强制 `BYPASS` 完成前，不应将这批数据
描述为“分布式原子发布”。

`docs/openstack-dynamic-cache-results-20260730.md` 记录的是 `.1` 生命周期修订前的
2026-07-30 历史五轮结果。它可作为功能和性能基线，不是 `.1` 的生命周期验证；P2
需要使用修订后的脚本重新跑完整的五策略、五负载矩阵。
