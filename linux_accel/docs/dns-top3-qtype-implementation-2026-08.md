# DNS Top-3 QTYPE 实现与验证记录

本轮目标是覆盖观测到的前三类 DNS 请求：`A 56.6%`、`AAAA 30.3%`、`HTTPS 6.3%`。实现选择了“直接单 Answer 才加速，复杂请求保持 fail-open”的边界。

## 已完成的路径

| QTYPE | 静态服务端 cache | client 自学习 cache | 当前安全边界 |
| --- | --- | --- | --- |
| A (1) | 已支持 | 已支持 | 单问题、`IN`、直接单 A RR |
| AAAA (28) | 已支持 | 已支持 | 单问题、`IN`、直接单 AAAA RR |
| HTTPS (65) | 已支持 | 已支持 | 单问题、`IN`、单条长度受限的 wire RR；当前不解析复杂 SvcParam |

缓存 value 已从 IPv4 专用字段改为“TTL/过期时间 + 完整 Answer RR wire bytes”。命中时 XDP 只改写 Answer 区域和 TTL，随后 `XDP_TX`；学习器只接受可信 resolver 返回的单条直接响应。NXDOMAIN、CNAME、多 Answer、EDNS、截断、超长或不符合规则的 HTTPS 响应都保留原包放行，不生成逐包 ringbuf event。

## 测试证据

- `tests/run_dns_xdp_prog_test.sh`：server object 的 A/AAAA/HTTPS 和旁路用例 `7/7`；client object 同样 `7/7`。
- `tests/run_arp_proxy_xdp_prog_test.sh`：将生产 DNS/client object 放入 ARP proxy harness 后，server/client 均 `13/13`；client object 的动态学习路径通过 verifier/load。
- `scripts/build_linux.sh`：node1 Ubuntu `7.0.0-14-generic` 完整 Linux 构建通过。
- `cachectl --validate-only`：typed cache fixture 与 policy fixture 均通过，包含 A、AAAA、HTTPS 三条记录。
- 离线 DNS backend correctness：扩展为 10 类、重复 2 次，共 `20/20`；HTTPS wire RR 校验通过。
- `generate_openstack_dns_corpus.py --profile top3 --lines 50000`：生成 `A=28300`、`AAAA=15150`、`HTTPS=3150`，即精确 `56.6%/30.3%/6.3%`；其余 `6.8%` 为 TXT/截断等旁路流量，负面和多 Answer A 请求已经计入 A 的 56.6%。

## OpenStack 性能轮状态

真实 OpenStack TAP 加速比尚未在本轮重新产生。当前集群的候选 client/backend VM 都是 `shut off`，而 `openstack server/port` 及 compute/Neutron agent 查询仍返回 HTTP 500；同时 host TAP 上没有现成 XDP/tc attach。为遵守“不启动 Kubernetes、不绕过 OpenStack 控制面”的约束，本轮只完成了代码、Linux verifier/包级回归和离线 benchmark 准备，没有直接用 `virsh` 启动 VM。

控制面恢复且 VM 由 OpenStack 正常启动后，执行：

```bash
CORPUS_PROFILE=top3 ./bench/openstack_realistic_dns_bench.sh <artifact-dir> quick
./bench/openstack_dns_path_split_bench.sh <artifact-dir> 20000 8 3
```

第一条给出混合 top-3 场景的 userspace/no-hook 与 TAP-XDP 对比；第二条分离 hot A、AAAA、HTTPS、NXDOMAIN、CNAME 和混合旁路，单独测出三种主要 QTYPE 的命中收益和 miss/fail-open 开销。

## 仍然不宣称的范围

HTTPS 目前是窄范围直接 wire-RR 加速，不是完整的 RFC 9460 SVCB/HTTPS 解析器；不包含复杂 SvcParam、AliasMode、多 Answer、DNS-over-TCP/DoT/DoH。下一轮应先用真实 dnstap/pcap 抽样确认这些复杂形态的占比，再决定是否扩展 parser。
