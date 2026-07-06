# macOS 上编辑 eBPF 代码

本仓库可以在 macOS 上编辑，但 eBPF 程序目标运行环境是 Linux。

`third_party/bpf-headers/` 下的头文件是轻量级 shim，只用于编辑器 IntelliSense 和基础语法检查。

这些 shim 用于减少如下 include 在编辑器中的红线：

```c
#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>
```

## macOS 语法检查

编辑器级语法检查：

```bash
clang -fsyntax-only -I third_party/bpf-headers bpf/dns_monitor.c
```

BPF target 语法检查：

```bash
clang -target bpf -D__BPF_TARGET__ -fsyntax-only -I third_party/bpf-headers bpf/dns_monitor.c
```

## 真实构建

真实 eBPF 构建应在 Linux 中完成，并安装正确包：

- `clang`
- `llvm`
- `libbpf-dev`
- `linux-headers`
- `bpftool`

shim 头文件不能替代真实 Linux UAPI 和 libbpf 头文件。
