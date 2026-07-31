import argparse
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


LINUX_ACCEL = Path(__file__).resolve().parents[1]
SCRIPT = LINUX_ACCEL / "agent" / "openstack_metrics_bridge.py"
if str(LINUX_ACCEL) not in sys.path:
    sys.path.insert(0, str(LINUX_ACCEL))

import agent.openstack_metrics_bridge as bridge


NOW_NS = 2_000_000_000_000_000_000


def dns_line(
    role,
    *,
    qps=100,
    timeout=0,
    unmatched=0,
    ringbuf_drop=0,
    cache_hit=10,
    cache_miss=4,
    shadow_hit=2,
    shadow_miss=1,
    p95="1.250ms",
):
    return (
        f"dns_metrics dev=ens3 role={role} qps={qps} rps={qps} pending=0 "
        f"timeout={timeout} unmatched={unmatched} avg=0.500ms p95={p95} "
        f"p99=2.000ms ringbuf_drop={ringbuf_drop} cache_hit={cache_hit} "
        f"cache_miss={cache_miss} cache_expired=0 cache_tx=0 "
        f"cache_learned=0 learn_rejected=0 pending_expired=0 "
        f"policy_bypass=0 shadow_hit={shadow_hit} shadow_miss={shadow_miss} "
        "alerts=none"
    )


def grpc_line(
    *,
    reqps=50,
    timeout=0,
    unmatched=0,
    ringbuf_drop=0,
    p95="2.500ms",
):
    return (
        f"grpc_metrics dev=tap0 port=50052 reqps={reqps} resps={reqps} "
        f"active_flows=0 pending=0 timeout={timeout} unmatched={unmatched} "
        f"avg=1.000ms p50=1.000ms p95={p95} p99=3.000ms h2_preface=1 "
        f"h2_headers={reqps} h2_data={reqps} h2_end_stream={reqps} "
        f"stream_aware={reqps} ringbuf_drop={ringbuf_drop}"
    )


def fast_line(
    role,
    *,
    accepted=100,
    policy_miss=10,
    response_cache_miss=4,
    cache_hit=70,
    shadow_hit=3,
    shadow_miss=2,
    fallback=12,
    parse_error=0,
    fallback_error=0,
    tx_error=0,
):
    return (
        "grpc_fast_cache listen=127.0.0.1:50053 "
        "backend=127.0.0.1:50052 default_method=/grpc.health.v1.Health/Check "
        f"cache_role={role} accepted={accepted} policy_miss={policy_miss} "
        "policy_bypass=0 runtime_map_error=0 runtime_epoch=1 "
        f"cache_hit={cache_hit} serving_cache_hit={cache_hit} "
        f"not_serving_cache_hit=0 response_cache_miss={response_cache_miss} "
        f"shadow_hit={shadow_hit} shadow_miss={shadow_miss} "
        f"fallback={fallback} parse_error={parse_error} "
        f"fallback_error={fallback_error} tx_error={tx_error}"
    )


def source(name, kind, role, root, *, error_authoritative=True):
    return bridge.SourceConfig(
        name,
        kind,
        role,
        path=root / f"{name}.log",
        error_authoritative=error_authoritative,
    )


def snapshot(name, line, mtime_ns):
    tail = "startup line\n" + line + "\n"
    size = len(tail.encode("utf-8"))
    return bridge.LogSnapshot(
        name,
        f"/var/log/{name}.log",
        mtime_ns,
        size,
        f"{mtime_ns}:{size}",
        tail,
    )


def regenerate(current, mtime_ns):
    return bridge.LogSnapshot(
        current.source_name,
        current.path,
        mtime_ns,
        current.size,
        f"{mtime_ns}:{current.size}",
        current.tail,
    )


def source_set(root):
    return (
        source("dns-client-old", "dns_metrics", "client", root),
        source("dns-client-new", "dns_metrics", "client", root),
        source("dns-server", "dns_metrics", "server", root),
        source("grpc-monitor", "grpc_metrics", "client", root),
        source("grpc-client", "grpc_fast_cache", "client", root),
        source("grpc-server", "grpc_fast_cache", "server", root),
    )


def config(root, sources=None):
    desired = root / "desired-mode.json"
    controller_mode = root / "controller-mode.json"
    executable = root / "dynamic_cache_controller"
    return bridge.BridgeConfig(
        desired_mode_file=desired,
        controller_mode_file=controller_mode,
        controller_command=(
            str(executable),
            "--desired-mode-file",
            str(controller_mode),
            "--initial-mode",
            "bypass",
        ),
        sources=tuple(sources or source_set(root)),
        poll_interval_seconds=1.0,
        source_timeout_seconds=0.1,
        decision_timeout_seconds=0.1,
        stop_timeout_seconds=0.1,
        max_snapshot_age_seconds=5.0,
        max_future_skew_seconds=1.0,
        max_snapshot_bytes=64 * 1024,
    )


class MapReader:
    def __init__(self, values):
        self.values = values

    def read(self, current):
        value = self.values[current.name]
        if isinstance(value, BaseException):
            raise value
        return value


class FakePrepared:
    def __init__(self, sample):
        self.sample = sample
        self.committed = False

    def commit(self):
        self.committed = True


class FakeCollector:
    def __init__(self, outcomes):
        self.outcomes = list(outcomes)
        self.reset_count = 0

    def prepare(self, _now_ns, _elapsed_seconds):
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome

    def reset(self):
        self.reset_count += 1


class FakeController:
    def __init__(
        self,
        controller_mode_file,
        *,
        mode="client",
        startup_mode="bypass",
        staging_mode=None,
        send_error=None,
        alive=True,
        on_staging_write=None,
    ):
        self.controller_mode_file = controller_mode_file
        self.mode = mode
        self.startup_mode = startup_mode
        self.staging_mode = staging_mode
        self.send_error = send_error
        self.is_alive = alive
        self.on_staging_write = on_staging_write
        self.started = False
        self.stopped = False
        self.samples = []

    def start(self):
        self.started = True
        bridge._atomic_write_controller_mode(
            self.controller_mode_file, self.startup_mode
        )

    def alive(self):
        return self.is_alive and not self.stopped

    def send(self, sample):
        self.samples.append(sample)
        bridge._atomic_write_controller_mode(
            self.controller_mode_file, self.staging_mode or self.mode
        )
        if self.on_staging_write is not None:
            self.on_staging_write()
        if self.send_error is not None:
            raise self.send_error
        return bridge.ControllerDecision(sample.timestamp_ms, self.mode)

    def stop(self):
        self.stopped = True


class MetricsParsingTests(unittest.TestCase):
    def test_parses_real_metric_lines_and_converts_latency(self):
        dns = bridge.parse_metric_line(
            "2026-07-30T12:00:00Z " + dns_line("client"),
            "dns_metrics",
            "client",
            "dns",
        )
        grpc = bridge.parse_metric_line(
            grpc_line(p95="350us"), "grpc_metrics", "client", "grpc"
        )
        cache = bridge.parse_metric_line(
            fast_line("server"), "grpc_fast_cache", "server", "cache"
        )

        self.assertEqual(dns["cache_hit"], 10)
        self.assertEqual(dns["p95_us"], 1250.0)
        self.assertEqual(grpc["p95_us"], 350.0)
        self.assertEqual(cache["fallback"], 12)

    def test_role_mismatch_and_malformed_numeric_field_fail(self):
        with self.assertRaisesRegex(bridge.MetricParseError, "role"):
            bridge.parse_metric_line(
                dns_line("server"), "dns_metrics", "client", "dns"
            )
        with self.assertRaisesRegex(bridge.MetricParseError, "cache_hit"):
            bridge.parse_metric_line(
                fast_line("client").replace("cache_hit=70", "cache_hit=-1"),
                "grpc_fast_cache",
                "client",
                "cache",
            )

    def test_metric_sample_is_strict_nine_column_csv(self):
        sample = bridge.MetricSample(1, 2, 3, 4.0, 5, 6, 7.0, 8.0, 0.25)
        fields = sample.to_csv().split(",")
        self.assertEqual(len(fields), 9)
        self.assertEqual(fields, ["1", "2", "3", "4.000000", "5", "6",
                                  "7.000000", "8.000000", "0.250000"])


class CollectorTests(unittest.TestCase):
    def _collector(self, root, values):
        current_config = config(root)
        return bridge.MetricsCollector(current_config, MapReader(values))

    def _initial_values(self):
        return {
            "dns-client-old": snapshot(
                "dns-client-old",
                dns_line("client", cache_hit=99),
                NOW_NS - 2_000_000_000,
            ),
            "dns-client-new": snapshot(
                "dns-client-new",
                dns_line(
                    "client",
                    qps=100,
                    timeout=1,
                    cache_hit=10,
                    cache_miss=4,
                    shadow_hit=2,
                    shadow_miss=1,
                ),
                NOW_NS - 1_000_000_000,
            ),
            "dns-server": snapshot(
                "dns-server",
                dns_line(
                    "server",
                    qps=40,
                    unmatched=1,
                    cache_hit=5,
                    cache_miss=6,
                    shadow_hit=0,
                    shadow_miss=2,
                ),
                NOW_NS - 500_000_000,
            ),
            "grpc-monitor": snapshot(
                "grpc-monitor",
                grpc_line(reqps=50, ringbuf_drop=1),
                NOW_NS - 400_000_000,
            ),
            "grpc-client": snapshot(
                "grpc-client",
                fast_line("client", accepted=100, cache_hit=70),
                NOW_NS - 300_000_000,
            ),
            "grpc-server": snapshot(
                "grpc-server",
                fast_line("server", accepted=80, fallback=12),
                NOW_NS - 200_000_000,
            ),
        }

    def test_selects_latest_source_and_establishes_grpc_baseline(self):
        with tempfile.TemporaryDirectory() as temp:
            values = self._initial_values()
            collector = self._collector(Path(temp), values)
            prepared = collector.prepare(NOW_NS, 2.0)

        self.assertIsNotNone(prepared)
        sample = prepared.sample
        self.assertEqual((sample.dns_hits, sample.dns_misses), (12, 5))
        self.assertEqual((sample.grpc_hits, sample.grpc_misses), (0, 0))
        self.assertEqual(sample.backend_qps, 4.0)
        self.assertEqual(sample.dns_p95_us, 1250.0)
        self.assertEqual(sample.grpc_p95_us, 2500.0)
        self.assertAlmostEqual(sample.error_rate, 3 / 190)

    def test_delta_reset_and_duplicate_generation(self):
        with tempfile.TemporaryDirectory() as temp:
            values = self._initial_values()
            collector = self._collector(Path(temp), values)
            first = collector.prepare(NOW_NS, 1.0)
            first.commit()
            self.assertIsNone(collector.prepare(NOW_NS + 100_000_000, 0.1))

            values["grpc-client"] = snapshot(
                "grpc-client",
                fast_line(
                    "client",
                    accepted=125,
                    policy_miss=13,
                    response_cache_miss=6,
                    cache_hit=80,
                    shadow_hit=5,
                    shadow_miss=3,
                    fallback_error=2,
                    tx_error=1,
                ),
                NOW_NS + 100_000_000,
            )
            self.assertIsNone(
                collector.prepare(NOW_NS + 150_000_000, 0.15)
            )
            for name, current in tuple(values.items()):
                if name != "grpc-client":
                    values[name] = regenerate(current, NOW_NS + 100_000_000)
            values["grpc-server"] = snapshot(
                "grpc-server",
                fast_line("server", accepted=90, fallback=18),
                NOW_NS + 100_000_000,
            )
            second = collector.prepare(NOW_NS + 200_000_000, 2.0)
            self.assertEqual(
                (second.sample.grpc_hits, second.sample.grpc_misses), (12, 6)
            )
            self.assertEqual(second.sample.backend_qps, 7.0)
            second.commit()

            for name, current in tuple(values.items()):
                values[name] = regenerate(current, NOW_NS + 300_000_000)
            values["grpc-client"] = snapshot(
                "grpc-client",
                fast_line(
                    "client",
                    accepted=4,
                    policy_miss=1,
                    response_cache_miss=1,
                    cache_hit=3,
                    shadow_hit=1,
                    shadow_miss=1,
                ),
                NOW_NS + 300_000_000,
            )
            values["grpc-server"] = snapshot(
                "grpc-server",
                fast_line("server", accepted=3, fallback=2),
                NOW_NS + 300_000_000,
            )
            reset = collector.prepare(NOW_NS + 400_000_000, 1.0)

        self.assertEqual((reset.sample.grpc_hits, reset.sample.grpc_misses), (4, 3))
        self.assertEqual(reset.sample.backend_qps, 10.0)

    def test_parse_fallback_noise_does_not_raise_error_rate(self):
        with tempfile.TemporaryDirectory() as temp:
            values = self._initial_values()
            collector = self._collector(Path(temp), values)
            first = collector.prepare(NOW_NS, 1.0)
            first.commit()

            for name, current in tuple(values.items()):
                values[name] = regenerate(current, NOW_NS + 1_000_000_000)
            values["dns-client-new"] = snapshot(
                "dns-client-new",
                dns_line("client", timeout=0, unmatched=0, ringbuf_drop=0),
                NOW_NS + 1_000_000_000,
            )
            values["dns-server"] = snapshot(
                "dns-server",
                dns_line("server", qps=40, timeout=0, unmatched=0, ringbuf_drop=0),
                NOW_NS + 1_000_000_000,
            )
            values["grpc-monitor"] = snapshot(
                "grpc-monitor",
                grpc_line(reqps=50, timeout=0, unmatched=0, ringbuf_drop=0),
                NOW_NS + 1_000_000_000,
            )
            values["grpc-client"] = snapshot(
                "grpc-client",
                fast_line(
                    "client",
                    accepted=140,
                    cache_hit=70,
                    shadow_hit=43,
                    fallback=140,
                    parse_error=0,
                    fallback_error=0,
                ),
                NOW_NS + 1_000_000_000,
            )
            values["grpc-server"] = snapshot(
                "grpc-server",
                fast_line(
                    "server",
                    accepted=140,
                    cache_hit=70,
                    shadow_hit=43,
                    fallback=140,
                    parse_error=17,
                    fallback_error=17,
                ),
                NOW_NS + 1_000_000_000,
            )
            prepared = collector.prepare(NOW_NS + 1_000_000_000, 1.0)

        self.assertIsNotNone(prepared)
        self.assertEqual(prepared.sample.error_rate, 0.0)

    def test_real_fallback_error_remains_in_error_rate(self):
        with tempfile.TemporaryDirectory() as temp:
            values = self._initial_values()
            collector = self._collector(Path(temp), values)
            first = collector.prepare(NOW_NS, 1.0)
            first.commit()

            for name, current in tuple(values.items()):
                values[name] = regenerate(current, NOW_NS + 1_000_000_000)
            values["dns-client-new"] = snapshot(
                "dns-client-new",
                dns_line("client", timeout=0, unmatched=0, ringbuf_drop=0),
                NOW_NS + 1_000_000_000,
            )
            values["dns-server"] = snapshot(
                "dns-server",
                dns_line("server", qps=40, timeout=0, unmatched=0, ringbuf_drop=0),
                NOW_NS + 1_000_000_000,
            )
            values["grpc-monitor"] = snapshot(
                "grpc-monitor",
                grpc_line(reqps=50, timeout=0, unmatched=0, ringbuf_drop=0),
                NOW_NS + 1_000_000_000,
            )
            values["grpc-client"] = snapshot(
                "grpc-client",
                fast_line(
                    "client",
                    accepted=140,
                    cache_hit=70,
                    shadow_hit=43,
                    fallback=140,
                ),
                NOW_NS + 1_000_000_000,
            )
            values["grpc-server"] = snapshot(
                "grpc-server",
                fast_line(
                    "server",
                    accepted=140,
                    cache_hit=70,
                    shadow_hit=43,
                    fallback=140,
                    parse_error=17,
                    fallback_error=18,
                ),
                NOW_NS + 1_000_000_000,
            )
            prepared = collector.prepare(NOW_NS + 1_000_000_000, 1.0)

        self.assertIsNotNone(prepared)
        self.assertAlmostEqual(prepared.sample.error_rate, 1 / 290)

    def test_observer_timeout_does_not_override_guest_cache_success(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            values = self._initial_values()
            sources = list(source_set(root))
            sources[3] = source(
                "grpc-monitor",
                "grpc_metrics",
                "client",
                root,
                error_authoritative=False,
            )
            collector = bridge.MetricsCollector(
                config(root, sources=sources), MapReader(values)
            )
            first = collector.prepare(NOW_NS, 1.0)
            first.commit()

            for name, current in tuple(values.items()):
                values[name] = regenerate(current, NOW_NS + 1_000_000_000)
            values["dns-client-new"] = snapshot(
                "dns-client-new",
                dns_line("client", timeout=0, unmatched=0, ringbuf_drop=0),
                NOW_NS + 1_000_000_000,
            )
            values["dns-server"] = snapshot(
                "dns-server",
                dns_line("server", qps=40, timeout=0, unmatched=0, ringbuf_drop=0),
                NOW_NS + 1_000_000_000,
            )
            values["grpc-monitor"] = snapshot(
                "grpc-monitor",
                grpc_line(reqps=0, timeout=9, unmatched=7, ringbuf_drop=2),
                NOW_NS + 1_000_000_000,
            )
            values["grpc-client"] = snapshot(
                "grpc-client",
                fast_line("client", accepted=140, shadow_hit=43, fallback=140),
                NOW_NS + 1_000_000_000,
            )
            values["grpc-server"] = snapshot(
                "grpc-server",
                fast_line("server", accepted=140, shadow_hit=43, fallback=140),
                NOW_NS + 1_000_000_000,
            )
            prepared = collector.prepare(NOW_NS + 1_000_000_000, 1.0)

        self.assertIsNotNone(prepared)
        self.assertEqual(prepared.sample.error_rate, 0.0)

    def test_observer_traffic_does_not_dilute_authoritative_error_rate(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            values = self._initial_values()
            sources = list(source_set(root))
            sources[3] = source(
                "grpc-monitor",
                "grpc_metrics",
                "client",
                root,
                error_authoritative=False,
            )
            collector = bridge.MetricsCollector(
                config(root, sources=sources), MapReader(values)
            )
            first = collector.prepare(NOW_NS, 1.0)
            first.commit()

            for name, current in tuple(values.items()):
                values[name] = regenerate(current, NOW_NS + 1_000_000_000)
            values["dns-client-old"] = regenerate(
                values["dns-client-old"], NOW_NS + 900_000_000
            )
            values["dns-client-new"] = snapshot(
                "dns-client-new",
                dns_line(
                    "client", qps=100, timeout=1, unmatched=0, ringbuf_drop=0
                ),
                NOW_NS + 1_000_000_000,
            )
            values["dns-server"] = snapshot(
                "dns-server",
                dns_line("server", qps=40, timeout=0, unmatched=0, ringbuf_drop=0),
                NOW_NS + 1_000_000_000,
            )
            values["grpc-monitor"] = snapshot(
                "grpc-monitor",
                grpc_line(reqps=1000, timeout=0, unmatched=0, ringbuf_drop=0),
                NOW_NS + 1_000_000_000,
            )
            values["grpc-client"] = snapshot(
                "grpc-client",
                fast_line("client", accepted=140),
                NOW_NS + 1_000_000_000,
            )
            values["grpc-server"] = snapshot(
                "grpc-server",
                fast_line("server", accepted=140),
                NOW_NS + 1_000_000_000,
            )
            prepared = collector.prepare(NOW_NS + 1_000_000_000, 1.0)

        self.assertIsNotNone(prepared)
        self.assertAlmostEqual(prepared.sample.error_rate, 1 / 240)

    def test_stale_group_fails_even_when_other_groups_are_fresh(self):
        with tempfile.TemporaryDirectory() as temp:
            values = self._initial_values()
            values["dns-server"] = snapshot(
                "dns-server", dns_line("server"), NOW_NS - 10_000_000_000
            )
            collector = self._collector(Path(temp), values)
            with self.assertRaisesRegex(bridge.SnapshotError, "dns_metrics/server"):
                collector.prepare(NOW_NS, 1.0)


class ConfigAndSnapshotTests(unittest.TestCase):
    def _config_value(self, root):
        current = config(root)
        return {
            "schema_version": 1,
            "desired_mode_file": str(current.desired_mode_file),
            "controller_mode_file": str(current.controller_mode_file),
            "controller_command": list(current.controller_command),
            "sources": [
                {
                    "name": item.name,
                    "kind": item.kind,
                    "role": item.role,
                    "path": str(item.path),
                }
                for item in current.sources
            ],
        }

    def test_config_is_strict_and_controller_path_must_match(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            config_path = root / "bridge.json"
            value = self._config_value(root)
            config_path.write_text(json.dumps(value), encoding="utf-8")
            loaded = bridge.load_config(config_path)
            self.assertEqual(loaded.desired_mode_file, root / "desired-mode.json")
            self.assertEqual(
                loaded.controller_mode_file, root / "controller-mode.json"
            )

            value["unknown"] = True
            config_path.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(bridge.ConfigError, "unknown"):
                bridge.load_config(config_path)

            value.pop("unknown")
            value["sources"][0]["error_authoritative"] = "false"
            config_path.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(bridge.ConfigError, "boolean"):
                bridge.load_config(config_path)

            value["sources"][0].pop("error_authoritative")
            value["controller_command"][2] = str(root / "other.json")
            config_path.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(bridge.ConfigError, "must match"):
                bridge.load_config(config_path)

            value["controller_mode_file"] = value["desired_mode_file"]
            value["controller_command"][2] = value["desired_mode_file"]
            config_path.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(bridge.ConfigError, "must differ"):
                bridge.load_config(config_path)

    def test_repository_example_has_no_secret_and_loads_strictly(self):
        example = (
            LINUX_ACCEL / "deploy" / "examples" / "metrics-bridge.json.example"
        )
        text = example.read_text(encoding="utf-8")
        self.assertNotIn("password", text.lower())
        loaded = bridge.load_config(example)
        self.assertEqual(len(loaded.sources), 9)
        self.assertIn("master", text)
        self.assertIn("compute2", text)
        self.assertIn("CLIENT_GUEST", text)
        self.assertIn("SERVER_GUEST", text)
        desired_index = loaded.controller_command.index("--desired-mode-file")
        self.assertTrue(
            bridge._same_path(
                loaded.controller_command[desired_index + 1],
                loaded.controller_mode_file,
            )
        )
        self.assertNotEqual(
            loaded.controller_mode_file, loaded.desired_mode_file
        )
        remote_sources = [source for source in loaded.sources if source.command]
        self.assertEqual(len(remote_sources), 6)
        grpc_observers = [
            source
            for source in loaded.sources
            if source.kind == "grpc_metrics"
        ]
        self.assertTrue(grpc_observers)
        self.assertTrue(all(not source.error_authoritative for source in grpc_observers))
        server_dns_observers = [
            source
            for source in loaded.sources
            if source.kind == "dns_metrics" and source.role == "server"
        ]
        self.assertTrue(server_dns_observers)
        self.assertTrue(
            all(not source.error_authoritative for source in server_dns_observers)
        )
        for source in remote_sources:
            python_index = source.command.index("/usr/bin/python3")
            self.assertEqual(
                source.command[python_index - 2 : python_index],
                ("/usr/bin/sudo", "-n"),
                source.name,
            )
        service = (
            LINUX_ACCEL
            / "deploy"
            / "systemd"
            / "vnet-dataplane-metrics-controller.service"
        ).read_text(encoding="utf-8")
        self.assertIn("RuntimeDirectoryMode=0700", service)
        self.assertIn("Restart=always", service)

    def test_lab_sudoers_limits_snapshot_roots_and_omits_cachectl(self):
        sudoers = (
            LINUX_ACCEL
            / "deploy"
            / "lab"
            / "shuka1-p1"
            / "vnet-dataplane.sudoers"
        ).read_text(encoding="utf-8")

        self.assertNotIn("cachectl", sudoers)
        self.assertNotIn("snapshot-log *", sudoers)
        self.assertIn(
            "snapshot-log --path /var/log/vnet-dataplane-agent/* "
            "--max-bytes 262144",
            sudoers,
        )
        self.assertIn(
            "snapshot-log --path /var/log/vnet-dataplane-guest/* "
            "--max-bytes 262144",
            sudoers,
        )

    def test_snapshot_reader_returns_bounded_structured_json_inside_allowed_root(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            path = root / "monitor.log"
            path.write_text("old\n" + dns_line("client") + "\n", encoding="utf-8")
            snapshot = bridge.read_log_snapshot(
                path, 65536, allowed_roots=(root,)
            )

        value = bridge.snapshot_payload(snapshot)
        self.assertEqual(value["schema_version"], 1)
        self.assertEqual(
            value["generation"], f"{value['mtime_ns']}:{value['size']}"
        )
        self.assertIn("dns_metrics", value["tail"])

    def test_snapshot_log_cli_rejects_path_outside_production_log_roots(self):
        with tempfile.TemporaryDirectory() as temp:
            path = (Path(temp) / "monitor.log").resolve()
            path.write_text(dns_line("client") + "\n", encoding="utf-8")
            for rejected in (str(path), "/etc/shadow"):
                with self.subTest(path=rejected):
                    result = subprocess.run(
                        [
                            sys.executable,
                            str(SCRIPT),
                            "snapshot-log",
                            "--path",
                            rejected,
                        ],
                        check=False,
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )

                    self.assertNotEqual(result.returncode, 0)
                    self.assertRegex(
                        result.stderr,
                        r"(outside allowed log roots|must be absolute)",
                    )

    def test_snapshot_log_rejects_relative_and_non_regular_paths(self):
        with self.assertRaisesRegex(bridge.SnapshotError, "absolute"):
            bridge.read_log_snapshot(Path("relative.log"), 1024)
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(bridge.SnapshotError, "regular"):
                root = Path(temp).resolve()
                bridge.read_log_snapshot(root, 1024, allowed_roots=(root.parent,))

    def test_snapshot_reader_rejects_symlinked_parent_below_allowed_root(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp).resolve()
            root = base / "allowed"
            nested = root / "port"
            outside = base / "outside"
            nested.mkdir(parents=True)
            outside.mkdir()
            (outside / "monitor.log").write_text(
                dns_line("client") + "\n", encoding="utf-8"
            )
            link = nested / "escape"
            try:
                link.symlink_to(outside, target_is_directory=True)
            except OSError as error:
                self.skipTest(f"directory symlinks unavailable: {error}")

            with self.assertRaisesRegex(bridge.SnapshotError, "symlink"):
                bridge.read_log_snapshot(
                    link / "monitor.log", 1024, allowed_roots=(root,)
                )

    def test_snapshot_reader_checks_each_nested_parent_for_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            port = root / "port-id"
            escape = port / "escape"
            path = escape / "monitor.log"
            modes = {
                root: stat.S_IFDIR | 0o750,
                port: stat.S_IFDIR | 0o750,
                escape: stat.S_IFLNK | 0o777,
            }

            def fake_lstat(candidate):
                candidate = Path(candidate)
                if candidate not in modes:
                    raise FileNotFoundError(candidate)
                return mock.Mock(st_mode=modes[candidate])

            with (
                mock.patch.object(bridge.os, "lstat", side_effect=fake_lstat),
                self.assertRaisesRegex(bridge.SnapshotError, "symlink"),
            ):
                bridge.read_log_snapshot(path, 1024, allowed_roots=(root,))

    def test_remote_command_is_argv_without_shell_and_has_hard_timeout(self):
        current = bridge.SourceConfig(
            "remote",
            "grpc_metrics",
            "client",
            command=("/usr/bin/ssh", "REPLACE_HOST", "snapshot-log"),
        )
        runner = mock.Mock(
            side_effect=subprocess.TimeoutExpired(["ssh"], timeout=0.25)
        )
        reader = bridge.SnapshotReader(0.25, 1024, run_command=runner)
        with self.assertRaisesRegex(bridge.SnapshotError, "timed out"):
            reader.read(current)
        kwargs = runner.call_args.kwargs
        self.assertIs(kwargs["shell"], False)
        self.assertEqual(kwargs["timeout"], 0.25)
        self.assertIsInstance(runner.call_args.args[0], list)

    def test_direct_script_help_and_package_import(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--help"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("snapshot-log", result.stdout)
        self.assertTrue(callable(bridge.main))


class ControllerAndFailSafeTests(unittest.TestCase):
    def _sample(self, timestamp_ms=1234):
        return bridge.MetricSample(timestamp_ms, 1, 2, 3.0, 4, 5, 6.0, 7.0, 0.0)

    def test_atomic_bypass_contains_heartbeat_and_leaves_no_temp_file(self):
        with tempfile.TemporaryDirectory() as temp:
            path = (Path(temp) / "desired.json").resolve()
            controller_path = (Path(temp) / "controller.json").resolve()
            bridge._atomic_write_mode(path, "dual", 10)
            bridge._atomic_write_controller_mode(controller_path, "server")
            bridge.write_bypass(path, 20)
            value = json.loads(path.read_text(encoding="utf-8"))
            controller_value = json.loads(
                controller_path.read_text(encoding="utf-8")
            )
            verified_controller_mode = bridge.read_controller_mode(
                controller_path, "server"
            )
            temporary = list(path.parent.glob(f".{path.name}.*.tmp"))

        self.assertEqual(
            value,
            {"schema_version": 1, "mode": "bypass", "updated_ms": 20},
        )
        self.assertEqual(
            controller_value, {"schema_version": 1, "mode": "server"}
        )
        self.assertEqual(verified_controller_mode, "server")
        self.assertEqual(temporary, [])

    def test_controller_session_uses_pipes_and_validates_correlated_decision(self):
        calls = []

        class FakeProcess:
            def __init__(self):
                self.stdin = io.StringIO()
                self.stdout = io.StringIO(
                    "dynamic_cache_decision timestamp_ms=1234 mode=CLIENT_CACHE "
                    "candidate=CLIENT_CACHE epoch=2 window_ready=1 changed=1 "
                    "publish_failed=0 hit_ratio=0.5 p95_us=1 backend_qps=2 "
                    "error_rate=0 reason=test\n"
                )
                self.returncode = None

            def poll(self):
                return self.returncode

            def terminate(self):
                self.returncode = 0

            def kill(self):
                self.returncode = -9

            def wait(self, timeout=None):
                self.returncode = 0
                return 0

        def popen(argv, **kwargs):
            calls.append((argv, kwargs))
            return FakeProcess()

        session = bridge.ControllerSession(
            ["/opt/vnet/dynamic_cache_controller"],
            0.5,
            0.5,
            popen_factory=popen,
        )
        session.start()
        decision = session.send(self._sample())
        session.stop()

        self.assertEqual(decision.mode, "client")
        self.assertIsInstance(calls[0][0], list)
        self.assertIs(calls[0][1]["shell"], False)
        self.assertIs(calls[0][1]["stdin"], subprocess.PIPE)
        self.assertIs(calls[0][1]["stdout"], subprocess.PIPE)

    def test_mismatched_or_failed_decision_is_rejected(self):
        with self.assertRaisesRegex(bridge.ControllerError, "mismatch"):
            bridge.parse_controller_decision(
                "dynamic_cache_decision timestamp_ms=2 mode=BYPASS publish_failed=0",
                1,
            )
        with self.assertRaisesRegex(bridge.ControllerError, "publication"):
            bridge.parse_controller_decision(
                "dynamic_cache_decision timestamp_ms=1 mode=BYPASS publish_failed=1",
                1,
            )

    def test_source_error_writes_bypass_stops_controller_and_recovers(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            prepared = FakePrepared(self._sample(2000))
            collector = FakeCollector(
                [bridge.SnapshotError("stale source"), prepared]
            )
            current_config = config(root)
            authoritative_during_staging = []

            def observe_authoritative():
                authoritative_during_staging.append(
                    json.loads(
                        current_config.desired_mode_file.read_text(
                            encoding="utf-8"
                        )
                    )
                )

            controllers = [
                FakeController(current_config.controller_mode_file),
                FakeController(
                    current_config.controller_mode_file,
                    mode="dual",
                    on_staging_write=observe_authoritative,
                ),
            ]
            service = bridge.MetricsBridge(
                current_config,
                collector=collector,
                controller_factory=lambda: controllers.pop(0),
                wall_time_ns=lambda: NOW_NS,
                monotonic=lambda: 100.0,
            )
            service.start()
            first_controller = service._controller
            self.assertFalse(
                service.poll_once(now_ns=NOW_NS, elapsed_seconds=1.0)
            )
            bypass = json.loads(
                current_config.desired_mode_file.read_text(encoding="utf-8")
            )
            self.assertTrue(first_controller.stopped)
            self.assertEqual(bypass["mode"], "bypass")
            self.assertEqual(bypass["updated_ms"], NOW_NS // 1_000_000)

            self.assertTrue(
                service.poll_once(now_ns=NOW_NS, elapsed_seconds=1.0)
            )
            heartbeat = json.loads(
                current_config.desired_mode_file.read_text(encoding="utf-8")
            )
            staging_heartbeat = json.loads(
                current_config.controller_mode_file.read_text(
                    encoding="utf-8"
                )
            )
            service.stop()
            stopped = json.loads(
                current_config.desired_mode_file.read_text(encoding="utf-8")
            )

        self.assertTrue(prepared.committed)
        self.assertEqual(heartbeat["mode"], "dual")
        self.assertEqual(heartbeat["updated_ms"], NOW_NS // 1_000_000)
        self.assertEqual(
            staging_heartbeat, {"schema_version": 1, "mode": "dual"}
        )
        self.assertEqual(authoritative_during_staging[0]["mode"], "bypass")
        self.assertEqual(stopped["mode"], "bypass")
        self.assertEqual(stopped["updated_ms"], NOW_NS // 1_000_000)

    def test_controller_exit_and_no_response_force_bypass(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            current_config = config(root)
            dead = FakeController(
                current_config.controller_mode_file, alive=False
            )
            service = bridge.MetricsBridge(
                current_config,
                collector=FakeCollector([None]),
                controller_factory=lambda: dead,
                wall_time_ns=lambda: NOW_NS,
                monotonic=lambda: 100.0,
            )
            service.start()
            with self.assertRaisesRegex(bridge.ControllerError, "exited"):
                service.poll_once(now_ns=NOW_NS, elapsed_seconds=1.0)
            value = json.loads(
                current_config.desired_mode_file.read_text(encoding="utf-8")
            )
            self.assertEqual(value["mode"], "bypass")

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            prepared = FakePrepared(self._sample())
            current_config = config(root)
            silent = FakeController(
                current_config.controller_mode_file,
                send_error=bridge.ControllerError("decision timed out")
            )
            service = bridge.MetricsBridge(
                current_config,
                collector=FakeCollector([prepared]),
                controller_factory=lambda: silent,
                wall_time_ns=lambda: NOW_NS,
                monotonic=lambda: 100.0,
            )
            service.start()
            with self.assertRaisesRegex(bridge.ControllerError, "timed out"):
                service.poll_once(now_ns=NOW_NS, elapsed_seconds=1.0)
            value = json.loads(
                service._config.desired_mode_file.read_text(encoding="utf-8")
            )

        self.assertTrue(silent.stopped)
        self.assertFalse(prepared.committed)
        self.assertEqual(value["mode"], "bypass")

    def test_staging_mismatch_never_reaches_authoritative_mode(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            current_config = config(root)
            prepared = FakePrepared(self._sample())
            observed = []

            def observe_authoritative():
                observed.append(
                    json.loads(
                        current_config.desired_mode_file.read_text(
                            encoding="utf-8"
                        )
                    )
                )

            controller = FakeController(
                current_config.controller_mode_file,
                mode="dual",
                staging_mode="server",
                on_staging_write=observe_authoritative,
            )
            service = bridge.MetricsBridge(
                current_config,
                collector=FakeCollector([prepared]),
                controller_factory=lambda: controller,
                wall_time_ns=lambda: NOW_NS,
                monotonic=lambda: 100.0,
            )
            service.start()
            with self.assertRaisesRegex(
                bridge.ControllerError, "controller mode mismatch"
            ):
                service.poll_once(now_ns=NOW_NS, elapsed_seconds=1.0)
            authoritative = json.loads(
                current_config.desired_mode_file.read_text(encoding="utf-8")
            )
            staging = json.loads(
                current_config.controller_mode_file.read_text(encoding="utf-8")
            )

        self.assertEqual(observed[0]["mode"], "bypass")
        self.assertEqual(authoritative["mode"], "bypass")
        self.assertEqual(staging, {"schema_version": 1, "mode": "bypass"})
        self.assertTrue(controller.stopped)
        self.assertFalse(prepared.committed)

    def test_invalid_controller_startup_mode_fails_safe(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            current_config = config(root)
            controller = FakeController(
                current_config.controller_mode_file,
                startup_mode="dual",
            )
            service = bridge.MetricsBridge(
                current_config,
                collector=FakeCollector([None]),
                controller_factory=lambda: controller,
                wall_time_ns=lambda: NOW_NS,
                monotonic=lambda: 100.0,
            )
            with self.assertRaisesRegex(
                bridge.ControllerError, "controller mode mismatch"
            ):
                service.start()
            authoritative = json.loads(
                current_config.desired_mode_file.read_text(encoding="utf-8")
            )
            staging = json.loads(
                current_config.controller_mode_file.read_text(encoding="utf-8")
            )

        self.assertEqual(authoritative["mode"], "bypass")
        self.assertEqual(staging, {"schema_version": 1, "mode": "bypass"})
        self.assertTrue(controller.stopped)


if __name__ == "__main__":
    unittest.main()
