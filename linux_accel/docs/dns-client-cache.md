# DNS 客户端自学习缓存

本文档描述 DNS 双端缓存中的客户端侧路径。它部署在 client VM、container 或 network namespace 对应的 host-side veth/tap 接口上，而不是植入 DNS 应用进程或 libc resolver。

## 数据路径

```text
client netns / VM
  -> client host-side veth RX
  -> XDP client cache lookup
     -> hit: XDP_TX response back to client
     -> miss: record pending query and XDP_PASS
  -> bridge / OVS / server path
  -> DNS response reaches client host-side veth egress
  -> tc egress validates response and learns cache entry
```

客户端 cache key 为 `resolver IPv4 + normalized QNAME + QTYPE + QCLASS`。将 resolver 放入 key 是为了避免同一域名在不同 DNS 视图、不同租户或 split-horizon resolver 下复用错误答案。

## 启动方式

先在 Linux 主机编译：

```bash
cd linux_accel
./scripts/build_linux.sh
```

在 client 对应的 host-side veth 上启动：

```bash
sudo ./build/dns_monitor \
  --dev veth_client_host \
  --hook xdp \
  --role client \
  --xdp-mode generic \
  --trusted-dns 10.20.0.53 \
  --max-learn-ttl 300 \
  --learn-window-ms 2000
```

`--trusted-dns` 可以重复传入多个 IPv4 地址。client role 会同时挂载 XDP ingress 和 tc egress；如果接口已有 XDP 程序，启动会失败而不是替换对方程序。

服务端静态 XDP cache 保持原有入口：

```bash
sudo ./build/dns_monitor \
  --dev veth_server \
  --hook xdp \
  --role server \
  --xdp-mode generic \
  --cache-domain example.test \
  --cache-ip 10.0.0.123 \
  --cache-ttl 60
```

## 学习规则与回退

客户端只学习 IPv4 UDP DNS 的直接 `A/IN` 单问题响应。响应必须来自可信 resolver，匹配此前记录的五元组、DNS ID 和问题字段，并在默认 2000ms 的 pending 窗口内返回。

学习器拒绝 TTL 为零、NXDOMAIN、CNAME、多个 Answer、EDNS、压缩异常、TCP DNS、IPv6、分片和畸形响应。拒绝或未命中时始终放行原包，不 drop、不伪造响应。命中时 XDP 使用剩余 TTL 构造响应；TTL 到期后删除条目并恢复普通 DNS 请求。

运行期间会输出：

```text
dns_metrics dev=veth_client_host role=client ...
cache_hit=... cache_miss=... cache_expired=... cache_tx=...
cache_learned=... learn_rejected=... pending_expired=...
```

## 复现验证

`bench/dns_dual_end_cache_bench.sh` 创建下列拓扑并输出 artifact：

```text
client netns -> host-side veth -> bridge -> server netns
```

```bash
cd linux_accel
REPEAT=5 REQUESTS=1000 ./bench/dns_dual_end_cache_bench.sh
```

该脚本依次验证 baseline、server-only、client-only、both、TTL expiry、resolver isolation、untrusted resolver 和 NXDOMAIN rejection。产物中的 backend 请求计数用于证明 client cache hit 后请求没有继续访问服务端或用户态 DNS。

## 当前边界

- 第一版仅覆盖 IPv4 UDP、未压缩 QNAME、`A/IN`、单 Question、单直接 A Answer。
- `generic XDP` 用于 veth/tap 的可复现实验；native XDP 需要目标网卡和驱动支持。
- 每个 client 接口由一个 `dns_monitor` 进程和独立 map 生命周期管理；pinned map、在线刷新和自适应 admission 属于下一阶段控制面工作。
