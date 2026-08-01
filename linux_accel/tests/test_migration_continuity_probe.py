import importlib.util
import json
import signal
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "bench"
    / "migration_continuity_probe.py"
)


def load_module():
    spec = importlib.util.spec_from_file_location(
        "migration_continuity_probe", MODULE_PATH
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MigrationContinuityProbeTest(unittest.TestCase):
    def test_two_protocols_reach_minimum_samples_and_emit_passing_summary(self):
        probe = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dns_harness = root / "dns-harness"
            grpc_harness = root / "grpc-harness"
            dns_harness.write_text("#!/bin/sh\n", encoding="utf-8")
            grpc_harness.write_text("#!/bin/sh\n", encoding="utf-8")
            output_dir = root / "evidence"
            stop_event = threading.Event()
            calls = {"dns": 0, "grpc": 0}
            commands = {"dns": [], "grpc": []}
            lock = threading.Lock()

            def command_runner(command, **kwargs):
                protocol = "dns" if command[0] == str(dns_harness) else "grpc"
                with lock:
                    calls[protocol] += 1
                    commands[protocol].append(command)
                    if min(calls.values()) >= 2:
                        stop_event.set()
                stdout = (
                    "success=1 failed=0 qps=1 avg_us=1 p50_us=1 "
                    "p95_us=1 p99_us=1 workload=hot keys=1\n"
                    if protocol == "dns"
                    else "count=1 failed=0 serving=1 not_serving=0 qps=1 "
                    "avg_us=1 p50_us=1 p95_us=1 p99_us=1\n"
                )
                return subprocess.CompletedProcess(command, 0, stdout, "")

            config = probe.ProbeConfig(
                phase="forward",
                backend_ip="10.0.0.55",
                dns_harness=dns_harness,
                grpc_harness=grpc_harness,
                output_dir=output_dir,
                interval=0.001,
                command_timeout=1.0,
                min_samples=2,
            )
            summary = probe.run_probe(
                config,
                command_runner=command_runner,
                stop_event=stop_event,
                install_signal_handlers=False,
            )

            self.assertTrue(summary["passed"])
            self.assertEqual(summary["schema_version"], 1)
            self.assertEqual(summary["phase"], "forward")
            for protocol in ("dns", "grpc"):
                self.assertGreaterEqual(summary[protocol]["samples"], 2)
                self.assertEqual(summary[protocol]["failure"], 0)
                records = [
                    json.loads(line)
                    for line in (output_dir / f"{protocol}.jsonl")
                    .read_text(encoding="utf-8")
                    .splitlines()
                ]
                self.assertEqual(len(records), summary[protocol]["samples"])
                self.assertTrue(all(record["success"] for record in records))
            self.assertEqual(
                json.loads((output_dir / "summary.json").read_text(encoding="utf-8")),
                summary,
            )
            self.assertEqual(
                commands["dns"][0],
                [
                    str(dns_harness),
                    "client-workload",
                    "10.0.0.55",
                    "53",
                    "dynamic.test",
                    "10.0.0.55",
                    "1",
                    "0",
                    "hot",
                    "1",
                ],
            )
            self.assertEqual(
                commands["grpc"][0],
                [
                    str(grpc_harness),
                    "client",
                    "127.0.0.1",
                    "50053",
                    "1",
                    "0",
                    "migration",
                ],
            )

    def test_any_failed_request_makes_the_summary_fail(self):
        probe = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dns_harness = root / "dns-harness"
            grpc_harness = root / "grpc-harness"
            dns_harness.touch()
            grpc_harness.touch()
            stop_event = threading.Event()
            seen = set()
            lock = threading.Lock()

            def command_runner(command, **kwargs):
                protocol = "dns" if command[0] == str(dns_harness) else "grpc"
                with lock:
                    seen.add(protocol)
                    if len(seen) == 2:
                        stop_event.set()
                rc = 7 if protocol == "dns" else 0
                stdout = (
                    "success=0 failed=1\n"
                    if protocol == "dns"
                    else "count=1 failed=0 serving=1 not_serving=0\n"
                )
                return subprocess.CompletedProcess(command, rc, stdout, "failed")

            config = probe.ProbeConfig(
                phase="reverse",
                backend_ip="10.0.0.55",
                dns_harness=dns_harness,
                grpc_harness=grpc_harness,
                output_dir=root / "evidence",
                interval=0.001,
                command_timeout=1.0,
                min_samples=1,
            )
            summary = probe.run_probe(
                config,
                command_runner=command_runner,
                stop_event=stop_event,
                install_signal_handlers=False,
            )

            self.assertFalse(summary["passed"])
            self.assertGreaterEqual(summary["dns"]["failure"], 1)
            dns_record = json.loads(
                (config.output_dir / "dns.jsonl")
                .read_text(encoding="utf-8")
                .splitlines()[0]
            )
            self.assertEqual(dns_record["rc"], 7)
            self.assertEqual(dns_record["stderr"], "failed")
            self.assertFalse(dns_record["success"])

    def test_command_timeout_is_recorded_as_a_failed_sample(self):
        probe = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dns_harness = root / "dns-harness"
            grpc_harness = root / "grpc-harness"
            dns_harness.touch()
            grpc_harness.touch()
            stop_event = threading.Event()
            seen = set()
            lock = threading.Lock()

            def command_runner(command, **kwargs):
                protocol = "dns" if command[0] == str(dns_harness) else "grpc"
                with lock:
                    seen.add(protocol)
                    if len(seen) == 2:
                        stop_event.set()
                if protocol == "dns":
                    raise subprocess.TimeoutExpired(
                        command, kwargs["timeout"], output="partial", stderr="late"
                    )
                return subprocess.CompletedProcess(
                    command, 0, "count=1 failed=0 serving=1 not_serving=0\n", ""
                )

            config = probe.ProbeConfig(
                phase="forward",
                backend_ip="10.0.0.55",
                dns_harness=dns_harness,
                grpc_harness=grpc_harness,
                output_dir=root / "evidence",
                interval=0.001,
                command_timeout=0.5,
                min_samples=1,
            )
            summary = probe.run_probe(
                config,
                command_runner=command_runner,
                stop_event=stop_event,
                install_signal_handlers=False,
            )

            record = json.loads(
                (config.output_dir / "dns.jsonl")
                .read_text(encoding="utf-8")
                .splitlines()[0]
            )
            self.assertFalse(summary["passed"])
            self.assertTrue(record["timed_out"])
            self.assertIsNone(record["rc"])
            self.assertEqual(record["stdout"], "partial")
            self.assertEqual(record["stderr"], "late")

    def test_harness_execution_error_is_preserved_as_a_failed_sample(self):
        probe = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dns_harness = root / "dns-harness"
            grpc_harness = root / "grpc-harness"
            dns_harness.touch()
            grpc_harness.touch()
            stop_event = threading.Event()
            seen = set()
            lock = threading.Lock()

            def command_runner(command, **kwargs):
                protocol = "dns" if command[0] == str(dns_harness) else "grpc"
                with lock:
                    seen.add(protocol)
                    if len(seen) == 2:
                        stop_event.set()
                if protocol == "dns":
                    raise OSError(13, "permission denied")
                return subprocess.CompletedProcess(
                    command, 0, "count=1 failed=0 serving=1 not_serving=0\n", ""
                )

            config = probe.ProbeConfig(
                phase="forward",
                backend_ip="10.0.0.55",
                dns_harness=dns_harness,
                grpc_harness=grpc_harness,
                output_dir=root / "evidence",
                interval=0,
                command_timeout=1,
                min_samples=1,
            )
            summary = probe.run_probe(
                config,
                command_runner=command_runner,
                stop_event=stop_event,
                install_signal_handlers=False,
            )

            record = json.loads(
                (config.output_dir / "dns.jsonl")
                .read_text(encoding="utf-8")
                .splitlines()[0]
            )
            self.assertFalse(summary["passed"])
            self.assertIsNone(record["rc"])
            self.assertEqual(record["error"], "OSError")
            self.assertIn("permission denied", record["stderr"])

    def test_grpc_not_serving_is_a_failure_even_when_harness_returns_zero(self):
        probe = load_module()
        self.assertFalse(
            probe._request_succeeded(
                "grpc",
                0,
                "count=1 failed=0 serving=0 not_serving=1 qps=1\n",
            )
        )
        self.assertTrue(
            probe._request_succeeded(
                "grpc",
                0,
                "count=1 failed=0 serving=1 not_serving=0 qps=1\n",
            )
        )

    def test_nonempty_output_directory_is_rejected_without_deleting_it(self):
        probe = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dns_harness = root / "dns-harness"
            grpc_harness = root / "grpc-harness"
            dns_harness.touch()
            grpc_harness.touch()
            output_dir = root / "evidence"
            output_dir.mkdir()
            sentinel = output_dir / "keep.txt"
            sentinel.write_text("keep", encoding="utf-8")
            config = probe.ProbeConfig(
                phase="forward",
                backend_ip="10.0.0.55",
                dns_harness=dns_harness,
                grpc_harness=grpc_harness,
                output_dir=output_dir,
                interval=0.1,
                command_timeout=1.0,
                min_samples=1,
            )

            with self.assertRaisesRegex(ValueError, "output directory is not empty"):
                probe.run_probe(config, install_signal_handlers=False)

            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")

    def test_signal_stop_finishes_inflight_samples_and_writes_summary_atomically(self):
        probe = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dns_harness = root / "dns-harness"
            grpc_harness = root / "grpc-harness"
            dns_harness.touch()
            grpc_harness.touch()
            output_dir = root / "evidence"
            installed = {}
            seen = set()
            lock = threading.Lock()

            def install_handler(signum, handler):
                previous = installed.get(signum, signal.SIG_DFL)
                installed[signum] = handler
                return previous

            def command_runner(command, **kwargs):
                protocol = "dns" if command[0] == str(dns_harness) else "grpc"
                with lock:
                    seen.add(protocol)
                    should_stop = len(seen) == 2
                if should_stop:
                    installed[signal.SIGTERM](signal.SIGTERM, None)
                stdout = (
                    "success=1 failed=0\n"
                    if protocol == "dns"
                    else "count=1 failed=0 serving=1 not_serving=0\n"
                )
                return subprocess.CompletedProcess(command, 0, stdout, "")

            config = probe.ProbeConfig(
                phase="reverse",
                backend_ip="10.0.0.55",
                dns_harness=dns_harness,
                grpc_harness=grpc_harness,
                output_dir=output_dir,
                interval=0.001,
                command_timeout=1.0,
                min_samples=1,
            )
            with mock.patch.object(probe.signal, "signal", install_handler):
                summary = probe.run_probe(config, command_runner=command_runner)

            self.assertTrue(summary["passed"])
            self.assertEqual(summary["stop_reason"], "signal:SIGTERM")
            self.assertTrue((output_dir / "summary.json").is_file())
            self.assertEqual(list(output_dir.glob(".summary.json.*.tmp")), [])

    def test_cli_rejects_invalid_paths_and_parameters(self):
        probe = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dns_harness = root / "dns-harness"
            grpc_harness = root / "grpc-harness"
            dns_harness.touch()
            grpc_harness.touch()
            common = [
                "--phase",
                "forward",
                "--backend-ip",
                "10.0.0.55",
                "--dns-harness",
                str(dns_harness),
                "--grpc-harness",
                str(grpc_harness),
                "--output-dir",
                str(root / "evidence"),
                "--interval",
                "0.1",
                "--command-timeout",
                "1",
                "--min-samples",
                "1",
            ]
            invalid_cases = [
                ("backend IP", ["--backend-ip", "not-an-ip"]),
                ("phase", ["--phase", "bad phase"]),
                ("DNS harness", ["--dns-harness", str(root / "missing")]),
                ("interval", ["--interval", "-1"]),
                ("command timeout", ["--command-timeout", "0"]),
                ("minimum samples", ["--min-samples", "0"]),
                ("maximum duration", ["--max-duration", "0"]),
            ]
            for expected, replacement in invalid_cases:
                args = list(common)
                option = replacement[0]
                if option in args:
                    index = args.index(option)
                    args[index : index + 2] = replacement
                else:
                    args.extend(replacement)
                with self.subTest(option=option):
                    with self.assertRaisesRegex(ValueError, expected):
                        probe.main(args, install_signal_handlers=False)

    def test_summary_reports_request_duration_and_gap_between_successes(self):
        probe = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dns_harness = root / "dns-harness"
            grpc_harness = root / "grpc-harness"
            dns_harness.touch()
            grpc_harness.touch()
            stop_event = threading.Event()
            calls = {"dns": 0, "grpc": 0}
            sample_barrier = threading.Barrier(2)
            clock_values = {
                "dns": iter((10.0, 12.0, 17.0, 18.0)),
                "grpc": iter((20.0, 21.0, 25.0, 29.0)),
            }
            lock = threading.Lock()

            def command_runner(command, **kwargs):
                protocol = "dns" if command[0] == str(dns_harness) else "grpc"
                with lock:
                    calls[protocol] += 1
                sample_barrier.wait(timeout=1)
                with lock:
                    if min(calls.values()) >= 2:
                        stop_event.set()
                stdout = (
                    "success=1 failed=0\n"
                    if protocol == "dns"
                    else "count=1 failed=0 serving=1 not_serving=0\n"
                )
                return subprocess.CompletedProcess(command, 0, stdout, "")

            def wall_clock():
                return next(clock_values[threading.current_thread().name])

            config = probe.ProbeConfig(
                phase="forward",
                backend_ip="10.0.0.55",
                dns_harness=dns_harness,
                grpc_harness=grpc_harness,
                output_dir=root / "evidence",
                interval=0,
                command_timeout=1,
                min_samples=2,
            )
            summary = probe.run_probe(
                config,
                command_runner=command_runner,
                stop_event=stop_event,
                wall_clock=wall_clock,
                install_signal_handlers=False,
            )

            self.assertEqual(summary["dns"]["max_request_duration"], 2.0)
            self.assertEqual(summary["dns"]["max_adjacent_success_gap"], 6.0)
            self.assertEqual(summary["dns"]["start_time"], 10.0)
            self.assertEqual(summary["dns"]["end_time"], 18.0)
            self.assertEqual(summary["grpc"]["max_request_duration"], 4.0)
            self.assertEqual(summary["grpc"]["max_adjacent_success_gap"], 8.0)

    def test_max_duration_stops_the_probe_and_fails_without_minimum_samples(self):
        probe = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dns_harness = root / "dns-harness"
            grpc_harness = root / "grpc-harness"
            dns_harness.touch()
            grpc_harness.touch()
            values = iter((0.0, 10.0, 10.0))
            lock = threading.Lock()

            def monotonic():
                with lock:
                    return next(values)

            config = probe.ProbeConfig(
                phase="forward",
                backend_ip="10.0.0.55",
                dns_harness=dns_harness,
                grpc_harness=grpc_harness,
                output_dir=root / "evidence",
                interval=0,
                command_timeout=1,
                min_samples=1,
                max_duration=5,
            )
            summary = probe.run_probe(
                config,
                monotonic=monotonic,
                install_signal_handlers=False,
            )

            self.assertEqual(summary["stop_reason"], "max_duration")
            self.assertFalse(summary["passed"])
            self.assertEqual(summary["dns"]["samples"], 0)
            self.assertEqual(summary["grpc"]["samples"], 0)


if __name__ == "__main__":
    unittest.main()
