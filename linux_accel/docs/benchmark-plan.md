# 基准测试计划

## 指标

- 请求延迟 p50/p95/p99；
- 吞吐量；
- 缓存命中率；
- CPU 使用率；
- eBPF map lookup/update 开销；
- host-to-VM 数据包路径延迟；
- 服务错误率。

## 基线

- 原生 userspace DNS 服务；
- 仅启用 eBPF 监控的 DNS 服务；
- 启用 eBPF cache path 的 DNS 服务；
- 原生 gRPC 服务；
- 仅启用 eBPF 监控的 gRPC 服务；
- 启用缓存策略的 gRPC 服务。

## 工具

- `perf`
- `bpftool`
- `tcpdump`
- `wrk` 或自定义 gRPC benchmark
- DNS 查询生成器
- VM/KVM benchmark 脚本

## 报告格式

每次 benchmark 应记录：

- 环境；
- 内核版本；
- 硬件/VM 配置；
- 服务配置；
- 执行命令；
- 原始结果；
- 图表；
- 结论。
