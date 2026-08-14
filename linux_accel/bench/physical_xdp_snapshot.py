#!/usr/bin/env python3
"""Emit one machine-readable physical NIC/softirq snapshot for a run."""

from pathlib import Path
import time


def number(path: str) -> int:
    try:
        return int(Path(path).read_text().strip())
    except (OSError, ValueError):
        return -1


softirq = {}
for line in Path("/proc/softirqs").read_text().splitlines():
    stripped = line.lstrip()
    if stripped.startswith("NET_RX:") or stripped.startswith("NET_TX:"):
        parts = stripped.split()
        softirq[parts[0][:-1]] = sum(int(value) for value in parts[1:])

softnet = [0, 0, 0]
for line in Path("/proc/net/softnet_stat").read_text().splitlines():
    parts = line.split()
    for index in range(3):
        softnet[index] += int(parts[index], 16)

stat_softirq = ""
for line in Path("/proc/stat").read_text().splitlines():
    if line.startswith("softirq "):
        stat_softirq = line
        break

values = {
    "rx_packets": number("/sys/class/net/enp3s0/statistics/rx_packets"),
    "tx_packets": number("/sys/class/net/enp3s0/statistics/tx_packets"),
    "rx_dropped": number("/sys/class/net/enp3s0/statistics/rx_dropped"),
    "tx_dropped": number("/sys/class/net/enp3s0/statistics/tx_dropped"),
    "rx_errors": number("/sys/class/net/enp3s0/statistics/rx_errors"),
    "tx_errors": number("/sys/class/net/enp3s0/statistics/tx_errors"),
    "net_rx": softirq.get("NET_RX", -1),
    "net_tx": softirq.get("NET_TX", -1),
    "softnet_processed": softnet[0],
    "softnet_dropped": softnet[1],
    "softnet_squeezed": softnet[2],
    "carrier": number("/sys/class/net/enp3s0/carrier"),
    "ts_ns": time.monotonic_ns(),
    "stat_softirq": stat_softirq,
}

print(" ".join(f"{key}={value}" for key, value in values.items()))
