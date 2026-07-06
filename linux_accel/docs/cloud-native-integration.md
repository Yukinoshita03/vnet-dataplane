# OpenStack 与 Kubernetes 接入说明

本文档说明本项目如何接入虚拟化和云原生网络路径。DNS 与 gRPC eBPF 程序本身保持不变，接入重点是选择正确挂载点，并验证业务包在该路径上可见。

## OpenStack / KVM

常见候选挂载点：

| 路径元素 | 接口示例 | 推荐 hook | 用途 |
| --- | --- | --- | --- |
| OVS integration bridge | `br-int` | tc ingress/egress | 观察 OVS 交换后的 VM 租户流量 |
| OVS external bridge | `br-ex` | tc ingress/egress | 观察南北向服务流量 |
| Linux bridge / libvirt bridge | `virbr0`、`qbr*` | tc ingress/egress | 观察 KVM bridge 流量 |
| VM tap / veth peer | `tap*`、`qvo*`、`vnet*`、`veth*` | tc 或 generic XDP | 观察单个 VM 或 namespace 路径 |
| 物理网卡 | `ens*`、`eth*` | 支持时使用 native XDP，否则使用 tc | 在进入主机协议栈前加速数据包 |

可用脚本：

```bash
./bench/openstack_path_probe.sh
./bench/openstack_tc_attach_smoke.sh
./bench/openstack_workload_evidence.sh
```

`openstack_path_probe.sh` 是只读探测脚本，会采集 Linux 接口、OVS bridge/port、libvirt domain、OpenStack server/network/port 以及 tc/XDP 候选挂载点。`openstack_tc_attach_smoke.sh` 会在真实候选接口上短时间挂载 DNS 与 gRPC tc monitor，然后自动卸载。

构建项目后，可以运行 workload evidence 脚本生成更严格的证据：

```bash
sudo -v
./bench/openstack_workload_evidence.sh
```

默认情况下，脚本记录 DevStack/OVS 环境，并运行隔离的 `netns + veth` fallback workload，用于验证 DNS 与 gRPC monitor 计数。如果要证明真实租户 VM 流量，需要传入能驱动 OpenStack 实例产生流量的命令：

```bash
OPENSTACK_TRAFFIC_CMD='ssh cirros@<vm-ip> "dig @<server-ip> example.test; nc -vz <server-ip> 50051"' \
  IFACE=br-int ./bench/openstack_workload_evidence.sh
```

如果 DevStack 测试实例有 floating IP，也可以直接传入目标 IP。脚本会在 monitor 挂载期间从宿主机产生 UDP/53 和 TCP 流量：

```bash
OPENSTACK_TARGET_IP=<floating-ip> GRPC_PORT=22 IFACE=br-int ./bench/openstack_workload_evidence.sh
```

结果写入：

```text
artifacts/openstack-workload-evidence/<timestamp>/summary.md
```

summary 会明确标注本次运行使用的是 `external-openstack-workload` 还是 `ovs-host-netns-fallback`，因此 fallback 运行不能描述成 VM-to-VM 流量。

最新 VM 证据：

```text
artifact: artifacts/openstack-workload-evidence/20260630-162110/summary.md
mode: ovs-host-netns-fallback
openstack: DevStack hypervisor up, test instance ebpf-evidence-vm1 active on br-int/tap path
dns: count=30 failed=0 qps=5016.91; monitor qps=33 rps=33 ringbuf_drop=0
grpc transport: count=30 failed=0 qps=1027.17; monitor reqps=28 resps=29 p99=0.311ms ringbuf_drop=0
```

OpenStack 路径可引用的加速比：

| 开源项目 | 已验证挂载 / 可见性 | 加速路径 | QPS 加速比 | p99 提升 | 证据边界 |
| --- | --- | --- | ---: | ---: | --- |
| OpenStack / OVS / KVM | `br-int` tc attach smoke；DevStack/OVS workload evidence | DNS XDP cache | `7.14x` | `182.52x` | 同 VM 快路径 benchmark；OpenStack 运行证明可挂载且可见业务包 |
| OpenStack / OVS / KVM | `br-int` tc attach smoke；DevStack/OVS workload evidence | gRPC h2c fast-cache | `3.69x` | `3.33x` | 同 VM 快路径 benchmark；OpenStack 运行证明可挂载且可见业务包 |

当前 VM 不能同时保持 DevStack etcd 和 kubeadm etcd 运行，因为二者都会绑定 `192.168.106.130:2379/2380`。因此在这台机器上，OpenStack 与 Kubernetes 证据需要分时采集。

已验证的 VM 挂载证据：

```text
candidate interfaces: br-ex, br-int, ens33, ovs-system, virbr0, veth*
br-int smoke: dns_tc=attached grpc_tc=attached
artifact: openstack-tc-attach-smoke/20260627-160408
```

## Kubernetes

常见候选挂载点：

| CNI / 路径 | 接口示例 | 推荐 hook | 用途 |
| --- | --- | --- | --- |
| Calico | `cali*`、`tunl0`、`vxlan.calico` | tc ingress/egress | 观察 Pod-to-Pod 或 Pod-to-Service 流量 |
| Flannel | `flannel.1`、`cni0`、`veth*` | tc ingress/egress | 观察 overlay 和 pod veth 流量 |
| Cilium | `cilium_*`、`lxc*` | 谨慎使用 tc | 观察 Pod 流量，避免与 Cilium 托管的 BPF 程序冲突 |
| 普通 pod veth | `veth*` | tc 或 generic XDP | 观察单个 Pod 路径 |
| Node NIC | `ens*`、`eth*` | XDP 或 tc | 观察南北向流量 |

项目提供 Kubernetes 只读路径探测与 workload 证据脚本：

```bash
./bench/k8s_path_probe.sh
./bench/k8s_workload_evidence.sh
```

探测脚本在可用时采集宿主机接口、路由、tc qdisc、Kubernetes node/pod/service 以及 `kubectl`、`crictl`、`nerdctl` 等运行时信号，不修改集群。

Pod workload 证据运行方式：

```bash
sudo -v
./bench/k8s_workload_evidence.sh
```

脚本会创建临时 namespace，部署一个代表 gRPC transport 路径的小型 TCP request/response 服务，发送 Pod-to-Service 流量；如果 CoreDNS 可用，也会发送 DNS 查询；然后把现有 DNS/gRPC tc monitor 挂到自动发现的 node 接口上。默认退出时删除 namespace，除非设置 `KEEP_RESOURCES=1`。

结果写入：

```text
artifacts/k8s-workload-evidence/<timestamp>/summary.md
```

最新 VM 证据：

```text
artifact: artifacts/k8s-workload-evidence/20260630-161729/summary.md
cluster: kubeadm single-node, flannel/cni0, nginx:alpine cached image
dns pod-to-service: count=20 failed=0 qps=20.00; monitor on cni0 qps=1 ringbuf_drop=0
grpc transport pod-to-service: count=20 failed=0 qps=20.00; monitor on pod veth veth2d3ad4ff reqps=22 resps=44 p99=0.175ms ringbuf_drop=0
```

Kubernetes 路径可引用的加速比：

| 开源项目 | 已验证挂载 / 可见性 | 加速路径 | QPS 加速比 | p99 提升 | 证据边界 |
| --- | --- | --- | ---: | ---: | --- |
| Kubernetes / CNI / Pod veth | Pod-to-Service workload evidence；`cni0` 和 pod-veth monitor 计数非零 | DNS XDP cache | `7.14x` | `182.52x` | 同 VM 快路径 benchmark；Kubernetes 运行证明 Pod 路径可见 |
| Kubernetes / CNI / Pod veth | Pod-to-Service workload evidence；`cni0` 和 pod-veth monitor 计数非零 | gRPC h2c fast-cache | `3.69x` | `3.33x` | 同 VM 快路径 benchmark；Kubernetes 运行证明 Pod 路径可见 |

## 接入规则

- bridge、OVS port、pod veth pair、CNI 托管接口优先使用 tc 做监控。
- DNS cache 加速只在 generic 或 native XDP 能成功加载的接口上启用。
- 不替换、不卸载 CNI 自带的 BPF 程序。Cilium 节点上应先做只读探测和非关键接口 tc smoke。
- DNS 加速范围限定为 UDP IPv4 `A/IN` 缓存命中请求。
- gRPC 加速范围限定为 h2c unary demo 流量，除非部署明确支持 plaintext h2c。

## 演示声明边界

当前项目已经验证：

- 使用 `netns + bridge + veth` 的可复现虚拟化类 benchmark；
- 真实 DevStack/OpenStack 挂载点发现；
- 在真实 OVS integration bridge `br-int` 上完成 tc attach/detach smoke；
- Kubernetes 只读挂载点发现脚本；
- OpenStack/OVS 与 Kubernetes Pod 路径 workload evidence 脚本，且 summary 会区分真实集群流量与 fallback 回归流量。

完整生产级租户 VM workload 或 Kubernetes service mesh 接入仍需要专门 workload 和集群级安全审查。
