#!/usr/bin/env python3
"""Analyze isolated OpenStack hot-cache and non-cacheable DNS paths."""

import argparse
import csv
import json
import statistics
import sys
from pathlib import Path


TOOLS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS_DIR))
from analyze_openstack_dns_bench import parse_case  # noqa: E402


MODES = ("no_hook", "tap_xdp")
CATEGORIES = ("hot_cache", "aaaa", "https", "nxdomain", "cname", "noncache_mixed")
METRICS = (
    "average_latency_s",
    "p50_latency_us",
    "p95_latency_us",
    "p99_latency_us",
    "p999_latency_us",
    "backend_queries",
    "xdp_cache_hit",
    "xdp_cache_miss",
    "xdp_cache_tx",
    "xdp_cache_learned",
    "xdp_learn_rejected",
    "geneve_packets",
    "tap_drop_errors",
    "softnet_drops",
    "node1_cycles",
    "node2_cycles",
)


def load_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def median(rows, key):
    values = []
    for row in rows:
        value = row.get(key)
        if isinstance(value, (int, float)):
            values.append(float(value))
    return statistics.median(values) if values else None


def us(row, key):
    value = median(row, key)
    if value is None:
        return None
    if key == "average_latency_s":
        return value * 1_000_000
    return value


def fmt(value, digits=1):
    return "—" if value is None else f"{value:.{digits}f}"


def ratio(numerator, denominator):
    if numerator is None or denominator in (None, 0):
        return None
    return numerator / denominator


def write_csv(path, rows):
    columns = [
        "category",
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
        "xdp_cache_hit",
        "xdp_cache_miss",
        "xdp_cache_tx",
        "xdp_cache_learned",
        "xdp_learn_rejected",
        "xdp_unsupported",
        "xdp_egress_no_pending",
        "geneve_packets",
        "tap_drop_errors",
        "softnet_drops",
        "node1_cycles",
        "node2_cycles",
        "gate_pass",
    ]
    with Path(path).open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact_dir")
    args = parser.parse_args()
    root = Path(args.artifact_dir)
    rows = []
    for case_dir in sorted((root / "cases").iterdir()):
        if not (case_dir / "metadata.json").is_file():
            continue
        row = parse_case(case_dir)
        if row.get("category") in CATEGORIES and row.get("mode") in MODES:
            rows.append(row)
    write_csv(root / "results.csv", rows)

    grouped = {}
    for category in CATEGORIES:
        grouped[category] = {}
        for mode in MODES:
            grouped[category][mode] = [
                row
                for row in rows
                if row.get("category") == category and row.get("mode") == mode
            ]

    summary = {"categories": {}, "cases": len(rows)}
    table = []
    for category in CATEGORIES:
        no_hook = grouped[category]["no_hook"]
        tap_xdp = grouped[category]["tap_xdp"]
        no_p95 = us(no_hook, "p95_latency_us")
        xdp_p95 = us(tap_xdp, "p95_latency_us")
        no_p99 = us(no_hook, "p99_latency_us")
        xdp_p99 = us(tap_xdp, "p99_latency_us")
        no_backend = median(no_hook, "backend_queries")
        xdp_backend = median(tap_xdp, "backend_queries")
        xdp_tx = median(tap_xdp, "xdp_cache_tx")
        completed = median(tap_xdp, "completed")
        item = {
            "runs": {mode: len(grouped[category][mode]) for mode in MODES},
            "no_hook": {
                "avg_us": us(no_hook, "average_latency_s"),
                "p50_us": us(no_hook, "p50_latency_us"),
                "p95_us": no_p95,
                "p99_us": no_p99,
                "backend_queries": no_backend,
            },
            "tap_xdp": {
                "avg_us": us(tap_xdp, "average_latency_s"),
                "p50_us": us(tap_xdp, "p50_latency_us"),
                "p95_us": xdp_p95,
                "p99_us": xdp_p99,
                "backend_queries": xdp_backend,
                "xdp_cache_hit": median(tap_xdp, "xdp_cache_hit"),
                "xdp_cache_tx": xdp_tx,
                "xdp_learn_rejected": median(tap_xdp, "xdp_learn_rejected"),
            },
            "p95_ratio_no_hook_over_xdp": ratio(no_p95, xdp_p95),
            "p99_ratio_no_hook_over_xdp": ratio(no_p99, xdp_p99),
            "p95_extra_us_xdp_minus_no_hook": None
            if no_p95 is None or xdp_p95 is None
            else xdp_p95 - no_p95,
            "p99_extra_us_xdp_minus_no_hook": None
            if no_p99 is None or xdp_p99 is None
            else xdp_p99 - no_p99,
            "backend_offload_percent": None
            if no_backend in (None, 0) or xdp_backend is None
            else 100 * (1 - xdp_backend / no_backend),
            "xdp_hit_share_percent": None
            if xdp_tx is None or completed in (None, 0)
            else 100 * xdp_tx / completed,
        }
        summary["categories"][category] = item
        table.append((category, item))

    (root / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    lines = [
        "# OpenStack DNS path-split benchmark",
        "",
        "This is a paired cross-host OpenStack VM experiment using isolated deterministic corpora.",
        "The hot corpus is warmed before every measured run. AAAA and the narrow single-answer HTTPS corpus are cache-eligible; NXDOMAIN, CNAME and truncated/other traffic are expected to fail open.",
        "",
        "## Median results",
        "",
        "`ratio = no_hook / tap_xdp`; below 1.00x means the XDP path is slower.",
        "",
        "| corpus | no-hook p50 | XDP p50 | no-hook p95 | XDP p95 | p95 ratio | no-hook p99 | XDP p99 | p99 ratio | XDP backend | XDP TX |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for category, item in table:
        no_hook = item["no_hook"]
        tap_xdp = item["tap_xdp"]
        lines.append(
            "| {category} | {np50} | {xp50} | {np95} | {xp95} | {r95}x | {np99} | {xp99} | {r99}x | {backend} | {tx} |".format(
                category=category,
                np50=fmt(no_hook["p50_us"]),
                xp50=fmt(tap_xdp["p50_us"]),
                np95=fmt(no_hook["p95_us"]),
                xp95=fmt(tap_xdp["p95_us"]),
                r95=fmt(item["p95_ratio_no_hook_over_xdp"], 2),
                np99=fmt(no_hook["p99_us"]),
                xp99=fmt(tap_xdp["p99_us"]),
                r99=fmt(item["p99_ratio_no_hook_over_xdp"], 2),
                backend=fmt(tap_xdp["backend_queries"], 0),
                tx=fmt(tap_xdp["xdp_cache_tx"], 0),
            )
        )

    lines.extend(
        [
            "",
            "## Interpretation fields",
            "",
            "| corpus | p95 XDP extra | p99 XDP extra | backend offload | XDP hit share | XDP learn rejected |",
            "| --- | ---: | ---: | ---: | ---: | ---: |",
        ]
    )
    for category, item in table:
        lines.append(
            "| {category} | {p95} µs | {p99} µs | {offload}% | {hit}% | {reject} |".format(
                category=category,
                p95=fmt(item["p95_extra_us_xdp_minus_no_hook"]),
                p99=fmt(item["p99_extra_us_xdp_minus_no_hook"]),
                offload=fmt(item["backend_offload_percent"]),
                hit=fmt(item["xdp_hit_share_percent"]),
                reject=fmt(item["tap_xdp"]["xdp_learn_rejected"], 0),
            )
        )

    lines.extend(
        [
            "",
            "## Repetition values",
            "",
            "The raw per-run rows are in `results.csv`; before/after host and backend snapshots remain under `cases/`.",
            "",
        ]
    )
    for category in CATEGORIES:
        lines.append(f"### {category}")
        lines.append("")
        lines.append("| repetition | mode | p50 us | p95 us | p99 us | backend | XDP TX | completion |")
        lines.append("| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |")
        for row in sorted(grouped[category]["no_hook"] + grouped[category]["tap_xdp"], key=lambda value: (int(value.get("repetition", 0)), value.get("mode", ""))):
            lines.append(
                "| {rep} | {mode} | {p50} | {p95} | {p99} | {backend} | {tx} | {completion}% |".format(
                    rep=row.get("repetition", "—"),
                    mode=row.get("mode", "—"),
                    p50=fmt(row.get("p50_latency_us")),
                    p95=fmt(row.get("p95_latency_us")),
                    p99=fmt(row.get("p99_latency_us")),
                    backend=fmt(row.get("backend_queries"), 0),
                    tx=fmt(row.get("xdp_cache_tx"), 0),
                    completion=fmt(row.get("completion_percent"), 3),
                )
            )
        lines.append("")

    report = "\n".join(lines)
    (root / "summary.md").write_text(report, encoding="utf-8")
    print(report)


if __name__ == "__main__":
    main()
