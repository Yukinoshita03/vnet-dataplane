# src

本目录保存用户态控制面和服务 demo 代码。

主要组件包括：

- `dns_monitor.cpp`：程序入口、tc/XDP 挂载与生命周期控制。
- `dns_monitor_args.cpp`：命令行参数解析和使用说明。
- `dns_monitor_metrics.cpp`：ringbuf 事件处理、pending/timeout 跟踪和每秒指标输出。
- `grpc_monitor.cpp`：gRPC tc 监控用户态加载器。
- `grpc_fast_cache.cpp`：gRPC h2c fast-cache/proxy 原型。
- `include/packet_parser.hpp`：协议解析与服务分类工具的公共数据结构和接口声明。
- `packet_parser.cpp`：用户态 L2-L4 协议解析模块，负责 Ethernet / IPv4 / TCP / UDP 头解析。
- `virt_service_classifier.cpp`：面向 `veth / tap / bridge` 虚拟化路径的原始帧服务分类工具，可识别 DNS / gRPC / other。
- `cache policy manager`：双端缓存策略控制面逻辑。

## gRPC fast-cache module layout

The gRPC cache is intentionally split by responsibility:

- `grpc_fast_cache.cpp`: process lifecycle, option validation, listener,
  backend fallback, map-backed cache lookup, statistics, and the main loop.
- `grpc_cache_types.hpp`: shared cache key, request, option, status, and
  statistics types.
- `grpc_cache_protocol.hpp` / `grpc_cache_protocol.cpp`: h2c preface and
  frame parsing, the small HPACK subset used by the demo, payload hashing, and
  gRPC Health Check response encoding.

`scripts/build_linux.sh` and the OpenStack E2E harness compile the protocol
module explicitly. This keeps protocol changes independent from cache policy
and runtime lifecycle changes.
