#!/usr/bin/env python3
"""Probe DNS and gRPC request continuity while an OpenStack guest migrates."""

import argparse
import ipaddress
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path


class ProbeConfig:
    def __init__(
        self,
        *,
        phase,
        backend_ip,
        dns_harness,
        grpc_harness,
        output_dir,
        interval,
        command_timeout,
        min_samples,
        max_duration=None,
    ):
        self.phase = phase
        self.backend_ip = backend_ip
        self.dns_harness = Path(dns_harness)
        self.grpc_harness = Path(grpc_harness)
        self.output_dir = Path(output_dir)
        self.interval = interval
        self.command_timeout = command_timeout
        self.min_samples = min_samples
        self.max_duration = max_duration


def _validate_config(config):
    if not isinstance(config.phase, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9_.-]*", config.phase
    ):
        raise ValueError("phase is invalid")
    try:
        ipaddress.ip_address(config.backend_ip)
    except ValueError as error:
        raise ValueError("backend IP is invalid") from error
    for label, harness in (
        ("DNS", config.dns_harness),
        ("gRPC", config.grpc_harness),
    ):
        if not harness.is_file():
            raise ValueError(f"{label} harness is not a regular file: {harness}")
    if config.output_dir.exists():
        if not config.output_dir.is_dir():
            raise ValueError("output path is not a directory")
        if next(config.output_dir.iterdir(), None) is not None:
            raise ValueError("output directory is not empty")
    if config.interval < 0:
        raise ValueError("interval must be non-negative")
    if config.command_timeout <= 0:
        raise ValueError("command timeout must be positive")
    if not isinstance(config.min_samples, int) or config.min_samples <= 0:
        raise ValueError("minimum samples must be a positive integer")
    if config.max_duration is not None and config.max_duration <= 0:
        raise ValueError("maximum duration must be positive")


def _command(config, protocol):
    if protocol == "dns":
        return [
            str(config.dns_harness),
            "client-workload",
            config.backend_ip,
            "53",
            "dynamic.test",
            config.backend_ip,
            "1",
            "0",
            "hot",
            "1",
        ]
    return [
        str(config.grpc_harness),
        "client",
        "127.0.0.1",
        "50053",
        "1",
        "0",
        "migration",
    ]


def _request_succeeded(protocol, returncode, stdout):
    if returncode != 0:
        return False
    fields = {
        key: int(value)
        for key, value in re.findall(r"(?<![A-Za-z0-9_])([a-z_]+)=([0-9]+)", stdout)
    }
    if protocol == "dns":
        return fields.get("success") == 1 and fields.get("failed") == 0
    if protocol == "grpc":
        return (
            fields.get("count") == 1
            and fields.get("failed") == 0
            and fields.get("serving") == 1
            and fields.get("not_serving") == 0
        )
    raise ValueError(f"unsupported protocol: {protocol}")


def _atomic_write_json(path, value):
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def _protocol_summary(records):
    successes = [record for record in records if record["success"]]
    success_times = [record["end"] for record in successes]
    gaps = [
        current - previous
        for previous, current in zip(success_times, success_times[1:])
    ]
    return {
        "samples": len(records),
        "success": len(successes),
        "failure": len(records) - len(successes),
        "max_request_duration": max(
            (record["duration"] for record in records), default=0.0
        ),
        "max_adjacent_success_gap": max(gaps, default=0.0),
        "start_time": records[0]["start"] if records else None,
        "end_time": records[-1]["end"] if records else None,
    }


def run_probe(
    config,
    *,
    command_runner=subprocess.run,
    stop_event=None,
    monotonic=time.monotonic,
    wall_clock=time.time,
    install_signal_handlers=True,
):
    _validate_config(config)
    stop_event = stop_event or threading.Event()
    config.output_dir.mkdir(parents=True, exist_ok=True)
    records = {"dns": [], "grpc": []}
    stop_state = {"reason": "external_stop"}
    deadline = (
        monotonic() + config.max_duration
        if config.max_duration is not None
        else None
    )
    old_handlers = {}

    def request_stop(signum, _frame):
        stop_state["reason"] = f"signal:{signal.Signals(signum).name}"
        stop_event.set()

    if install_signal_handlers:
        for signum in (signal.SIGTERM, signal.SIGINT):
            old_handlers[signum] = signal.signal(signum, request_stop)

    def worker(protocol):
        path = config.output_dir / f"{protocol}.jsonl"
        command = _command(config, protocol)
        with path.open("a", encoding="utf-8") as stream:
            while not stop_event.is_set():
                if deadline is not None and monotonic() >= deadline:
                    stop_state["reason"] = "max_duration"
                    stop_event.set()
                    break
                started = wall_clock()
                try:
                    completed = command_runner(
                        command,
                        capture_output=True,
                        text=True,
                        timeout=config.command_timeout,
                        check=False,
                    )
                    rc = completed.returncode
                    stdout = completed.stdout or ""
                    stderr = completed.stderr or ""
                    timed_out = False
                    error_name = None
                except subprocess.TimeoutExpired as error:
                    rc = None
                    stdout = error.stdout or ""
                    stderr = error.stderr or ""
                    timed_out = True
                    error_name = type(error).__name__
                except OSError as error:
                    rc = None
                    stdout = ""
                    stderr = str(error)
                    timed_out = False
                    error_name = "OSError"
                ended = wall_clock()
                success = _request_succeeded(protocol, rc, stdout)
                if rc == 0 and not success and error_name is None:
                    error_name = "UnexpectedHarnessResult"
                record = {
                    "timestamp": datetime.fromtimestamp(
                        started, tz=timezone.utc
                    ).isoformat(),
                    "start": started,
                    "end": ended,
                    "duration": max(0.0, ended - started),
                    "rc": rc,
                    "stdout": stdout,
                    "stderr": stderr,
                    "timed_out": timed_out,
                    "error": error_name,
                    "success": success,
                }
                records[protocol].append(record)
                stream.write(json.dumps(record, sort_keys=True) + "\n")
                stream.flush()
                stop_event.wait(config.interval)

    threads = [
        threading.Thread(target=worker, args=(protocol,), name=protocol)
        for protocol in ("dns", "grpc")
    ]
    try:
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
    finally:
        if install_signal_handlers:
            for signum, handler in old_handlers.items():
                signal.signal(signum, handler)

    summary = {
        "schema_version": 1,
        "phase": config.phase,
        "stop_reason": stop_state["reason"],
        "dns": _protocol_summary(records["dns"]),
        "grpc": _protocol_summary(records["grpc"]),
    }
    summary["passed"] = all(
        summary[protocol]["samples"] >= config.min_samples
        and summary[protocol]["failure"] == 0
        for protocol in ("dns", "grpc")
    )
    _atomic_write_json(config.output_dir / "summary.json", summary)
    return summary


def _argument_parser():
    parser = argparse.ArgumentParser(
        description="Continuously probe guest DNS and gRPC migration traffic."
    )
    parser.add_argument("--phase", required=True)
    parser.add_argument("--backend-ip", required=True)
    parser.add_argument("--dns-harness", required=True, type=Path)
    parser.add_argument("--grpc-harness", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--interval", required=True, type=float)
    parser.add_argument("--command-timeout", required=True, type=float)
    parser.add_argument("--min-samples", required=True, type=int)
    parser.add_argument("--max-duration", type=float)
    return parser


def main(
    argv=None,
    *,
    command_runner=subprocess.run,
    stop_event=None,
    install_signal_handlers=True,
):
    args = _argument_parser().parse_args(argv)
    config = ProbeConfig(
        phase=args.phase,
        backend_ip=args.backend_ip,
        dns_harness=args.dns_harness,
        grpc_harness=args.grpc_harness,
        output_dir=args.output_dir,
        interval=args.interval,
        command_timeout=args.command_timeout,
        min_samples=args.min_samples,
        max_duration=args.max_duration,
    )
    _validate_config(config)
    summary = run_probe(
        config,
        command_runner=command_runner,
        stop_event=stop_event,
        install_signal_handlers=install_signal_handlers,
    )
    return 0 if summary["passed"] else 1


def _cli():
    try:
        return main()
    except ValueError as error:
        print(f"migration continuity probe: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(_cli())
