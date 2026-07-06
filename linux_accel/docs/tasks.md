# 任务拆解

## 核心交付物

- [x] eBPF 监控基线
- [x] DNS 服务支持
- [x] gRPC 服务支持
- [x] 双端缓存设计
- [x] 运行时策略配置
- [x] 虚拟化路径优化实验
- [x] OpenStack 挂载点探测与 tc smoke test
- [x] Kubernetes 挂载点探测
- [x] 相关工作与基线对比文档
- [x] benchmark 脚本
- [x] 包含通过标准和最新证据的测试矩阵
- [x] 最终报告草稿
- [x] demo 视频或现场演示脚本

## 工程任务

- [x] 选择 eBPF 技术栈：libbpf、bcc 或 cilium/ebpf
- [x] 定义 map schema
- [x] 定义用户态控制面
- [x] 定义指标格式
- [x] 实现 DNS 解析器
- [x] 实现 gRPC 可观测性
- [x] 实现缓存策略模块
- [x] 实现 benchmark runner
- [x] 编写环境与测试脚本

## 研究问题

- 哪些服务请求可以安全缓存？
- 不同服务应优先选择哪类 hook：XDP、tc、kprobe、uprobe 还是 tracepoint？
- eBPF 监控会带来多少额外开销？
- 缓存命中能带来多少延迟收益？
- 虚拟化会如何改变数据包路径？

## 当前 demo 证据

- DNS XDP cache benchmark：`bench/dns_xdp_cache_bench.sh`
- gRPC tc transport benchmark：`bench/grpc_tc_monitor_bench.sh`
- gRPC h2c fast-cache benchmark：`bench/grpc_fast_cache_bench.sh`
- 真实 h2c gRPC monitor demo：`bench/grpc_h2c_monitor_bench.sh`
- 虚拟化 bridge 路径 benchmark：`bench/virt_path_bench.sh`
- OpenStack/KVM 路径挂载点探测：`bench/openstack_path_probe.sh`
- Kubernetes 路径挂载点探测：`bench/k8s_path_probe.sh`
- 云原生接入说明：`docs/cloud-native-integration.md`
- 相关工作与基线对比：`docs/related-work-and-baselines.md`
- 统一策略校验与 map 加载：`build/cachectl`，支持 `dns`、`grpc`、`grpc-cache` 记录
- 需求到证据矩阵：`docs/competition-completion-matrix.md`
- 测试矩阵：`docs/test-matrix.md`
- 最终报告草稿：`docs/final-report-draft.md`
- Demo 演示手册：`docs/demo-runbook.md`
