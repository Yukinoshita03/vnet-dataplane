# OpenStack DNS 双端缓存 E2E 结果

## 结论

2026-07-30 的 P0 候选版本已在当前脚本、当前 OpenStack 实例上完成五轮 host-tap
正式复验。25 个主场景均为 `1000/1000` 成功；TTL 过期、非可信 resolver 和
NXDOMAIN 三项回退检查均通过，`cleanup_status=0`。客户端缓存必须挂在计算节点对应的
guest tap 出口/入口路径；直接挂在 guest `ens3` 的 XDP ingress 无法观察本机发出的请求。

本次正式中位数为 baseline `2081.12 QPS`，server-only `2678.64 QPS`（`1.29x`），
client-only `9859.51 QPS`（`4.74x`），both `10208.86 QPS`（`4.91x`）。该数字仅代表
Shuka1 的固定域名、UDP/IPv4、host-tap 客户端路径，不外推为通用 DNS 性能结论。

## P0 当前正式验证（2026-07-30）

- 原始 artifact：`/tmp/vnet-p0-dns-formal-20260730-115435`
- 参数：`REQUESTS=1000`、`WARMUP=100`、`REPEAT=5`、`GUEST_BPF=1`、
  `REQUIRE_TC_COEXISTENCE=1`。
- 有效客户端模式为 `host-ebpf`：客户端 XDP/TC 位于 `tap2200c160-c0`；服务端
  generic XDP 位于 backend guest 的 `ens3`。`GUEST_BPF=1` 表示 guest 侧准备和
  服务端 BPF 路径开启，不能把客户端模式写成 guest-XDP。
- 每一轮 client-only 都记录 `cache_learned=1 cache_hit=1099 cache_tx=1099`、
  `backend_requests=1`；both 都记录客户端学习/命中、服务端 `cache_hit=1 cache_tx=1`，
  `backend_requests=0`。
- 退出后没有 DNS/gRPC monitor 进程或 DNS `0x1` TC filter；既存 NetMig ingress
  `0x65` / egress `0x66` 仍在，host tap 无 XDP 残留。

| 场景 | QPS min | QPS median | QPS max | 相对 baseline median | p95 median (us) | p99 median (us) | 每轮 backend 请求 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| baseline | 1797.85 | 2081.12 | 2393.69 | 1.00x | 619.92 | 965.68 | 1100 |
| monitor-only | 303.75 | 2082.19 | 2233.31 | 1.00x | 667.26 | 948.81 | 1100 |
| server-only | 2447.43 | 2678.64 | 2771.37 | 1.29x | 480.30 | 868.24 | 0 |
| client-only | 4502.68 | 9859.51 | 11796.63 | 4.74x | 135.30 | 222.71 | 1 |
| both | 9401.96 | 10208.86 | 10802.01 | 4.91x | 134.78 | 213.52 | 0 |

monitor-only 第 5 轮出现 host 侧长尾异常（p99 `28647.43 us`）；中位数表保留该轮，
不以 monitor-only 作为加速结论。

## 环境

- OpenStack：Shuka1 DevStack，私有网络中的 client VM 与 backend VM
- guest：Ubuntu 24.04，Linux `6.8.0-134-generic`
- DNS：UDP/IPv4，固定域名和 A 记录，`1000` 次请求，`100` 次 warmup，五轮
- 服务端：guest 网卡 `ens3` 上 generic XDP
- 客户端：host 计算节点对应 `tap<port-id>` 上的 eBPF client cache；旧 guest-`ens3` 模式仅保留作对照

## 历史五轮 host-tap 数据（2026-07-26）

该批结果来自 Shuka1 DevStack 的 OVN 私有网络；两台临时 Ubuntu 24.04 KVM 来宾固定在 `nova:master`，客户端 hook 位于 host-side `tap<port-id>`，服务端 hook 位于 backend VM `ens3` 的 generic XDP。每轮 `1000` 请求、`100` warmup。

| 场景 | QPS min | QPS median | QPS max | 相对 baseline median | backend 请求 |
| --- | ---: | ---: | ---: | ---: | ---: |
| baseline | 2215.48 | 2275.04 | 2374.79 | 1.00x | 1100 |
| monitor-only | 1615.18 | 1906.57 | 2173.76 | 0.84x | 1100 |
| server-only | 2642.65 | 2785.15 | 3136.49 | 1.22x | 0 |
| client-only | 7937.00 | 8346.38 | 9350.94 | 3.67x | 1 |
| both | 8776.74 | 8887.80 | 9406.44 | 3.91x | 0 |

每轮 client-only 均观察到 `cache_learned=1 cache_hit=1099 cache_tx=1099`；both 同时观察到客户端上述学习/命中事件和服务端 `cache_hit=1 cache_tx=1`。正式 artifact 保存在实验机：`/tmp/vnet-dataplane-dns-e2e-20260726-1545/artifacts/dns-host-tap-formal-r1`。

## 五轮 guest-only 正式数据

该批数据的 baseline、monitor-only、server-only 和 both 场景请求均为 `1000/1000` 成功。client-only 的 guest `ens3` 路径没有收到本机发出的请求，`cache_learned=0`、`cache_hit=0`，因此不能作为客户端加速结论。

| 场景 | 平均 QPS | 平均延迟（us） | 平均 p99（us） | 结论 |
| --- | ---: | ---: | ---: | --- |
| baseline | 584.06 | 1774.17 | 3112.53 | 对照 |
| monitor-only | 462.45 | - | - | 仅监控开销 |
| server-only | 1161.87 | 855.47 | 1403.01 | **1.99x baseline** |
| client-only | 459.94 | 2170.18 | 3966.21 | 路径无效，不采纳 |
| both | 755.09 | 1327.71 | 2735.51 | **1.29x baseline** |

五轮逐轮 QPS：

| 轮次 | baseline | monitor-only | server-only | client-only | both |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 395.42 | 489.80 | 1175.92 | 458.71 | 656.16 |
| 2 | 660.03 | 425.51 | 1174.62 | 425.23 | 704.62 |
| 3 | 667.22 | 458.65 | 1164.79 | 460.74 | 823.15 |
| 4 | 543.12 | 443.80 | 1178.75 | 480.77 | 798.85 |
| 5 | 654.52 | 494.50 | 1115.29 | 474.26 | 792.67 |

## Host-tap 客户端修复 smoke

在 host tap 上同时挂载 TC ingress 和 egress 后，客户端缓存可以学习并命中。`client-only` 日志出现：`cache_miss=1 cache_learned=1 cache_hit=21 cache_tx=21`；后端只收到 `1` 个请求，说明 warmup miss 后进入本地响应路径。

| 场景 | QPS（20 请求） | 后端请求数 |
| --- | ---: | ---: |
| baseline | 654.89 | 22 |
| monitor-only | 452.11 | 22 |
| server-only | 1190.41 | 0 |
| client-only | 2568.75 | 1 |
| both | 2070.06 | 0 |

该 smoke 中 client-only 相对 baseline 约 **3.92 倍**（按表中 QPS 计算）；另一轮断言 smoke 为 `2411.75 / 624.79 ≈ 3.86 倍`。两者均为短 smoke，不替代五轮正式测试。

## 代码与验证

- `linux_accel/bpf/dns_client_cache.c`：恢复 IPv4/UDP 长度和逻辑包尾初始化，保证 verifier 边界检查成立。
- `linux_accel/src/dns_monitor.cpp`：client role 同时挂载 TC ingress/egress，覆盖 tap 上的请求和响应方向。
- `linux_accel/bench/openstack_dns_e2e.sh`：增加 host-tap 模式、backend 计数断言、进程/端口/XDP/TC 清理和超时保护。
- `scripts/build_linux.sh`：DNS/gRPC eBPF 与用户态程序构建通过。
- `cachectl --policy-file /tmp/cache-policy-e2e.txt --validate-only`：DNS、gRPC、gRPC cache 三类策略校验通过。

原始工件位于实验机：

`/tmp/vnet-dataplane-dns-e2e/linux_accel/artifacts/`

其中 `openstack-dns-e2e-formal` 保存五轮 guest-only 数据，`openstack-dns-e2e-host-smoke2` 和 `openstack-dns-e2e-assert-smoke` 保存 host-tap 修复验证。

## 后续门槛

上述 P0 复验门槛已经满足。P1 需要把当前手工 host-tap 运行收敛为多端口 Agent、
健康门控 epoch 发布、迁移冻结/恢复和失败 `BYPASS`；跨主机动态策略的串行实验结果
不能替代这些自动闭环验收。
