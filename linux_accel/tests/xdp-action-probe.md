# XDP action probe

This test-only probe supplies deterministic `XDP_PASS`, `XDP_DROP`,
`XDP_ABORTED`, and invalid action `5` programs for driver validation. It is not
part of the DNS production data path.

Every program returns `XDP_PASS` unless the frame simultaneously has:

- the configured target interface MAC as its destination;
- experimental EtherType `0x88b5`; and
- the fixed 16-byte `R8169XDP_ACTION!` magic at the start of its payload.

The invalid-action program therefore cannot affect ordinary IP, ARP, VLAN,
Geneve, or DNS traffic. Physical use is still disruptive because first native
attach and final detach can restart the driver's RX layout. Run it only inside
the separately guarded local/OOB-console trial window.

## Non-physical build and program test

On a local Linux VM or container with Clang, libbpf development headers, and a
kernel that permits `BPF_PROG_TEST_RUN`:

```bash
./tests/run_xdp_action_probe_test.sh
```

Set `BUILD_ONLY=1` to compile the BPF object, test harness, loader, and sender
without loading a BPF program.

For a root-only integration test that creates an isolated veth pair, performs
native attach, sends exactly one matching AF_PACKET frame, and verifies both
normal detach and replacement ownership fencing:

```bash
sudo ./tests/run_xdp_action_probe_veth_test.sh
```

The veth test never selects an existing interface. It creates two temporary
interfaces in the current network namespace and removes them on exit. Run it
in a local VM or privileged test container, not on the physical cluster.

## Physical components

The loader refuses to replace an existing native XDP program, attaches with
`XDP_FLAGS_UPDATE_IF_NOEXIST`, records the attached program ID, and detaches
with the still-open program FD as `old_prog_fd`. If ownership changes, it
leaves the replacement untouched.

Example loader invocation during an already-authorized guarded driver trial:

```bash
sudo ./build/tests/xdp-action-probe/xdp_action_probe_loader \
  --dev enp3s0 \
  --object ./build/tests/xdp-action-probe/xdp_action_probe.bpf.o \
  --action drop \
  --duration 30
```

The loader prints the target MAC. On the trusted external peer, send one frame:

```bash
sudo ./xdp_action_probe_sender \
  --dev PEER_IFACE --dst-mac TARGET_MAC --count 1 --sequence 1
```

Do not send invalid-action traffic in a loop. One exact frame is sufficient to
validate the driver's counter, warning, and `xdp_exception` trace path. These
components do not load or replace a NIC driver, arm a rollback watchdog, flap a
link, or claim that a management NIC is safe to disrupt.
