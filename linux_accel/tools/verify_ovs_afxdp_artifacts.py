#!/usr/bin/env python3
"""Verify the isolated OVS system/AF_XDP/linux_accel UDP comparison.

This audit deliberately checks the raw run directory rather than the prose
report.  It is intended to catch a partial run, a client-side failure, an
unexpected XDP path, or a polluted host before the medians are quoted.
"""

from __future__ import annotations

import argparse
import math
import re
import sys
from pathlib import Path


MODES = ("nohook", "afxdp", "linux-accel")
EXPECTED_MEDIANS = {
    "nohook": (76250.3, 40.441, 77.567, 90.112),
    "afxdp": (315018.0, 12.239, 14.238, 16.212),
    "linux-accel": (2571010.0, 1.495, 1.512, 1.528),
}


class Audit:
    def __init__(self) -> None:
        self.checks = 0
        self.errors: list[str] = []

    def require(self, condition: bool, message: str) -> None:
        self.checks += 1
        if not condition:
            self.errors.append(message)

    def finish(self) -> int:
        if self.errors:
            print(f"FAIL: {len(self.errors)} of {self.checks} checks failed")
            for error in self.errors:
                print(f"  - {error}")
            return 1
        print(f"PASS: {self.checks} OVS/AF_XDP comparison checks")
        return 0


def parse_args() -> argparse.Namespace:
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "artifact_dir",
        nargs="?",
        type=Path,
        default=repo
        / "artifacts/paper-competitors/20260815-node1-v1/ovs-afxdp-linux-accel",
    )
    return parser.parse_args()


def text(path: Path, audit: Audit) -> str:
    audit.require(path.is_file(), f"missing artifact: {path}")
    if not path.is_file():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def number(value: str) -> float:
    return float(value)


def close(actual: float, expected: float) -> bool:
    return math.isclose(actual, expected, rel_tol=1e-5, abs_tol=1e-3)


def softnet_drops(value: str) -> int:
    total = 0
    for line in value.splitlines():
        fields = line.split()
        if len(fields) >= 2:
            total += int(fields[1], 16)
    return total


def check_metadata(root: Path, audit: Audit) -> None:
    metadata = text(root / "metadata.txt", audit)
    for key, expected in {
        "hostname": "node1",
        "kernel": "7.0.0-14-generic",
        "ovs": '"3.7.1"',
        "repetitions": "5",
        "threads": "4",
        "requests": "25000",
        "warmup": "1000",
        "topology": "isolated-netns-veth-to-ovs-userspace-netdev",
        "kubernetes": "required-inactive",
        "linux_accel_mode": "1",
    }.items():
        audit.require(f"{key}={expected}" in metadata, f"metadata mismatch: {key}")


def check_medians(root: Path, audit: Audit) -> None:
    medians = text(root / "medians.txt", audit)
    seen: dict[str, tuple[float, float, float, float]] = {}
    pattern = re.compile(
        r"^(?P<mode>\S+) qps=(?P<qps>\S+) p50_us=(?P<p50>\S+) "
        r"p95_us=(?P<p95>\S+) p99_us=(?P<p99>\S+)$"
    )
    for line in medians.splitlines():
        match = pattern.match(line.strip())
        if match:
            seen[match.group("mode")] = tuple(
                number(match.group(field)) for field in ("qps", "p50", "p95", "p99")
            )  # type: ignore[assignment]
    audit.require(set(seen) == set(MODES), "median mode set changed")
    for mode, expected in EXPECTED_MEDIANS.items():
        actual = seen.get(mode)
        if actual is None:
            continue
        for field, value, target in zip(("qps", "p50", "p95", "p99"), actual, expected):
            audit.require(close(value, target), f"{mode} median {field} changed")


def check_run(root: Path, mode: str, audit: Audit) -> None:
    mode_root = root / mode
    for repetition in range(1, 6):
        log = text(mode_root / f"rep-{repetition}.log", audit)
        match = re.search(
            r"completed=(?P<completed>\d+) failed=(?P<failed>\d+) "
            r"qps=(?P<qps>\S+) avg_us=(?P<avg>\S+) "
            r"p50_us=(?P<p50>\S+) p95_us=(?P<p95>\S+) p99_us=(?P<p99>\S+)",
            log,
        )
        audit.require(match is not None, f"{mode} repetition {repetition} has no result")
        if match is None:
            continue
        audit.require(
            int(match.group("completed")) == 100000,
            f"{mode} repetition {repetition} completed count changed",
        )
        audit.require(
            int(match.group("failed")) == 0,
            f"{mode} repetition {repetition} has failed requests",
        )
        for field in ("qps", "avg", "p50", "p95", "p99"):
            audit.require(
                number(match.group(field)) >= 0,
                f"{mode} repetition {repetition} invalid {field}",
            )

        before = text(mode_root / f"softnet-before-{repetition}.txt", audit)
        after = text(mode_root / f"softnet-after-{repetition}.txt", audit)
        audit.require(
            softnet_drops(after) - softnet_drops(before) == 0,
            f"{mode} repetition {repetition} has softnet drops",
        )

    interface_type = text(mode_root / "client-interface-type.txt", audit)
    expected_type = "afxdp" if mode == "afxdp" else "system"
    audit.require(
        expected_type in interface_type,
        f"{mode} OVS interface type is not {expected_type}",
    )

    if mode in ("nohook", "afxdp", "linux-accel"):
        pmd = text(mode_root / "pmd-stats-3.txt", audit)
        audit.require(
            "miss with failed upcall: 0" in pmd,
            f"{mode} has an OVS failed upcall",
        )


def check_linux_accel(root: Path, audit: Audit) -> None:
    mode_root = root / "linux-accel"
    loader = text(mode_root / "loader.log", audit)
    audit.require("mode=generic" in loader, "linux_accel was not generic XDP")
    audit.require(
        re.search(
            r"request=520000 hit=520000 miss=0 expired=0 unsupported=0 "
            r"malformed=0 tx=520000 adjust_fail=0",
            loader,
        )
        is not None,
        "linux_accel loader counters are not an all-hit/all-TX run",
    )
    attachment = text(mode_root / "attachment.txt", audit)
    audit.require("generic id " in attachment, "linux_accel XDP attachment is not generic")
    server = text(mode_root / "server.log", audit)
    audit.require("requests=0" in server, "linux_accel did not bypass the UDP server")


def check_health(root: Path, audit: Audit) -> None:
    health = root / "health"
    bridges_before = text(health / "bridges-before.txt", audit)
    bridges_after = text(health / "bridges-after.txt", audit)
    audit.require(bridges_before == bridges_after, "OVS bridge set changed during run")
    ovs_before = text(health / "ovs-before.txt", audit)
    ovs_after = text(health / "ovs-after.txt", audit)
    audit.require(ovs_before == ovs_after, "OVSDB state changed after cleanup")
    kubernetes_before = text(health / "kubernetes-before.txt", audit)
    kubernetes_after = text(health / "kubernetes-after.txt", audit)
    audit.require(kubernetes_before == kubernetes_after, "Kubernetes service state changed")
    audit.require("=active" not in kubernetes_after, "Kubernetes was active during run")
    bpftool_after = text(health / "bpftool-after.txt", audit)
    audit.require("oac-" not in bpftool_after, "temporary client XDP remained attached")
    audit.require("oab-" not in bpftool_after, "temporary backend XDP remained attached")


def main() -> int:
    args = parse_args()
    root = args.artifact_dir.resolve()
    audit = Audit()
    audit.require(root.is_dir(), f"missing artifact directory: {root}")
    if not root.is_dir():
        return audit.finish()
    check_metadata(root, audit)
    check_medians(root, audit)
    for mode in MODES:
        check_run(root, mode, audit)
    check_linux_accel(root, audit)
    check_health(root, audit)
    return audit.finish()


if __name__ == "__main__":
    sys.exit(main())
