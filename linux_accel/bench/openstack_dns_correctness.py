#!/usr/bin/env python3
"""Validate representative closed-world DNS answers over UDP."""

import argparse
import json
import socket
import struct


QTYPE = {"A": 1, "CNAME": 5, "TXT": 16, "AAAA": 28, "HTTPS": 65}


def encode_name(name):
    return b"".join(
        bytes((len(label),)) + label.encode("ascii")
        for label in name.rstrip(".").split(".")
    ) + b"\x00"


def query(server, port, name, qtype, transaction_id, edns=False):
    flags = 0x0100
    additional = 1 if edns else 0
    header = struct.pack("!HHHHHH", transaction_id, flags, 1, 0, 0, additional)
    question = encode_name(name) + struct.pack("!HH", QTYPE[qtype], 1)
    opt = b"\x00\x00\x29\x04\xd0\x00\x00\x00\x00\x00\x00" if edns else b""
    packet = header + question + opt
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(1.0)
    try:
        sock.sendto(packet, (server, port))
        response, peer = sock.recvfrom(4096)
    finally:
        sock.close()
    if peer[0] != server or len(response) < 12:
        raise RuntimeError("invalid response peer or header")
    values = struct.unpack("!HHHHHH", response[:12])
    if values[0] != transaction_id or not values[1] & 0x8000:
        raise RuntimeError("transaction ID or QR flag mismatch")
    return {
        "rcode": values[1] & 0xF,
        "tc": bool(values[1] & 0x0200),
        "answers": values[3],
        "bytes": len(response),
        "wire": response,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True)
    parser.add_argument("--port", type=int, default=53)
    parser.add_argument("--domain", default="openstack.example.test")
    parser.add_argument("--answer", default="10.99.0.123")
    parser.add_argument("--repeats", type=int, default=2)
    args = parser.parse_args()
    if args.repeats < 1:
        raise SystemExit("--repeats must be positive")
    suffix = args.domain.rstrip(".")
    cases = (
        ("root_a", suffix, "A", 0, 1, False),
        ("hot_a", f"hot-0001.{suffix}", "A", 0, 1, False),
        ("warm_a", f"warm-00001.{suffix}", "A", 0, 1, False),
        ("cold_a", f"cold-999999.{suffix}", "A", 0, 1, False),
        ("aaaa", f"v6-0001.{suffix}", "AAAA", 0, 1, False),
        ("https", f"https-0001.{suffix}", "HTTPS", 0, 1, False),
        ("nxdomain", f"nxd-99999.{suffix}", "A", 3, 0, False),
        ("cname", f"cname-0001.{suffix}", "A", 0, 2, False),
        ("truncated", f"large-99999.{suffix}", "TXT", 0, 0, True),
        ("edns_a", f"hot-0002.{suffix}", "A", 0, 1, False),
    )
    expected_a = socket.inet_aton(args.answer)
    results = []
    for attempt in range(args.repeats):
        for index, (label, name, qtype, rcode, answers, expect_tc) in enumerate(cases):
            result = query(
                args.server,
                args.port,
                name,
                qtype,
                0x7000 + attempt * len(cases) + index,
                edns=(label == "edns_a"),
            )
            passed = (
                result["rcode"] == rcode
                and result["answers"] == answers
                and result["tc"] == expect_tc
            )
            if qtype == "A" and rcode == 0 and label != "cname":
                passed = passed and expected_a in result["wire"]
            if label == "https" and rcode == 0:
                passed = passed and b"\x00\x01\x00" in result["wire"]
            results.append(
                {
                    "case": label,
                    "attempt": attempt + 1,
                    "passed": passed,
                    "rcode": result["rcode"],
                    "answers": result["answers"],
                    "tc": result["tc"],
                    "bytes": result["bytes"],
                }
            )
    payload = {"passed": all(row["passed"] for row in results), "cases": results}
    print(json.dumps(payload, sort_keys=True))
    if not payload["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
