#!/usr/bin/env python3
"""Analyze OpenStack realistic DNS benchmark artifacts and write a report."""

import argparse
import csv
import json
import re
import statistics
from pathlib import Path


def load_json(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def numeric_delta(before, after, key):
    first = before.get(key, 0) if isinstance(before, dict) else 0
    second = after.get(key, 0) if isinstance(after, dict) else 0
    if isinstance(first, (int, float)) and isinstance(second, (int, float)):
        return second - first
    return 0


def interface_packet_delta(before, after, interface):
    first = before.get("interfaces", {}).get(interface, {})
    second = after.get("interfaces", {}).get(interface, {})
    return numeric_delta(first, second, "rx_packets") + numeric_delta(
        first, second, "tx_packets"
    )


def interface_drop_delta(before, after, interface):
    first = before.get("interfaces", {}).get(interface, {})
    second = after.get("interfaces", {}).get(interface, {})
    return sum(
        numeric_delta(first, second, name)
        for name in ("rx_dropped", "tx_dropped", "rx_errors", "tx_errors")
    )


def perf_metrics(path):
    metrics = {}
    try:
        lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return metrics
    for line in lines:
        fields = line.split(",")
        if len(fields) < 3:
            continue
        raw_value = fields[0].strip().replace(" ", "")
        event = fields[2].strip()
        try:
            value = float(raw_value)
        except ValueError:
            continue
        metrics[event] = value
    return metrics


def guest_time_metrics(path):
    try:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    patterns = {
        "guest_user_s": r"User time \(seconds\):\s+([0-9.]+)",
        "guest_system_s": r"System time \(seconds\):\s+([0-9.]+)",
        "guest_voluntary_ctxt": r"Voluntary context switches:\s+(\d+)",
        "guest_involuntary_ctxt": r"Involuntary context switches:\s+(\d+)",
    }
    result = {}
    for name, pattern in patterns.items():
        match = re.search(pattern, text)
        if match:
            result[name] = float(match.group(1))
    return result


def parse_case(case_dir):
    metadata = load_json(case_dir / "metadata.json", {})
    dnsperf = load_json(case_dir / "dnsperf.json", {})
    backend_before = load_json(case_dir / "backend-before.json", {})
    backend_after = load_json(case_dir / "backend-after.json", {})
    node1_before = load_json(case_dir / "node1-before.json", {})
    node1_after = load_json(case_dir / "node1-after.json", {})
    node2_before = load_json(case_dir / "node2-before.json", {})
    node2_after = load_json(case_dir / "node2-after.json", {})
    node1_perf = perf_metrics(case_dir / "node1-perf.csv")
    node2_perf = perf_metrics(case_dir / "node2-perf.csv")
    target = float(metadata.get("target_qps", 0))
    completion = float(dnsperf.get("completion_percent", 0))
    sent_qps = float(dnsperf.get("sent_qps", 0))
    p99_us = dnsperf.get("p99_latency_us")
    tap_drops = interface_drop_delta(
        node1_before, node1_after, metadata.get("client_tap", "")
    )
    tap_drops += interface_drop_delta(
        node2_before, node2_after, metadata.get("backend_tap", "")
    )
    softnet_drops = numeric_delta(
        node1_before.get("softirq", {}),
        node1_after.get("softirq", {}),
        "softnet_dropped",
    ) + numeric_delta(
        node2_before.get("softirq", {}),
        node2_after.get("softirq", {}),
        "softnet_dropped",
    )
    gate_reasons = []
    if target and sent_qps < target * 0.99:
        gate_reasons.append("generator<99%")
    if completion < 99.9:
        gate_reasons.append("completion<99.9%")
    if p99_us is None or p99_us > 10000:
        gate_reasons.append("p99>10ms")
    if tap_drops:
        gate_reasons.append("tap-drop/error")
    if softnet_drops:
        gate_reasons.append("softnet-drop")

    bpf_before = node1_before.get("bpf", {})
    bpf_after = node1_after.get("bpf", {})
    backend_queries = numeric_delta(backend_before, backend_after, "requests")
    completed = int(dnsperf.get("completed", 0))
    row = {
        **metadata,
        **dnsperf,
        **guest_time_metrics(case_dir / "dnsperf.log"),
        "case": case_dir.name,
        "gate_pass": not gate_reasons,
        "gate_reasons": ";".join(gate_reasons),
        "backend_queries": backend_queries,
        "backend_queries_per_completion": backend_queries / completed if completed else 0,
        "xdp_cache_hit": numeric_delta(bpf_before, bpf_after, "cache_hit"),
        "xdp_cache_miss": numeric_delta(bpf_before, bpf_after, "cache_miss"),
        "xdp_cache_tx": numeric_delta(bpf_before, bpf_after, "cache_tx"),
        "xdp_cache_learned": numeric_delta(bpf_before, bpf_after, "cache_learned"),
        "xdp_learn_rejected": numeric_delta(
            bpf_before, bpf_after, "learn_rejected"
        ),
        "node1_geneve_packets": interface_packet_delta(
            node1_before, node1_after, "genev_sys_6081"
        ),
        "node2_geneve_packets": interface_packet_delta(
            node2_before, node2_after, "genev_sys_6081"
        ),
        "tap_drop_errors": tap_drops,
        "softnet_drops": softnet_drops,
        "node1_cycles": node1_perf.get("cycles", 0),
        "node2_cycles": node2_perf.get("cycles", 0),
        "node1_context_switches": node1_perf.get("context-switches", 0),
        "node2_context_switches": node2_perf.get("context-switches", 0),
    }
    row["geneve_packets"] = row["node1_geneve_packets"] + row["node2_geneve_packets"]
    return row


def median(rows, key):
    values = [float(row[key]) for row in rows if row.get(key) is not None]
    return statistics.median(values) if values else 0.0


def ratio(numerator, denominator):
    return numerator / denominator if denominator else 0.0


def percent_offload(baseline, accelerated):
    return 100.0 * (1.0 - ratio(accelerated, baseline)) if baseline else 0.0


def write_csv(path, rows):
    preferred = [
        "case",
        "phase",
        "mode",
        "repetition",
        "target_qps",
        "sent_qps",
        "completed_qps",
        "completion_percent",
        "lost",
        "average_latency_s",
        "p50_latency_us",
        "p95_latency_us",
        "p99_latency_us",
        "p999_latency_us",
        "backend_queries",
        "xdp_cache_tx",
        "xdp_cache_learned",
        "xdp_learn_rejected",
        "geneve_packets",
        "tap_drop_errors",
        "softnet_drops",
        "node1_cycles",
        "node2_cycles",
        "gate_pass",
        "gate_reasons",
    ]
    with Path(path).open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=preferred, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def compact_metrics(rows):
    return {
        "runs": len(rows),
        "sent_qps": median(rows, "sent_qps"),
        "completed_qps": median(rows, "completed_qps"),
        "completion_percent": median(rows, "completion_percent"),
        "average_latency_us": median(rows, "average_latency_s") * 1_000_000,
        "p50_latency_us": median(rows, "p50_latency_us"),
        "p95_latency_us": median(rows, "p95_latency_us"),
        "p99_latency_us": median(rows, "p99_latency_us"),
        "p999_latency_us": median(rows, "p999_latency_us"),
        "backend_queries": median(rows, "backend_queries"),
        "xdp_cache_tx": median(rows, "xdp_cache_tx"),
        "geneve_packets": median(rows, "geneve_packets"),
        "node1_cycles": median(rows, "node1_cycles"),
        "node2_cycles": median(rows, "node2_cycles"),
    }


def markdown_table(rows, columns, headers):
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join("---" for _ in headers) + " |"]
    for row in rows:
        lines.append("| " + " | ".join(str(row.get(column, "")) for column in columns) + " |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact_dir")
    args = parser.parse_args()
    root = Path(args.artifact_dir)
    rows = [
        parse_case(case_dir)
        for case_dir in sorted((root / "cases").iterdir())
        if (case_dir / "metadata.json").is_file()
    ]
    rows.sort(key=lambda row: (row.get("phase", ""), float(row.get("target_qps", 0)), row.get("case", "")))
    write_csv(root / "results.csv", rows)

    modes = ("no_hook", "tap_xdp")
    scan = {mode: [row for row in rows if row.get("phase") == "scan" and row.get("mode") == mode] for mode in modes}
    capacity = {
        mode: max((float(row["target_qps"]) for row in scan[mode] if row["gate_pass"]), default=0)
        for mode in modes
    }
    tested_rates = sorted({float(row["target_qps"]) for row in rows if row.get("phase") == "scan"})
    capacity_censored = {
        mode: bool(tested_rates and capacity[mode] == tested_rates[-1]) for mode in modes
    }
    steady_rows = {mode: [row for row in rows if row.get("phase") == "steady" and row.get("mode") == mode] for mode in modes}
    steady = {mode: compact_metrics(steady_rows[mode]) for mode in modes}
    baseline = steady["no_hook"]
    accelerated = steady["tap_xdp"]
    speedup = {
        "capacity": ratio(capacity["tap_xdp"], capacity["no_hook"]),
        "average_latency": ratio(baseline["average_latency_us"], accelerated["average_latency_us"]),
        "p50_latency": ratio(baseline["p50_latency_us"], accelerated["p50_latency_us"]),
        "p95_latency": ratio(baseline["p95_latency_us"], accelerated["p95_latency_us"]),
        "p99_latency": ratio(baseline["p99_latency_us"], accelerated["p99_latency_us"]),
        "backend_offload_percent": percent_offload(baseline["backend_queries"], accelerated["backend_queries"]),
        "geneve_offload_percent": percent_offload(baseline["geneve_packets"], accelerated["geneve_packets"]),
    }
    correctness = {
        mode: load_json(root / "correctness" / f"{mode}.json", {}) for mode in modes
    }
    summary = {
        "capacity_qps": capacity,
        "capacity_censored": capacity_censored,
        "steady": steady,
        "speedup": speedup,
        "correctness": {mode: bool(value.get("passed")) for mode, value in correctness.items()},
        "cases": len(rows),
    }
    (root / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    scan_table = []
    for row in [row for row in rows if row.get("phase") == "scan"]:
        scan_table.append(
            {
                "rate": int(float(row["target_qps"])),
                "mode": row["mode"],
                "sent": f'{row["sent_qps"]:.0f}',
                "done": f'{row["completion_percent"]:.3f}%',
                "p50": f'{row.get("p50_latency_us", 0):.0f}',
                "p99": f'{row.get("p99_latency_us", 0):.0f}',
                "backend": row["backend_queries"],
                "xdp_tx": row["xdp_cache_tx"],
                "gate": "PASS" if row["gate_pass"] else f'FAIL ({row["gate_reasons"]})',
            }
        )
    steady_table = []
    for mode in modes:
        item = steady[mode]
        steady_table.append(
            {
                "mode": mode,
                "runs": item["runs"],
                "qps": f'{item["completed_qps"]:.0f}',
                "done": f'{item["completion_percent"]:.3f}%',
                "avg": f'{item["average_latency_us"]:.1f}',
                "p50": f'{item["p50_latency_us"]:.1f}',
                "p95": f'{item["p95_latency_us"]:.1f}',
                "p99": f'{item["p99_latency_us"]:.1f}',
                "backend": f'{item["backend_queries"]:.0f}',
                "geneve": f'{item["geneve_packets"]:.0f}',
            }
        )
    cap_text = []
    for mode in modes:
        suffix = "+" if capacity_censored[mode] else ""
        cap_text.append(f"{mode}={capacity[mode]:.0f}{suffix} QPS")
    report = f"""# OpenStack realistic DNS benchmark

This is a cross-host OpenStack VM test using the deterministic 50k-name bootstrap corpus. It is not presented as a production trace.

## Outcome

- correctness: no_hook={summary['correctness']['no_hook']}, tap_xdp={summary['correctness']['tap_xdp']}
- maximum sustainable tested capacity: {', '.join(cap_text)}
- capacity speedup: {speedup['capacity']:.2f}x
- paired steady latency speedup: average {speedup['average_latency']:.2f}x, p50 {speedup['p50_latency']:.2f}x, p95 {speedup['p95_latency']:.2f}x, p99 {speedup['p99_latency']:.2f}x
- backend offload at steady load: {speedup['backend_offload_percent']:.1f}%
- Geneve packet offload at steady load: {speedup['geneve_offload_percent']:.1f}%

A trailing `+` on capacity means the highest tested point still passed, so the value is a lower bound.

## Paired steady runs (median)

{markdown_table(steady_table, ('mode', 'runs', 'qps', 'done', 'avg', 'p50', 'p95', 'p99', 'backend', 'geneve'), ('mode', 'runs', 'completed QPS', 'completion', 'avg us', 'p50 us', 'p95 us', 'p99 us', 'backend queries', 'Geneve packets'))}

## Capacity scan

{markdown_table(scan_table, ('rate', 'mode', 'sent', 'done', 'p50', 'p99', 'backend', 'xdp_tx', 'gate'), ('target QPS', 'mode', 'sent QPS', 'completion', 'p50 us', 'p99 us', 'backend queries', 'XDP TX', 'SLO gate'))}

The SLO gate requires generator delivery >=99% of target, completion >=99.9%, p99 <=10 ms, and zero TAP/softnet drop deltas. Raw `dnsperf`, `resperf`, host snapshots, perf counters and backend counters are retained in this directory.

## Scope limits

- One 2-vCPU client VM and one 2-vCPU backend VM were used across node1/node2.
- The corpus preserves a hot/warm/cold mix but is synthetic; the 5% unsupported-QTYPE stream stands in for per-query EDNS because dnsperf cannot toggle EDNS per input row.
- OpenStack uses TAP generic XDP. The physical NIC native-XDP result is a separate capability track.
"""
    (root / "summary.md").write_text(report, encoding="utf-8")
    print(report)


if __name__ == "__main__":
    main()
