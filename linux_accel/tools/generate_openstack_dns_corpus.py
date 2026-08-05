#!/usr/bin/env python3
"""Generate a deterministic bootstrap DNS corpus for the OpenStack bench."""

import argparse
import json
import random
from pathlib import Path


PROFILE = (
    ("hot_a", 45),
    ("warm_a", 20),
    ("cold_a", 10),
    ("aaaa", 10),
    ("unsupported", 5),
    ("nxdomain", 5),
    ("cname", 3),
    ("truncated", 2),
)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--domain", default="openstack.example.test")
    parser.add_argument("--lines", type=int, default=50000)
    parser.add_argument("--seed", type=int, default=20260805)
    return parser.parse_args()


def skewed_index(rng, pool_size):
    """A stable heavy-head distribution without third-party dependencies."""
    return min(pool_size - 1, int((rng.random() ** 3.0) * pool_size))


def main():
    args = parse_args()
    if args.lines < 100 or args.lines % 100:
        raise SystemExit("--lines must be at least 100 and divisible by 100")
    domain = args.domain.rstrip(".").lower()
    rng = random.Random(args.seed)
    counts = {name: args.lines * percent // 100 for name, percent in PROFILE}
    rows = []

    hot_pool = min(500, max(32, counts["hot_a"] // 20))
    for _ in range(counts["hot_a"]):
        index = skewed_index(rng, hot_pool)
        rows.append(("hot_a", f"hot-{index:04d}.{domain} A"))

    warm_pool = min(5000, max(256, counts["warm_a"] // 2))
    for _ in range(counts["warm_a"]):
        index = skewed_index(rng, warm_pool)
        rows.append(("warm_a", f"warm-{index:05d}.{domain} A"))

    for index in range(counts["cold_a"]):
        rows.append(("cold_a", f"cold-{index:06d}.{domain} A"))

    v6_pool = min(1000, max(64, counts["aaaa"] // 5))
    for _ in range(counts["aaaa"]):
        index = skewed_index(rng, v6_pool)
        rows.append(("aaaa", f"v6-{index:04d}.{domain} AAAA"))

    # dnsperf cannot toggle EDNS per row.  This 5% unsupported-QTYPE stream is
    # the fail-open stand-in for the first run; EDNS gets a separate smoke.
    unsupported_pool = min(1000, max(64, counts["unsupported"] // 2))
    for _ in range(counts["unsupported"]):
        index = skewed_index(rng, unsupported_pool)
        rows.append(("unsupported", f"unsupported-{index:04d}.{domain} TXT"))

    for index in range(counts["nxdomain"]):
        rows.append(("nxdomain", f"nxd-{index:05d}.{domain} A"))

    cname_pool = min(500, max(32, counts["cname"] // 4))
    for _ in range(counts["cname"]):
        index = skewed_index(rng, cname_pool)
        rows.append(("cname", f"cname-{index:04d}.{domain} A"))

    for index in range(counts["truncated"]):
        rows.append(("truncated", f"large-{index:05d}.{domain} TXT"))

    rng.shuffle(rows)
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(row for _, row in rows) + "\n", encoding="ascii")

    manifest = {
        "domain": domain,
        "lines": len(rows),
        "seed": args.seed,
        "counts": counts,
        "cache_eligible_percent": 75,
        "hot_repeat_percent": 45,
        "notes": [
            "bootstrap synthetic profile; not a production trace",
            "unsupported QTYPE is the 5% per-row stand-in for EDNS",
            "cold A names are unique within one corpus pass",
        ],
    }
    manifest_path = Path(args.manifest)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="ascii"
    )


if __name__ == "__main__":
    main()
