# Architecture

## High-level data path

```text
Linux network stack
        |
      vnet0
        |
 kernel virtual NIC driver
        |
 shared RX/TX ring
        |
 C++20 userspace dataplane
        |
 parser / filter / forward / metrics
```

## Kernel responsibilities

- Register a virtual Ethernet device with `net_device`
- Provide lifecycle hooks: `ndo_open`, `ndo_stop`, `ndo_start_xmit`
- Track packet and byte counters
- Add NAPI-based polling once RX queue support lands
- Later expose a packet exchange path to userspace

## Userspace responsibilities

- Consume packet batches from the shared queue
- Parse Ethernet, ARP, IPv4, TCP, and UDP headers
- Apply packet filter or forwarding actions
- Publish counters and latency metrics
- Drive reproducible benchmarks

## Design constraints

- Keep the first milestone small enough to finish
- Prefer explicit ownership and simple queue semantics over clever abstractions
- Separate Linux-only code from portable parsing code where possible
- Make every milestone demonstrable with a command, packet trace, or test
