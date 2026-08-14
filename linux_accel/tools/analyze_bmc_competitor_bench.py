#!/usr/bin/env python3
"""Summarize reproducible nohook/BMC/linux_accel Memcached benchmarks."""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
from pathlib import Path
from typing import Any, Iterable


CASE_RE = re.compile(r"^(nohook|bmc|linux-accel)-r([0-9]+)$")
CLIENT_PREFIX = "memcached_udp_zipf"
MODES = ("nohook", "bmc", "linux-accel")
LATENCY_FIELDS = ("avg_us", "p50_us", "p95_us", "p99_us")
CPU_FIELDS = (
    "user",
    "nice",
    "system",
    "idle",
    "iowait",
    "irq",
    "softirq",
    "steal",
    "guest",
    "guest_nice",
)


def parse_scalar(value: str) -> Any:
    if re.fullmatch(r"[-+]?[0-9]+", value):
        return int(value)
    try:
        number = float(value)
    except ValueError:
        return value
    return number if math.isfinite(number) else value


def parse_kv_line(line: str, expected_prefix: str | None = None) -> dict[str, Any]:
    words = line.strip().split()
    if expected_prefix:
        if not words or words[0] != expected_prefix:
            raise ValueError(f"expected {expected_prefix!r}, got {line.strip()!r}")
        words = words[1:]
    values: dict[str, Any] = {}
    for word in words:
        if "=" not in word:
            continue
        key, value = word.split("=", 1)
        values[key] = parse_scalar(value)
    return values


def read_metadata(path: Path) -> dict[str, Any]:
    values: dict[str, Any] = {}
    if not path.exists():
        return values
    for line in path.read_text(errors="replace").splitlines():
        if "=" not in line:
            continue
        words = line.split()
        if len(words) > 1 and all("=" in word for word in words):
            values.update(parse_kv_line(line))
            continue
        key, value = line.split("=", 1)
        if re.fullmatch(r"[A-Za-z0-9_.-]+", key):
            values[key] = parse_scalar(value)
    return values


def read_proc_stat(path: Path) -> dict[str, Any]:
    values: dict[str, Any] = {}
    for line in path.read_text(errors="replace").splitlines():
        words = line.split()
        if not words:
            continue
        if words[0] == "cpu":
            for index, field in enumerate(CPU_FIELDS, start=1):
                values[f"cpu_{field}"] = int(words[index]) if index < len(words) else 0
        elif words[0] in ("ctxt", "intr", "processes", "procs_running", "procs_blocked"):
            values[words[0]] = int(words[1])
    return values


def read_softirqs(path: Path) -> dict[str, int]:
    values: dict[str, int] = {}
    for line in path.read_text(errors="replace").splitlines():
        if ":" not in line:
            continue
        name, counts = line.split(":", 1)
        name = name.strip()
        words = counts.split()
        if words and all(word.isdigit() for word in words):
            values[name] = sum(int(word) for word in words)
    return values


def read_softnet(path: Path) -> dict[str, int]:
    names = (
        "processed",
        "dropped",
        "time_squeeze",
        "cpu_collision",
        "received_rps",
        "flow_limit_count",
    )
    totals = {name: 0 for name in names}
    for line in path.read_text(errors="replace").splitlines():
        words = line.split()
        indexes = (0, 1, 2, 8, 9, 10)
        for name, index in zip(names, indexes):
            if index < len(words):
                totals[name] += int(words[index], 16)
    return totals


def read_snmp(path: Path) -> dict[str, int]:
    rows = path.read_text(errors="replace").splitlines()
    values: dict[str, int] = {}
    for index in range(0, len(rows) - 1):
        header = rows[index].split()
        data = rows[index + 1].split()
        if not header or not data or not header[0].endswith(":") or header[0] != data[0]:
            continue
        protocol = header[0][:-1]
        if len(header) != len(data):
            continue
        for name, value in zip(header[1:], data[1:]):
            if re.fullmatch(r"[0-9]+", value):
                values[f"{protocol}_{name}"] = int(value)
    return values


def delta(before: dict[str, int], after: dict[str, int], prefix: str) -> dict[str, int]:
    return {
        f"{prefix}_{key}_delta": after[key] - before[key]
        for key in sorted(before.keys() & after.keys())
    }


def median(values: Iterable[float | int]) -> float:
    return float(statistics.median(values))


def load_case(case_dir: Path, profile: str) -> dict[str, Any]:
    match = CASE_RE.fullmatch(case_dir.name)
    if not match:
        raise ValueError(f"invalid case directory {case_dir}")
    mode, repetition = match.group(1), int(match.group(2))
    client_lines = [
        line
        for line in (case_dir / "client.log").read_text(errors="replace").splitlines()
        if line.startswith(CLIENT_PREFIX)
    ]
    if len(client_lines) != 1:
        raise ValueError(f"expected one client result in {case_dir}, found {len(client_lines)}")
    row: dict[str, Any] = {
        "profile": profile,
        "mode": mode,
        "repetition": repetition,
        "case_dir": str(case_dir),
    }
    row.update(parse_kv_line(client_lines[0], CLIENT_PREFIX))
    row.update(read_metadata(case_dir / "metadata.txt"))

    proc_before = read_proc_stat(case_dir / "proc-stat-before.txt")
    proc_after = read_proc_stat(case_dir / "proc-stat-after.txt")
    row.update(delta(proc_before, proc_after, "proc"))
    total_ticks = sum(
        row.get(f"proc_cpu_{field}_delta", 0)
        for field in CPU_FIELDS[:8]
    )
    idle_ticks = row.get("proc_cpu_idle_delta", 0) + row.get("proc_cpu_iowait_delta", 0)
    row["host_busy_pct"] = 100.0 * (total_ticks - idle_ticks) / total_ticks if total_ticks else 0.0

    softirq_before = read_softirqs(case_dir / "softirqs-before.txt")
    softirq_after = read_softirqs(case_dir / "softirqs-after.txt")
    row.update(delta(softirq_before, softirq_after, "softirq"))
    softnet_before = read_softnet(case_dir / "softnet-before.txt")
    softnet_after = read_softnet(case_dir / "softnet-after.txt")
    row.update(delta(softnet_before, softnet_after, "softnet"))
    snmp_before = read_snmp(case_dir / "snmp-before.txt")
    snmp_after = read_snmp(case_dir / "snmp-after.txt")
    row.update(delta(snmp_before, snmp_after, "snmp"))
    guest_snmp_before_path = case_dir / "guest-snmp-before.txt"
    guest_snmp_after_path = case_dir / "guest-snmp-after.txt"
    if guest_snmp_before_path.exists() and guest_snmp_after_path.exists():
        row.update(
            delta(
                read_snmp(guest_snmp_before_path),
                read_snmp(guest_snmp_after_path),
                "guest_snmp",
            )
        )
    guest_netstat_before_path = case_dir / "guest-netstat-before.txt"
    guest_netstat_after_path = case_dir / "guest-netstat-after.txt"
    if guest_netstat_before_path.exists() and guest_netstat_after_path.exists():
        row.update(
            delta(
                read_snmp(guest_netstat_before_path),
                read_snmp(guest_netstat_after_path),
                "guest_netstat",
            )
        )
    client_snmp_before_path = case_dir / "client-snmp-before.txt"
    client_snmp_after_path = case_dir / "client-snmp-after.txt"
    if client_snmp_before_path.exists() and client_snmp_after_path.exists():
        row.update(
            delta(
                read_snmp(client_snmp_before_path),
                read_snmp(client_snmp_after_path),
                "client_snmp",
            )
        )
    client_netstat_before_path = case_dir / "client-netstat-before.txt"
    client_netstat_after_path = case_dir / "client-netstat-after.txt"
    if client_netstat_before_path.exists() and client_netstat_after_path.exists():
        row.update(
            delta(
                read_snmp(client_netstat_before_path),
                read_snmp(client_netstat_after_path),
                "client_netstat",
            )
        )

    attempted = int(row["attempted"])
    completed = int(row["completed"])
    backend = int(row["backend_delta"])
    row["failure_pct"] = 100.0 * int(row["failed"]) / attempted if attempted else 0.0
    row["backend_offload_pct"] = 100.0 * (attempted - backend) / attempted if attempted else 0.0
    row["elapsed_s"] = completed / float(row["qps"]) if row["qps"] else 0.0
    row["context_switches_per_request"] = row.get("proc_ctxt_delta", 0) / attempted if attempted else 0.0
    row["net_rx_softirqs_per_request"] = row.get("softirq_NET_RX_delta", 0) / attempted if attempted else 0.0
    return row


def load_run(
    run_dir: Path, *, allow_failures: bool = False
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    metadata = read_metadata(run_dir / "metadata.txt")
    # `path_profile` only distinguishes hit/miss mechanics.  Prefer the
    # workload identity so independent mixed workloads (paper parameters,
    # capacity pressure and Facebook locality) are never pooled together.
    profile = str(metadata.get("profile", metadata.get("path_profile", run_dir.name)))
    rows = [
        load_case(path, profile)
        for path in sorted((run_dir / "cases").iterdir())
        if path.is_dir() and CASE_RE.fullmatch(path.name)
    ]
    if not rows:
        raise ValueError(f"no benchmark cases under {run_dir}")
    expected_repetitions = int(metadata.get("repetitions", 0))
    for mode in MODES:
        repetitions = sorted(int(row["repetition"]) for row in rows if row["mode"] == mode)
        expected = list(range(1, expected_repetitions + 1))
        if repetitions != expected:
            raise ValueError(f"{run_dir}: {mode} repetitions {repetitions}, expected {expected}")
    if not allow_failures and any(int(row["failed"]) != 0 for row in rows):
        raise ValueError(f"{run_dir}: at least one run has failed requests")
    return metadata, rows


def aggregate(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    fields = (
        "qps",
        *LATENCY_FIELDS,
        "failure_pct",
        "backend_delta",
        "backend_offload_pct",
        "host_busy_pct",
        "proc_ctxt_delta",
        "context_switches_per_request",
        "softirq_NET_RX_delta",
        "net_rx_softirqs_per_request",
        "softnet_dropped_delta",
        "softnet_time_squeeze_delta",
        "snmp_Udp_InErrors_delta",
        "snmp_Udp_RcvbufErrors_delta",
        "snmp_Udp_SndbufErrors_delta",
    )
    profiles = sorted({str(row["profile"]) for row in rows})
    output: list[dict[str, Any]] = []
    for profile in profiles:
        profile_rows = [row for row in rows if row["profile"] == profile]
        medians: dict[str, dict[str, float]] = {}
        for mode in MODES:
            mode_rows = [row for row in profile_rows if row["mode"] == mode]
            medians[mode] = {
                field: median(float(row.get(field, 0)) for row in mode_rows)
                for field in fields
            }
            medians[mode]["failed"] = median(int(row["failed"]) for row in mode_rows)
            medians[mode]["failed_total"] = float(
                sum(int(row["failed"]) for row in mode_rows)
            )
            medians[mode]["attempted_total"] = float(
                sum(int(row["attempted"]) for row in mode_rows)
            )
            medians[mode]["failure_pct_total"] = (
                100.0
                * medians[mode]["failed_total"]
                / medians[mode]["attempted_total"]
                if medians[mode]["attempted_total"]
                else 0.0
            )
            medians[mode]["runs"] = float(len(mode_rows))

        baseline = medians["nohook"]
        for mode in MODES:
            summary: dict[str, Any] = {"profile": profile, "mode": mode}
            summary.update(medians[mode])
            summary["qps_speedup_vs_nohook"] = (
                medians[mode]["qps"] / baseline["qps"] if baseline["qps"] else 0.0
            )
            for field in LATENCY_FIELDS:
                summary[f"{field}_improvement_vs_nohook"] = (
                    baseline[field] / medians[mode][field] if medians[mode][field] else 0.0
                )
            output.append(summary)
    return output


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fields = sorted({key for row in rows for key in row})
    with path.open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def fmt(value: Any, digits: int = 3) -> str:
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def write_markdown(path: Path, summaries: list[dict[str, Any]], sources: list[Path]) -> None:
    lines = [
        "# BMC competitor benchmark summary",
        "",
        "All values are medians across repetitions. Throughput speedup is variant QPS / nohook QPS; latency improvement is nohook latency / variant latency.",
        "",
    ]
    for profile in sorted({row["profile"] for row in summaries}):
        lines.extend(
            [
                f"## {profile}",
                "",
                "| Mode | QPS | QPS speedup | avg us | p50 us | p95 us | p99 us | Backend offload | Failed total | Failure rate | Host busy | ctxt/request | NET_RX/request | softnet drop |",
                "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
            ]
        )
        for mode in MODES:
            row = next(item for item in summaries if item["profile"] == profile and item["mode"] == mode)
            lines.append(
                "| {mode} | {qps:,.0f} | {speed:.3f}x | {avg:.3f} | {p50:.3f} | {p95:.3f} | {p99:.3f} | {offload:.3f}% | {failed:.0f} | {failure:.4f}% | {busy:.2f}% | {ctxt:.3f} | {netrx:.3f} | {drop:.0f} |".format(
                    mode=mode,
                    qps=row["qps"],
                    speed=row["qps_speedup_vs_nohook"],
                    avg=row["avg_us"],
                    p50=row["p50_us"],
                    p95=row["p95_us"],
                    p99=row["p99_us"],
                    offload=row["backend_offload_pct"],
                    failed=row["failed_total"],
                    failure=row["failure_pct_total"],
                    busy=row["host_busy_pct"],
                    ctxt=row["context_switches_per_request"],
                    netrx=row["net_rx_softirqs_per_request"],
                    drop=row["softnet_dropped_delta"],
                )
            )
        lines.append("")
    lines.extend(["## Inputs", ""])
    lines.extend(f"- `{source}`" for source in sources)
    lines.append("")
    path.write_text("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("runs", nargs="+", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--allow-failures",
        action="store_true",
        help="summarize measured request failures instead of rejecting the run",
    )
    args = parser.parse_args()

    all_rows: list[dict[str, Any]] = []
    run_metadata: dict[str, dict[str, Any]] = {}
    for run in args.runs:
        metadata, rows = load_run(run, allow_failures=args.allow_failures)
        run_metadata[str(run)] = metadata
        all_rows.extend(rows)
    summaries = aggregate(all_rows)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    write_csv(args.output_dir / "runs.csv", all_rows)
    write_csv(args.output_dir / "summary.csv", summaries)
    (args.output_dir / "summary.json").write_text(
        json.dumps(
            {"runs": all_rows, "summary": summaries, "metadata": run_metadata},
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )
    write_markdown(args.output_dir / "summary.md", summaries, args.runs)
    print(args.output_dir / "summary.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
