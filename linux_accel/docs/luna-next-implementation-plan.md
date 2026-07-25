# Luna 后续实现计划

本文档供 Luna 直接执行。目标是从当前已完成的 DNS/gRPC 模块出发，
补齐比赛最重要的 OpenStack DNS 双端缓存端到端证据，再完成动态策略、
测试和文档收尾。

## 0. 当前基线

- 仓库：`Yukinoshita03/vnet-dataplane`
- 起点分支：`benchmark/dns-client-cache-comparison`
- 起点提交：`c5c5aa631778abf84a730e936907f5311ac1573a`
- 已完成：
  - DNS tc 监控、server-side XDP cache。
  - DNS client-side 自学习缓存与 `dns_client_pending` 安全学习链路。
  - 本地 `netns + bridge + veth` 的 baseline/server-only/client-only/both 对比。
  - gRPC h2c unary fast-cache、pinned response map、动态 `SERVING -> NOT_SERVING`。
  - OpenStack 三 VM gRPC guest-eBPF E2E，正式结果为 `2.31x` QPS。
- 尚未闭环：
  - OpenStack 真实 VM-to-VM DNS baseline/server/client/both E2E。
  - 缓存策略在线 list/add/update/delete 和自适应控制。
  - 测试矩阵中部分旧状态与最新实测结果不一致。

不要重新实现 gRPC fast-cache，也不要把 h2c demo 描述成 XDP gRPC cache。

## 1. 分支与工作区要求

开始前执行：

```bash
git fetch origin
git switch -c feature/openstack-dns-e2e \
  origin/benchmark/dns-client-cache-comparison
git status --short
```

只提交 `linux_accel/` 范围内与本计划有关的文件。不要提交仓库根目录现有的
VMware 截图、PowerShell 临时脚本、`agent/` 草稿或其他无关文件。

先阅读：

```text
linux_accel/bench/openstack_grpc_e2e.sh
linux_accel/bench/dns_dual_end_cache_bench.sh
linux_accel/bpf/dns_client_cache.c
linux_accel/bpf/dns_xdp_monitor.c
linux_accel/src/dns_monitor.cpp
linux_accel/src/cachectl.cpp
linux_accel/docs/openstack-grpc-e2e.md
linux_accel/docs/dns-client-cache-comparison.md
```

## 2. P0：OpenStack DNS 双端缓存 E2E

### 2.1 新增文件

至少新增：

```text
linux_accel/bench/openstack_dns_e2e.sh
linux_accel/bench/openstack_dns_harness.c
linux_accel/docs/openstack-dns-e2e.md
```

`openstack_dns_e2e.sh` 可以复用 `openstack_grpc_e2e.sh` 的以下模式：

- OpenStack 凭据加载。
- 临时 VM、安全组、浮动 IP 和配额管理。
- SSH/SCP、guest 命令执行和超时等待。
- `trap` 清理以及 `KEEP_RESOURCES=1` 诊断开关。
- artifact 目录、`run.log`、`topology.txt` 和 `summary.md`。

不要在本轮大规模重构两个 OpenStack 脚本。只有当公共代码边界明确且不影响
现有 gRPC 回归时，才提取小型公共 helper。

### 2.2 测试拓扑

使用 Ubuntu 24.04 cloud image，保证 guest 支持：

```text
bpffs
generic XDP
tc clsact
libbpf 运行依赖
```

目标拓扑：

```text
client VM
  -> client-side cache hook
  -> OpenStack OVN/OVS private network
  -> server-side cache hook
  -> DNS backend VM/process
```

可以使用两个 VM，也可以使用 client/cache/backend 三 VM；但所有场景必须使用
同一网络、同一请求生成器、同一请求数量和同一 DNS 响应内容。

优先尝试 host-side client tap/veth：

- 查询从 client VM 发出，在 host-side 接口 ingress 被 XDP 观察。
- 响应进入 client VM 前，在同一接口 tc egress 被学习。

server-side hook 根据实际包方向选择 guest 网卡或可用的 host-side veth。
选择前必须用 `openstack port show`、`ovs-vsctl`、`ip link` 和短时
`tcpdump` 证明 VM、tap/veth、OVS port 与流量方向的映射。

如果目标 tap/OVS port 不支持 XDP：

1. 记录 attach 错误和接口类型。
2. 尝试 generic XDP。
3. 仍失败时切换到 Ubuntu guest 内的 eBPF。
4. 在结果中明确标记 `host-side` 或 `guest-ebpf`，禁止混写。

### 2.3 DNS harness

`openstack_dns_harness.c` 至少支持：

```text
server --listen <ip:53> --domain <name> --answer <ipv4> --ttl <sec>
client --server <ip:53> --domain <name> --expect <ipv4>
       --requests <n> --warmup <n>
```

客户端输出：

```text
success
failed
qps
avg_us
p50_us
p95_us
p99_us
```

服务端输出或文件记录累计 backend 请求数。解析时校验 DNS ID、问题字段、
RCODE、A 记录和值，不能只判断 UDP `recvfrom()` 成功。

### 2.4 场景矩阵

同一轮必须完成：

| 场景 | Hook | 后端请求预期 |
| --- | --- | --- |
| baseline | 无 | 等于 warmup + requests |
| monitor-only | tc monitor | 等于 warmup + requests |
| server-only | server XDP cache | 0 |
| client-only | client XDP + tc learner | warmup 学习后保持为 1 |
| both | client cache + server cache | 首次 client miss 由 server hit，backend 为 0 |

正确性附加测试：

- client TTL 过期后重新访问后端或下一级缓存。
- 不可信 resolver 响应不得学习。
- NXDOMAIN 不得进入当前正向 A 记录缓存。
- resolver 地址必须属于 cache key，不能跨 resolver 污染。
- 不支持的 AAAA、EDNS、多问题请求必须 fail-open。

### 2.5 指标和断言

脚本必须采集并自动检查：

```text
cache_hit
cache_miss
cache_expired
cache_tx
cache_learned
learn_rejected
pending_expired
ringbuf_drop
backend_requests
success/failed
qps
avg/p50/p95/p99
```

硬性通过条件：

- 所有正式场景 `failed=0`。
- server-only：`cache_hit > 0`、`cache_tx > 0`、`backend_requests=0`。
- client-only：`cache_learned > 0`、`cache_hit > 0`、学习后 backend 不增长。
- both：首次请求出现 server hit，随后出现 client learn 和 client hit。
- 安全回退测试全部满足预期。
- `ringbuf_drop=0`，否则必须解释并降低采样压力后复测。

### 2.6 重复性和 artifact

开发阶段至少运行 1 次完整矩阵，正式数据运行 5 次。报告中使用中位数，并保留
min/max；不要只记录最好的一次。

每次生成：

```text
environment.md
topology.txt
openstack-servers.txt
openstack-ports.txt
ovs-ports.txt
interface-map.txt
baseline.log
monitor-only.log
server-only.log
client-only.log
both.log
backend-counts.txt
client-monitor.log
server-monitor.log
bpftool-map-dump.txt
cleanup-status.txt
summary.md
```

`summary.md` 必须写清：

- OpenStack、OVN/OVS、VM image、kernel、hook 位置和 XDP mode。
- 五组 QPS 与延迟。
- baseline 相对 server/client/both 的加速比。
- monitor-only 开销。
- backend 请求削减比例。
- 所有结论的边界。

## 3. P1：动态缓存策略控制面

OpenStack DNS E2E 稳定后再实现，不要与 P0 混在同一个提交。

扩展 `cachectl`：

```text
cachectl dns list
cachectl dns add
cachectl dns update
cachectl dns delete
cachectl dns flush
```

要求：

- 操作 pinned DNS map，不重新挂载 XDP/tc。
- 支持 client/server map 路径显式指定。
- list 输出 domain、resolver、answer、初始 TTL、剩余 TTL 和过期时间。
- add/update/delete 需要明确退出码和错误信息。
- `--replace` 先校验完整输入，再执行更新，避免半更新状态。
- 每次变更写审计日志：时间、操作、key、旧值、新值、结果。

随后实现最小自适应控制器：

- 输入：QPS、hit ratio、p99、backend requests、expired、map 容量。
- 热点提升：达到请求和命中收益阈值后允许进入 client cache。
- 冷项降级：低频或高失效率条目移除。
- 只处理白名单内的 DNS A/IN 条目。
- 默认 dry-run；显式 `--apply` 才修改 map。
- 每次决策记录原因和前后指标。

需要比较 `static`、`LRU`、`adaptive` 三种策略。

## 4. P1：测试与文档一致性

完成代码后：

1. 修正 `competition-completion-matrix.md` 中已过期的 gRPC G-08 状态。
2. 更新 `test-matrix.md`，将 OpenStack gRPC guest-eBPF 结果放入正式表格，
   不只追加在文末。
3. 加入 OpenStack DNS E2E 的真实结果和 artifact 路径。
4. README 只引用同环境、同方法的正式中位数。
5. 明确区分：
   - netns benchmark；
   - OpenStack host-side eBPF；
   - OpenStack guest-eBPF；
   - userspace fallback。

不要把本地 `7.14x` DNS 结果直接写成 OpenStack 加速比。

## 5. 验证顺序

本地/控制节点：

```bash
cd linux_accel
bash -n bench/openstack_dns_e2e.sh
./scripts/build_linux.sh
REPEAT=1 REQUESTS=200 WARMUP=20 ./bench/dns_dual_end_cache_bench.sh
REQUESTS=100 WARMUP=10 ./bench/grpc_fast_cache_bench.sh
```

Shuka1 OpenStack：

```bash
source /opt/stack/devstack/openrc admin admin
REPEAT=1 REQUESTS=100 WARMUP=10 GUEST_BPF=1 \
  bash bench/openstack_dns_e2e.sh
```

短测通过后：

```bash
REPEAT=5 REQUESTS=1000 WARMUP=100 GUEST_BPF=1 \
  bash bench/openstack_dns_e2e.sh
```

密码、私钥内容和 token 不得写入仓库、日志摘要或提交信息。

## 6. 清理验收

每次运行结束必须确认：

- 临时 VM、安全组、规则和浮动 IP 均已删除。
- 临时 quota 已恢复。
- 无残留 tc/XDP 程序和 qdisc。
- 无残留 `/sys/fs/bpf/<test-prefix>`。
- 无残留 benchmark 进程。
- `KEEP_RESOURCES=1` 只用于失败诊断，正式运行必须关闭。

清理失败视为测试失败。

## 7. 提交拆分

建议使用三个中文提交：

```text
实现 OpenStack DNS 双端缓存端到端测试
完善 DNS 运行时策略管理与自适应控制
更新 OpenStack 性能证据与赛题完成矩阵
```

每个提交前执行：

```bash
git diff --check
git status --short
```

只暂存本阶段相关文件。推送到：

```text
origin/feature/openstack-dns-e2e
```

## 8. 最终完成定义

只有同时满足以下条件才能报告完成：

- OpenStack DNS 五场景自动化脚本可从干净环境运行。
- 正确性、安全回退和资源清理均通过。
- 正式 5 轮数据完整，结论使用中位数。
- gRPC 现有构建和 benchmark 无回归。
- 文档状态与当前代码、当前 artifact 一致。
- 中文提交已推送，远端 commit 与本地 HEAD 一致。

本轮不做 AAAA/CNAME/EDNS 加速、TLS gRPC、streaming gRPC、Native XDP
硬件性能扩展；这些放在主线闭环后的增强阶段。
