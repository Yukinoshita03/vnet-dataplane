#!/usr/bin/env python3
"""Audit the reproducibility evidence for the 2026-08-14 comparison batch.

The script intentionally validates source artifacts instead of the prose report.
It checks pinned inputs, exact release hashes, formal repetition counts, error/drop
fields, traffic marginals, the v2 correctness gate, and the final cluster snapshot.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import sys
from pathlib import Path


BATCH = "20260814-node1-v1"
BMC_COMMIT = "2997145508e02c55aa92f63a0009ac2a26800810"

EXPECTED_HASHES = {
    "sources/bmc-cache-2997145508e0.bundle": (
        "0c8e85ff5da691fdb1ed21445102072dac9cef066b0cb2c01f0d0db5ea219076"
    ),
    "packages/all-comparisons-20260814-node2-results.tar.gz": (
        "1029179fafc5e8638df93216ad2c49bdff91a891195b86a98ae6283975c69555"
    ),
    "packages/bmc-target-32x96-v1.tar.gz": (
        "4f4f98798e15b5a83ad49b6696d2df5ebce44277fdefc74450b1e29c378fc8f0"
    ),
    "packages/correctness-v2-final.tar.gz": (
        "2c03b4daaccc32b83791938d09042ea1d740d0a44f944c1298ee5d29d1c779df"
    ),
    "packages/linux-accel-all-comparisons-20260814-v2.tar.gz": (
        "277e2a5e1ea99adc4868e0b09aef072acab3800cd9e269a4d5f733a14fc2dc9a"
    ),
    "packages/linux-accel-source-20260814-node1-v1.tar.gz": (
        "6e1ead5af3a3b7e5f0c2124e5557ab68b3e3baab4f5878304ac3955728efb1cb"
    ),
    "packages/openstack-dns-runtime-v1.tar.gz": (
        "7465a125c9184a53d6602adb5d4c3dafb94663342ce66d2caf2adaff079ec130"
    ),
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
        print(f"PASS: {self.checks} reproducibility checks")
        return 0


def parse_args() -> argparse.Namespace:
    repo_default = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=repo_default)
    parser.add_argument(
        "--artifacts",
        type=Path,
        default=repo_default / "artifacts" / "all-comparisons" / BATCH,
    )
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_csv(path: Path, audit: Audit) -> list[dict[str, str]]:
    audit.require(path.is_file(), f"missing CSV: {path}")
    if not path.is_file():
        return []
    with path.open(newline="", encoding="utf-8") as stream:
        return list(csv.DictReader(stream))


def read_json(path: Path, audit: Audit):
    audit.require(path.is_file(), f"missing JSON: {path}")
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def rows_by(
    rows: list[dict[str, str]], *keys: str
) -> dict[tuple[str, ...], dict[str, str]]:
    return {tuple(row[key] for key in keys): row for row in rows}


def number(row: dict[str, str], key: str) -> float:
    return float(row[key])


def close(actual: float, expected: float, tolerance: float = 1e-3) -> bool:
    return math.isclose(actual, expected, rel_tol=tolerance, abs_tol=tolerance)


def check_hashes(root: Path, repo: Path, audit: Audit) -> None:
    for relative, expected in EXPECTED_HASHES.items():
        path = root / relative
        audit.require(path.is_file(), f"missing pinned artifact: {relative}")
        if path.is_file():
            audit.require(sha256(path) == expected, f"SHA-256 mismatch: {relative}")

    patch = repo / "patches/competitors/0001-bmc-linux7-libbpf16-tap-compat.patch"
    audit.require(patch.is_file(), "missing audited BMC compatibility patch")
    if patch.is_file():
        audit.require(
            sha256(patch)
            == "2f98ade68f9253b960d2abb82f07857d5a206a5cc4102f5135168dce5fdd4a77",
            "BMC compatibility patch SHA-256 mismatch",
        )


def check_bmc(root: Path, audit: Audit) -> None:
    path = root / "node2-results/analysis-netns-bmc-formal-v2/summary.csv"
    rows = read_csv(path, audit)
    indexed = rows_by(rows, "profile", "mode") if rows else {}
    expected = {
        ("BMC-PAPER-TARGET-scaled-4to1-keyspace", "nohook"): 577170.0,
        ("BMC-PAPER-TARGET-scaled-4to1-keyspace", "bmc"): 970340.0,
        ("BMC-PAPER-TARGET-scaled-4to1-keyspace", "linux-accel"): 1197340.0,
        ("same-nominal-slot-pressure", "nohook"): 572858.0,
        ("same-nominal-slot-pressure", "bmc"): 827996.5,
        ("same-nominal-slot-pressure", "linux-accel"): 1004330.5,
        ("all-hot-hit-control", "nohook"): 580581.0,
        ("all-hot-hit-control", "bmc"): 1712655.0,
        ("all-hot-hit-control", "linux-accel"): 1767370.0,
        ("all-backend-miss-control", "nohook"): 600544.5,
        ("all-backend-miss-control", "bmc"): 582471.5,
        ("all-backend-miss-control", "linux-accel"): 586094.5,
        ("FB-ETC-COARSE-LOCALITY-exact-scale", "nohook"): 578058.5,
        ("FB-ETC-COARSE-LOCALITY-exact-scale", "bmc"): 590502.5,
        ("FB-ETC-COARSE-LOCALITY-exact-scale", "linux-accel"): 598007.0,
    }
    audit.require(set(indexed) == set(expected), "netns BMC profile/mode matrix differs")
    for key, qps in expected.items():
        row = indexed.get(key)
        if row is None:
            continue
        audit.require(number(row, "runs") == 6, f"netns BMC {key} is not six runs")
        audit.require(close(number(row, "qps"), qps), f"netns BMC {key} QPS changed")
        for field in (
            "failed_total",
            "snmp_Udp_InErrors_delta",
            "snmp_Udp_RcvbufErrors_delta",
            "snmp_Udp_SndbufErrors_delta",
            "softnet_dropped_delta",
            "softnet_time_squeeze_delta",
        ):
            audit.require(number(row, field) == 0, f"netns BMC {key} nonzero {field}")
        for field in ("p50_us", "p95_us", "p99_us", "context_switches_per_request"):
            audit.require(number(row, field) >= 0, f"netns BMC {key} missing {field}")

    raw = read_json(
        root / "node2-results/analysis-netns-bmc-formal-v2/summary.json", audit
    )
    metadata = raw.get("metadata", {}) if isinstance(raw, dict) else {}
    audit.require(bool(metadata), "netns BMC metadata is empty")
    for item in metadata.values():
        competitor = str(item.get("competitor", ""))
        audit.require(BMC_COMMIT in competitor, "netns BMC metadata is not pinned")
        audit.require(
            item.get("mode_order") == "balanced-six-permutation-cycle",
            "netns BMC mode order is not balanced",
        )


def check_openstack_bmc(root: Path, audit: Audit) -> None:
    rows = read_csv(root / "openstack-bmc-formal-v1/analysis/summary.csv", audit)
    indexed = rows_by(rows, "mode") if rows else {}
    expected = {"nohook": 23288.0, "bmc": 51546.95, "linux-accel": 68078.0}
    audit.require(set(key[0] for key in indexed) == set(expected), "OpenStack BMC modes differ")
    for mode, qps in expected.items():
        row = indexed.get((mode,))
        if row is None:
            continue
        audit.require(number(row, "runs") == 6, f"OpenStack BMC {mode} is not six runs")
        audit.require(close(number(row, "qps"), qps), f"OpenStack BMC {mode} QPS changed")
        for field in (
            "failed_total",
            "snmp_Udp_InErrors_delta",
            "snmp_Udp_RcvbufErrors_delta",
            "snmp_Udp_SndbufErrors_delta",
            "softnet_dropped_delta",
            "softnet_time_squeeze_delta",
        ):
            audit.require(number(row, field) == 0, f"OpenStack BMC {mode} nonzero {field}")
        for field in ("p50_us", "p95_us", "p99_us", "backend_offload_pct"):
            audit.require(number(row, field) >= 0, f"OpenStack BMC {mode} missing {field}")

    raw = read_json(root / "openstack-bmc-formal-v1/analysis/summary.json", audit)
    metadata = next(iter(raw.get("metadata", {}).values()), {})
    audit.require(BMC_COMMIT in str(metadata.get("competitor", "")), "OpenStack BMC is not pinned")
    audit.require(
        metadata.get("topology")
        == "client VM -> client TAP generic XDP -> OVS/OVN/Geneve -> backend VM Memcached",
        "OpenStack BMC topology metadata changed",
    )


def check_dns(root: Path, audit: Audit) -> None:
    path = root / "node2-results/analysis-netns-dnsperf-formal-v1/summary.csv"
    rows = read_csv(path, audit)
    indexed = rows_by(rows, "rate", "mode") if rows else {}
    expected_qps = {
        ("20000", "nohook"): 19999.968,
        ("20000", "xpress"): 19999.964,
        ("20000", "linux-accel"): 19999.972,
        ("100000", "nohook"): 99998.950004,
        ("100000", "xpress"): 99998.9166695,
        ("100000", "linux-accel"): 99998.800004,
        ("250000", "nohook"): 146694.2625655,
        ("250000", "xpress"): 230236.2391855,
        ("250000", "linux-accel"): 246918.551422,
        ("500000", "nohook"): 146647.716262,
        ("500000", "xpress"): 233075.7981555,
        ("500000", "linux-accel"): 297475.092912,
        ("650000", "nohook"): 147327.390027,
        ("650000", "xpress"): 217850.3271495,
        ("650000", "linux-accel"): 297823.7104785,
    }
    audit.require(set(indexed) == set(expected_qps), "dnsperf rate/mode matrix differs")
    for key, qps in expected_qps.items():
        row = indexed.get(key)
        if row is None:
            continue
        audit.require(number(row, "runs") == 6, f"dnsperf {key} is not six runs")
        audit.require(close(number(row, "qps_received"), qps), f"dnsperf {key} QPS changed")
        for field in (
            "snmp_Udp_InErrors_delta",
            "snmp_Udp_RcvbufErrors_delta",
            "snmp_Udp_SndbufErrors_delta",
            "softnet_dropped_delta",
            "softnet_time_squeeze_delta",
        ):
            audit.require(number(row, field) == 0, f"dnsperf {key} nonzero {field}")
        for field in ("p50_us", "p95_us", "p99_us", "loss_pct"):
            audit.require(number(row, field) >= 0, f"dnsperf {key} missing {field}")

    resperf = read_csv(
        root / "node2-results/analysis-netns-resperf-formal-v1/summary.csv", audit
    )
    capacities = {row["mode"]: number(row, "capacity_1pct_actual_qps") for row in resperf}
    audit.require(
        capacities == {"nohook": 140834.0, "xpress": 227500.0, "linux-accel": 268344.0},
        "resperf 1% loss capacities changed",
    )
    for row in resperf:
        audit.require(number(row, "runs") == 3, f"resperf {row['mode']} is not three runs")

    openstack = read_csv(root / "analysis-openstack-dns-formal-20k-v1/summary.csv", audit)
    os_index = rows_by(openstack, "mode") if openstack else {}
    expected = {
        "nohook": (19999.806002, 81.0, 105.0, 229.0, 0.0),
        "xpress": (19999.834001, 76.0, 103.0, 195.0, 35.342),
        "linux-accel": (19999.846001, 72.0, 99.0, 183.0, 48.92),
    }
    audit.require(set(key[0] for key in os_index) == set(expected), "OpenStack DNS modes differ")
    for mode, values in expected.items():
        row = os_index.get((mode,))
        if row is None:
            continue
        for field, value in zip(
            ("completed_qps", "p50_us", "p95_us", "p99_us", "backend_offload_percent"),
            values,
        ):
            audit.require(close(number(row, field), value), f"OpenStack DNS {mode} {field} changed")
        audit.require(number(row, "runs") == 6, f"OpenStack DNS {mode} is not six runs")
        audit.require(number(row, "completion_percent") == 100, f"OpenStack DNS {mode} lost requests")


def check_protocols(root: Path, audit: Audit) -> None:
    for relative, expected_modes in (
        (
            "analysis-netns-udp-formal-v1/summary.csv",
            {"userspace": (292277.5, 33.145), "generic-xdp": (3295770.0, 4.8535)},
        ),
        (
            "analysis-netns-grpc-formal-v2/summary.csv",
            {
                "direct-backend": (1777.115, 682.59),
                "cache-hit-serving": (22471.36, 56.74),
                "cache-hit-not-serving": (22489.845, 57.46),
                "response-cache-miss": (1507.83, 801.09),
                "policy-miss": (1482.365, 823.26),
            },
        ),
    ):
        rows = read_csv(root / relative, audit)
        indexed = {row["mode"]: row for row in rows}
        audit.require(set(indexed) == set(expected_modes), f"{relative} modes differ")
        for mode, (qps, p99) in expected_modes.items():
            row = indexed.get(mode)
            if row is None:
                continue
            audit.require(number(row, "runs") == 6, f"{relative} {mode} is not six runs")
            audit.require(number(row, "failed") == 0, f"{relative} {mode} has failures")
            audit.require(close(number(row, "qps"), qps), f"{relative} {mode} QPS changed")
            audit.require(close(number(row, "p99_us"), p99), f"{relative} {mode} p99 changed")

    markdown_expectations = {
        "node2-results/netns-arp-formal-v1/summary.md": (
            "718032.763",
            "QPS speedup: 1.840x",
        ),
        "openstack-udp-formal-v1/summary.md": (
            "generic XDP exact hit on client TAP | 342951",
            "Miss-path QPS ratio (XDP/nohook): 1.013x",
        ),
        "ldap-cluster-formal-v2/summary.md": (
            "sockmap | 16513.200000",
            "| 0.882x | 0.877x | 0.02 |",
        ),
    }
    for relative, needles in markdown_expectations.items():
        path = root / relative
        audit.require(path.is_file(), f"missing protocol summary: {relative}")
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        for needle in needles:
            audit.require(needle in text, f"{relative} missing expected value: {needle}")


def check_traffic(root: Path, repo: Path, audit: Audit) -> None:
    manifest = read_json(root / "corpora/radar-observed-v1/corpus-manifest.json", audit)
    audit.require(manifest.get("profile") == "radar-nl-observed", "DNS corpus profile changed")
    audit.require(manifest.get("lines") == 50000, "DNS corpus line count changed")
    audit.require(
        manifest.get("qtype_counts")
        == {"A": 28300, "AAAA": 15150, "HTTPS": 3150, "NS": 350, "Other": 1250, "PTR": 1800},
        "DNS QTYPE marginals changed",
    )
    audit.require(
        manifest.get("resolver_cache_counts") == {"hit": 39250, "miss": 10750},
        "DNS cache-status marginals changed",
    )
    audit.require(
        manifest.get("source_url") == "https://radar.cloudflare.com/dns/nl",
        "DNS corpus source URL changed",
    )

    sources = repo / "docs/competitor-traffic-profile-sources-2026-08.md"
    audit.require(sources.is_file(), "missing traffic-source audit")
    if sources.is_file():
        text = sources.read_text(encoding="utf-8")
        for needle in (
            "https://www.usenix.org/system/files/nsdi21-ghigoff.pdf",
            "http://frachtenberg.org/eitan/pubs/papers/atikoglu12%3Aworkload.pdf",
            "A 56.6%、AAAA 30.3%、HTTPS 6.3%",
            "hit 78.5%、miss 21.5%",
            "Zipf exponent/skewness `0.99`",
        ):
            audit.require(needle in text, f"traffic-source audit missing: {needle}")


def check_correctness_and_recovery(root: Path, repo: Path, audit: Audit) -> None:
    correctness = root / "node2-results/correctness-v2-final"
    result = correctness / "RESULT.txt"
    audit.require(result.is_file(), "missing v2 correctness result")
    if result.is_file():
        text = result.read_text(encoding="utf-8")
        audit.require("correctness_gate=PASS" in text, "v2 correctness gate did not pass")
        audit.require(
            "linux-accel-all-comparisons-20260814-v2" in text,
            "correctness gate was not run against v2",
        )
    for name in (
        "run_dns_xdp_prog_test",
        "run_udp_fastpath_test",
        "run_arp_proxy_xdp_prog_test",
        "run_arp_proxy_veth_test",
        "run_dhcp_relay_control_test",
        "run_dhcp_relay_xdp_test",
        "run_ldap_sockmap_test",
        "run_xdp_dispatcher_test",
        "run_xdp_action_probe_test",
        "run_xdp_action_probe_veth_test",
    ):
        log = correctness / f"{name}.log"
        audit.require(log.is_file(), f"missing v2 correctness log: {name}")
        if log.is_file():
            audit.require(f"PASS {name}" in log.read_text(encoding="utf-8"), f"{name} did not pass")

    before = correctness / "kubernetes-before.txt"
    after = correctness / "kubernetes-after.txt"
    audit.require(before.is_file() and after.is_file(), "missing v2 K8s guard snapshots")
    if before.is_file() and after.is_file():
        audit.require(before.read_bytes() == after.read_bytes(), "K8s state changed during v2 gate")
        audit.require("=active" not in after.read_text(encoding="utf-8"), "K8s became active")
    bpf_after = correctness / "bpf-after.txt"
    netns_after = correctness / "netns-after.txt"
    audit.require(bpf_after.is_file(), "missing v2 post-gate BPF snapshot")
    audit.require(netns_after.is_file(), "missing v2 post-gate netns snapshot")
    if bpf_after.is_file():
        audit.require(
            not any(token in bpf_after.read_text(encoding="utf-8") for token in ("generic id", "native id", "offload id")),
            "v2 gate left an XDP hook",
        )
    if netns_after.is_file():
        audit.require(
            not any(token in netns_after.read_text(encoding="utf-8") for token in ("arp-", "udp-", "ldap-", "xdp-")),
            "v2 gate left a benchmark namespace",
        )

    live = root / "health/final-live-20260814/cluster-runtime.txt"
    openstack = root / "health/final-live-20260814/openstack-status.txt"
    preflight = root / "health/final-live-20260814/physical-native-preflight.txt"
    for path in (live, openstack, preflight):
        audit.require(path.is_file(), f"missing final live snapshot: {path.name}")
    if live.is_file():
        text = live.read_text(encoding="utf-8")
        audit.require(text.count("kubelet=inactive") == 3, "final snapshot does not show three inactive kubelets")
        audit.require(text.count("containerd=inactive") == 3, "final snapshot does not show three inactive containerd units")
        audit.require(text.count("driver: r8169") == 3, "final NIC driver snapshot changed")
        audit.require("dns_ingress" in text and "grpc_ingress" in text, "original node1 TC hooks missing")
        audit.require("prog/xdp" not in text, "final live snapshot has an XDP attachment")
    if openstack.is_file():
        text = openstack.read_text(encoding="utf-8")
        for endpoint, status in (
            ("Horizon", "200"),
            ("Keystone", "200"),
            ("Glance", "300"),
            ("Nova", "200"),
            ("Placement", "200"),
            ("Neutron", "200"),
        ):
            audit.require(f"{endpoint}" in text and status in text, f"final OpenStack {endpoint} status missing")
        audit.require(text.count("enabled up") == 9, "not all nine Nova services are up")
        audit.require(text.count("True") == 6, "not all six OVN agents are alive")
    if preflight.is_file():
        text = preflight.read_text(encoding="utf-8")
        audit.require(
            "expected r8169_xdp, found r8169" in text,
            "physical native exclusion lacks exact driver evidence",
        )

    report = repo / "docs/all-comparisons-experiment-report-2026-08-14.md"
    audit.require(report.is_file(), "missing authoritative experiment report")
    if report.is_file():
        text = report.read_text(encoding="utf-8")
        for needle in (BATCH, BMC_COMMIT, "207,338,877", "correctness_gate=PASS"):
            audit.require(needle in text, f"report missing required identity/evidence: {needle}")


def check_reproduction_entrypoints(repo: Path, audit: Audit) -> None:
    required = (
        "bench/run_bmc_formal_matrix.sh",
        "bench/run_dnsperf_resperf_formal_matrix.sh",
        "bench/arp_proxy_bench.sh",
        "bench/udp_fastpath_bench.sh",
        "bench/grpc_fast_cache_bench.sh",
        "bench/ldap_cluster_bench.sh",
        "bench/openstack_bmc_competitor_bench.sh",
        "bench/openstack_udp_fastpath_bench.sh",
        "bench/openstack_dns_xdp_competitor_bench.sh",
        "bench/run_physical_xdp_burst.sh",
        "tools/analyze_bmc_competitor_bench.py",
        "tools/analyze_dns_competitor_bench.py",
        "tools/analyze_resperf.py",
        "tools/analyze_openstack_dns_competitor_bench.py",
        "tools/analyze_protocol_repetitions.py",
        "tools/generate_openstack_dns_corpus.py",
    )
    for relative in required:
        path = repo / relative
        audit.require(path.is_file(), f"missing reproduction entrypoint: {relative}")


def main() -> int:
    args = parse_args()
    repo = args.repo.resolve()
    root = args.artifacts.resolve()
    audit = Audit()
    audit.require(root.is_dir(), f"artifact root does not exist: {root}")
    audit.require(repo.is_dir(), f"repository root does not exist: {repo}")
    if not root.is_dir() or not repo.is_dir():
        return audit.finish()

    check_hashes(root, repo, audit)
    check_bmc(root, audit)
    check_openstack_bmc(root, audit)
    check_dns(root, audit)
    check_protocols(root, audit)
    check_traffic(root, repo, audit)
    check_correctness_and_recovery(root, repo, audit)
    check_reproduction_entrypoints(repo, audit)
    return audit.finish()


if __name__ == "__main__":
    sys.exit(main())
