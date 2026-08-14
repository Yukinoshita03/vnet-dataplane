#!/usr/bin/env python3
"""Audit and summarize interleaved nohook/Xpress/linux_accel DNS runs."""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
from pathlib import Path
from typing import Any


MODES = ("nohook", "xpress", "linux-accel")
CASE_RE = re.compile(r"^rep-([0-9]+)$")
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


def parse_kv_line(line: str) -> dict[str, Any]:
    values: dict[str, Any] = {}
    for word in line.split():
        if "=" not in word:
            continue
        key, value = word.split("=", 1)
        values[key] = parse_scalar(value)
    return values


def read_metadata(path: Path) -> dict[str, Any]:
    values: dict[str, Any] = {}
    for line in path.read_text(errors="replace").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if re.fullmatch(r"[A-Za-z0-9_.-]+", key):
            values[key] = parse_scalar(value)
    return values


def read_proc_stat(path: Path) -> dict[str, int]:
    values: dict[str, int] = {}
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
        words = counts.split()
        if words and all(word.isdigit() for word in words):
            values[name.strip()] = sum(int(word) for word in words)
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
    indexes = (0, 1, 2, 8, 9, 10)
    totals = {name: 0 for name in names}
    for line in path.read_text(errors="replace").splitlines():
        words = line.split()
        for name, index in zip(names, indexes):
            if index < len(words):
                totals[name] += int(words[index], 16)
    return totals


def read_snmp(path: Path) -> dict[str, int]:
    rows = path.read_text(errors="replace").splitlines()
    values: dict[str, int] = {}
    for index in range(len(rows) - 1):
        header = rows[index].split()
        data = rows[index + 1].split()
        if not header or header[0] != data[0] or len(header) != len(data):
            continue
        protocol = header[0].rstrip(":")
        for name, value in zip(header[1:], data[1:]):
            if value.isdigit():
                values[f"{protocol}_{name}"] = int(value)
    return values


def add_delta(row: dict[str, Any], before: dict[str, int], after: dict[str, int], prefix: str) -> None:
    for key in sorted(before.keys() & after.keys()):
        row[f"{prefix}_{key}_delta"] = after[key] - before[key]


def load_case(run_dir: Path, profile: str, mode: str, case_dir: Path) -> dict[str, Any]:
    match = CASE_RE.fullmatch(case_dir.name)
    if not match:
        raise ValueError(f"invalid case directory: {case_dir}")
    lines = [
        line
        for line in (case_dir / "client.log").read_text(errors="replace").splitlines()
        if line.startswith("target=")
    ]
    if len(lines) != 1:
        raise ValueError(f"expected one client result in {case_dir}, found {len(lines)}")
    row: dict[str, Any] = {
        "run_dir": str(run_dir),
        "profile": profile,
        "mode": mode,
        "repetition": int(match.group(1)),
        "case_dir": str(case_dir),
    }
    row.update(parse_kv_line(lines[0]))
    # backend.log is a single whitespace-delimited record, for example:
    # backend_before=10 backend_after=20 backend_delta=10.  It is not the
    # one-key-per-line format used by metadata.txt.
    row.update(parse_kv_line((case_dir / "backend.log").read_text(errors="replace")))

    proc_before = read_proc_stat(case_dir / "proc-stat-before.txt")
    proc_after = read_proc_stat(case_dir / "proc-stat-after.txt")
    add_delta(row, proc_before, proc_after, "proc")
    total_ticks = sum(row.get(f"proc_cpu_{field}_delta", 0) for field in CPU_FIELDS[:8])
    idle_ticks = row.get("proc_cpu_idle_delta", 0) + row.get("proc_cpu_iowait_delta", 0)
    row["host_busy_pct"] = 100 * (total_ticks - idle_ticks) / total_ticks if total_ticks else 0.0

    add_delta(
        row,
        read_softirqs(case_dir / "softirqs-before.txt"),
        read_softirqs(case_dir / "softirqs-after.txt"),
        "softirq",
    )
    add_delta(
        row,
        read_softnet(case_dir / "softnet-before.txt"),
        read_softnet(case_dir / "softnet-after.txt"),
        "softnet",
    )
    add_delta(
        row,
        read_snmp(case_dir / "snmp-before.txt"),
        read_snmp(case_dir / "snmp-after.txt"),
        "snmp",
    )

    sent = int(row["sent"])
    received = int(row["received"])
    backend = int(row["backend_delta"])
    offered_rate = float(row.get("offered_rate", 0))
    qps_sent = float(row.get("qps_sent", 0))
    row["generator_delivery_pct"] = (
        100 * qps_sent / offered_rate if offered_rate else 0.0
    )
    row["completion_pct"] = 100 * received / sent if sent else 0.0
    # The backend counter measures queries actually consumed by the UDP
    # backend.  At saturation, sent - backend includes both fast-path replies
    # and packets dropped before the backend, so it overstates offload.  Every
    # backend query in this harness produces one reply; completed replies in
    # excess of that count are therefore the observable XDP fast-path replies.
    fastpath_completed = max(received - backend, 0)
    row["fastpath_completed"] = fastpath_completed
    row["backend_bypass_pct"] = 100 * fastpath_completed / sent if sent else 0.0
    row["backend_received_pct"] = 100 * backend / sent if sent else 0.0
    row["context_switches_per_sent"] = row.get("proc_ctxt_delta", 0) / sent if sent else 0.0
    row["net_rx_softirqs_per_sent"] = row.get("softirq_NET_RX_delta", 0) / sent if sent else 0.0
    return row


def load_run(run_dir: Path) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, Any]]]:
    metadata = read_metadata(run_dir / "metadata.txt")
    manifest = json.loads((run_dir / "corpus-manifest.json").read_text())
    profile = str(metadata.get("profile", run_dir.name))
    repetitions = int(metadata["repetitions"])

    for mode in MODES:
        correctness = json.loads((run_dir / mode / "correctness.json").read_text())
        if correctness.get("passed") is not True:
            raise ValueError(f"{run_dir}: {mode} correctness failed")
        smoke = parse_kv_line((run_dir / mode / "smoke.log").read_text())
        if int(smoke.get("invalid", -1)) != 0 or int(smoke.get("send_errors", -1)) != 0:
            raise ValueError(f"{run_dir}: {mode} smoke failed")

    before = (run_dir / "health/kubernetes-before.txt").read_text()
    after = (run_dir / "health/kubernetes-after.txt").read_text()
    if before != after or "=active\n" in before:
        raise ValueError(f"{run_dir}: Kubernetes guard changed or was active")
    if (run_dir / "health/attachments-before.txt").read_text() != (
        run_dir / "health/attachments-after.txt"
    ).read_text():
        raise ValueError(f"{run_dir}: attachment cleanup invariant failed")

    rows: list[dict[str, Any]] = []
    for mode in MODES:
        case_dirs = sorted(
            (path for path in (run_dir / mode).iterdir() if path.is_dir() and CASE_RE.fullmatch(path.name)),
            key=lambda path: int(CASE_RE.fullmatch(path.name).group(1)),
        )
        expected = list(range(1, repetitions + 1))
        actual = [int(CASE_RE.fullmatch(path.name).group(1)) for path in case_dirs]
        if actual != expected:
            raise ValueError(f"{run_dir}: {mode} repetitions {actual}, expected {expected}")
        for case_dir in case_dirs:
            row = load_case(run_dir, profile, mode, case_dir)
            client_tool = str(row.get("client_tool", metadata.get("client_tool", "burst")))
            if client_tool == "burst":
                if any(
                    int(row.get(field, -1)) != 0
                    for field in ("send_errors", "unexpected", "invalid", "affinity_errors")
                ):
                    raise ValueError(f"{case_dir}: client validation counters are nonzero")
            elif client_tool == "dnsperf":
                client = json.loads((case_dir / "client.json").read_text())
                response_count = sum(int(value) for value in client.get("response_codes", {}).values())
                if (
                    int(client["sent"]) != int(row["sent"])
                    or int(client["completed"]) != int(row["received"])
                    or int(client["sent"]) != int(client["completed"]) + int(client["lost"])
                    or int(client["histogram_answers"]) != int(client["completed"])
                    or response_count != int(client["completed"])
                ):
                    raise ValueError(f"{case_dir}: dnsperf normalization invariant failed")
                raw_log = (case_dir / "dnsperf.log").read_text(errors="replace")
                if re.search(r"^\[(Unexpected|Error|Fatal)\]", raw_log, re.MULTILINE):
                    raise ValueError(f"{case_dir}: dnsperf reported an error")
            else:
                raise ValueError(f"{case_dir}: unsupported client tool {client_tool}")
            rows.append(row)
    return metadata, manifest, rows


def expected_bypass(manifest: dict[str, Any], mode: str) -> float:
    if mode == "nohook":
        return 0.0
    field = "xpress_preloaded_hit_percent" if mode == "xpress" else "preloaded_hit_percent"
    return float(manifest[field])


def aggregate(
    metadata: dict[str, dict[str, Any]],
    manifests: dict[str, dict[str, Any]],
    rows: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    fields = (
        "qps_sent",
        "generator_delivery_pct",
        "qps_received",
        "completion_pct",
        "loss_pct",
        "avg_us",
        "p50_us",
        "p95_us",
        "p99_us",
        "backend_delta",
        "backend_bypass_pct",
        "host_busy_pct",
        "context_switches_per_sent",
        "net_rx_softirqs_per_sent",
        "softnet_dropped_delta",
        "softnet_time_squeeze_delta",
        "snmp_Udp_InErrors_delta",
        "snmp_Udp_RcvbufErrors_delta",
        "snmp_Udp_SndbufErrors_delta",
    )
    summaries: list[dict[str, Any]] = []
    for run_key, run_metadata in metadata.items():
        run_rows = [row for row in rows if row["run_dir"] == run_key]
        medians: dict[str, dict[str, float]] = {}
        for mode in MODES:
            mode_rows = [row for row in run_rows if row["mode"] == mode]
            medians[mode] = {
                field: float(statistics.median(float(row.get(field, 0)) for row in mode_rows))
                for field in fields
            }
        baseline = medians["nohook"]
        for mode in MODES:
            result: dict[str, Any] = {
                "run_dir": run_key,
                "profile": str(run_metadata.get("profile", Path(run_key).name)),
                "corpus_profile": str(run_metadata.get("corpus_profile", "unknown")),
                "rate": int(run_metadata["rate"]),
                "mode": mode,
                "runs": sum(row["mode"] == mode for row in run_rows),
                "expected_backend_bypass_pct": expected_bypass(manifests[run_key], mode),
            }
            result.update(medians[mode])
            result["completed_qps_ratio_vs_nohook"] = (
                medians[mode]["qps_received"] / baseline["qps_received"]
                if baseline["qps_received"]
                else 0.0
            )
            result["p99_improvement_vs_nohook"] = (
                baseline["p99_us"] / medians[mode]["p99_us"]
                if medians[mode]["p99_us"]
                else 0.0
            )
            summaries.append(result)
    return summaries


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fields = sorted({key for row in rows for key in row})
    with path.open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def write_markdown(path: Path, summaries: list[dict[str, Any]]) -> None:
    lines = [
        "# DNS competitor benchmark summary",
        "",
        "Medians across repetitions. Latencies only describe completed requests; high-loss capacity points therefore have survivor bias.",
        "",
    ]
    profiles = []
    for row in summaries:
        if row["profile"] not in profiles:
            profiles.append(row["profile"])
    for profile in profiles:
        lines.extend(
            [
                f"## {profile}",
                "",
                "| Mode | sent QPS | generator delivery | completed QPS | vs nohook | completion | loss | p50 us | p95 us | p99 us | nohook p99 / mode | backend bypass observed / expected | host busy | ctxt/sent | NET_RX/sent | softnet drop |",
                "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
            ]
        )
        for mode in MODES:
            row = next(item for item in summaries if item["profile"] == profile and item["mode"] == mode)
            lines.append(
                "| {mode} | {sent_qps:,.0f} | {delivery:.2f}% | {qps:,.0f} | {ratio:.3f}x | {completion:.3f}% | {loss:.3f}% | {p50:.1f} | {p95:.1f} | {p99:.1f} | {p99ratio:.3f}x | {bypass:.3f}% / {expected:.3f}% | {busy:.2f}% | {ctxt:.3f} | {netrx:.3f} | {drop:.0f} |".format(
                    mode=mode,
                    sent_qps=row["qps_sent"],
                    delivery=row["generator_delivery_pct"],
                    qps=row["qps_received"],
                    ratio=row["completed_qps_ratio_vs_nohook"],
                    completion=row["completion_pct"],
                    loss=row["loss_pct"],
                    p50=row["p50_us"],
                    p95=row["p95_us"],
                    p99=row["p99_us"],
                    p99ratio=row["p99_improvement_vs_nohook"],
                    bypass=row["backend_bypass_pct"],
                    expected=row["expected_backend_bypass_pct"],
                    busy=row["host_busy_pct"],
                    ctxt=row["context_switches_per_sent"],
                    netrx=row["net_rx_softirqs_per_sent"],
                    drop=row["softnet_dropped_delta"],
                )
            )
        lines.append("")

    capacity = [
        row
        for row in summaries
        if row["profile"].startswith(("radar-observed-", "dnsperf-radar-observed-"))
    ]
    if capacity:
        lines.extend(
            [
                "## Observed-mix capacity sweep",
                "",
                "| Target rate | Mode | sent QPS | generator delivery | completed QPS | completion | loss | p99 us |",
                "|---:|---|---:|---:|---:|---:|---:|---:|",
            ]
        )
        for row in sorted(capacity, key=lambda item: (item["rate"], MODES.index(item["mode"]))):
            lines.append(
                f"| {row['rate']:,} | {row['mode']} | {row['qps_sent']:,.0f} | "
                f"{row['generator_delivery_pct']:.2f}% | {row['qps_received']:,.0f} | "
                f"{row['completion_pct']:.3f}% | {row['loss_pct']:.3f}% | {row['p99_us']:.1f} |"
            )
        lines.append("")
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("runs", nargs="+", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    metadata: dict[str, dict[str, Any]] = {}
    manifests: dict[str, dict[str, Any]] = {}
    rows: list[dict[str, Any]] = []
    for run_dir in args.runs:
        run_metadata, manifest, run_rows = load_run(run_dir)
        metadata[str(run_dir)] = run_metadata
        manifests[str(run_dir)] = manifest
        rows.extend(run_rows)
    summaries = aggregate(metadata, manifests, rows)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    write_csv(args.output_dir / "runs.csv", rows)
    write_csv(args.output_dir / "summary.csv", summaries)
    (args.output_dir / "summary.json").write_text(
        json.dumps(
            {"metadata": metadata, "manifests": manifests, "runs": rows, "summary": summaries},
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )
    write_markdown(args.output_dir / "summary.md", summaries)
    print(args.output_dir / "summary.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
