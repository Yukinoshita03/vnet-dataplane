# DHCP/BOOTP XDP controlled relay

DHCP is implemented as a controlled IPv4 BOOTP relay in the existing
`dns_xdp_monitor` object. It is a forwarding fast path: it does not allocate
leases, cache replies, replay transactions, or synthesize DHCP responses.

The first version deliberately supports Ethernet DHCP/BOOTP over IPv4 UDP:

- client request: UDP `68 -> 67`, `BOOTREQUEST`, `giaddr == 0`;
- server response: UDP `67 -> 67`, `BOOTREPLY`, with a matching relay
  transaction;
- DHCPv6, chained relays, non-Ethernet BOOTP, and already-relayed requests are
  passed through;
- malformed, expired, unmatched, or unsupported packets fail open with
  `XDP_PASS`.

## Datapath

The control plane installs one policy per client-side interface. A request is
keyed by the ingress client ifindex and the Ethernet source MAC, then the
program records `{relay_ifindex, xid, client_mac}` for the response path.

| Direction | Rewrite | Action |
| --- | --- | --- |
| client → server | L2 source/destination to relay/server MAC; IPv4 source/destination to relay/server IPv4; UDP `68 -> 67`; set `giaddr`; increment `hops` | `bpf_redirect(relay_ifindex)` |
| server → client | Match relay ifindex, transaction ID and client MAC; L2 source/destination to relay/client MAC or broadcast; IPv4 source to server IPv4 and destination to `ciaddr`, `yiaddr`, or broadcast; UDP `67 -> 68`; clear `giaddr`/`hops` | `bpf_redirect(client_ifindex)` |

OFFER state is retained. ACK and NAK retire the transaction. Transactions have
a short fixed lifetime and are stored in an LRU hash map. Telemetry uses only
per-CPU counters; DHCP packets do not create DNS ring-buffer events.

To keep the combined DNS + ARP + DHCP XDP object within the kernel program
limit, the parser scans at most the first four DHCP options. The DHCP message
type option is normally near the beginning of a client packet. A packet whose
message type is outside that bounded prefix is intentionally passed through;
this is a correctness-preserving miss, not a malformed response.

## Policy file

Each non-comment line contains seven whitespace-separated fields:

```text
client_if relay_if relay_ipv4 server_ipv4 relay_mac server_mac lease_seconds
```

Example:

```text
tap-vm-a br-dhcp 192.0.2.1 192.0.2.2 fa:16:3e:aa:bb:cc fa:16:3e:dd:ee:ff 30
```

The interface names must exist when `dns_monitor` starts. IPv4 addresses and
MAC addresses are explicit policy values; the control plane does not infer
them from Neutron, OVS, ARP, or DHCP traffic. MAC addresses must be unicast and
non-zero. Lease values are one second through 24 hours.

The checked-in template is
[`config/dhcp-relay.conf.example`](../config/dhcp-relay.conf.example).

## Start the integrated monitor

The DHCP relay uses the same XDP object as the existing DNS monitor and ARP
proxy. A separate DHCP XDP program must not be attached to the same TAP or
bridge interface, because an interface has one XDP hook. Start one integrated
monitor with the client and relay interfaces listed in the policy file:

```bash
sudo ./build/dns_monitor \
  --hook xdp --role server --xdp-mode generic \
  --bpf-object build/dns_xdp_monitor.bpf.o \
  --dhcp-policy-file ./config/dhcp-relay.conf.example
```

For an OpenStack deployment, replace the example interface names and L2/L3
values with the actual VM TAP/OVS DHCP path. The initial implementation does
not change Neutron ports, OVN flows, or the active OpenStack service
configuration automatically.

The monitor renews policies periodically. On a renewal failure, the policy
expires in the BPF map and the data path returns `XDP_PASS`; this is the
fail-open behavior. Runtime output includes request/response/redirect counts
and policy, transaction, format, and expiry misses.

## Tests

The package-level test compiles the production `dns_xdp_monitor` object on
Linux, loads it into the kernel, and invokes `BPF_PROG_TEST_RUN`:

```bash
./tests/run_dhcp_relay_xdp_test.sh
```

It verifies request rewriting, OFFER retention, ACK cleanup, broadcast
response L2/L3 rewriting, policy misses, invalid cookies, and expired policy
fail-open behavior. It does not attach the program to a netdev or alter the
running OpenStack/Kubernetes cluster.

