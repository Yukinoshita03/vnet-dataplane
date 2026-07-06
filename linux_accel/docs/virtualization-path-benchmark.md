# 虚拟化路径 Benchmark

该 benchmark 覆盖赛题中“虚拟化数据包路径分析”的要求。它使用 Linux `netns + bridge + veth` 模拟常见 KVM 路径：guest tap/veth 设备接入 host bridge，再转发到另一个 guest 或 host service。

## 拓扑

```text
client netns            host bridge             server netns
10.40.0.2  <-> veth <-> br_virt_bench <-> veth <-> 10.40.0.3:50080
```

这不是完整 KVM VM，但它覆盖了许多 VM 和容器路径中都会出现的 Linux bridge/veth 转发层。它提供可复现延迟基线；下方 OpenStack/OVS probe 和 tc attach smoke 则验证同一 monitor 可挂载到真实 DevStack bridge 接口。

## 运行

```bash
./bench/virt_path_bench.sh
REQUESTS=3000 ./bench/virt_path_bench.sh
```

脚本依赖 `ip`、`gcc`、`python3`、`awk` 和 `sudo`。它会创建两个 namespace、一个 bridge、两对 veth、一个 TCP echo server 和一个 C latency client。结果写入：

```text
artifacts/virt-path-bench/<timestamp>/summary.md
```

## 指标

- `qps`：每秒完成的 TCP request/response 操作数。
- `avg_us`、`p50_us`、`p95_us`、`p99_us`：客户端观测到的 TCP connect/send/receive 延迟。
- `failed`：失败请求数。
- `ping`：模拟 guest namespace 之间的 ICMP 连通性摘要。

## 赛题映射

- `netns` 表示隔离的 guest 网络栈。
- `veth` 表示 tap/vhost 类虚拟链路。
- `bridge` 表示 host bridge 或 integration bridge。
- 结果可作为后续在 bridge、veth、tap ingress/egress 上挂载 tc/eBPF 程序的基线。

## OpenStack / KVM 路径探测

真实 OpenStack 或 KVM host 上，先用只读 probe 选择 tc/XDP 挂载点：

```bash
./bench/openstack_path_probe.sh
```

如果 OpenStack CLI 可用，先加载凭据：

```bash
cd /opt/stack/devstack
source openrc admin admin
cd /path/to/ebpf-network-service-cache
./bench/openstack_path_probe.sh
```

probe 写入：

```text
artifacts/openstack-path-probe/<timestamp>/summary.md
```

它会采集 Linux interface、bridge link、tc qdisc 状态；存在 `ovs-vsctl` 时采集 OVS bridge/port；存在 `virsh` 时采集 libvirt domain/interface；存在已认证 `openstack` 命令时采集 hypervisor/server/network/port 列表。脚本只读，不创建、删除、挂载、卸载、迁移或修改任何 VM/network/eBPF 状态。

使用生成的 `candidate-ifaces.txt` 选择运行位置：

```bash
sudo ./build/dns_monitor --dev <candidate-iface> --hook tc
sudo ./build/grpc_monitor --dev <candidate-iface> --port 50051
sudo ./build/dns_monitor --dev <candidate-iface> --hook xdp --xdp-mode generic --cache-file cache-policy.txt
```

在 VMware DevStack VM 上已验证，probe 找到 12 个候选挂载点，包括：

```text
br-ex
br-int
ens33
ovs-system
virbr0
veth018df9b
veth15e8039
veth84ad00e
vetha76d845
vethacbe751
```

同一 DevStack VM 上也验证了 tc attach smoke：

```bash
DURATION=2 IFACES='br-int br-ex ens33' ./bench/openstack_tc_attach_smoke.sh
```

结果：

```text
interface=br-int
dns_tc=attached
grpc_tc=attached
grpc_port=50051
artifacts=openstack-tc-attach-smoke/20260627-160408
```

该结果证明现有 DNS 和 gRPC tc monitor 可以挂载到真实 OpenStack/OVS integration bridge。smoke 运行期间 bridge 上没有活跃 VM workload，因此 packet counter 为 0；该检查目标是验证真实虚拟化数据路径上的 attach/detach 能力。

## 下一步优化

基线完成后，可在 `veth_*_host`、`br_virt_bench` 或 `openstack_path_probe.sh` 报告的真实 tap/bridge/OVS 接口上挂载 tc 程序，对比纯 bridge 转发、tc 可观测性开销、服务端 veth 上的 DNS XDP 快路径，以及未来 redirect 或 host-side interception 原型。
