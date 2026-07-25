# OpenStack DNS 双端缓存 E2E 结果

## 结论

OpenStack 私有网络中的 DNS 服务端 XDP 缓存已经完成可复现验证；在当前测试环境中，服务端缓存相对 baseline 的平均 QPS 约为 **1.99 倍**。客户端缓存必须挂在 OpenStack 计算节点的 guest tap 出口/入口路径，直接挂在 guest `ens3` 的 XDP ingress 无法观察本机发出的请求。改用 host tap 后，客户端学习和命中事件已出现，短 smoke 测试的客户端缓存 QPS 约为 **3.92 倍**。

严格的五轮 host-tap 正式结果尚未闭环，因此本文不把短 smoke 结果冒充正式五轮结果。

## 环境

- OpenStack：Shuka1 DevStack，私有网络中的 client VM 与 backend VM
- guest：Ubuntu 24.04，Linux `6.8.0-134-generic`
- DNS：UDP/IPv4，固定域名和 A 记录，`1000` 次请求，`100` 次 warmup，五轮
- 服务端：guest 网卡 `ens3` 上 generic XDP
- 客户端：host 计算节点对应 `tap<port-id>` 上的 eBPF client cache；旧 guest-`ens3` 模式仅保留作对照

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

在把 OpenStack DNS P0 标记为完成前，需要使用当前脚本在 host-tap 模式下重新跑满五轮，并同时保留 `cleanup-status.txt=0`、五个场景计数断言和 client host log 的学习/命中证据。
