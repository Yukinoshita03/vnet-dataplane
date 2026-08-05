#!/usr/bin/env python3
"""Parse dnsperf 2.x summary and latency histogram into JSON."""

import argparse
import json
import math
import re
from pathlib import Path


FIELD_PATTERNS = {
    "sent": re.compile(r"^\s*Queries sent:\s+(\d+)", re.MULTILINE),
    "completed": re.compile(r"^\s*Queries completed:\s+(\d+)", re.MULTILINE),
    "lost": re.compile(r"^\s*Queries lost:\s+(\d+)", re.MULTILINE),
    "run_time_s": re.compile(r"^\s*Run time \(s\):\s+([0-9.]+)", re.MULTILINE),
    "completed_qps": re.compile(
        r"^\s*Queries per second:\s+([0-9.]+)", re.MULTILINE
    ),
    "average_latency_s": re.compile(
        r"^\s*Average Latency \(s\):\s+([0-9.]+)", re.MULTILINE
    ),
    "minimum_latency_s": re.compile(
        r"^\s*Average Latency \(s\):.*\(min\s+([0-9.]+)", re.MULTILINE
    ),
    "maximum_latency_s": re.compile(
        r"^\s*Average Latency \(s\):.*max\s+([0-9.]+)\)", re.MULTILINE
    ),
    "latency_stddev_s": re.compile(
        r"^\s*Latency StdDev \(s\):\s+([0-9.]+)", re.MULTILINE
    ),
}
HISTOGRAM = re.compile(
    r"^\s*([0-9.]+)\s+-\s+([0-9.]+):\s+(\d+)\s*$", re.MULTILINE
)
INTERVAL = re.compile(r"^(\d{10}\.[0-9]+):\s+([0-9.]+)\s*$", re.MULTILINE)
RESPONSE_CODES = re.compile(r"^\s*Response codes:\s+(.+)$", re.MULTILINE)


def percentile(buckets, fraction):
    total = sum(count for _, count in buckets)
    if total <= 0:
        return None
    threshold = math.ceil(total * fraction)
    cumulative = 0
    for upper, count in buckets:
        cumulative += count
        if cumulative >= threshold:
            return upper
    return buckets[-1][0]


def parse(path):
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    values = {}
    integer_fields = {"sent", "completed", "lost"}
    for name, pattern in FIELD_PATTERNS.items():
        match = pattern.search(text)
        if match:
            values[name] = int(match.group(1)) if name in integer_fields else float(match.group(1))

    if "sent" not in values or "completed" not in values or "run_time_s" not in values:
        raise ValueError(f"dnsperf summary is missing from {path}")
    values["completion_percent"] = (
        100.0 * values["completed"] / values["sent"] if values["sent"] else 0.0
    )
    values["sent_qps"] = values["sent"] / values["run_time_s"]

    buckets = [(float(match.group(2)), int(match.group(3))) for match in HISTOGRAM.finditer(text)]
    values["histogram_answers"] = sum(count for _, count in buckets)
    for label, fraction in (("p50", 0.50), ("p95", 0.95), ("p99", 0.99), ("p999", 0.999)):
        seconds = percentile(buckets, fraction)
        values[f"{label}_latency_s"] = seconds
        values[f"{label}_latency_us"] = seconds * 1_000_000 if seconds is not None else None

    intervals = [float(match.group(2)) for match in INTERVAL.finditer(text)]
    values["interval_qps"] = intervals
    if intervals:
        values["interval_qps_min"] = min(intervals)
        values["interval_qps_max"] = max(intervals)

    response_match = RESPONSE_CODES.search(text)
    response_codes = {}
    if response_match:
        for code, count in re.findall(r"([A-Z0-9]+)\s+(\d+)", response_match.group(1)):
            response_codes[code] = int(count)
    values["response_codes"] = response_codes
    return values


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("log")
    args = parser.parse_args()
    print(json.dumps(parse(args.log), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
