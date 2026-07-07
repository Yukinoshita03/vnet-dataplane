# vnet-agent

`vnet-agent` 是后续统一命令行入口的预留目录。

第一版计划提供：

- `vnet-agent status`：检查本机运行环境和构建产物
- `vnet-agent probe`：发现虚拟化网络路径和候选 eBPF 挂载点
- `vnet-agent bench virt-path`：统一调用虚拟化路径 benchmark

建议先在 `src/` 下实现最小 CLI，再把本目录接入根 `CMakeLists.txt`。
