# DNS 客户端缓存对比结果

本报告对比上一版的 server-side XDP cache 与加入客户端自学习缓存后的路径。结果来自 VMware Ubuntu VM 上的可复现 `netns + veth + bridge` 拓扑。

## 方法

- 测试脚本：`bench/dns_dual_end_cache_bench.sh`。
- 每组 2000 个顺序 IPv4 UDP DNS `A/IN` 查询。
- 重复 5 轮，表中使用 QPS 和 p99 的中位数。
- XDP 使用 generic 模式；client cache 挂在 client host-side veth，学习器挂在同接口 tc egress。
- userspace baseline 使用同一个 Python DNS backend；server-only 是此前已有的服务端 XDP cache；client-only 和 both 均在第一次请求后进入客户端缓存命中路径。

## 结果

| Path | Median QPS | Median p99 | Backend requests |
| --- | ---: | ---: | ---: |
| userspace baseline | 5,188 | 785.55 us | 2,000 |
| previous server-only XDP cache | 21,708 | 265.84 us | 0 |
| current client-only cache | 126,499 | 39.14 us | 1 warm-up request |
| current dual-end cache | 122,286 | 49.00 us | 0 |

相对 previous server-only：

- client-only QPS 为 `5.83x`，p99 再降低 `6.79x`。
- dual-end QPS 为 `5.63x`，p99 再降低 `5.43x`。

相对 userspace baseline：

- client-only QPS 为 `24.38x`。
- dual-end QPS 为 `23.57x`。

五轮中，client-only 均满足 `cache_learned=1`、`cache_hit=2000`、`cache_tx=2000`，且 backend 请求数保持为 1；dual-end 均满足 client miss 后 server hit、client 学习成功，backend 请求数为 0。

## 边界

该脚本使用顺序请求来同时验证端到端延迟、缓存学习和 backend 绕过，因此结果适合比较本项目版本之间的相对变化。它不是 `dnsperf` 并发压测，不能与 `bench/dns_xdp_cache_bench.sh` 输出的峰值吞吐量直接混用。
