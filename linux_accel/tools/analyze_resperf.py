#!/usr/bin/env python3
"""Audit and summarize repeated DNS-OARC resperf capacity ramps."""

from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
from pathlib import Path
from typing import Any


MODES = ("nohook", "xpress", "linux-accel")
CASE_RE = re.compile(r"^rep-([0-9]+)$")
LOG_FIELDS = {
    "queries_sent": re.compile(r"^\s*Queries sent:\s+(\d+)", re.MULTILINE),
    "queries_completed": re.compile(r"^\s*Queries completed:\s+(\d+)", re.MULTILINE),
    "queries_lost": re.compile(r"^\s*Queries lost:\s+(\d+)", re.MULTILINE),
    "run_time_s": re.compile(r"^\s*Run time \(s\):\s+([0-9.]+)", re.MULTILINE),
    "reported_max_qps": re.compile(
        r"^\s*Maximum throughput:\s+([0-9.]+) qps", re.MULTILINE
    ),
    "reported_loss_at_max_pct": re.compile(
        r"^\s*Lost at that point:\s+([0-9.]+)%", re.MULTILINE
    ),
}


def parse_kv_line(line: str) -> dict[str, int]:
    values: dict[str, int] = {}
    for word in line.split():
        if "=" not in word:
            continue
        key, value = word.split("=", 1)
        if value.isdigit():
            values[key] = int(value)
    return values


def parse_log(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8", errors="replace")
    if "[Status] Testing complete" not in text:
        raise ValueError(f"{path}: resperf did not complete")
    if re.search(r"^\[(Unexpected|Error|Fatal)\]", text, re.MULTILINE):
        raise ValueError(f"{path}: resperf reported an error")
    values: dict[str, Any] = {}
    for name, pattern in LOG_FIELDS.items():
        match = pattern.search(text)
        if not match:
            raise ValueError(f"{path}: missing {name}")
        values[name] = float(match.group(1)) if name.endswith(("_s", "_qps", "_pct")) else int(match.group(1))
    if values["queries_sent"] != values["queries_completed"] + values["queries_lost"]:
        raise ValueError(f"{path}: sent != completed + lost")
    values["reached_outstanding_limit"] = "Reached 65536 outstanding queries" in text
    values["fell_behind"] = "Fell behind" in text
    return values


def parse_plot(path: Path) -> list[dict[str, float]]:
    rows: list[dict[str, float]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        words = line.split()
        if len(words) != 8:
            raise ValueError(f"{path}: invalid plot row: {line}")
        values = [float(word) for word in words]
        actual = values[2]
        responses = values[3]
        rows.append(
            {
                "time_s": values[0],
                "target_qps": values[1],
                "actual_qps": actual,
                "responses_qps": responses,
                "failures_qps": values[4],
                "avg_latency_s": values[5],
                "connections_qps": values[6],
                "connection_avg_latency_s": values[7],
                "loss_pct": 100.0 * (actual - responses) / actual if actual else 0.0,
            }
        )
    if not rows:
        raise ValueError(f"{path}: no plot rows")
    return rows


def capacity_before_loss(rows: list[dict[str, float]], threshold_pct: float) -> dict[str, float]:
    """Match resperf -L semantics: stop at the first interval over threshold."""
    eligible: list[dict[str, float]] = []
    for row in rows:
        if row["loss_pct"] > threshold_pct:
            break
        eligible.append(row)
    if not eligible:
        return {
            "responses_qps": 0.0,
            "actual_qps": 0.0,
            "target_qps": 0.0,
            "loss_pct": 0.0,
            "avg_latency_us": 0.0,
        }
    best = max(eligible, key=lambda row: row["responses_qps"])
    return {
        "responses_qps": best["responses_qps"],
        "actual_qps": best["actual_qps"],
        "target_qps": best["target_qps"],
        "loss_pct": best["loss_pct"],
        "avg_latency_us": best["avg_latency_s"] * 1_000_000,
    }


def load_case(mode: str, case_dir: Path) -> dict[str, Any]:
    match = CASE_RE.fullmatch(case_dir.name)
    if not match:
        raise ValueError(f"invalid case directory: {case_dir}")
    exit_code = int((case_dir / "resperf.exit").read_text().strip())
    if exit_code != 0:
        raise ValueError(f"{case_dir}: resperf exit {exit_code}")
    row: dict[str, Any] = {
        "mode": mode,
        "repetition": int(match.group(1)),
        "case_dir": str(case_dir),
    }
    row.update(parse_log(case_dir / "resperf.log"))
    plot = parse_plot(case_dir / "resperf.plot")
    row["plot_intervals"] = len(plot)
    row["peak_actual_qps"] = max(item["actual_qps"] for item in plot)
    row["peak_responses_qps"] = max(item["responses_qps"] for item in plot)
    row["final_target_qps"] = plot[-1]["target_qps"]
    row["final_actual_qps"] = plot[-1]["actual_qps"]
    row["final_responses_qps"] = plot[-1]["responses_qps"]
    row["final_loss_pct"] = plot[-1]["loss_pct"]
    for threshold in (1, 5, 10):
        capacity = capacity_before_loss(plot, float(threshold))
        for field, value in capacity.items():
            row[f"capacity_{threshold}pct_{field}"] = value

    backend = parse_kv_line((case_dir / "backend.log").read_text())
    row.update(backend)
    completed = int(row["queries_completed"])
    sent = int(row["queries_sent"])
    backend_delta = int(row["backend_delta"])
    fastpath_completed = max(completed - backend_delta, 0)
    row["completion_pct"] = 100.0 * completed / sent if sent else 0.0
    row["backend_bypass_pct"] = 100.0 * fastpath_completed / sent if sent else 0.0

    # A run is client-limited when the scheduled rate is still rising, the
    # actual rate has flattened far below it, and responses continue to match
    # actual sends.  In that case the measured capacity is only a lower bound.
    row["client_limited"] = (
        not row["reached_outstanding_limit"]
        and not row["fell_behind"]
        and row["final_target_qps"] > row["final_actual_qps"] * 1.5
        and row["final_loss_pct"] <= 1.0
    )
    return row


def load_run(root: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for mode in MODES:
        mode_root = root / mode
        case_dirs = sorted(
            (path for path in mode_root.iterdir() if path.is_dir() and CASE_RE.fullmatch(path.name)),
            key=lambda path: int(CASE_RE.fullmatch(path.name).group(1)),
        )
        if not case_dirs:
            raise ValueError(f"{mode_root}: no repetitions")
        expected = list(range(1, len(case_dirs) + 1))
        actual = [int(CASE_RE.fullmatch(path.name).group(1)) for path in case_dirs]
        if actual != expected:
            raise ValueError(f"{mode_root}: repetitions {actual}, expected {expected}")
        rows.extend(load_case(mode, case_dir) for case_dir in case_dirs)
    return rows


def aggregate(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    numeric_fields = (
        "reported_max_qps",
        "reported_loss_at_max_pct",
        "peak_actual_qps",
        "peak_responses_qps",
        "completion_pct",
        "backend_bypass_pct",
        "capacity_1pct_responses_qps",
        "capacity_1pct_actual_qps",
        "capacity_1pct_loss_pct",
        "capacity_1pct_avg_latency_us",
        "capacity_5pct_responses_qps",
        "capacity_10pct_responses_qps",
    )
    summaries: list[dict[str, Any]] = []
    for mode in MODES:
        mode_rows = [row for row in rows if row["mode"] == mode]
        summary: dict[str, Any] = {
            "mode": mode,
            "runs": len(mode_rows),
            "client_limited_runs": sum(bool(row["client_limited"]) for row in mode_rows),
            "outstanding_limited_runs": sum(bool(row["reached_outstanding_limit"]) for row in mode_rows),
        }
        for field in numeric_fields:
            summary[field] = float(statistics.median(float(row[field]) for row in mode_rows))
        summaries.append(summary)
    baseline = summaries[0]
    for summary in summaries:
        summary["capacity_1pct_ratio_vs_nohook"] = (
            summary["capacity_1pct_responses_qps"] / baseline["capacity_1pct_responses_qps"]
            if baseline["capacity_1pct_responses_qps"]
            else 0.0
        )
        summary["reported_max_ratio_vs_nohook"] = (
            summary["reported_max_qps"] / baseline["reported_max_qps"]
            if baseline["reported_max_qps"]
            else 0.0
        )
    return summaries


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fields = sorted({key for row in rows for key in row})
    with path.open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def write_markdown(path: Path, summaries: list[dict[str, Any]]) -> None:
    lines = [
        "# resperf capacity summary",
        "",
        "Medians across repeated linear ramps. The 1% capacity follows resperf `-L 1` semantics: the highest response rate before the first 0.5-second interval above 1% loss.",
        "",
        "| Mode | 1% capacity QPS | vs nohook | loss at point | avg latency us | unconstrained max QPS | loss at max | backend bypass | limiter |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for row in summaries:
        if row["client_limited_runs"] == row["runs"]:
            limiter = "client (lower bound)"
        elif row["outstanding_limited_runs"] == row["runs"]:
            limiter = "65,536 outstanding"
        else:
            limiter = "mixed/server"
        lines.append(
            f"| {row['mode']} | {row['capacity_1pct_responses_qps']:,.0f} | "
            f"{row['capacity_1pct_ratio_vs_nohook']:.3f}x | "
            f"{row['capacity_1pct_loss_pct']:.3f}% | "
            f"{row['capacity_1pct_avg_latency_us']:.1f} | "
            f"{row['reported_max_qps']:,.0f} | {row['reported_loss_at_max_pct']:.2f}% | "
            f"{row['backend_bypass_pct']:.2f}% | {limiter} |"
        )
    lines.extend(
        [
            "",
            "The unconstrained maximum is resperf's default `-L 100` statistic and may occur after unacceptable loss. A client-limited 1% result is a demonstrated lower bound, not the server's true ceiling.",
            "",
        ]
    )
    path.write_text("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("resperf_root", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    rows = load_run(args.resperf_root)
    summaries = aggregate(rows)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    write_csv(args.output_dir / "runs.csv", rows)
    write_csv(args.output_dir / "summary.csv", summaries)
    (args.output_dir / "summary.json").write_text(
        json.dumps({"runs": rows, "summary": summaries}, indent=2, sort_keys=True) + "\n"
    )
    write_markdown(args.output_dir / "summary.md", summaries)
    print(args.output_dir / "summary.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
