#!/usr/bin/env python3
"""Audit and summarize OpenStack nohook/Xpress/linux_accel DNS runs."""

from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
from pathlib import Path
from typing import Any


MODES = ("nohook", "xpress", "linux-accel")
CASE_RE = re.compile(r"^(nohook|xpress|linux-accel)-r([1-9][0-9]*)$")


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def validate_health(root: Path) -> None:
    before_path = root / "health" / "kubernetes-before.txt"
    after_path = root / "health" / "kubernetes-after.txt"
    before = before_path.read_text(encoding="utf-8", errors="replace")
    after = after_path.read_text(encoding="utf-8", errors="replace")
    if before != after:
        raise ValueError("Kubernetes unit state changed during the benchmark")
    for line in before.splitlines():
        if line.rstrip().endswith("=active"):
            raise ValueError(f"Kubernetes unit was active: {line}")


def validate_correctness(root: Path) -> None:
    expected_backend = {"nohook": 14, "xpress": 13, "linux-accel": 11}
    for mode in MODES:
        result = load_json(root / "correctness" / f"{mode}.json")
        if result.get("passed") is not True:
            raise ValueError(f"{mode} correctness gate failed")
        text = (root / "correctness" / f"{mode}-backend.txt").read_text(
            encoding="utf-8"
        )
        expected = expected_backend[mode]
        if f"backend_delta={expected}" not in text or f"expected={expected}" not in text:
            raise ValueError(f"{mode} backend correctness delta is invalid: {text.strip()}")


def load_case(case_dir: Path, mode: str, repetition: int) -> dict[str, Any]:
    dnsperf = load_json(case_dir / "dnsperf.json")
    metadata = load_json(case_dir / "metadata.json")
    if metadata.get("mode") != mode or int(metadata.get("repetition", -1)) != repetition:
        raise ValueError(f"metadata identity mismatch in {case_dir}")

    sent = int(dnsperf["sent"])
    completed = int(dnsperf["completed"])
    lost = int(dnsperf["lost"])
    histogram_answers = int(dnsperf["histogram_answers"])
    response_count = sum(int(value) for value in dnsperf["response_codes"].values())
    if sent != completed + lost:
        raise ValueError(f"sent != completed + lost in {case_dir}")
    if histogram_answers != completed or response_count != completed:
        raise ValueError(f"dnsperf accounting mismatch in {case_dir}")

    backend_delta = int(metadata["backend_delta"])
    if backend_delta < 0 or backend_delta > completed:
        raise ValueError(f"invalid backend delta in {case_dir}: {backend_delta}")

    return {
        "mode": mode,
        "repetition": repetition,
        "offered_qps": int(metadata["offered_qps"]),
        "duration_seconds": int(metadata["duration_seconds"]),
        "sent": sent,
        "completed": completed,
        "lost": lost,
        "completion_percent": float(dnsperf["completion_percent"]),
        "sent_qps": float(dnsperf["sent_qps"]),
        "completed_qps": float(dnsperf["completed_qps"]),
        "p50_us": float(dnsperf["p50_latency_us"]),
        "p95_us": float(dnsperf["p95_latency_us"]),
        "p99_us": float(dnsperf["p99_latency_us"]),
        "backend_delta": backend_delta,
        "backend_offload_percent": (
            100.0 * (completed - backend_delta) / completed if completed else 0.0
        ),
        "case_dir": str(case_dir),
    }


def load_runs(root: Path) -> list[dict[str, Any]]:
    cases: dict[str, dict[int, Path]] = {mode: {} for mode in MODES}
    for path in (root / "cases").iterdir():
        if not path.is_dir():
            continue
        match = CASE_RE.fullmatch(path.name)
        if match:
            cases[match.group(1)][int(match.group(2))] = path

    repetitions = None
    rows: list[dict[str, Any]] = []
    for mode in MODES:
        actual = sorted(cases[mode])
        if not actual or actual != list(range(1, actual[-1] + 1)):
            raise ValueError(f"{mode} repetitions are incomplete: {actual}")
        if repetitions is None:
            repetitions = actual
        elif actual != repetitions:
            raise ValueError(f"repetition sets differ: {mode} has {actual}, expected {repetitions}")
        rows.extend(load_case(cases[mode][rep], mode, rep) for rep in actual)
    return rows


def aggregate(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    numeric_fields = (
        "sent_qps",
        "completed_qps",
        "completion_percent",
        "p50_us",
        "p95_us",
        "p99_us",
        "backend_delta",
        "backend_offload_percent",
    )
    summaries: list[dict[str, Any]] = []
    for mode in MODES:
        selected = [row for row in rows if row["mode"] == mode]
        summary: dict[str, Any] = {"mode": mode, "runs": len(selected)}
        for field in numeric_fields:
            summary[field] = float(
                statistics.median(float(row[field]) for row in selected)
            )
        summaries.append(summary)

    nohook = summaries[0]
    for summary in summaries:
        summary["qps_ratio_vs_nohook"] = (
            summary["completed_qps"] / nohook["completed_qps"]
            if nohook["completed_qps"]
            else 0.0
        )
        summary["p99_improvement_vs_nohook"] = (
            nohook["p99_us"] / summary["p99_us"] if summary["p99_us"] else 0.0
        )
    return summaries


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fields = sorted({key for row in rows for key in row})
    with path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def write_markdown(path: Path, summaries: list[dict[str, Any]]) -> None:
    by_mode = {row["mode"]: row for row in summaries}
    xpress = by_mode["xpress"]
    linux = by_mode["linux-accel"]
    linux_vs_xpress = (
        linux["completed_qps"] / xpress["completed_qps"]
        if xpress["completed_qps"]
        else 0.0
    )
    lines = [
        "# OpenStack DNS competitor benchmark",
        "",
        "Medians across audited repetitions. The path is client VM/TAP -> OVS/OVN/Geneve -> backend VM.",
        "",
        "| Mode | completed QPS | vs nohook | completion | p50 us | p95 us | p99 us | nohook p99 / mode | backend offload |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for mode in MODES:
        row = by_mode[mode]
        lines.append(
            f"| {mode} | {row['completed_qps']:,.0f} | {row['qps_ratio_vs_nohook']:.3f}x | "
            f"{row['completion_percent']:.3f}% | {row['p50_us']:.1f} | "
            f"{row['p95_us']:.1f} | {row['p99_us']:.1f} | "
            f"{row['p99_improvement_vs_nohook']:.3f}x | "
            f"{row['backend_offload_percent']:.3f}% |"
        )
    lines.extend(
        [
            "",
            f"linux_accel / Xpress completed-QPS ratio: **{linux_vs_xpress:.3f}x**.",
            "",
        ]
    )
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact_dir", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    validate_health(args.artifact_dir)
    validate_correctness(args.artifact_dir)
    rows = load_runs(args.artifact_dir)
    summaries = aggregate(rows)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    write_csv(args.output_dir / "runs.csv", rows)
    write_csv(args.output_dir / "summary.csv", summaries)
    (args.output_dir / "summary.json").write_text(
        json.dumps({"runs": rows, "summary": summaries}, indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )
    write_markdown(args.output_dir / "summary.md", summaries)
    print(args.output_dir / "summary.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
