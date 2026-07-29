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

## 证据与清理

每次运行保留：

- `windows.csv`：逐窗口性能、决策信号、两端命中，以及产生该窗口数据的
  `applied_mode/epoch` 和供下一窗口使用的 `next_mode/epoch`。
- `runs.csv`：逐轮汇总。
- `summary.csv`、`summary.md`：按策略和负载计算的中位数。
- `raw/`：每个 harness 的原始输出。
- `decisions/`：动态决策、epoch 发布和回滚日志。
- `monitors/`：DNS、gRPC、TC 顺序及两级 gRPC 缓存日志。
- `cleanup-audit.txt`、`cleanup-status.txt`：进程、pin 和 TC 残留检查。

只要 campaign 自己的 pin、进程或 TC handle `0x1/0x2` 有残留，清理状态就
会失败。NetMig 的 `0x65/0x66` 不属于 campaign，脚本不会删除。

2026-07-30 的正式五轮结果见
`docs/openstack-dynamic-cache-results-20260730.md`。
