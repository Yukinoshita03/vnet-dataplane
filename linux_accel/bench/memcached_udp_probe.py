#!/usr/bin/env python3
"""Send one canonical UDP memcached GET and report exact response bytes."""

from __future__ import annotations

import argparse
import json
import socket
import struct
import time


def key_for(index: int) -> bytes:
    return f"key{index:013d}".encode("ascii")


def value_for(index: int) -> bytes:
    prefix = f"val{index:013d}".encode("ascii")
    return prefix + prefix


def packet_for(index: int, request_id: int) -> tuple[bytes, bytes]:
    header = struct.pack("!HHHH", request_id, 0, 1, 0)
    key = key_for(index)
    request = header + b"get " + key + b"\r\n"
    expected = (
        header
        + b"VALUE "
        + key
        + b" 0 32\r\n"
        + value_for(index)
        + b"\r\nEND\r\n"
    )
    return request, expected


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True, help="IPv4:port")
    parser.add_argument("--key", type=int, default=0)
    parser.add_argument("--request-id", type=int, default=0x1234)
    parser.add_argument("--timeout-ms", type=int, default=1000)
    args = parser.parse_args()

    host, port_text = args.server.rsplit(":", 1)
    request, expected = packet_for(args.key, args.request_id)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(args.timeout_ms / 1000.0)
    sock.connect((host, int(port_text)))

    started = time.monotonic_ns()
    sock.send(request)
    try:
        response = sock.recv(4096)
        error = None
    except TimeoutError:
        response = b""
        error = "timeout"
    elapsed_us = (time.monotonic_ns() - started) / 1000.0
    sock.close()

    passed = response == expected
    print(
        json.dumps(
            {
                "passed": passed,
                "error": error,
                "elapsed_us": elapsed_us,
                "request_len": len(request),
                "response_len": len(response),
                "expected_len": len(expected),
                "request_hex": request.hex(),
                "response_hex": response.hex(),
                "expected_hex": expected.hex(),
            },
            sort_keys=True,
        )
    )
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
