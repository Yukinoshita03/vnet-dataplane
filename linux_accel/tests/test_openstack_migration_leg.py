import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "bench" / "openstack_migration_leg.py"


def load_module():
    spec = importlib.util.spec_from_file_location("openstack_migration_leg", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class OpenStackMigrationLegCliTest(unittest.TestCase):
    def run_cli(
        self,
        module,
        evidence_dir,
        runner,
        *,
        phase="forward",
        source_host="master",
        target_host="compute2",
    ):
        stdout = io.StringIO()
        argv = [
            "--phase",
            phase,
            "--server-id",
            "server-1",
            "--port-id",
            "port-1",
            "--source-host",
            source_host,
            "--target-host",
            target_host,
            "--evidence-dir",
            str(evidence_dir),
            "--openstack-bin",
            "openstack",
            "--api-version",
            "2.30",
            "--timeout",
            "5",
            "--poll",
            "0.01",
        ]
        with mock.patch.object(module.subprocess, "run", side_effect=runner):
            with contextlib.redirect_stdout(stdout):
                returncode = module.main(argv)
        lines = stdout.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        return returncode, json.loads(lines[0])

    def test_forward_leg_completes_only_after_new_migration_and_placement_converge(self):
        module = load_module()
        commands = []
        migration_lists = 0
        server_shows = 0
        port_shows = 0

        def runner(args, **kwargs):
            nonlocal migration_lists, server_shows, port_shows
            commands.append(list(args))
            command = list(args)
            if command[3:6] == ["server", "migration", "list"]:
                migration_lists += 1
                migrations = [
                    {
                        "ID": 7,
                        "Type": "live-migration",
                        "Source Node": "master",
                        "Dest Node": "compute2",
                        "Status": "completed",
                    }
                ]
                if migration_lists > 1:
                    migrations.append(
                        {
                            "ID": 8,
                            "Type": "live-migration",
                            "Source Node": "master",
                            "Dest Node": "compute2",
                            "Status": "completed",
                        }
                    )
                return subprocess.CompletedProcess(command, 0, json.dumps(migrations), "")
            if command[3:5] == ["server", "show"]:
                server_shows += 1
                host = "master" if server_shows == 1 else "compute2"
                value = {"status": "ACTIVE", "OS-EXT-SRV-ATTR:host": host}
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:5] == ["port", "show"]:
                port_shows += 1
                host = "master" if port_shows == 1 else "compute2"
                value = {"status": "ACTIVE", "binding_host_id": host}
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:5] == ["server", "migrate"]:
                return subprocess.CompletedProcess(command, 0, "", "")
            raise AssertionError(f"unexpected command: {command}")

        with tempfile.TemporaryDirectory() as tmp:
            returncode, summary = self.run_cli(module, Path(tmp), runner)
            evidence = [json.loads(line) for line in (Path(tmp) / "events.jsonl").read_text().splitlines()]

        self.assertEqual(returncode, 0)
        self.assertEqual(summary["schema"], 1)
        self.assertEqual(summary["outcome"], "completed")
        self.assertEqual(summary["status"], "completed")
        self.assertEqual(summary["final_host"], "compute2")
        self.assertEqual(summary["migration_id"], "8")
        self.assertEqual(summary["source_host"], "master")
        self.assertEqual(summary["target_host"], "compute2")
        baseline = next(record for record in evidence if record["event"] == "migration_baseline")
        self.assertEqual(baseline["migration_ids"], ["7"])
        self.assertTrue(any(record["event"] == "migration_completed" for record in evidence))
        migrate = next(command for command in commands if command[3:5] == ["server", "migrate"])
        self.assertIn("--live-migration", migrate)
        self.assertIn("--block-migration", migrate)
        self.assertNotIn("--wait", migrate)
        self.assertEqual(migrate[migrate.index("--host") + 1], "compute2")
        self.assertFalse(any(command[3:6] == ["server", "migration", "show"] for command in commands))

    def test_restore_is_idempotent_when_server_and_port_are_already_on_target(self):
        module = load_module()
        commands = []

        def runner(args, **kwargs):
            command = list(args)
            commands.append(command)
            if command[3:5] == ["server", "show"]:
                value = {"status": "ACTIVE", "OS-EXT-SRV-ATTR:host": "master"}
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:5] == ["port", "show"]:
                value = {"status": "ACTIVE", "binding:host_id": "master"}
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:6] == ["server", "migration", "list"]:
                return subprocess.CompletedProcess(command, 0, "[]", "")
            raise AssertionError(f"restore should not run: {command}")

        with tempfile.TemporaryDirectory() as tmp:
            stdout = io.StringIO()
            argv = [
                "--phase", "restore",
                "--server-id", "server-1",
                "--port-id", "port-1",
                "--source-host", "compute2",
                "--target-host", "master",
                "--evidence-dir", tmp,
                "--timeout", "5",
                "--poll", "0.01",
            ]
            with mock.patch.object(module.subprocess, "run", side_effect=runner):
                with contextlib.redirect_stdout(stdout):
                    returncode = module.main(argv)
            summary = json.loads(stdout.getvalue())

        self.assertEqual(returncode, 0)
        self.assertEqual(summary["outcome"], "already_on_target")
        self.assertEqual(summary["status"], "completed")
        self.assertEqual(summary["final_host"], "master")
        self.assertIsNone(summary["migration_id"])
        self.assertFalse(any(command[3:5] == ["server", "migrate"] for command in commands))

    def test_restore_reconciles_stale_requested_source_from_live_placement(self):
        module = load_module()
        migration_lists = 0
        server_shows = 0
        port_shows = 0
        migrate_started = False
        commands = []

        def runner(args, **kwargs):
            nonlocal migration_lists, server_shows, port_shows, migrate_started
            command = list(args)
            commands.append(command)
            if command[3:5] == ["server", "show"]:
                server_shows += 1
                host = "master" if migrate_started else "compute2"
                value = {"status": "ACTIVE", "OS-EXT-SRV-ATTR:host": host}
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:5] == ["port", "show"]:
                port_shows += 1
                host = "master" if migrate_started else "compute2"
                value = {"status": "ACTIVE", "binding:host_id": host}
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:6] == ["server", "migration", "list"]:
                migration_lists += 1
                value = [
                    {
                        "ID": 11,
                        "Type": "live-migration",
                        "Source Node": "master",
                        "Dest Node": "compute2",
                        "Status": "completed",
                    }
                ]
                if migrate_started:
                    value.append(
                        {
                            "ID": 12,
                            "Type": "live-migration",
                            "Source Node": "compute2",
                            "Dest Node": "master",
                            "Status": "completed",
                        }
                    )
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:5] == ["server", "migrate"]:
                migrate_started = True
                return subprocess.CompletedProcess(command, 0, "", "")
            raise AssertionError(f"unexpected command: {command}")

        with tempfile.TemporaryDirectory() as tmp:
            returncode, summary = self.run_cli(
                module,
                Path(tmp),
                runner,
                phase="restore",
                source_host="master",
                target_host="master",
            )
            evidence = [
                json.loads(line)
                for line in (Path(tmp) / "events.jsonl").read_text().splitlines()
            ]

        self.assertEqual(returncode, 0)
        self.assertEqual(summary["source_host"], "compute2")
        self.assertEqual(summary["requested_source_host"], "master")
        self.assertEqual(summary["final_host"], "master")
        self.assertTrue(
            any(record["event"] == "restore_source_reconciled" for record in evidence)
        )
        migrate = next(command for command in commands if command[3:5] == ["server", "migrate"])
        self.assertEqual(migrate[migrate.index("--host") + 1], "master")

    def test_restore_waits_out_inflight_leg_before_deciding_it_is_on_target(self):
        module = load_module()
        migration_lists = 0
        server_shows = 0
        port_shows = 0
        migrate_started = False

        def runner(args, **kwargs):
            nonlocal migration_lists, server_shows, port_shows, migrate_started
            command = list(args)
            if command[3:6] == ["server", "migration", "list"]:
                migration_lists += 1
                value = [
                    {
                        "ID": 20,
                        "Type": "live-migration",
                        "Source Node": "master",
                        "Dest Node": "compute2",
                        "Status": "running" if migration_lists == 1 else "completed",
                    }
                ]
                if migrate_started:
                    value.append(
                        {
                            "ID": 21,
                            "Type": "live-migration",
                            "Source Node": "compute2",
                            "Dest Node": "master",
                            "Status": "completed",
                        }
                    )
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:5] == ["server", "show"]:
                server_shows += 1
                if migrate_started:
                    host = "master"
                else:
                    host = "master" if server_shows == 1 else "compute2"
                value = {"status": "ACTIVE", "OS-EXT-SRV-ATTR:host": host}
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:5] == ["port", "show"]:
                port_shows += 1
                if migrate_started:
                    host = "master"
                else:
                    host = "master" if port_shows == 1 else "compute2"
                value = {"status": "ACTIVE", "binding:host_id": host}
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:5] == ["server", "migrate"]:
                migrate_started = True
                return subprocess.CompletedProcess(command, 0, "", "")
            raise AssertionError(f"unexpected command: {command}")

        with tempfile.TemporaryDirectory() as tmp:
            returncode, summary = self.run_cli(
                module,
                Path(tmp),
                runner,
                phase="restore",
                source_host="master",
                target_host="master",
            )
            evidence = [
                json.loads(line)
                for line in (Path(tmp) / "events.jsonl").read_text().splitlines()
            ]

        self.assertEqual(returncode, 0)
        self.assertEqual(summary["outcome"], "completed")
        self.assertEqual(summary["source_host"], "compute2")
        self.assertEqual(summary["final_host"], "master")
        self.assertEqual(summary["migration_id"], "21")
        waits = [
            record
            for record in evidence
            if record["event"] == "restore_placement_observation"
        ]
        self.assertTrue(waits[0]["live_migration_in_flight"])
        self.assertGreaterEqual(len(waits), 3)

    def test_reverse_phase_is_supported_and_proves_target_placement(self):
        module = load_module()
        migration_lists = 0
        server_shows = 0
        port_shows = 0

        def runner(args, **kwargs):
            nonlocal migration_lists, server_shows, port_shows
            command = list(args)
            if command[3:6] == ["server", "migration", "list"]:
                migration_lists += 1
                migrations = []
                if migration_lists > 1:
                    migrations.append(
                        {
                            "ID": 9,
                            "Type": "live-migration",
                            "Source Node": "compute2",
                            "Dest Node": "master",
                            "Status": "completed",
                        }
                    )
                return subprocess.CompletedProcess(command, 0, json.dumps(migrations), "")
            if command[3:5] == ["server", "show"]:
                server_shows += 1
                host = "compute2" if server_shows == 1 else "master"
                value = {"status": "ACTIVE", "OS-EXT-SRV-ATTR:host": host}
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:5] == ["port", "show"]:
                port_shows += 1
                host = "compute2" if port_shows == 1 else "master"
                value = {"status": "ACTIVE", "binding:host_id": host}
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:5] == ["server", "migrate"]:
                return subprocess.CompletedProcess(command, 0, "", "")
            raise AssertionError(f"unexpected command: {command}")

        with tempfile.TemporaryDirectory() as tmp:
            returncode, summary = self.run_cli(
                module,
                Path(tmp),
                runner,
                phase="reverse",
                source_host="compute2",
                target_host="master",
            )

        self.assertEqual(returncode, 0)
        self.assertEqual(summary["phase"], "reverse")
        self.assertEqual(summary["status"], "completed")
        self.assertEqual(summary["final_host"], "master")

    def test_source_placement_mismatch_fails_before_migration_request(self):
        module = load_module()
        commands = []

        def runner(args, **kwargs):
            command = list(args)
            commands.append(command)
            if command[3:5] == ["server", "show"]:
                value = {"status": "ACTIVE", "OS-EXT-SRV-ATTR:host": "master"}
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:5] == ["port", "show"]:
                value = {"status": "ACTIVE", "binding:host_id": "master"}
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:6] == ["server", "migration", "list"]:
                return subprocess.CompletedProcess(command, 0, "[]", "")
            raise AssertionError(f"migration must not start: {command}")

        with tempfile.TemporaryDirectory() as tmp:
            returncode, summary = self.run_cli(
                module,
                Path(tmp),
                runner,
                phase="reverse",
                source_host="compute2",
                target_host="master",
            )

        self.assertEqual(returncode, 1)
        self.assertEqual(summary["reason"], "source_placement_mismatch")
        self.assertFalse(any(command[3:5] == ["server", "migrate"] for command in commands))

    def test_terminal_migration_error_fails_immediately_and_preserves_evidence(self):
        module = load_module()
        migration_lists = 0

        def runner(args, **kwargs):
            nonlocal migration_lists
            command = list(args)
            if command[3:6] == ["server", "migration", "list"]:
                migration_lists += 1
                value = [] if migration_lists == 1 else [{
                    "ID": "failure-9",
                    "Migration Type": "live-migration",
                    "Source Compute": "master",
                    "Dest Compute": "compute2",
                    "Status": "error",
                }]
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:5] == ["server", "migrate"]:
                return subprocess.CompletedProcess(command, 0, "", "")
            if command[3:5] == ["server", "show"]:
                return subprocess.CompletedProcess(command, 0, json.dumps({"status": "ACTIVE", "OS-EXT-SRV-ATTR:host": "master"}), "")
            if command[3:5] == ["port", "show"]:
                return subprocess.CompletedProcess(command, 0, json.dumps({"status": "ACTIVE", "binding:host_id": "master"}), "")
            raise AssertionError(f"unexpected command: {command}")

        with tempfile.TemporaryDirectory() as tmp:
            returncode, summary = self.run_cli(module, Path(tmp), runner)
            evidence_path = Path(tmp) / "events.jsonl"
            evidence = [json.loads(line) for line in evidence_path.read_text().splitlines()]
            saved_summary = json.loads((Path(tmp) / "summary.json").read_text())

        self.assertEqual(returncode, 1)
        self.assertEqual(summary["outcome"], "failed")
        self.assertEqual(summary["reason"], "migration_status_error")
        self.assertEqual(saved_summary, summary)
        self.assertEqual(evidence[-1]["event"], "migration_failed")

    def test_terminal_migration_failed_fails_immediately_and_keeps_id(self):
        module = load_module()
        migration_lists = 0

        def runner(args, **kwargs):
            nonlocal migration_lists
            command = list(args)
            if command[3:6] == ["server", "migration", "list"]:
                migration_lists += 1
                value = [] if migration_lists == 1 else [{
                    "ID": "failed-10",
                    "Migration Type": "live-migration",
                    "Source Compute": "master",
                    "Dest Compute": "compute2",
                    "Status": "failed",
                }]
                return subprocess.CompletedProcess(
                    command, 0, json.dumps(value), ""
                )
            if command[3:5] == ["server", "migrate"]:
                return subprocess.CompletedProcess(command, 0, "", "")
            if command[3:5] == ["server", "show"]:
                value = {
                    "status": "ACTIVE",
                    "OS-EXT-SRV-ATTR:host": "master",
                }
                return subprocess.CompletedProcess(
                    command, 0, json.dumps(value), ""
                )
            if command[3:5] == ["port", "show"]:
                value = {"status": "ACTIVE", "binding:host_id": "master"}
                return subprocess.CompletedProcess(
                    command, 0, json.dumps(value), ""
                )
            raise AssertionError(f"unexpected command: {command}")

        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            module.time,
            "sleep",
            side_effect=AssertionError("terminal failed status must not sleep"),
        ):
            returncode, summary = self.run_cli(module, Path(tmp), runner)

        self.assertEqual(returncode, 1)
        self.assertEqual(summary["reason"], "migration_status_failed")
        self.assertEqual(summary["migration_id"], "failed-10")

    def test_cancelled_migration_fails_without_waiting_for_timeout(self):
        module = load_module()
        migration_lists = 0

        def runner(args, **kwargs):
            nonlocal migration_lists
            command = list(args)
            if command[3:6] == ["server", "migration", "list"]:
                migration_lists += 1
                value = [] if migration_lists == 1 else [{
                    "ID": 10,
                    "Type": "live-migration",
                    "Source Node": "master",
                    "Dest Node": "compute2",
                    "Status": "cancelled",
                }]
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:5] == ["server", "migrate"]:
                return subprocess.CompletedProcess(command, 0, "", "")
            if command[3:5] == ["server", "show"]:
                return subprocess.CompletedProcess(command, 0, json.dumps({"status": "ACTIVE", "OS-EXT-SRV-ATTR:host": "master"}), "")
            if command[3:5] == ["port", "show"]:
                return subprocess.CompletedProcess(command, 0, json.dumps({"status": "ACTIVE", "binding:host_id": "master"}), "")
            raise AssertionError(f"unexpected command: {command}")

        with tempfile.TemporaryDirectory() as tmp:
            returncode, summary = self.run_cli(module, Path(tmp), runner)

        self.assertEqual(returncode, 1)
        self.assertEqual(summary["reason"], "migration_status_cancelled")

    def test_server_error_fails_even_while_migration_is_running(self):
        module = load_module()
        migration_lists = 0

        def runner(args, **kwargs):
            nonlocal migration_lists
            command = list(args)
            if command[3:6] == ["server", "migration", "list"]:
                migration_lists += 1
                value = [] if migration_lists == 1 else [{
                    "ID": 11,
                    "Type": "live-migration",
                    "Source Node": "master",
                    "Dest Node": "compute2",
                    "Status": "running",
                }]
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:5] == ["server", "migrate"]:
                return subprocess.CompletedProcess(command, 0, "", "")
            if command[3:5] == ["server", "show"]:
                return subprocess.CompletedProcess(command, 0, json.dumps({"status": "ERROR", "OS-EXT-SRV-ATTR:host": "master"}), "")
            if command[3:5] == ["port", "show"]:
                return subprocess.CompletedProcess(command, 0, json.dumps({"status": "ACTIVE", "binding:host_id": "master"}), "")
            raise AssertionError(f"unexpected command: {command}")

        with tempfile.TemporaryDirectory() as tmp:
            returncode, summary = self.run_cli(module, Path(tmp), runner)

        self.assertEqual(returncode, 1)
        self.assertEqual(summary["reason"], "server_status_error")

    def test_server_error_before_migration_record_is_terminal(self):
        module = load_module()

        def runner(args, **kwargs):
            command = list(args)
            if command[3:6] == ["server", "migration", "list"]:
                return subprocess.CompletedProcess(command, 0, "[]", "")
            if command[3:5] == ["server", "migrate"]:
                return subprocess.CompletedProcess(command, 0, "", "")
            if command[3:5] == ["server", "show"]:
                return subprocess.CompletedProcess(command, 0, json.dumps({"status": "ERROR", "OS-EXT-SRV-ATTR:host": "master"}), "")
            if command[3:5] == ["port", "show"]:
                return subprocess.CompletedProcess(command, 0, json.dumps({"status": "ACTIVE", "binding:host_id": "master"}), "")
            raise AssertionError(f"unexpected command: {command}")

        with tempfile.TemporaryDirectory() as tmp:
            stdout = io.StringIO()
            argv = [
                "--phase", "forward",
                "--server-id", "server-1",
                "--port-id", "port-1",
                "--source-host", "master",
                "--target-host", "compute2",
                "--evidence-dir", tmp,
                "--timeout", "0.02",
                "--poll", "0",
            ]
            with mock.patch.object(module.subprocess, "run", side_effect=runner):
                with contextlib.redirect_stdout(stdout):
                    returncode = module.main(argv)
            summary = json.loads(stdout.getvalue())

        self.assertEqual(returncode, 1)
        self.assertEqual(summary["reason"], "server_status_error")
        self.assertIsNone(summary["migration_id"])

    def test_timeout_returns_failed_summary_and_keeps_jsonl(self):
        module = load_module()
        server_shows = 0

        def runner(args, **kwargs):
            nonlocal server_shows
            command = list(args)
            if command[3:6] == ["server", "migration", "list"]:
                return subprocess.CompletedProcess(command, 0, "[]", "")
            if command[3:5] == ["server", "migrate"]:
                return subprocess.CompletedProcess(command, 0, "", "")
            if command[3:5] == ["server", "show"]:
                server_shows += 1
                status = "ACTIVE" if server_shows == 1 else "MIGRATING"
                return subprocess.CompletedProcess(command, 0, json.dumps({"status": status, "OS-EXT-SRV-ATTR:host": "master"}), "")
            if command[3:5] == ["port", "show"]:
                return subprocess.CompletedProcess(command, 0, json.dumps({"status": "ACTIVE", "binding:host_id": "master"}), "")
            raise AssertionError(f"unexpected command: {command}")

        with tempfile.TemporaryDirectory() as tmp:
            stdout = io.StringIO()
            argv = [
                "--phase", "forward",
                "--server-id", "server-1",
                "--port-id", "port-1",
                "--source-host", "master",
                "--target-host", "compute2",
                "--evidence-dir", tmp,
                "--timeout", "0",
                "--poll", "0",
            ]
            with mock.patch.object(module.subprocess, "run", side_effect=runner):
                with contextlib.redirect_stdout(stdout):
                    returncode = module.main(argv)
            summary = json.loads(stdout.getvalue())
            evidence = [json.loads(line) for line in (Path(tmp) / "events.jsonl").read_text().splitlines()]

        self.assertEqual(returncode, 1)
        self.assertEqual(summary["reason"], "timeout")
        self.assertEqual(evidence[-1]["event"], "migration_failed")

    def test_openstack_command_error_returns_failed_summary(self):
        module = load_module()

        def runner(args, **kwargs):
            command = list(args)
            if command[3:5] == ["server", "show"]:
                value = {"status": "ACTIVE", "OS-EXT-SRV-ATTR:host": "master"}
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:5] == ["port", "show"]:
                value = {"status": "ACTIVE", "binding:host_id": "master"}
                return subprocess.CompletedProcess(command, 0, json.dumps(value), "")
            if command[3:6] == ["server", "migration", "list"]:
                return subprocess.CompletedProcess(command, 0, "[]", "")
            if command[3:5] == ["server", "migrate"]:
                return subprocess.CompletedProcess(command, 1, "", "No valid host was found")
            raise AssertionError(f"unexpected command: {command}")

        with tempfile.TemporaryDirectory() as tmp:
            returncode, summary = self.run_cli(module, Path(tmp), runner)
            evidence = [json.loads(line) for line in (Path(tmp) / "events.jsonl").read_text().splitlines()]

        self.assertEqual(returncode, 1)
        self.assertEqual(summary["reason"], "openstack_command_error")
        self.assertIn("No valid host", summary["detail"])
        self.assertEqual(evidence[-1]["event"], "migration_failed")

    def test_openstack_command_timeout_is_recorded_as_failure(self):
        module = load_module()

        def runner(args, **kwargs):
            raise subprocess.TimeoutExpired(
                args,
                kwargs.get("timeout", 1),
                output=b"partial",
                stderr=b"hung",
            )

        with tempfile.TemporaryDirectory() as tmp:
            returncode, summary = self.run_cli(module, Path(tmp), runner)
            evidence = [json.loads(line) for line in (Path(tmp) / "events.jsonl").read_text().splitlines()]

        self.assertEqual(returncode, 1)
        self.assertEqual(summary["reason"], "openstack_command_error")
        self.assertIn("timed out", summary["detail"])
        self.assertEqual(evidence[0]["event"], "openstack_command_timeout")
        self.assertEqual(evidence[-1]["event"], "migration_failed")

    def test_missing_openstack_binary_is_recorded_as_failure(self):
        module = load_module()

        def runner(args, **kwargs):
            raise FileNotFoundError("openstack-not-found")

        with tempfile.TemporaryDirectory() as tmp:
            returncode, summary = self.run_cli(module, Path(tmp), runner)
            evidence = [json.loads(line) for line in (Path(tmp) / "events.jsonl").read_text().splitlines()]

        self.assertEqual(returncode, 1)
        self.assertEqual(summary["reason"], "openstack_command_error")
        self.assertEqual(evidence[0]["event"], "openstack_command_start_error")


if __name__ == "__main__":
    unittest.main()
