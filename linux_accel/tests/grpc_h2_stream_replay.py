#!/usr/bin/env python3
"""Replay three h2c streams on one TCP connection for eBPF correlation tests."""

from __future__ import annotations

import argparse
import socket
import time


PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
STREAM_IDS = (1, 3, 5)


def frame(frame_type: int, flags: int, stream_id: int, payload: bytes) -> bytes:
    return (
        len(payload).to_bytes(3, "big")
        + bytes((frame_type, flags))
        + (stream_id & 0x7FFFFFFF).to_bytes(4, "big")
        + payload
    )


def request_parts(stream_id: int, first: bool) -> tuple[bytes, bytes]:
    prefix = PREFACE + frame(0x4, 0, 0, b"") if first else b""
    headers = frame(0x1, 0x4, stream_id, b"\x82")
    grpc_message = b"\x00\x00\x00\x00\x02\x08\x01"
    return prefix + headers, frame(0x0, 0x1, stream_id, grpc_message)


def response_chunk(stream_id: int) -> bytes:
    return frame(0x1, 0x5, stream_id, b"\x88")


def read_exact(connection: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            raise RuntimeError("peer closed before the replay completed")
        data.extend(chunk)
    return bytes(data)


def run_server(address: str, port: int) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((address, port))
        listener.listen(1)
        connection, _ = listener.accept()
        with connection:
            connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            for index, stream_id in enumerate(STREAM_IDS):
                expected_headers, expected_data = request_parts(
                    stream_id, index == 0
                )
                headers = read_exact(connection, len(expected_headers))
                data = read_exact(connection, len(expected_data))
                if headers != expected_headers or data != expected_data:
                    raise RuntimeError(
                        f"request bytes differ for stream {stream_id}"
                    )
                connection.sendall(response_chunk(stream_id))


def run_client(address: str, port: int) -> None:
    with socket.create_connection((address, port), timeout=5.0) as connection:
        connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        for index, stream_id in enumerate(STREAM_IDS):
            headers, data = request_parts(stream_id, index == 0)
            connection.sendall(headers)
            time.sleep(0.02)
            connection.sendall(data)
            response = read_exact(connection, len(response_chunk(stream_id)))
            if response != response_chunk(stream_id):
                raise RuntimeError(
                    f"response bytes differ for stream {stream_id}"
                )
            time.sleep(0.05)
    print("streams=1,3,5 result=ok")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("server", "client"))
    parser.add_argument("--address", required=True)
    parser.add_argument("--port", type=int, default=50051)
    args = parser.parse_args()

    if args.mode == "server":
        run_server(args.address, args.port)
    else:
        run_client(args.address, args.port)


if __name__ == "__main__":
    main()
