# 比赛双平台展示方案

## 结论

做两套“部署适配”，不要做两套协议实现：

```text
同一套策略/协议逻辑
        |
        +-- OpenStack VM: OVS br-int -> TAP/veth -> generic XDP + TC
        |
        +-- Kubernetes:   CNI/overlay -> Pod veth -> TC 观测
                              (Pod-veth generic XDP 仍需 agent/image 验证)
```

现场入口是：

```bash
./bench/competition_dual_platform_demo.sh both plan
VM_NODE=node1 K8S_NODE=node1 \
  ./bench/competition_dual_platform_demo.sh both preflight
```

默认只生成展示卡或采集只读证据；真实运行必须显式加
`CONFIRM_LIVE=1`。这避免比赛前因为误 attach、误 apply 或误启动服务影响
OpenStack。

## 两个版本分别展示什么

| 维度 | OpenStack 虚拟机版 | Kubernetes 版 |
| --- | --- | --- |
| 入口 | `competition_dual_platform_demo.sh vm live` | `competition_dual_platform_demo.sh k8s live` |
| 拓扑 | OVS `br-int`、TAP、qvo/qvb/veth | CNI、Pod `eth0`、host-side veth、Service、overlay |
| DNS/UDP | 真实 VM/TAP generic XDP fastpath；exact-hit、miss、fail-open | 先展示 Pod 路径和 DNS/TC 计数；不要说成 native NIC XDP |
| gRPC | `grpc_monitor` TC 事件和已验证 h2c fast-cache 原型 | 在 Pod veth/CNI 路径展示 TC 事件；若没有真实 h2c workload，不要把 HTTP smoke 叫 gRPC |
| LDAP | TCP/用户态 splice/sockmap 版本单独展示 | 建议只展示协议路径/连接数，不在 K8s 现场临时引入 LDAP 服务 |
| 性能数字 | 可放 OpenStack TAP UDP/DNS 历史结果 | K8s 先放路径可见性/正确性；没有本次 live benchmark 就不报 K8s speedup |

## 推荐现场剧本（10 分钟）

### 1. 先讲共同数据面（1 分钟）

展示 `summary.md` 和项目结构，强调：

- 同一接口只有一个 XDP root/dispatcher，DNS、通用 UDP、ARP、DHCP 按协议和
  端口分流；不相关流量快速 `XDP_PASS`。
- XDP 只做确定性短路径；miss、过期、畸形、超长包和不支持的协议回到内核。
- gRPC/LDAP 不是“硬塞进 XDP”：gRPC 用 TC/用户态 h2c，LDAP 用 TCP 用户态
  splice/sockmap，保留 TLS/复杂语义的正确性边界。

### 2. VM 版（3 分钟）

只读检查：

```bash
VM_NODE=node1 ./bench/competition_dual_platform_demo.sh vm preflight
```

真实演示：

```bash
sudo -v
CONFIRM_LIVE=1 \
  VM_NODE=node1 \
  VM_IFACES='br-int br-ex ens33' \
  OPENSTACK_TARGET_IP=<backend-vm-ip> GRPC_PORT=50051 \
  REQUESTS=20 WARMUP=5 DURATION=8 \
  ./bench/competition_dual_platform_demo.sh vm live
```

如果要展示真实 TAP UDP fastpath，单独确认当前实例、TAP 和 release 后再开：

```bash
CONFIRM_LIVE=1 VM_UDP_FASTPATH=1 VM_FASTPATH_PROFILE=smoke \
  VM_NODE=node1 \
  CLIENT_INSTANCE=<current-client-instance> \
  BACKEND_INSTANCE=<current-backend-instance> \
  CLIENT_TAP=<current-client-tap> BACKEND_IP=<backend-ip> \
  ./bench/competition_dual_platform_demo.sh vm live
```

这一步会停/恢复 TAP adapter，并要求当前 OpenStack/Kubernetes 共存状态已经
通过预检；不能把历史默认实例 ID 当成现场 ID。VM 的 full UDP fastpath runner
现有安全门会要求 Kubernetes 单元保持 inactive；因此 VM XDP 性能段和 K8s
workload 段按顺序展示，不在同一时刻启动。

讲解结果时只抓三件事：

1. `tc-attach-summary.md`：DNS/gRPC TC attach 成功且能清理。
2. `workload-summary.md`：monitor 看到真实 VM 流量，`failed=0`。
3. UDP fastpath summary：miss 仍到后端，exact-hit 时 client XDP `hit/tx`
   增长、后端计数不增长。

### 3. K8s 版（3 分钟）

先不 apply 特权 DaemonSet，先展示真实路径：

```bash
KUBECONFIG=/Users/tankaiwen/.kube/school-k8s.yaml \
  K8S_NODE=node1 \
  ./bench/competition_dual_platform_demo.sh k8s preflight
```

API 正常且镜像已在节点缓存时，再运行临时 workload evidence：

```bash
CONFIRM_LIVE=1 \
  K8S_NODE=node1 \
  KUBECONFIG=/Users/tankaiwen/.kube/school-k8s.yaml \
  K8S_WORKLOAD_IMAGE=nginx:alpine \
  REQUESTS=20 WARMUP=5 DURATION=8 \
  ./bench/competition_dual_platform_demo.sh k8s live
```

这里默认创建 `ebpf-competition-demo` namespace，结束后删除本次资源。它的
价值是证明 Pod-to-Service、CoreDNS、Pod veth 和 TC monitor 路径可见。当前
`bench/k8s_workload_evidence.sh` 的服务请求是 HTTP transport smoke；如果现场
没有真实 h2c gRPC server，不要在答辩中把它报成 gRPC benchmark。

K8s XDP 集成要单独过以下门槛后再开：

- Linux/amd64 `linux-accel-dataplane` 和 agent image 已构建、校验并导入节点；
- CNI 已确认是 Flannel，Pod `iflink -> host veth` 映射正确；
- CRD/RBAC 已 dry-run 或 server-side validate；
- agent 先 `ObserveOnly`，确认 owner-FD 清理和 Pod churn 后才用 `Auto`。

现有 `k8s/manifests/daemonset.yaml` 不由双平台入口自动 apply，避免比赛前
临时把特权 DaemonSet、XDP owner 和 CNI 绑定关系引入未知状态。

### 4. 收尾对比（3 分钟）

| 结论 | 说法 |
| --- | --- |
| VM XDP | 已在真实 OpenStack TAP 路径上展示/验证，适合讲性能和 hit/miss |
| K8s 路径 | 已展示 CNI/Pod veth/Service 观测；XDP 自动纳管是下一阶段切片 |
| gRPC | TC 监控 + 窄范围 h2c unary fast-cache，不是 XDP |
| LDAP/LDAPS | TCP 用户态连接快路径/可观测性，不做内容缓存 |
| 安全边界 | 不支持、非法、miss、超时都 fail-open，不影响原协议语义 |

## 证据规则

1. 只有本次 `artifacts/competition-demo/<run-id>/` 中生成的日志可以称为本次
   live 证据。
2. 旧的 `artifacts/openstack-*`、`artifacts/protocol-fastpath/*` 只能标为历史
   结果；它们可以放性能页，但要保留日期和拓扑。
3. K8s 的 Pod-to-Service 正确性不等于 native NIC XDP 性能；两者分开讲。
4. 没有真实 LDAP/gRPC server 时，展示监控/协议路径，不临时伪造协议结果。

## 当前阻塞

本次整理时学校集群的 OpenStack VIP、Kubernetes API 和节点 SSH 均不可达，
因此只完成入口和本地静态校验，没有自动恢复服务或在远端继续压测。恢复后
先执行 `VM_NODE=node1 K8S_NODE=node1 ./bench/competition_dual_platform_demo.sh both preflight`，确认节点、VIP、K8s
readyz、OpenStack API 和服务状态正常，再执行 live。入口默认把 Linux
脚本复制到指定节点执行，Mac 只负责编排和收集 artifact。
