#!/usr/bin/env python3
"""Audit and summarize repeated UDP or gRPC fast-path benchmark runs."""

from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
from pathlib import Path
from typing import Any


REP_RE = re.compile(r"^rep-([1-9][0-9]*)$")


def parse_kv(path: Path) -> dict[str, Any]:
    values: dict[str, Any] = {}
    for word in path.read_text(encoding="utf-8", errors="replace").split():
        if "=" not in word:
            continue
        key, value = word.split("=", 1)
        try:
            values[key] = float(value)
        except ValueError:
            values[key] = value
    return values


def repetition_dirs(root: Path) -> list[tuple[int, Path]]:
    found: list[tuple[int, Path]] = []
    for path in root.iterdir():
        match = REP_RE.fullmatch(path.name)
        if path.is_dir() and match:
            found.append((int(match.group(1)), path))
    found.sort()
    actual = [number for number, unused in found]
    if not actual or actual != list(range(1, actual[-1] + 1)):
        raise ValueError(f"incomplete repetitions in {root}: {actual}")
    return found


def require_success(values: dict[str, Any], path: Path) -> None:
    if int(values.get("failed", -1)) != 0:
        raise ValueError(f"failed requests in {path}: {values.get('failed')}")


def load_udp(root: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for repetition, path in repetition_dirs(root):
        for mode, filename in (("userspace", "baseline.log"), ("generic-xdp", "xdp.log")):
            values = parse_kv(path / filename)
            require_success(values, path / filename)
            rows.append(
                {
                    "repetition": repetition,
                    "mode": mode,
                    "qps": float(values["qps"]),
                    "p50_us": float(values["p50_us"]),
                    "p95_us": float(values["p95_us"]),
                    "p99_us": float(values["p99_us"]),
                    "failed": int(values["failed"]),
                }
            )
    return rows


def load_grpc(root: Path) -> list[dict[str, Any]]:
    files = (
        ("direct-backend", "backend-latency.log"),
        ("cache-hit-serving", "cache-serving-latency.log"),
        ("cache-hit-not-serving", "cache-not-serving-latency.log"),
        ("response-cache-miss", "response-miss-latency.log"),
        ("policy-miss", "fallback-latency.log"),
    )
    rows: list[dict[str, Any]] = []
    for repetition, path in repetition_dirs(root):
        for mode, filename in files:
            values = parse_kv(path / filename)
            require_success(values, path / filename)
            rows.append(
                {
                    "repetition": repetition,
                    "mode": mode,
                    "qps": float(values["qps"]),
                    "p50_us": float(values["p50_us"]),
                    "p95_us": float(values["p95_us"]),
                    "p99_us": float(values["p99_us"]),
                    "failed": int(values["failed"]),
                }
            )
    return rows


def aggregate(rows: list[dict[str, Any]], baseline_mode: str) -> list[dict[str, Any]]:
    modes = list(dict.fromkeys(row["mode"] for row in rows))
    summaries: list[dict[str, Any]] = []
    for mode in modes:
        selected = [row for row in rows if row["mode"] == mode]
        summaries.append(
            {
                "mode": mode,
                "runs": len(selected),
                "qps": statistics.median(row["qps"] for row in selected),
                "p50_us": statistics.median(row["p50_us"] for row in selected),
                "p95_us": statistics.median(row["p95_us"] for row in selected),
                "p99_us": statistics.median(row["p99_us"] for row in selected),
                "failed": sum(row["failed"] for row in selected),
            }
        )
    baseline = next(row for row in summaries if row["mode"] == baseline_mode)
    for row in summaries:
        row["qps_ratio_vs_baseline"] = row["qps"] / baseline["qps"]
        row["p99_improvement_vs_baseline"] = baseline["p99_us"] / row["p99_us"]
    return summaries


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fields = sorted({key for row in rows for key in row})
    with path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def write_markdown(path: Path, kind: str, summaries: list[dict[str, Any]]) -> None:
    lines = [
        f"# {kind.upper()} repeated benchmark summary",
        "",
        "Medians across audited repetitions; every included client log has `failed=0`.",
        "",
        "| path | median QPS | QPS / baseline | p50 us | p95 us | p99 us | baseline p99 / path | failures |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in summaries:
        lines.append(
            f"| {row['mode']} | {row['qps']:,.2f} | {row['qps_ratio_vs_baseline']:.3f}x | "
            f"{row['p50_us']:.3f} | {row['p95_us']:.3f} | {row['p99_us']:.3f} | "
            f"{row['p99_improvement_vs_baseline']:.3f}x | {row['failed']} |"
        )
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("udp", "grpc"))
    parser.add_argument("run_root", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    if args.kind == "udp":
        rows = load_udp(args.run_root)
        baseline = "userspace"
    else:
        rows = load_grpc(args.run_root)
        baseline = "direct-backend"
    summaries = aggregate(rows, baseline)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    write_csv(args.output_dir / "runs.csv", rows)
    write_csv(args.output_dir / "summary.csv", summaries)
    (args.output_dir / "summary.json").write_text(
        json.dumps({"runs": rows, "summary": summaries}, indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )
    write_markdown(args.output_dir / "summary.md", args.kind, summaries)
    print(args.output_dir / "summary.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
