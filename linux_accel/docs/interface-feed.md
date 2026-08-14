# Kubernetes interface desired-state feed

The Kubernetes adapter does not write BPF maps and does not modify the active
CNI configuration.  It sends a complete, source-scoped snapshot to
`dns_monitor` over an AF_UNIX `SOCK_SEQPACKET` socket:

```text
Kubernetes adapter
       |
       | YUKINONET_INTERFACE/1
       v
InterfaceFeedServer -> InterfaceReconciler -> owned XDP/TC attach
```

## Wire format

```text
YUKINONET_INTERFACE/1 REPLACE <cluster> <source> <revision> <lease> <count>
<host-ifname> <pod-uid>/<network-name>
...
```

An empty snapshot is valid and removes all targets owned by that source after
the data-plane reconcile succeeds.  A source withdrawal is:

```text
YUKINONET_INTERFACE/1 WITHDRAW <cluster> <source> <revision>
```

`revision` is monotonic per `cluster/source`.  Re-sending the same revision
and content is idempotent and refreshes the lease.  A delayed revision is
rejected after withdraw or lease expiry.  Two sources cannot claim one
interface with different stable identities.

The stable identity is normally `<Pod UID>/eth0`, not the Linux ifindex.  The
dataplane resolves the current ifindex from the name immediately before
attach, and detaches when either the identity or the ifindex changes.  This
protects against veth deletion and ifindex reuse.

## Dataplane behavior

`dns_monitor` accepts:

```bash
./build/dns_monitor \
  --hook xdp --role client --xdp-mode generic \
  --interface-feed /run/yukinonet/interface-feed.sock \
  --interface-feed-uid 0
```

The process can start without `--dev`; it waits for interface snapshots and
keeps the path fail-open while no target is present.  XDP uses
`XDP_FLAGS_UPDATE_IF_NOEXIST`.  Cleanup uses the program FD captured at
attach, so a later owner cannot be detached accidentally.  The client DNS
profile also installs its TC egress learning hook on each selected host veth.

