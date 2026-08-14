#!/usr/bin/env python3
"""Deterministic closed-world UDP DNS backend for OpenStack benchmarks.

The backend keeps the original single-name behavior and also understands the
synthetic corpus prefixes emitted by generate_openstack_dns_corpus.py.  This
lets one offline VM serve repeatable A, AAAA, HTTPS, CNAME, NXDOMAIN, short-TTL
and truncated-response traffic without depending on the public Internet.
"""

import argparse
import json
import os
import signal
import socket
import time


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True)
    parser.add_argument("--port", type=int, default=53)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--answer", required=True)
    parser.add_argument("--ttl", type=int, default=60)
    parser.add_argument(
        "--count-file", default="/run/linux-accel-openstack-dns-backend.json"
    )
    return parser.parse_args()


def encode_question(domain):
    labels = domain.rstrip(".").split(".")
    return b"".join(bytes([len(label)]) + label.encode("ascii") for label in labels) + (
        b"\x00\x00\x01\x00\x01"
    )


def encode_name(domain):
    labels = domain.rstrip(".").split(".")
    encoded = bytearray()
    for label in labels:
        raw = label.encode("ascii")
        if not raw or len(raw) > 63:
            raise ValueError(f"invalid DNS label in {domain!r}")
        encoded.append(len(raw))
        encoded.extend(raw)
    encoded.append(0)
    return bytes(encoded)


def decode_name(packet, offset):
    labels = []
    while True:
        if offset >= len(packet):
            raise ValueError("truncated DNS name")
        length = packet[offset]
        offset += 1
        if length == 0:
            break
        if length & 0xC0:
            raise ValueError("compressed query names are not supported")
        if length > 63 or offset + length > len(packet):
            raise ValueError("invalid DNS label")
        labels.append(packet[offset : offset + length].decode("ascii").lower())
        offset += length
    return ".".join(labels), offset


def parse_question(packet):
    if len(packet) < 12 or int.from_bytes(packet[4:6], "big") != 1:
        raise ValueError("expected exactly one DNS question")
    name, offset = decode_name(packet, 12)
    if offset + 4 > len(packet):
        raise ValueError("truncated DNS question")
    qtype = int.from_bytes(packet[offset : offset + 2], "big")
    qclass = int.from_bytes(packet[offset + 2 : offset + 4], "big")
    question_end = offset + 4
    return name, qtype, qclass, packet[12:question_end], question_end


def resource_record(owner, record_type, ttl, rdata):
    return (
        owner
        + record_type.to_bytes(2, "big")
        + b"\x00\x01"
        + ttl.to_bytes(4, "big")
        + len(rdata).to_bytes(2, "big")
        + rdata
    )


def make_response(request, question, flags, answers=()):
    header = (
        request[:2]
        + flags.to_bytes(2, "big")
        + b"\x00\x01"
        + len(answers).to_bytes(2, "big")
        + b"\x00\x00\x00\x00"
    )
    return header + question + b"".join(answers)


def first_numeric_suffix(label):
    try:
        return int(label.rsplit("-", 1)[1])
    except (IndexError, ValueError):
        return 0


def write_snapshot(path, counters):
    temporary_path = f"{path}.tmp"
    payload = dict(counters)
    payload["monotonic_ns"] = time.monotonic_ns()
    with open(temporary_path, "w", encoding="ascii") as output:
        json.dump(payload, output, sort_keys=True)
        output.write("\n")
    os.replace(temporary_path, path)


def main():
    args = parse_args()
    if args.port <= 0 or args.port > 65535 or args.ttl <= 0:
        raise SystemExit("port and TTL must be positive and valid")

    domain = args.domain.rstrip(".").lower()
    # Keep this eager validation because the root-domain smoke test relies on
    # the exact wire representation being valid.
    encode_question(domain)
    answer_ipv4 = socket.inet_aton(args.answer)
    answer_ipv6 = socket.inet_pton(socket.AF_INET6, "2001:db8::123")
    # A deliberately small HTTPS RR (priority 1, root target, no SvcParams).
    # It exercises the narrow single-answer HTTPS path without pretending that
    # the benchmark is a full HTTPS/SVCB resolver implementation.
    answer_https = b"\x00\x01\x00"
    counters = {
        "requests": 0,
        "responses": 0,
        "invalid": 0,
        "malformed": 0,
        "root_a": 0,
        "hot_a": 0,
        "warm_a": 0,
        "cold_a": 0,
        "aaaa": 0,
        "https": 0,
        "ptr": 0,
        "ns": 0,
        "other": 0,
        "cname": 0,
        "nxdomain": 0,
        "servfail": 0,
        "notimp": 0,
        "empty_noerror": 0,
        "edns": 0,
        "truncated": 0,
        "unsupported": 0,
    }
    running = True
    snapshot_requested = True

    def stop(_signum, _frame):
        nonlocal running
        running = False

    def request_snapshot(_signum, _frame):
        nonlocal snapshot_requested
        snapshot_requested = True

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGUSR1, request_snapshot)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.bind, args.port))
    sock.settimeout(0.1)

    while running:
        if snapshot_requested:
            write_snapshot(args.count_file, counters)
            snapshot_requested = False
        try:
            data, peer = sock.recvfrom(512)
        except socket.timeout:
            continue

        counters["requests"] += 1
        try:
            qname, qtype, qclass, question, question_end = parse_question(data)
        except (UnicodeDecodeError, ValueError):
            counters["invalid"] += 1
            counters["malformed"] += 1
            if len(data) < 2:
                continue
            response = data[:2] + b"\x81\x81" + b"\x00" * 8
            sock.sendto(response, peer)
            counters["responses"] += 1
            continue

        request_flags = int.from_bytes(data[2:4], "big")
        normal_flags = 0x8080 | (request_flags & 0x0100)
        owner_pointer = b"\xc0\x0c"
        first_label = qname.split(".", 1)[0]
        is_under_domain = qname == domain or qname.endswith(f".{domain}")
        has_edns = question_end < len(data)
        if has_edns:
            counters["edns"] += 1

        response = None
        if is_under_domain and first_label.startswith("nxd-"):
            counters["invalid"] += 1
            counters["nxdomain"] += 1
            response = make_response(data, question, normal_flags | 3)
        elif is_under_domain and first_label.startswith("servfail-"):
            counters["invalid"] += 1
            counters["servfail"] += 1
            response = make_response(data, question, normal_flags | 2)
        elif is_under_domain and first_label.startswith("notimp-"):
            counters["invalid"] += 1
            counters["notimp"] += 1
            response = make_response(data, question, normal_flags | 4)
        elif is_under_domain and first_label.startswith("empty-"):
            counters["empty_noerror"] += 1
            response = make_response(data, question, normal_flags)
        elif qclass == 1 and qtype == 1 and qname == domain:
            counters["root_a"] += 1
            answer = resource_record(owner_pointer, 1, args.ttl, answer_ipv4)
            response = make_response(data, question, normal_flags, (answer,))
        elif qclass == 1 and qtype == 1 and is_under_domain and first_label.startswith("hot-"):
            counters["hot_a"] += 1
            answer = resource_record(owner_pointer, 1, args.ttl, answer_ipv4)
            response = make_response(data, question, normal_flags, (answer,))
        elif qclass == 1 and qtype == 1 and is_under_domain and first_label.startswith("warm-"):
            counters["warm_a"] += 1
            ttl = (5, 30, args.ttl)[first_numeric_suffix(first_label) % 3]
            answer = resource_record(owner_pointer, 1, ttl, answer_ipv4)
            response = make_response(data, question, normal_flags, (answer,))
        elif qclass == 1 and qtype == 1 and is_under_domain and first_label.startswith("cold-"):
            counters["cold_a"] += 1
            answer = resource_record(owner_pointer, 1, 60, answer_ipv4)
            response = make_response(data, question, normal_flags, (answer,))
        elif qclass == 1 and qtype == 28 and is_under_domain and first_label.startswith("v6-"):
            counters["aaaa"] += 1
            answer = resource_record(owner_pointer, 28, args.ttl, answer_ipv6)
            response = make_response(data, question, normal_flags, (answer,))
        elif qclass == 1 and qtype == 65 and is_under_domain and first_label.startswith("https-"):
            counters["https"] += 1
            answer = resource_record(owner_pointer, 65, args.ttl, answer_https)
            response = make_response(data, question, normal_flags, (answer,))
        elif qclass == 1 and qtype == 12 and is_under_domain and first_label.startswith("ptr-"):
            counters["ptr"] += 1
            answer = resource_record(owner_pointer, 12, args.ttl, encode_name(domain))
            response = make_response(data, question, normal_flags, (answer,))
        elif qclass == 1 and qtype == 2 and is_under_domain and first_label.startswith("ns-"):
            counters["ns"] += 1
            answer = resource_record(owner_pointer, 2, args.ttl, encode_name(f"ns1.{domain}"))
            response = make_response(data, question, normal_flags, (answer,))
        elif qclass == 1 and qtype == 16 and is_under_domain and first_label.startswith("other-"):
            counters["other"] += 1
            text = b"radar-other"
            answer = resource_record(owner_pointer, 16, args.ttl, bytes([len(text)]) + text)
            response = make_response(data, question, normal_flags, (answer,))
        elif qclass == 1 and qtype == 1 and is_under_domain and first_label.startswith("cname-"):
            counters["cname"] += 1
            target = encode_name(domain)
            cname_answer = resource_record(owner_pointer, 5, 30, target)
            a_answer = resource_record(target, 1, args.ttl, answer_ipv4)
            response = make_response(
                data, question, normal_flags, (cname_answer, a_answer)
            )
        elif is_under_domain and first_label.startswith("large-"):
            counters["truncated"] += 1
            response = make_response(data, question, normal_flags | 0x0200)
        else:
            counters["invalid"] += 1
            counters["unsupported"] += 1
            response = make_response(data, question, normal_flags | 3)

        sock.sendto(response, peer)
        counters["responses"] += 1

    write_snapshot(args.count_file, counters)
    sock.close()


if __name__ == "__main__":
    main()
