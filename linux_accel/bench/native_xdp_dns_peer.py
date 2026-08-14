#!/usr/bin/env python3
"""One-shot external peer for the native-XDP DNS cache hardware smoke.

The listener is deliberately small and dependency-free so it can run on an
offline cluster peer.  It accepts one trigger connection from an explicitly
allowed address, sends DNS queries from that peer to the DUT, validates every
reply byte-for-byte, and returns the strict key/value contract consumed by
native_xdp_dns_smoke.sh.
"""

from __future__ import annotations

import argparse
import ipaddress
import secrets
import socket
import struct
import subprocess
import sys
import time
from dataclasses import dataclass


DNS_HEADER = struct.Struct("!HHHHHH")
DNS_QUESTION_TAIL = struct.Struct("!HH")
DNS_A_ANSWER = struct.Struct("!HHHIH")


@dataclass(frozen=True)
class ProbeResult:
    successes: int
    query_bytes: int
    response_bytes: int


def encode_qname(domain: str) -> bytes:
    normalized = domain.rstrip(".").lower()
    if not normalized:
        raise ValueError("domain must not be empty")

    encoded = bytearray()
    for label in normalized.split("."):
        raw = label.encode("ascii")
        if not raw or len(raw) > 63:
            raise ValueError("each DNS label must contain 1..63 ASCII bytes")
        encoded.append(len(raw))
        encoded.extend(raw)
    encoded.append(0)
    if len(encoded) > 255:
        raise ValueError("encoded qname exceeds 255 bytes")
    return bytes(encoded)


def build_query(query_id: int, qname: bytes) -> bytes:
    return (
        DNS_HEADER.pack(query_id, 0x0100, 1, 0, 0, 0)
        + qname
        + DNS_QUESTION_TAIL.pack(1, 1)
    )


def validate_response(
    response: bytes,
    query: bytes,
    query_id: int,
    answer_ip: ipaddress.IPv4Address,
) -> None:
    if len(response) != len(query) + 16:
        raise RuntimeError(
            f"response length {len(response)} is not query length "
            f"{len(query)} plus 16"
        )
    if len(response) < len(query) + DNS_A_ANSWER.size:
        raise RuntimeError("DNS response is truncated")

    response_id, flags, qdcount, ancount, nscount, arcount = DNS_HEADER.unpack_from(
        response
    )
    if response_id != query_id:
        raise RuntimeError(
            f"DNS transaction id mismatch: expected {query_id}, got {response_id}"
        )
    if flags != 0x8180:
        raise RuntimeError(f"unexpected DNS response flags: 0x{flags:04x}")
    if (qdcount, ancount, nscount, arcount) != (1, 1, 0, 0):
        raise RuntimeError(
            "unexpected DNS section counts: "
            f"qd={qdcount} an={ancount} ns={nscount} ar={arcount}"
        )
    # The cache program changes flags/counts in the DNS header but must
    # preserve the complete question starting at byte 12.
    if response[12 : len(query)] != query[12:]:
        raise RuntimeError("DNS question changed in the cache response")

    name, rr_type, rr_class, ttl, rdlength = DNS_A_ANSWER.unpack_from(
        response, len(query)
    )
    if name != 0xC00C or rr_type != 1 or rr_class != 1 or rdlength != 4:
        raise RuntimeError(
            "unexpected A-answer encoding: "
            f"name=0x{name:04x} type={rr_type} class={rr_class} "
            f"ttl={ttl} rdlength={rdlength}"
        )
    if ttl < 1:
        raise RuntimeError("cache response TTL must be positive")
    actual_ip = ipaddress.IPv4Address(response[-4:])
    if actual_ip != answer_ip:
        raise RuntimeError(
            f"cache answer mismatch: expected {answer_ip}, got {actual_ip}"
        )


def send_validated_query(
    udp_socket: socket.socket,
    qname: bytes,
    query_id: int,
    answer_ip: ipaddress.IPv4Address,
) -> tuple[int, int]:
    query = build_query(query_id, qname)
    sent = udp_socket.send(query)
    if sent != len(query):
        raise RuntimeError(f"short UDP send: {sent} of {len(query)} bytes")
    response = udp_socket.recv(4096)
    validate_response(response, query, query_id, answer_ip)
    return len(query), len(response)


def run_probe(args: argparse.Namespace) -> ProbeResult:
    target_ip = ipaddress.IPv4Address(args.target)
    source_ip = ipaddress.IPv4Address(args.source_ip)
    answer_ip = ipaddress.IPv4Address(args.answer_ip)
    ordinary_target = ipaddress.IPv4Address(args.ordinary_target)
    qname = encode_qname(args.domain)
    query_id = secrets.randbelow(65536)
    query_bytes = 0
    response_bytes = 0

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp_socket:
        udp_socket.settimeout(args.query_timeout)
        udp_socket.bind((str(source_ip), 0))
        udp_socket.connect((str(target_ip), args.target_port))

        for index in range(args.count):
            query_bytes, response_bytes = send_validated_query(
                udp_socket,
                qname,
                (query_id + index) & 0xFFFF,
                answer_ip,
            )

        time.sleep(args.quiet_seconds)
        sentinel_query_bytes, sentinel_response_bytes = send_validated_query(
            udp_socket,
            qname,
            (query_id + args.count) & 0xFFFF,
            answer_ip,
        )

    if (sentinel_query_bytes, sentinel_response_bytes) != (
        query_bytes,
        response_bytes,
    ):
        raise RuntimeError("post-quiet sentinel sizes differ from the bulk queries")

    ping = subprocess.run(
        [
            "/usr/bin/ping",
            "-c",
            "1",
            "-W",
            "1",
            str(ordinary_target),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=3,
    )
    if ping.returncode != 0:
        raise RuntimeError(f"ordinary ICMP packet to {ordinary_target} failed")

    return ProbeResult(args.count, query_bytes, response_bytes)


def format_result(result: ProbeResult) -> str:
    return "\n".join(
        (
            f"peer_dns_successes={result.successes}",
            "peer_dns_sentinel_after_quiet=1",
            f"peer_dns_query_bytes={result.query_bytes}",
            f"peer_dns_response_bytes={result.response_bytes}",
            "peer_ordinary_packet_success=1",
            "",
        )
    )


def read_trigger(connection: socket.socket) -> None:
    connection.settimeout(5)
    trigger = connection.recv(16)
    if trigger.strip() != b"GO":
        raise RuntimeError("listener did not receive the exact GO trigger")


def serve_once(args: argparse.Namespace) -> int:
    allowed_trigger_ip = ipaddress.IPv4Address(args.allow_trigger_ip)
    listen_ip = ipaddress.IPv4Address(args.listen_ip)

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((str(listen_ip), args.listen_port))
        listener.listen(1)
        listener.settimeout(args.listener_timeout)
        connection, peer = listener.accept()

    with connection:
        if ipaddress.IPv4Address(peer[0]) != allowed_trigger_ip:
            raise RuntimeError(
                f"refusing trigger from {peer[0]}; expected {allowed_trigger_ip}"
            )
        read_trigger(connection)
        result = run_probe(args)
        connection.sendall(format_result(result).encode("ascii"))
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True, help="DUT IPv4 address")
    parser.add_argument("--source-ip", required=True, help="peer source IPv4")
    parser.add_argument("--domain", default="example.test")
    parser.add_argument("--answer-ip", default="10.0.0.123")
    parser.add_argument("--count", type=int, default=1024)
    parser.add_argument("--target-port", type=int, default=53)
    parser.add_argument("--query-timeout", type=float, default=1.0)
    parser.add_argument("--quiet-seconds", type=float, default=2.0)
    parser.add_argument(
        "--ordinary-target",
        default="10.115.24.245",
        help="ordinary ICMP target, normally the DUT",
    )
    parser.add_argument("--listen-ip", help="serve one trigger on this address")
    parser.add_argument("--listen-port", type=int, default=45953)
    parser.add_argument("--allow-trigger-ip", help="only accept this trigger peer")
    parser.add_argument("--listener-timeout", type=float, default=120.0)
    args = parser.parse_args()

    if args.count < 1:
        parser.error("--count must be positive")
    if not 1 <= args.target_port <= 65535:
        parser.error("--target-port must be in 1..65535")
    if not 1 <= args.listen_port <= 65535:
        parser.error("--listen-port must be in 1..65535")
    if args.query_timeout <= 0 or args.quiet_seconds < 0:
        parser.error("timeouts must be positive and quiet time cannot be negative")
    if bool(args.listen_ip) != bool(args.allow_trigger_ip):
        parser.error("--listen-ip and --allow-trigger-ip must be used together")
    return args


def main() -> int:
    args = parse_args()
    try:
        if args.listen_ip:
            return serve_once(args)
        print(format_result(run_probe(args)), end="")
        return 0
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"peer_probe_error={error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
