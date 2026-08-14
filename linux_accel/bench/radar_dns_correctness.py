#!/usr/bin/env python3
"""Validate representative Cloudflare Radar NL DNS-mix responses."""

import argparse
import json
import socket
import struct


QTYPE = {
    "A": 1,
    "NS": 2,
    "TXT": 16,
    "PTR": 12,
    "AAAA": 28,
    "HTTPS": 65,
}


def encode_name(name):
    return b"".join(
        bytes((len(label),)) + label.encode("ascii")
        for label in name.rstrip(".").split(".")
    ) + b"\x00"


def query(server, port, name, qtype, transaction_id):
    header = struct.pack("!HHHHHH", transaction_id, 0x0100, 1, 0, 0, 0)
    question = encode_name(name) + struct.pack("!HH", QTYPE[qtype], 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(1.0)
    try:
        sock.sendto(header + question, (server, port))
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
        "answers": values[3],
        "wire": response,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True)
    parser.add_argument("--port", type=int, default=53)
    parser.add_argument("--domain", default="radar.example.test")
    parser.add_argument("--answer", default="10.0.0.123")
    args = parser.parse_args()
    domain = args.domain.rstrip(".")
    cases = (
        ("hot_a", f"hot-0001.{domain}", "A", 0, 1),
        ("cold_a", f"cold-000001.{domain}", "A", 0, 1),
        ("empty_a", f"empty-a-000001.{domain}", "A", 0, 0),
        ("hot_aaaa", f"v6-0001.{domain}", "AAAA", 0, 1),
        ("cold_aaaa", f"v6-cold-000001.{domain}", "AAAA", 0, 1),
        ("empty_aaaa", f"empty-aaaa-000001.{domain}", "AAAA", 0, 0),
        ("hot_https", f"https-0001.{domain}", "HTTPS", 0, 1),
        ("cold_https", f"https-cold-000001.{domain}", "HTTPS", 0, 1),
        ("ptr", f"ptr-000001.{domain}", "PTR", 0, 1),
        ("ns", f"ns-000001.{domain}", "NS", 0, 1),
        ("other", f"other-000001.{domain}", "TXT", 0, 1),
        ("nxdomain", f"nxd-a-000001.{domain}", "A", 3, 0),
        ("servfail", f"servfail-a-000001.{domain}", "A", 2, 0),
        ("notimp", f"notimp-a-000001.{domain}", "A", 4, 0),
    )
    expected_a = socket.inet_aton(args.answer)
    results = []
    for index, (label, name, qtype, rcode, answers) in enumerate(cases):
        result = query(args.server, args.port, name, qtype, 0x7100 + index)
        passed = result["rcode"] == rcode and result["answers"] == answers
        if qtype == "A" and answers == 1:
            passed = passed and expected_a in result["wire"]
        if qtype == "AAAA" and answers == 1:
            passed = passed and socket.inet_pton(
                socket.AF_INET6, "2001:db8::123"
            ) in result["wire"]
        if qtype == "HTTPS" and answers == 1:
            passed = passed and b"\x00\x01\x00" in result["wire"]
        results.append(
            {
                "case": label,
                "passed": passed,
                "rcode": result["rcode"],
                "answers": result["answers"],
                "bytes": len(result["wire"]),
            }
        )
    payload = {"passed": all(row["passed"] for row in results), "cases": results}
    print(json.dumps(payload, sort_keys=True))
    if not payload["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
