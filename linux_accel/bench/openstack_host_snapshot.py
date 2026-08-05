#!/usr/bin/env python3
"""Emit a JSON host/TAP/BPF counter snapshot for OpenStack benchmark runs."""

import argparse
import json
from pathlib import Path
import subprocess
import time


STAT_NAMES = (
    "rx_packets",
    "tx_packets",
    "rx_bytes",
    "tx_bytes",
    "rx_dropped",
    "tx_dropped",
    "rx_errors",
    "tx_errors",
)
CACHE_STATS = (
    "cache_hit",
    "cache_miss",
    "cache_expired",
    "cache_tx",
    "cache_learned",
    "learn_rejected",
    "pending_expired",
)


def read_int(path):
    try:
        return int(Path(path).read_text().strip())
    except (OSError, ValueError):
        return -1


def run_json(command):
    try:
        completed = subprocess.run(
            command, check=True, capture_output=True, text=True, timeout=5
        )
        return json.loads(completed.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return None


def interface_stats(name):
    root = Path("/sys/class/net") / name / "statistics"
    if not root.is_dir():
        return None
    return {stat: read_int(root / stat) for stat in STAT_NAMES}


def bpf_stats(tap):
    result = {"attached": False}
    net = run_json(("bpftool", "-j", "net", "show", "dev", tap))
    if not net:
        return result
    xdp = net[0].get("xdp", [])
    tc = net[0].get("tc", [])
    result.update(
        {
            "attached": bool(xdp),
            "xdp_prog_id": xdp[0].get("id", -1) if xdp else -1,
            "tc_prog_id": tc[0].get("id", -1) if tc else -1,
        }
    )
    if not xdp:
        return result
    program = run_json(("bpftool", "-j", "prog", "show", "id", str(xdp[0]["id"])))
    if not program:
        return result
    for map_id in program.get("map_ids", []):
        map_info = run_json(("bpftool", "-j", "map", "show", "id", str(map_id)))
        if not map_info or map_info.get("name") != "dns_cache_stats":
            continue
        dump = run_json(("bpftool", "-j", "map", "dump", "id", str(map_id)))
        if dump is None:
            break
        totals = [0] * len(CACHE_STATS)
        for row in dump:
            formatted = row.get("formatted", {})
            key = formatted.get("key", -1)
            values = formatted.get("values", [])
            if isinstance(key, int) and 0 <= key < len(totals):
                totals[key] = sum(item.get("value", 0) for item in values)
        result.update(dict(zip(CACHE_STATS, totals)))
        result["cache_map_id"] = map_id
        break
    return result


def proc_stats():
    values = {"context_switches": -1, "processes": -1, "softirq_total": -1}
    for line in Path("/proc/stat").read_text().splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "ctxt":
            values["context_switches"] = int(parts[1])
        elif parts[0] == "processes":
            values["processes"] = int(parts[1])
        elif parts[0] == "softirq":
            values["softirq_total"] = int(parts[1])
    return values


def softirq_stats():
    values = {}
    for line in Path("/proc/softirqs").read_text().splitlines():
        stripped = line.lstrip()
        if stripped.startswith("NET_RX:") or stripped.startswith("NET_TX:"):
            parts = stripped.split()
            values[parts[0][:-1].lower()] = sum(int(value) for value in parts[1:])
    softnet = [0, 0, 0]
    for line in Path("/proc/net/softnet_stat").read_text().splitlines():
        parts = line.split()
        for index in range(3):
            softnet[index] += int(parts[index], 16)
    values.update(
        {
            "softnet_processed": softnet[0],
            "softnet_dropped": softnet[1],
            "softnet_squeezed": softnet[2],
        }
    )
    return values


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tap", required=True)
    parser.add_argument("--interface", action="append", default=[])
    args = parser.parse_args()
    interfaces = []
    for name in (args.tap, *args.interface):
        if name not in interfaces:
            interfaces.append(name)
    payload = {
        "monotonic_ns": time.monotonic_ns(),
        "interfaces": {
            name: stats
            for name in interfaces
            if (stats := interface_stats(name)) is not None
        },
        "bpf": bpf_stats(args.tap),
        "proc": proc_stats(),
        "softirq": softirq_stats(),
    }
    print(json.dumps(payload, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
