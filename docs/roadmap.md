# Roadmap

## Phase 1: bootstrap

- Create repo structure and build system
- Register `vnet0` from a minimal kernel module
- Add a portable C++ packet parsing library
- Add one CLI binary and one parser test

## Phase 2: TX path and observability

- Extend `ndo_start_xmit` stats and trace points
- Add `ethtool -S` style counters
- Verify behavior with `ip`, `ping`, `tcpdump`, and `iperf`

## Phase 3: RX path and queueing

- Define shared RX/TX ring structures
- Add a packet injection path from kernel to userspace
- Batch packet delivery
- Add backpressure and drop accounting

## Phase 4: dataplane features

- Ethernet, ARP, IPv4, TCP, UDP parsing
- ACL or five-tuple packet filter
- Simple L2 forwarding or mirror mode
- Metrics endpoint or structured log output

## Phase 5: polish

- Benchmark notes
- Design write-up
- Demo scripts
- Resume-ready project summary
