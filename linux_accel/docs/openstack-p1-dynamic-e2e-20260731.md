# OpenStack P1 动态 DNS/gRPC systemd 单轮 E2E 结果（2026-08-01）

## 结论

Shuka1 上的固定主机 P1 自动闭环已完成一次有效真实 smoke：

```text
OpenStack/Neutron 端口发现
  -> master Compute Agent 管理两个 VM-facing tap
  -> client/backend Guest Agent 启动各自数据面
  -> metrics bridge 消费真实 DNS/gRPC 累计指标
  -> dynamic controller 选择 SERVER_CACHE
  -> epoch coordinator 完成四参与者健康门控和分阶段发布
  -> DNS/gRPC 计量请求命中缓存
  -> shutdown 栅栏发布最终 BYPASS
  -> systemd stop 和所有权清理
```

本轮 epoch 序列为：

```text
state baseline 75
  -> epoch 76 BYPASS
  -> epoch 77 SERVER_CACHE
  -> epoch 78 BYPASS (shutdown=true)
```

本轮证明：

- backend guest `ens3` 上的 generic XDP DNS server cache 能在内核直接返回响应。
- gRPC 由 Guest 内 `grpc_fast_cache` 用户态 h2c 代理返回缓存响应；代理受 pinned eBPF
  runtime map 控制，宿主 TC eBPF 只负责观测。
- 同一 master 上 client/backend gRPC runtime pin 是不同 BPF map。
- 结束后所有本轮 unit、pin、quiesce、进程、XDP、listener 和自有 TC hook 均已清理。
- NetMig 原有 `0x65/0x66` TC 程序在本轮 preflight 与 cleanup 间身份不变。

本轮不是五轮正式性能实验，也没有同轮 BYPASS 性能基线，因此不能计算或宣称
DNS/gRPC 加速比，更不能描述为“gRPC 在内核中直接生成响应”。

## 环境

| 项目 | 值 |
| --- | --- |
| 源码分支/基点 | `feature/openstack-dns-e2e` / `50eb404d3e5102366921d7b46d19c6b1f22413f4` |
| OpenStack Compute | `master`、`compute2`、`compute3` 均 `enabled/up`；本轮两个业务实例均在 `master` |
| 镜像 | `ubuntu-24.04-noble-cloud` |
| Flavor | `ds2G`：2 vCPU、2 GiB RAM、10 GiB disk |
| Guest kernel | `6.8.0-134-generic` |
| client | `private-p7-dns-path-r19-client` / `10.0.0.43` |
| backend | `private-p7-dns-path-r19-backend` / `10.0.0.55` |
| client port | `2200c160-c07d-43ea-9cda-5aabd4e54d37` / `fa:16:3e:42:69:89` |
| backend port | `8ddb7d32-92ab-41e2-b5b9-94596bef3952` / `fa:16:3e:30:1c:70` |
| DNS | `hot.dynamic.test`，UDP/53，回答 `10.0.0.55` |
| gRPC | `/grpc.health.v1.Health/Check`，h2c，Guest fast-cache |

真实 preflight artifact：

```text
/var/log/vnet-dataplane-e2e/p1-preflight-repaired-smoke-20260801T1300Z
```

有效 smoke artifact：

```text
/var/log/vnet-dataplane-e2e/p1-dynamic-dns-grpc-repaired-one-round-20260801T1305Z
```

## 单轮结果

每种协议使用 10 个 warmup 和 40 个计量请求。计量窗口位于
`epoch 77 / SERVER_CACHE`。

| 协议 | 成功/失败 | QPS | avg | p50 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| DNS | 40/0 | 518.42 | 1927.16 us | 605.64 us | 8815.50 us | 10632.55 us |
| gRPC | 40/0 | 813.17 | 954.27 us | 911 us | 1271 us | 1288 us |

这些绝对值只用于功能 smoke。正式性能结论必须在同一环境、同一请求参数下比较固定
策略和动态策略，并至少运行五轮后报告中位数、min/max。

## DNS 快路证据

计量前后累计指标：

```text
backend_count 100 -> 100
cache_hit       0 -> 50
cache_tx        0 -> 50
cache_miss      0 -> 0
policy_bypass 100 -> 100
```

40 个计量请求和 10 个 warmup 全部成功，backend 计数增量为 0；同时 XDP
`cache_hit/cache_tx` 各增加 50。这证明计量窗口由 backend guest DNS server XDP
cache 返回，而不是 userspace backend 回源成功后被误记为 cache hit。

## gRPC 快路证据

计量前后累计指标：

```text
accepted           100 -> 150
cache_hit            0 -> 50
serving_cache_hit    0 -> 50
fallback           100 -> 100
fallback_error       0 -> 0
parse_error          0 -> 0
tx_error             0 -> 0
runtime_epoch       76 -> 77
```

50 个总请求全部由 Guest 用户态 h2c fast-cache 命中，没有新增 fallback 或错误。
`grpc_kernel_response=false` 是结果合同的一部分。

## 身份、门控与发布

- attach 和 cleanup 两次 OpenStack 指纹重查均为 `stable=true`。
- 两个端口在三次观测中始终为 `ACTIVE`，server、port、host、MAC 和 IPv4 一致。
- master Agent 同时发布两个健康 attachment，分别对应 `tap2200c160-c0` 和
  `tap8ddb7d32-92`，ifindex 分别为 21 和 15。
- client/backend Guest Agent 均为 `ready=true`；backend DNS XDP 程序 ID 为 226。
- `map-identities.json` 的三项独立性断言全部通过；master client/backend gRPC
  runtime map ID 分别为 `307474` 和 `307465`。
- `epoch 76/77/78` 每次均有 4 个 endpoint readback；最终 BYPASS 包含
  `shutdown=true`。

## 清理与证据完整性

`cleanup-evidence.json` 为 `passed=true`，并以 `run_preflight` 作为 NetMig 基线。
以下七类检查全部通过：

```text
units_inactive
pins_removed
quiesce_removed
processes_absent
xdp_detached
listeners_absent
tc_cleanup
```

清理合同保留 47 个原始观察文件；整个 run 共 118 个普通证据文件，全部进入
`sha256sums.txt`。独立审计同时验证了 manifest 文件集合精确相等、哈希通过，以及
master、compute2、client guest、backend guest 的相关 unit 当前均为
`inactive/dead`。

## 无效样本与根因

以下早期尝试必须保留为无效样本，不得进入性能聚合：

```text
/var/log/vnet-dataplane-e2e/p1-dynamic-dns-grpc-hardened-one-round-20260731T194758Z
```

该轮有两个独立问题：

1. runner 在 `if verify_smoke` 条件函数中依赖 `set -e`，导致 Python 已写出
   `passed=false` 后仍被后续赋值覆盖为函数成功。
2. workload 查询 `hot.dynamic.test`，而 DNS server cache 只预装精确键
   `dynamic.test`，因此 50 个请求全部 cache miss 并回源。

修复后验证命令显式 `|| return 1`，生命周期测试增加“延迟收敛”和“永不收敛”两类
回归；Shuka1 策略同时预装 `hot.dynamic.test 10.0.0.55 60`。

## 构建与回归

- 本地 OpenStack Python 回归：212 项通过，11 项按环境跳过。
- epoch coordinator 定向回归：44 项通过。
- Shuka1 lifecycle action-driver 回归通过，包含指标不收敛、发布失败和缺清理证据。
- Shuka1 DNS harness domain validation 通过。
- runner、coordinator、lifecycle test 和 DNS policy 的本地/远端 SHA256 一致。
- Shuka1 上对精确候选重新执行 `scripts/build_linux.sh`：四个 eBPF 对象、十个
  C/C++ 可执行程序和全部本地测试构建成功，Python 回归 215 项通过。
- root 门禁依次通过 `bpf_runtime_verifier_test.sh`、
  `runtime_control_bpf_integration_test.sh`、`cache_policy_txn_integration_test.sh`、
  `dns_runtime_mode_integration_test.sh` 和 `grpc_runtime_mode_integration_test.sh`。
- 真实 Shuka1 环境暴露并修复了两个测试路径问题：bpffs 不接受带 `.` 的临时 pin
  目录名；`/run` 挂载为 `noexec`，测试二进制必须在独立 `/tmp` 目录执行。修复后
  策略事务集成测试完整通过，且两类临时目录均由白名单清理。
- 构建和内核门禁后的独立清理证据位于
  `/var/log/vnet-dataplane-e2e/p1-post-kernel-gates-cleanup-20260801T0445Z`：状态为
  `cleanup_audit_passed`，七类检查全部为真，47 个原始清理观察均在，72 个普通文件
  的 `sha256sums.txt` 全部校验通过。

## 尚未完成

固定在 `master` 的 DNS/gRPC systemd 自动闭环已经通过，但 P1 仍缺：

- 无人干预的 `master -> compute2 -> master` 迁移过程中 freeze、重挂载和恢复发布。
- 迁移期间请求连续性、最大中断时间和 reattach 耗时。
- 真实故障注入后的跨节点 `BYPASS` 收敛证据。
- 五类负载各五轮的 P2 正式联合实验。

本轮固定宿主基础随本报告所在提交保存；尚未合并 `main`，也未开始五轮正式性能实验。
