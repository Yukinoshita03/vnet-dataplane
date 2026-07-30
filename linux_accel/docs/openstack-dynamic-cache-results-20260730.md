# OpenStack DNS/gRPC 动态双端缓存正式结果

## 结论

2026-07-30 在 Shuka1 OpenStack 的两台 Ubuntu 24.04 实例之间完成了正式矩阵：

- 5 种策略：`bypass`、`server`、`client`、`dual`、`dynamic`。
- 5 类负载：`stable`、`burst`、`hot-key`、`shifting-hot-key`、`low-hit-rate`。
- 每个组合 5 轮，每轮 5 个窗口，每窗口并发执行 200 个 DNS 和 200 个 gRPC 请求。
- 共 125 轮、625 个窗口、250000 个正式请求，DNS/gRPC 失败数均为 0。

动态策略在前 3 个窗口观察和迟滞确认，后 2 个窗口执行选定策略。前四类可缓存
负载的切换后窗口相对 `bypass` 提升 `1.24x` 到 `2.13x`，且回源中位数从
每窗口 `436/440` 降到 `0`。低命中负载五轮均保持 `BYPASS`，没有因高延迟
误开启缓存。

## 环境与来源

| 项目 | 值 |
| --- | --- |
| OpenStack 客户端 | `private-p7-dns-path-r19-client`，`10.0.0.43` |
| OpenStack 后端 | `private-p7-dns-path-r19-backend`，`10.0.0.55` |
| 客户端 Neutron 端口 | `2200c160-c07d-43ea-9cda-5aabd4e54d37` |
| 客户端宿主 tap | `tap2200c160-c0` |
| 实例镜像/规格 | Ubuntu 24.04 / `ds2G` |
| 宿主内核 | `7.0.0-28-generic` |
| 源码基点 | `ae5be57` |
| 源码归档 SHA256 | `8ac62e17b6e477ab2b22948d771fb64d29c1228f664a13924fa7f8bd1576c098` |
| 原始证据目录 | Shuka1 `/tmp/vnet-dynamic-formal-20260730-0500` |

DNS 客户端缓存位于客户端 tap 的 XDP 路径，DNS 服务端缓存位于后端 VM
`ens3` 的 XDP 路径。gRPC 两级缓存是读取 pinned eBPF map 的两个
`grpc_fast_cache` h2c 用户态代理；宿主 TC eBPF 负责观测，不应将该结果描述为
“内核直接生成 gRPC 响应”。

DNS 和 gRPC 在同一窗口并发运行。下表的两种协议成功数相同，QPS 使用同一个
窗口墙钟时间计算，因此表示并发压力下各协议的有效吞吐；两种协议的延迟仍由各自
harness 独立记录。

## 五轮中位数

每个单元格为每协议 QPS。`dynamic` 包含前 3 个观察窗口的成本，不能与预先启用
缓存的固定策略混为同一种启动条件。

| 负载 | BYPASS | SERVER | CLIENT | DUAL | DYNAMIC |
| --- | ---: | ---: | ---: | ---: | ---: |
| stable | 242.97 | 319.61 | 521.34 | 524.94 | 266.09 |
| burst | 257.43 | 332.99 | 547.79 | 262.71 | 323.06 |
| hot-key | 254.65 | 327.26 | 547.43 | 544.57 | 272.64 |
| shifting-hot-key | 251.42 | 337.20 | 541.41 | 550.74 | 269.30 |
| low-hit-rate | 260.96 | 259.63 | 260.22 | 260.55 | 257.31 |

固定客户端缓存相对 `bypass` 在 stable、burst、hot-key 和
shifting-hot-key 下分别达到 `2.15x`、`2.13x`、`2.15x` 和 `2.15x`。
固定双端缓存对应为 `2.16x`、`1.02x`、`2.14x` 和 `2.19x`。burst 的
双端结果存在明显宿主调度波动，五轮为 `443.20/261.57/225.27/549.53/262.71`
QPS，因此只报告中位数，不选择最好一轮。

| 负载 | BYPASS 回源 | SERVER | CLIENT | DUAL | DYNAMIC |
| --- | ---: | ---: | ---: | ---: | ---: |
| stable | 2180 | 0 | 8 | 0 | 1308 |
| burst | 2200 | 0 | 3 | 0 | 1320 |
| hot-key | 2200 | 0 | 1 | 0 | 1320 |
| shifting-hot-key | 2200 | 0 | 2 | 0 | 1320 |
| low-hit-rate | 2180 | 2180 | 2180 | 2180 | 2180 |

回源计数包含每轮 warmup。客户端固定策略中的少量回源来自 DNS 首次学习；
burst 的 2 到 3 次回源还包含并发填充竞态。

## 动态切换

| 负载 | 窗口 4-5 实际模式 | 切换后 QPS | 同窗口 BYPASS | 提升 | 切换后回源 |
| --- | --- | ---: | ---: | ---: | ---: |
| stable | 5 次 SERVER | 327.46 | 246.95 | 1.33x | 0 |
| burst | 5 次 CLIENT | 545.24 | 256.37 | 2.13x | 0 |
| hot-key | 5 次 SERVER | 322.58 | 259.63 | 1.24x | 0 |
| shifting-hot-key | 5 次 SERVER | 330.49 | 254.23 | 1.30x | 0 |
| low-hit-rate | 5 次 BYPASS | 262.87 | 262.76 | 1.00x | 436 |

stable 第 5 轮先在 epoch 2 切到 `SERVER_CACHE`，随后两个连续窗口都观察到
高网络长尾，在 epoch 3 前移到 `CLIENT_CACHE`。其余 stable 轮次停在
`SERVER_CACHE`。epoch 3 的发布发生在最后一个窗口结束后，因此本轮没有把
CLIENT 模式计入性能表。所有切换均先出现 `*_pending`，下一窗口候选仍一致后
才提交，`publish_failed=0`，运行时 map 错误为 0。

## 完整性与清理

- `runs.csv` 125 行数据，`windows.csv` 625 行数据，`summary.csv` 25 行数据。
- 25 份动态决策流和 25 份审计日志齐全。
- 125 份 ingress 和 125 份 egress TC 快照均满足 DNS/gRPC handle 位于
  NetMig `0x65/0x66` 前。
- `cleanup_status=0`、`cleanup_residue=0`；实验 pin、进程和 TC `0x1/0x2`
  均无残留，NetMig `0x65/0x66` 保留。
- 临时附加的 gRPC/SSH 安全组已从两台实例移除；实例仍为 `ACTIVE`，只保留原
  DNS 实验安全组。

后台启动器没有继承 DevStack `openrc`，所以原始
`openstack-servers.txt/openstack-ports.txt` 记录了认证缺失。性能流量和
OVS/tap 证据不受影响；完成后使用认证环境补录
`post-audit-openstack-evidence.txt`，其 SHA256 为
`81572f1be7271a1ecaad19d23eecb8de1d6d2a7dae065a450aed9b88af5250cb`。
实验脚本现已将认证 OpenStack 证据设为默认强制门禁，避免以后静默产生同类缺口。

外层 SSH 启动器的退出码文件因换行转义写成了 `0n`。campaign 本身生成了完整
summary，结尾清理文件为 `cleanup_status=0`，后台进程退出；本结果不把该外层
标记当作独立成功证据。

本次原始 `windows.csv` 的 `mode/epoch` 是窗口结束后决策发布的状态。正式结果
根据决策流还原了产生窗口数据的实际模式。脚本现已拆分为
`applied_mode/epoch` 和 `next_mode/epoch`，后续运行不再存在该标签歧义。

## 发布边界

本批 `ae5be57` 证据记录的是 controller `--dry-run` 决策后，由 campaign 顺序写入
三个位置的 map；它证明五类负载的性能和各次串行发布日志，不证明跨主机原子提交。
P1 的多端健康门禁、prepare/readback/commit、迁移冻结和失败 `BYPASS` 尚未由本批
结果覆盖。
