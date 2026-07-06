# 相关工作与基线对比

本文档记录当前项目的基线位置，用于比赛报告和答辩问答；它本身不作为学术原创性声明。

## 最接近的相关工作

| 工作 | 类型 | 与本项目关系 |
| --- | --- | --- |
| hyDNS | eBPF Workshop @ SIGCOMM 2024 | 通过内核态解析加速 DNS；最接近的论文级 DNS 相关工作 |
| Xpress DNS | 工程项目 | XDP DNS 热点缓存；最接近的可运行 DNS 基线 |
| YADNS controller | 工程项目 | DNS 控制面/缓存项目；可作为架构参考 |
| BMC | NSDI 2021 | Memcached 内核缓存；安全内核缓存的重要参考 |
| eTran | NSDI 2025 | 基于 eBPF 的可扩展内核传输；与 transport-level fast path 有关，不是 DNS/gRPC cache |
| Demystifying Performance of eBPF Network Applications | CoNEXT 2025 | eBPF 网络程序性能评估参考 |

## 同 VM DNS 对比

以下对比在同一 VMware Ubuntu VM 上运行，使用相同 `dnsperf + latency bench` 风格。Xpress DNS 从 legacy `bpf_elf_map` map 定义本地 patch 到现代 BTF map 定义，以便在该 VM 的 libbpf 栈上加载。

| 实现 | dnsperf QPS | p99 延迟 | 相对 userspace QPS | 相对 userspace p99 | 相对 Xpress QPS | 相对 Xpress p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| userspace DNS stub | 65771.87 | 381.44 us | 1.00x | 1.00x | - | - |
| patch 后 Xpress DNS | 385295.75 | 4.92 us | 5.86x | 77.53x | 1.00x | 1.00x |
| 本项目 DNS XDP cache | 413933.01 | 2.82 us | 6.29x | 135.26x | 1.07x | 1.74x |

VM 运行产物：

```text
/home/xuexia/dns-xdp-baselines/artifacts/xpress-dns-bench/20260627-214832
/home/xuexia/ebpf-network-service-cache-plan-impl/artifacts/dns-xdp-cache-bench/20260627-214907
```

## 项目定位

本项目不应声称自己是第一个 DNS XDP cache。更强且更稳妥的表述是：

```text
一个面向 DNS 和 gRPC 的 eBPF 双服务监控与加速原型，
具备统一运行时缓存策略、可复现 benchmark 脚本，
以及虚拟化/云原生挂载点验证。
```

相比只做 DNS 的 XDP cache 项目，本项目增加了：

- DNS 与 gRPC 双服务覆盖；
- tc 监控基线 + XDP 快路径；
- 统一 DNS/gRPC 策略解析器和 `cachectl`；
- gRPC h2c unary fast-cache 原型；
- OpenStack/KVM 挂载点探测和 tc smoke test；
- 面向云原生扩展的 Kubernetes 挂载点探测。

## 剩余学术差距

如果要进一步支撑论文投稿，还需要：

- 更长时间、多轮重复实验和置信区间；
- CPU 利用率与丢包率对比；
- 在支持网卡上运行 native XDP，而不是只在 veth 上使用 generic XDP；
- 更完整的 gRPC/HTTP2 状态处理；
- 真实 OpenStack VM-to-VM 或 Kubernetes pod-to-pod workload 证据。
