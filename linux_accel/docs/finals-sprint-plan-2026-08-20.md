# 2026 操作系统设计赛决赛冲刺计划

> 队伍：桂林电子科技大学「回调鹰佐」
> 赛题：基于 eBPF 的网络服务加速与双端缓存系统
> 赛道：2026 年全国大学生计算机系统能力大赛操作系统设计赛（全国）OS 功能挑战赛道
> 计划周期：2026-07-13 至 2026-08-20
> 目标：冲击国一

## 1. 决赛目标

决赛前必须形成一条能现场复现、能解释边界、能用数据证明的业务闭环：

```text
真实或可复现的虚拟化网络路径
  -> eBPF 实时监控 DNS / gRPC
  -> 用户态控制面根据策略更新 BPF map
  -> 客户端侧与服务端侧缓存命中
  -> 未命中和异常请求安全回退
  -> 输出 QPS、p50/p95/p99、命中率、后端请求数和 CPU 开销
  -> 一键清理并恢复原网络状态
```

最终不以“代码数量”衡量完成度，而以以下结果衡量：

- 在一台干净 Ubuntu VM 上能够从零构建并运行全部稳定 demo。
- DNS 具备客户端侧和服务端侧两条真实快路径，不只停留在设计文档。
- gRPC 具备 eBPF 监控、动态策略和可验证的安全缓存加速路径。
- OpenStack/KVM 路径存在真实业务流量、真实挂载点和端到端数据，而不只是 attach smoke。
- 所有核心性能结论至少重复 5 次，报告中使用中位数并保留原始产物。
- 现场 demo 失败时有离线 artifact、录屏和可解释的降级演示。

## 2. 评分项映射

| 评分项 | 权重 | 决赛策略 | 必须拿出的证据 |
| --- | ---: | --- | --- |
| 实现完成度 | 30% | 补齐 DNS 双端缓存、gRPC 第二服务、动态策略、虚拟化端到端路径 | 源码、测试矩阵、三路径 benchmark、OpenStack workload |
| 创新性 | 25% | 做“拓扑感知的双端缓存放置 + 基于工作负载的动态策略”，不只做静态 map | 策略状态机、命中率/后端负载变化、对比实验 |
| 代码质量 | 20% | 收拢公共 map schema、拆分控制面、补单测和集成测试、严格清理资源 | CI、测试、静态检查、错误路径、无残留网络资源 |
| 文档完整性 | 15% | 需求到实现到证据一一对应，所有结论标注环境与边界 | 架构、测试、benchmark、部署、限制、答辩问答 |
| Demo 质量 | 10% | 5 分钟主 demo + 备用录屏，输出清楚且不依赖临场手工配置 | 一键脚本、固定拓扑、实时指标、结果表、清理结果 |

## 3. 国一主线与范围控制

### 3.1 必做主线

1. DNS 服务端 XDP cache 稳定化。
2. DNS 客户端侧 host-veth XDP cache 真正落地。
3. 双端缓存动态策略：角色、TTL、容量、启停、热度放置可在线更新。
4. gRPC tc eBPF 监控与 h2c unary fast-cache 稳定化。
5. OpenStack/KVM 真实 VM 流量观测和至少一条真实加速路径。
6. 可重复 benchmark、自动清理、测试矩阵和决赛演示。

### 3.2 暂不扩展

- 不实现完整递归 DNS、DNSSEC 或所有 DNS RR 类型。
- 不尝试在 XDP 中实现完整 HTTP/2/gRPC 状态机。
- 不把 Kubernetes 与 OpenStack 同时作为主现场环境；OpenStack/KVM 为主，Kubernetes 作为补充证据。
- 不继续扩展 `vnet-agent`、虚拟网卡驱动和通用 packet parser，除非它们直接阻塞决赛 demo。
- 不追求界面型 Dashboard；终端实时指标、Markdown 报告和图表足够。

## 4. 技术目标

### 4.1 DNS 双端缓存

目标拓扑：

```text
client netns / VM
  |
  | request TX
  v
host-side client veth/tap RX
  |-- client cache hit -> XDP_TX -> client
  |-- miss -> XDP_PASS
  v
bridge / OVS
  v
server-side interface RX
  |-- server cache hit -> XDP_TX -> client
  |-- miss -> XDP_PASS
  v
traditional DNS service
```

必须支持并验证：

- `A/IN` 单问题命中。
- 客户端 miss、服务端 hit。
- 双端都 miss 后进入传统 DNS。
- TTL 过期后回退。
- 缓存在线新增、更新、删除和禁用。
- AAAA、分片、多个 Question、畸形包安全放行或拒绝，不伪造响应。
- 客户端命中时服务端和后端请求计数不增长。
- 服务端命中时传统 DNS 服务请求计数不增长。

### 4.2 动态缓存策略

第一阶段策略字段：

```text
service=dns|grpc
role=client|server|both
mode=disabled|static|lru|adaptive
ttl=<seconds>
max_entries=<count>
admission_qps=<threshold>
demotion_seconds=<seconds>
```

`adaptive` 最小可交付定义：

- 只在管理员白名单内选择缓存对象，避免自动学习造成缓存污染。
- 控制面周期读取 hit/miss、请求频率和延迟。
- 热点超过阈值时将记录提升到客户端侧缓存。
- 长时间无命中时从客户端侧降级，仅保留服务端缓存或删除。
- 所有策略调整写入日志，能够解释“为什么移动这条缓存”。

### 4.3 gRPC 第二服务

保持窄范围：

- TCP/IPv4、h2c、unary RPC。
- eBPF tc ingress/egress 监控请求、响应、RTT、超时和 drop。
- 只缓存显式标记为 `idempotent` 的方法。
- key 使用 `method_hash + payload_hash`。
- 支持 SERVING、NOT_SERVING、response miss 和 policy miss。
- 所有 miss 必须回退后端，`fallback_error=0`。

不宣称：

- 不支持 TLS 解密。
- 不支持 streaming RPC。
- 不支持任意 protobuf 响应缓存。
- 当前加速数据面仍是 eBPF 策略驱动的用户态 fast-cache/proxy，不伪装成 XDP 内核 gRPC cache。

### 4.4 虚拟化路径

主验证环境为 VMware DevStack/OpenStack：

```text
VM application
  -> tap/qvo/veth
  -> br-int
  -> br-ex / host service / another VM
```

最终至少完成：

- 自动发现 VM 对应 tap/qvo/veth/OVS 端口。
- `br-int` 上 DNS/gRPC tc monitor 观察到真实非零业务流量。
- 一条 VM-to-host 或 VM-to-VM DNS 加速实验。
- 比较 baseline、monitor-only、server cache、client cache/both。
- 记录 VM、OVS、接口、hook、CPU、内核、请求量和清理状态。

## 5. 时间计划

## 阶段 0：基线冻结与风险清点（07-13 至 07-15）

目标：确认现有结果在当前代码和当前 VM 上仍然成立，停止依赖旧 artifact。

### 07-13

- [ ] 在干净测试目录 checkout 当前 `main`。
- [ ] 修复 Linux shell 的 CRLF 和执行权限问题，确保 Git checkout 后可直接运行。
- [ ] 执行 `scripts/build_linux.sh`，记录编译器、内核、libbpf、bpftool 版本。
- [ ] 对照 `build/` 检查 8 个预期产物。
- [ ] 建立 `artifacts/finals-baseline/<timestamp>/environment.md`。

### 07-14

- [ ] 连续运行 DNS XDP benchmark 3 次。
- [ ] 连续运行 gRPC fast-cache benchmark 3 次。
- [ ] 运行虚拟化 bridge benchmark。
- [ ] 运行结束后检查 netns、veth、bridge、tc、XDP 是否残留。
- [ ] 记录所有失败、偶现问题和手工步骤。

### 07-15

- [ ] 建立“现有声明审计表”：文档每个完成项必须能指向当前源码和当前 artifact。
- [ ] 将旧数据标为 historical，不与本轮结果混用。
- [ ] 冻结决赛 MVP 范围和接口命名。

阶段验收：

```text
clean build = pass
DNS 3/3 runs = pass
gRPC 3/3 runs = pass
virt path = pass
cleanup residuals = 0
```

## 阶段 1：DNS 客户端侧 XDP 快缓存（07-16 至 07-22）

目标：把“双端缓存”从设计文档变为真实代码和 benchmark。

### 07-16

- [ ] 画出 client/server 两端接口方向和 XDP hook 图。
- [ ] 确定客户端侧挂载点：client netns/VM 对应的 host-side veth/tap ingress。
- [ ] 定义 client/server map 命名、pin 路径和 role 配置。

### 07-17 至 07-18

- [ ] 复用 DNS XDP response 逻辑，支持显式 `--role client|server`。
- [ ] 避免复制两份不可维护的协议解析代码；共享 map schema 和可验证 helper。
- [ ] 增加缓存命中端标识与独立计数器。

### 07-19

- [ ] 新增 `bench/dns_dual_end_cache_bench.sh`。
- [ ] 构建 client netns、host-side veth、bridge、server namespace/service 拓扑。
- [ ] 增加后端请求计数器，证明命中时确实没有到达后端。

### 07-20 至 07-21

- [ ] 验证四条路径：baseline、server-only、client-only、both。
- [ ] 验证 client miss -> server hit。
- [ ] 验证 both miss -> userspace backend。
- [ ] 验证 TTL 过期和不支持请求回退。

### 07-22

- [ ] 补集成测试、清理检查、拓扑文档和第一轮性能表。
- [ ] 连续运行 5 次，记录中位数和离散程度。

阶段验收：

```text
client cache hit > 0
server cache hit > 0
client miss -> server hit = pass
both miss -> backend = pass
TTL expiry = pass
unsupported query fallback = pass
backend requests on client hit = 0
5 repeated runs = pass
```

## 阶段 2：动态策略与正确性（07-23 至 07-29）

目标：回应赛题“动态配置客户端和服务器端缓存算法”和“根据工作负载智能调整”。

### 07-23

- [ ] 扩展策略文件 schema，加入 role、mode、容量和热度阈值。
- [ ] `cachectl --validate-only` 覆盖新字段和错误提示。

### 07-24 至 07-25

- [ ] 实现缓存在线新增、更新、删除、启停。
- [ ] 支持 client/server 两端 pinned map，更新时不重新挂载 XDP。
- [ ] 增加策略变更审计日志。

### 07-26 至 07-27

- [ ] 实现最小 adaptive controller。
- [ ] 只对白名单候选项做热点提升和冷项降级。
- [ ] 输出每次决策的 QPS、hit ratio、延迟和原因。

### 07-28

- [ ] 修复 DNS 大小写归一化问题。
- [ ] 响应 TTL 改为剩余 TTL，而不是始终返回初始 TTL。
- [ ] 检查 LRU 淘汰、过期删除和并发更新行为。

### 07-29

- [ ] 设计稳定负载、热点切换负载和冷启动负载三组实验。
- [ ] 对比 static、LRU、adaptive 的命中率、p99、后端 QPS 和控制面开销。

阶段验收：

```text
online add/update/delete = pass
role switch without reattach = pass
hot entry promotion = pass
cold entry demotion = pass
remaining TTL correctness = pass
case-insensitive DNS key = pass
policy decision log = complete
```

## 阶段 3：gRPC 第二服务加固（07-30 至 08-04）

目标：保证第二服务不是“能运行一次的 demo”，而是可重复、可解释、可回退。

### 07-30

- [ ] 重新走读 `grpc_monitor.c`、`grpc_monitor.cpp`、`grpc_fast_cache.cpp`。
- [ ] 画出 tc monitor、pinned policy map、fast-cache 和 backend 的数据流。

### 07-31 至 08-01

- [ ] 加固 `grpc_policy_map` 在线更新。
- [ ] 检查 method hash、payload hash、TTL 和 key 冲突边界。
- [ ] 补策略非法、非幂等方法和未知 payload 测试。

### 08-02

- [ ] 保证 SERVING、NOT_SERVING、response miss、policy miss 四组路径稳定。
- [ ] 增加后端请求计数，证明 cache hit 不访问后端。

### 08-03

- [ ] 连续运行 gRPC benchmark 5 次。
- [ ] 记录 QPS、p50/p95/p99、cache hit、fallback、CPU、RSS。

### 08-04

- [ ] 更新 gRPC 边界说明和失败降级方案。
- [ ] 冻结 gRPC 功能，不再扩展 TLS/streaming。

阶段验收：

```text
tc monitor non-zero events = pass
SERVING/NOT_SERVING hit = pass
response/policy miss fallback = pass
fallback_error = 0
backend requests on cache hit = 0
5 repeated runs = pass
```

## 阶段 4：OpenStack/KVM 真实路径（08-05 至 08-10）

目标：将“可挂载”升级为“真实业务路径有可观测数据和加速结果”。

### 08-05

- [ ] 清点 DevStack 服务状态、VM、网络、subnet、router、floating IP 和 OVS 端口。
- [ ] 建立 VM 到 tap/qvo/veth/br-int 的映射报告。

### 08-06 至 08-07

- [ ] 创建稳定 DNS workload VM/namespace。
- [ ] 在 `br-int` 或确定的 VM host-side 接口挂 tc monitor。
- [ ] 证明真实 VM DNS 请求和响应计数非零。

### 08-08

- [ ] 在可支持的 host-side veth/tap 位置验证 Generic XDP 或选择 tc 路径。
- [ ] 跑 baseline、monitor-only、cache 三组实验。

### 08-09

- [ ] 运行 VM-to-host 或 VM-to-VM DNS workload，记录端到端 RTT、QPS、p99、CPU 和后端请求数。
- [ ] 保留 `tcpdump`、`tc`、`bpftool`、`ovs-vsctl` 和 OpenStack CLI 证据。

### 08-10

- [ ] 固化一键 OpenStack evidence 脚本。
- [ ] 验证 attach、运行、detach 和资源清理连续 3 次成功。

阶段验收：

```text
VM -> interface mapping = complete
real VM DNS traffic counters > 0
baseline/monitor/cache comparison = complete
attach/detach 3/3 = pass
OpenStack resources restored = pass
```

## 阶段 5：代码质量、测试与性能严谨性（08-11 至 08-14）

### 08-11

- [ ] 统一公共 BPF map schema 和用户态结构体。
- [ ] 检查对齐、字节序、边界检查、错误码和资源释放。
- [ ] 清理重复代码和无用实验分支。

### 08-12

- [ ] 为 DNS 编码、策略解析、TTL、非法输入补用户态单元测试。
- [ ] 为 hit/miss/expired/unsupported/cleanup 补 Linux 集成测试。

### 08-13

- [ ] CI 增加用户态构建测试、shell syntax check、敏感信息扫描。
- [ ] Linux 特权 benchmark 不放普通 CI，改为文档化 nightly/manual job。

### 08-14

- [ ] 所有核心 benchmark 使用统一 warmup、请求量、重复次数和统计方法。
- [ ] 至少记录 median、min/max 或标准差，不用单次最好结果。
- [ ] 加入监控开销对比：no-hook 与 tc-monitor。

阶段验收：

```text
unit/integration tests = pass
shell syntax = pass
sensitive scan = pass
cleanup tests = pass
benchmark methodology = unified
```

## 阶段 6：文档、答辩和 Demo（08-15 至 08-18）

### 08-15

- [ ] 更新架构图：控制面、数据面、双端挂载点、miss fallback。
- [ ] 更新赛题完成度矩阵，每项链接源码、测试和 artifact。
- [ ] 更新限制说明，删除无法证实或过度外推的性能声明。

### 08-16

- [ ] 生成最终性能表和 3 至 5 张核心图。
- [ ] 与传统用户态 DNS、tc monitor、Xpress DNS 做同环境对比。
- [ ] 写清测试环境、Generic/Native XDP 区别和公平性边界。

### 08-17

- [ ] 完成 5 分钟主 demo 脚本。
- [ ] 完成 10 至 15 分钟技术讲解脚本。
- [ ] 录制无剪辑备用 demo 视频。

### 08-18

- [ ] 至少进行 3 次完整模拟答辩。
- [ ] 建立评委问题清单，重点覆盖正确性、安全性、创新点、公平对比和生产边界。
- [ ] 根据模拟答辩只修阻塞问题，不再新增功能。

阶段验收：

```text
5-minute demo <= 5 minutes
demo success 3/3
offline video available
every slide claim has evidence
question bank reviewed
```

## 阶段 7：冻结与最终检查（08-19 至 08-20）

### 08-19

- [ ] 建立 release tag 候选版本。
- [ ] 在干净 VM 从 README 开始完整构建和演示。
- [ ] 冻结源码、脚本参数、数据和幻灯片。
- [ ] 备份仓库、artifact、PPT、PDF、视频和依赖包。

### 08-20

- [ ] 只处理 P0 阻塞问题。
- [ ] 检查现场机器、sudo、网络接口、内核、磁盘和投屏。
- [ ] 准备离线依赖与第二台备用环境。
- [ ] 最终演练一次后停止改动，保证休息和现场稳定性。

## 6. 每日执行制度

每天结束前更新本文件或独立日志，至少记录：

```text
今日目标
完成项
对应 commit
运行命令
artifact 路径
关键指标
失败原因
明日第一件事
```

每个任务必须满足 Definition of Done：

```text
代码完成
测试通过
错误路径验证
资源清理验证
文档更新
artifact 可回溯
中文 commit 并推送
```

每周日晚执行：

- 汇总本周成功率和未关闭 P0/P1 问题。
- 在干净目录运行一次完整构建。
- 重新跑一次主 demo。
- 删除或延期无法直接提高评分的任务。

## 7. Demo 设计

### 7.1 五分钟主 Demo

```text
00:00-00:30  展示拓扑与赛题问题
00:30-01:00  一键构建和环境检查
01:00-02:00  传统 DNS baseline
02:00-03:00  client/server 双端 XDP cache 与实时 hit/miss
03:00-03:40  TTL 过期和未命中安全回退
03:40-04:20  gRPC cache hit/fallback
04:20-05:00  OpenStack 路径证据和性能总结
```

### 7.2 Demo 必须实时显示

- 拓扑和 hook 位置。
- 当前策略和 client/server map 内容。
- 请求数、hit、miss、expired、fallback、backend count。
- QPS 与 p99。
- attach 前后状态。
- 清理后的 netns/veth/tc/XDP 状态。

### 7.3 备用方案

- 现场网络不可用：所有依赖和镜像离线可用。
- OpenStack 启动失败：播放无剪辑 OpenStack 录屏，同时现场跑 netns 双端缓存。
- XDP 驱动不支持：使用 Generic XDP，并明确说明 Native XDP 是后续硬件验证项。
- benchmark 波动：展示 5 次历史原始结果和中位数，不展示单次最好值。

## 8. 评委高频问题准备

必须能够不用看稿回答：

1. 为什么已有传统 DNS cache，还需要 XDP cache？
2. 客户端侧和服务端侧分别挂在哪里，数据方向是什么？
3. 为什么 `XDP_TX` 能把请求变成响应？
4. 未命中、过期、AAAA、EDNS、分片如何处理？
5. 如何避免 DNS cache poisoning 和跨租户污染？
6. 为什么 gRPC 不直接放进 XDP？
7. gRPC 的方法和 payload key 如何保证安全？
8. Generic XDP 与 Native XDP 的性能结论有什么区别？
9. benchmark 是否公平，为什么 Python stub 可以作为基线？
10. 监控本身带来多少开销？
11. OpenStack 中具体挂在 br-int、tap 还是 veth，为什么？
12. 项目的创新点和 ONCache、Xpress DNS 有什么不同？
13. BPF verifier、map 容量和并发更新有什么限制？
14. 生产化还缺什么？

## 9. 风险清单

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| DevStack/etcd/VM 不稳定 | OpenStack demo 失败 | 08-10 前固化环境；录屏；netns 现场兜底 |
| XDP 不支持目标接口 | 客户端/服务端路径无法挂载 | 优先 host-side veth Generic XDP；tc 作为观测回退 |
| 双端缓存导致回包方向错误 | 功能不可用 | 每条路径用 tcpdump 和 MAC/IP/端口日志验证 |
| TTL 或缓存更新错误 | 返回过期结果 | 剩余 TTL 测试、在线删除测试、白名单策略 |
| miss 路径开销过大 | 低命中率下性能下降 | 测 miss overhead；设置 admission threshold；允许禁用 |
| gRPC 功能范围过大 | 延误主线 | 冻结 h2c unary 和健康检查场景 |
| 性能数据波动 | 结论不可信 | 固定 CPU/负载、warmup、5 次重复、中位数、原始日志 |
| 脚本清理失败 | 污染现场网络 | `trap` 清理、幂等 cleanup、运行前后状态快照 |
| 文档过度声明 | 答辩被追问击穿 | 所有结论标注环境、路径、hook 和限制 |

## 10. 任务优先级规则

遇到时间冲突时按以下顺序取舍：

```text
P0  构建失败、网络无法恢复、demo 阻塞、数据错误
P1  DNS 双端缓存、动态策略、OpenStack 真实证据
P2  gRPC 稳定性、代码质量、测试与文档
P3  Native XDP、更多协议类型、更漂亮的输出
P4  新 UI、新服务、新框架和非赛题模块
```

任何新想法必须回答三个问题后才能进入计划：

1. 它直接提高哪一项评分？
2. 08-15 前能否完成代码、测试、文档和 demo？
3. 如果失败，是否会破坏现有稳定路径？

无法明确回答时，进入赛后 backlog。

## 11. 最终交付清单

### 代码

- [ ] DNS client/server 双端 XDP cache。
- [ ] 动态策略控制面和 pinned maps。
- [ ] DNS/gRPC eBPF monitor。
- [ ] gRPC safe fast-cache/fallback。
- [ ] OpenStack path/workload integration。
- [ ] 用户态单测和 Linux 集成测试。

### 实验

- [ ] DNS baseline/server/client/both 四组对比。
- [ ] static/LRU/adaptive 策略对比。
- [ ] gRPC hit/miss/fallback 对比。
- [ ] tc monitor overhead 对比。
- [ ] OpenStack VM 真实路径实验。
- [ ] Xpress DNS 或其他公开基线同环境对比。

### 文档

- [ ] README 快速开始。
- [ ] 架构与数据流图。
- [ ] 双端缓存设计与策略说明。
- [ ] 测试矩阵和原始证据索引。
- [ ] benchmark 方法与结果。
- [ ] OpenStack/KVM 部署文档。
- [ ] 安全、限制和生产化边界。
- [ ] 最终报告、PPT、演示手册、答辩问答。

### 现场材料

- [ ] 干净 release 包和 Git tag。
- [ ] 离线依赖。
- [ ] 主演示机器和备用机器。
- [ ] 无剪辑 demo 视频。
- [ ] 所有核心 artifact 的离线备份。

## 12. 第一项立即执行的任务

从以下任务开始，不先写新功能：

```bash
cd linux_accel
./scripts/build_linux.sh
DURATION=3 LATENCY_COUNT=3000 ./bench/dns_xdp_cache_bench.sh
REQUESTS=300 ./bench/grpc_fast_cache_bench.sh
REQUESTS=300 ./bench/virt_path_bench.sh
```

把三组最新结果写入 `artifacts/finals-baseline/`，确认当前主干可复现后，再开始客户端侧 XDP cache。
