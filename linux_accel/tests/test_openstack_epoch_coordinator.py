import errno
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from pathlib import Path

import agent.openstack_epoch_coordinator as coordinator_module
from agent.openstack_epoch_coordinator import (
    CommandResult,
    CoordinatorError,
    CoordinatorConfig,
    EpochCoordinator,
    PublisherEndpoint,
    StateSource,
    _read_desired_mode,
    _run_watch_loop,
    _short_host,
    load_config,
)
from agent.openstack_epoch_gate import RequiredEndpoint


SERVER_ID = "server-1"
PORT_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
NOW_MS = 1_000_000


class FakeRunner:
    def __init__(self):
        self.calls = []
        self.fail = set()
        self.fail_once = set()
        self.maps = {
            "publisher-a": {"epoch": 0, "mode": 0, "flags": 0},
            "publisher-b": {"epoch": 0, "mode": 0, "flags": 0},
        }
        self.map_counts = {"publisher-a": 2, "publisher-b": 2}

    def run(self, args, timeout_seconds):
        command = tuple(args)
        self.calls.append((command, timeout_seconds))
        endpoint = command[0]
        operation = command[command.index("--operation") + 1]
        mode = command[command.index("--mode") + 1]
        failure_key = (endpoint, operation, mode)
        if failure_key in self.fail or failure_key in self.fail_once:
            self.fail_once.discard(failure_key)
            return CommandResult(1, stderr="injected failure")
        current = self.maps[endpoint]
        if operation == "read-current":
            if current is None:
                value = {
                    "schema_version": 1,
                    "present": False,
                    "maps": 0,
                    "epoch": 0,
                    "mode": 0,
                    "flags": 0,
                }
            else:
                value = {
                    "schema_version": 1,
                    "present": True,
                    "maps": self.map_counts.get(endpoint, 2),
                    **current,
                }
            return CommandResult(0, stdout=json.dumps(value))
        if current is None:
            return CommandResult(0, stdout="maps absent")

        epoch = int(command[command.index("--epoch") + 1])
        mode_value = {"bypass": 1, "server": 2, "client": 3, "dual": 4}[mode]
        expected_staged = {"epoch": epoch, "mode": mode_value, "flags": 0}
        expected_committed = {"epoch": epoch, "mode": mode_value, "flags": 1}
        if operation == "stage":
            if current["epoch"] > epoch:
                current["mode"] = 1
                current["flags"] = 1
                return CommandResult(1, stderr="epoch rollback")
            if current["epoch"] == epoch and current != expected_staged:
                current["mode"] = 1
                current["flags"] = 1
                return CommandResult(1, stderr="epoch mismatch")
            self.maps[endpoint] = expected_staged
        elif operation == "verify-staged":
            if current != expected_staged:
                return CommandResult(1, stderr="not staged")
        elif operation == "commit":
            if current != expected_staged:
                return CommandResult(1, stderr="not staged")
            self.maps[endpoint] = expected_committed
        elif operation == "verify-committed":
            if current != expected_committed:
                return CommandResult(1, stderr="not committed")
        elif operation == "force-bypass":
            safe_epoch = max(current["epoch"], epoch)
            self.maps[endpoint] = {
                "epoch": safe_epoch,
                "mode": 1,
                "flags": 1,
            }
            if current["epoch"] > epoch:
                return CommandResult(1, stderr="bypass epoch rollback")
        else:
            raise AssertionError(f"unexpected operation: {operation}")
        return CommandResult(0, stdout="published")

    def seed(self, mode, epoch):
        mode_value = {"bypass": 1, "server": 2, "client": 3, "dual": 4}[mode]
        for endpoint in self.maps:
            self.maps[endpoint] = {
                "epoch": epoch,
                "mode": mode_value,
                "flags": 1,
            }


class BlockingFirstRunner(FakeRunner):
    def __init__(self):
        super().__init__()
        self.first_run_entered = threading.Event()
        self.release_first_run = threading.Event()
        self.follow_on_run_entered = threading.Event()
        self._run_lock = threading.Lock()
        self._block_first_run = True

    def run(self, args, timeout_seconds):
        with self._run_lock:
            block = self._block_first_run
            if block:
                self._block_first_run = False
                self.first_run_entered.set()
            else:
                self.follow_on_run_entered.set()
        if block and not self.release_first_run.wait(timeout=5):
            raise TimeoutError("test runner was not released")
        return super().run(args, timeout_seconds)


class LostSshRunner:
    def __init__(self):
        self.calls = []
        self.local_map = {"epoch": 7, "mode": 2, "flags": 1}
        self.local_force_at = None
        self.max_remote_active = 0
        self._remote_active = 0
        self._lock = threading.Lock()

    def run(self, args, timeout_seconds):
        command = tuple(args)
        operation = command[command.index("--operation") + 1]
        endpoint = command[1] if command[0].endswith("/ssh") else command[0]
        with self._lock:
            self.calls.append((endpoint, operation))
        if command[0].endswith("/ssh"):
            with self._lock:
                self._remote_active += 1
                self.max_remote_active = max(
                    self.max_remote_active, self._remote_active
                )
            try:
                time.sleep(timeout_seconds)
            finally:
                with self._lock:
                    self._remote_active -= 1
            raise subprocess.TimeoutExpired(command, timeout_seconds)

        if operation == "force-bypass":
            epoch = int(command[command.index("--epoch") + 1])
            self.local_map = {"epoch": epoch, "mode": 1, "flags": 1}
            self.local_force_at = time.monotonic()
            return CommandResult(0, stdout="published")
        if operation == "read-current":
            return CommandResult(
                0,
                stdout=json.dumps(
                    {
                        "schema_version": 1,
                        "present": True,
                        "maps": 2,
                        **self.local_map,
                    }
                ),
            )
        raise AssertionError(f"unexpected local operation: {operation}")


def write_snapshot(
    path,
    host,
    state,
    updated_ms=NOW_MS,
    ifindex=14,
    binding_host="compute2",
    revision_number=7,
    accel_role="client",
):
    dns_capability = (
        "xdp_client_cache" if accel_role == "client" else "tc_observability"
    )
    guest_grpc_listen_port = 50053 if accel_role == "client" else 50052
    endpoint_config = {
        "server_id": SERVER_ID,
        "port_ids": [PORT_ID],
        "accel_role": accel_role,
        "grpc_observe_port": 50052,
        "guest_grpc_listen_port": guest_grpc_listen_port,
    }
    if accel_role == "client":
        endpoint_config["trusted_dns"] = ["10.0.0.12"]
    port_health = []
    if state is not None:
        port_health.append(
            {
                "port_id": PORT_ID,
                "state": state,
                "reason": "test_state",
                "accel_role": accel_role,
                "grpc_observe_port": 50052,
                "guest_grpc_listen_port": guest_grpc_listen_port,
                "dns_capability": dns_capability,
                "grpc_capability": "tc_observability",
                "binding": {
                    "server_id": SERVER_ID,
                    "port_id": PORT_ID,
                    "host": host,
                    "interface": "tap-test",
                    "ifindex": ifindex,
                    "accel_role": accel_role,
                    "grpc_observe_port": 50052,
                    "guest_grpc_listen_port": guest_grpc_listen_port,
                    "dns_capability": dns_capability,
                    "grpc_capability": "tc_observability",
                },
            }
        )
    path.write_text(
        json.dumps(
            {
                "schema_version": 3,
                "local_host": host,
                "updated_ms": updated_ms,
                "endpoint_config": [endpoint_config],
                "grpc_capability": "tc_observability",
                "port_health": port_health,
                "port_inventory": [
                    {
                        "server_id": SERVER_ID,
                        "port_id": PORT_ID,
                        "status": "ACTIVE",
                        "binding_host": binding_host,
                        "vif_type": "ovs",
                        "revision_number": revision_number,
                    }
                ],
            }
        ),
        encoding="utf-8",
    )


def write_guest_snapshot(
    path,
    *,
    updated_ms=NOW_MS,
    role="client",
    state="healthy",
):
    expected_maps = 2 if role == "server" else 1
    program_id = 77 if role == "server" else None
    port_root = f"/sys/fs/bpf/vnet-dataplane-guest/{PORT_ID}"
    map_paths = {
        "grpc_runtime_control": f"{port_root}/grpc/cache_runtime_control",
        "dns_runtime_control": (
            f"{port_root}/dns/cache_runtime_control"
            if role == "server"
            else None
        ),
        "dns_cache_stats": (
            f"{port_root}/dns/dns_cache_stats" if role == "server" else None
        ),
        "dns_cache_entries": (
            f"{port_root}/dns/dns_cache_entries" if role == "server" else None
        ),
    }
    path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "source_kind": "guest_endpoint",
                "server_id": SERVER_ID,
                "port_id": PORT_ID,
                "accel_role": role,
                "interface": "ens3",
                "interface_ipv4": [
                    "10.0.0.43" if role == "client" else "10.0.0.55"
                ],
                "updated_ms": updated_ms,
                "state": state,
                "reason": "ready" if state == "healthy" else "test_failure",
                "grpc_capability": "userspace_fast_cache",
                "grpc": {
                    "listen": (
                        "0.0.0.0:50053"
                        if role == "client"
                        else "0.0.0.0:50052"
                    ),
                    "backend": (
                        "10.0.0.55:50052"
                        if role == "client"
                        else "10.0.0.55:50051"
                    ),
                    "method": "/grpc.health.v1.Health/Check",
                    "cache_file": "/etc/vnet/grpc-policy.txt",
                    "listener_owned": True,
                    "backend_ready": True,
                },
                "processes": {
                    "grpc_fast_cache": {"pid": 1201, "alive": True},
                    "dns_monitor": {
                        "pid": 1202 if role == "server" else None,
                        "alive": role == "server",
                    },
                },
                "dns_xdp_prog_id": program_id,
                "current_dns_xdp_prog_id": program_id,
                "map_paths": map_paths,
                "pins_present": {
                    pin: True for pin in map_paths.values() if pin is not None
                },
                "runtime_readback": {
                    "schema_version": 1,
                    "present": True,
                    "maps": expected_maps,
                    "epoch": 1,
                    "mode": 1,
                    "flags": 1,
                },
                "quiesced": False,
            }
        ),
        encoding="utf-8",
    )


def test_config(master_state, compute_state):
    return CoordinatorConfig(
        required_endpoints=(RequiredEndpoint(SERVER_ID, PORT_ID),),
        state_sources=(
            StateSource("master-state", path=master_state),
            StateSource("compute2-state", path=compute_state),
        ),
        publishers=(
            PublisherEndpoint(
                "publisher-a",
                "master",
                SERVER_ID,
                PORT_ID,
                ("publisher-a",),
                actor_id="actor-a",
                target_kind="guest_endpoint",
            ),
            PublisherEndpoint(
                "publisher-b",
                "compute2",
                SERVER_ID,
                PORT_ID,
                ("publisher-b",),
                actor_id="actor-b",
                target_kind="guest_endpoint",
            ),
        ),
        max_state_age_ms=10_000,
        command_timeout_seconds=3.0,
    )


def observer_compute_config(master_state, compute_state):
    return CoordinatorConfig(
        required_endpoints=(
            RequiredEndpoint(
                SERVER_ID,
                PORT_ID,
                compute_role="observer",
            ),
        ),
        state_sources=(
            StateSource("master-state", path=master_state),
            StateSource("compute2-state", path=compute_state),
        ),
        publishers=(
            PublisherEndpoint(
                "master-backend",
                "master",
                SERVER_ID,
                PORT_ID,
                ("master-backend",),
                actor_id="backend-host-caches",
                target_kind="compute_port",
                services=("grpc",),
                cache_role="server",
            ),
            PublisherEndpoint(
                "compute2-backend",
                "compute2",
                SERVER_ID,
                PORT_ID,
                ("compute2-backend",),
                actor_id="backend-host-caches",
                target_kind="compute_port",
                services=("grpc",),
                cache_role="server",
            ),
        ),
        max_state_age_ms=10_000,
        command_timeout_seconds=3.0,
    )


class EpochCoordinatorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.master_state = root / "master.json"
        self.compute_state = root / "compute2.json"
        self.runtime_state = root / "runtime.json"
        write_snapshot(self.master_state, "master", "absent")
        write_snapshot(self.compute_state, "compute2", "healthy", ifindex=21)
        self.runner = FakeRunner()
        self.coordinator = EpochCoordinator(
            test_config(self.master_state, self.compute_state),
            self.runtime_state,
            runner=self.runner,
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_shutdown_deadline_clamps_every_publication_command_timeout(self):
        self.coordinator.request_shutdown(102.5)

        with (
            mock.patch.object(coordinator_module, "fcntl", None),
            mock.patch.object(
                coordinator_module.time,
                "monotonic",
                return_value=100.0,
            ),
        ):
            result = self.coordinator.reconcile_shutdown(NOW_MS)

        self.assertTrue(self.runner.calls)
        self.assertTrue(all(timeout == 2.5 for _, timeout in self.runner.calls))
        self.assertEqual(result.state.mode, "bypass")

    def test_expired_shutdown_deadline_refuses_publication_commands(self):
        self.coordinator.request_shutdown(99.0)

        with (
            mock.patch.object(coordinator_module, "fcntl", None),
            mock.patch.object(
                coordinator_module.time,
                "monotonic",
                return_value=100.0,
            ),
            self.assertRaisesRegex(
                CoordinatorError, "publication deadline expired"
            ),
        ):
            self.coordinator.reconcile_shutdown(NOW_MS)

        self.assertEqual(self.runner.calls, [])

    def test_expired_shutdown_deadline_stops_waiting_for_state_lock(self):
        blocked_fcntl = mock.Mock()
        blocked_fcntl.LOCK_EX = 1
        blocked_fcntl.LOCK_NB = 2
        blocked_fcntl.LOCK_UN = 4
        blocked_fcntl.flock.side_effect = BlockingIOError(
            errno.EAGAIN, "state lock busy"
        )
        self.coordinator.request_shutdown(99.0)

        with (
            mock.patch.object(coordinator_module, "fcntl", blocked_fcntl),
            mock.patch.object(
                coordinator_module.time,
                "monotonic",
                return_value=100.0,
            ),
            self.assertRaisesRegex(
                CoordinatorError, "expired waiting for state lock"
            ),
        ):
            self.coordinator.reconcile_shutdown(NOW_MS)

        self.assertEqual(self.runner.calls, [])

    def test_bootstrap_bypass_precedes_first_accelerated_policy(self):
        result = self.coordinator.reconcile("server", NOW_MS)
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.state.mode, "server")
        self.assertEqual(result.state.epoch, 2)
        published = []
        for command, _timeout in self.runner.calls:
            operation = command[command.index("--operation") + 1]
            if operation in {"force-bypass", "verify-committed"}:
                published.append(
                    (
                        command[0],
                        command[command.index("--mode") + 1],
                        int(command[command.index("--epoch") + 1]),
                    )
                )
        self.assertEqual(
            published,
            [
                ("publisher-a", "bypass", 1),
                ("publisher-b", "bypass", 1),
                ("publisher-a", "server", 2),
                ("publisher-b", "server", 2),
            ],
        )

    def test_migration_forces_bypass_then_recovers_with_next_epoch(self):
        self.coordinator.reconcile("server", NOW_MS)
        write_snapshot(self.master_state, "master", "transition")
        frozen = self.coordinator.reconcile("server", NOW_MS)
        self.assertEqual(frozen.exit_code, 2)
        self.assertEqual(frozen.outcome, "migration_forced_bypass")
        self.assertEqual((frozen.state.mode, frozen.state.epoch), ("bypass", 3))

        write_snapshot(self.master_state, "master", "absent")
        recovered = self.coordinator.reconcile("server", NOW_MS)
        self.assertEqual(recovered.exit_code, 0)
        self.assertEqual((recovered.state.mode, recovered.state.epoch), ("server", 4))

    def test_observer_compute_publish_targets_only_the_healthy_backend_host(self):
        write_snapshot(
            self.master_state,
            "master",
            "absent",
            binding_host="compute2",
            accel_role="observer",
        )
        write_snapshot(
            self.compute_state,
            "compute2",
            "healthy",
            ifindex=21,
            binding_host="compute2",
            accel_role="observer",
        )
        self.runner.maps = {
            "master-backend": None,
            "compute2-backend": {"epoch": 1, "mode": 1, "flags": 1},
        }
        self.runner.map_counts = {
            "master-backend": 1,
            "compute2-backend": 1,
        }
        coordinator = EpochCoordinator(
            observer_compute_config(self.master_state, self.compute_state),
            self.runtime_state,
            runner=self.runner,
        )

        result = coordinator.reconcile("server", NOW_MS)

        self.assertEqual(result.outcome, "policy_published")
        self.assertEqual((result.state.mode, result.state.epoch), ("server", 2))
        accelerated_endpoints = {
            command[0]
            for command, _timeout in self.runner.calls
            if command[command.index("--operation") + 1]
            in {"stage", "verify-staged", "commit", "verify-committed"}
        }
        self.assertEqual(accelerated_endpoints, {"compute2-backend"})

    def test_observer_compute_publish_aborts_a_direct_host_switch_after_stage(self):
        write_snapshot(
            self.master_state,
            "master",
            "absent",
            binding_host="compute2",
            accel_role="observer",
        )
        write_snapshot(
            self.compute_state,
            "compute2",
            "healthy",
            ifindex=21,
            binding_host="compute2",
            accel_role="observer",
        )
        self.runner.maps = {
            "master-backend": None,
            "compute2-backend": {"epoch": 1, "mode": 1, "flags": 1},
        }
        self.runner.map_counts = {
            "master-backend": 1,
            "compute2-backend": 1,
        }
        coordinator = EpochCoordinator(
            observer_compute_config(self.master_state, self.compute_state),
            self.runtime_state,
            runner=self.runner,
        )
        initial = coordinator.reconcile("server", NOW_MS)
        self.assertEqual((initial.state.mode, initial.state.epoch), ("server", 2))
        self.runner.calls.clear()
        original_run = self.runner.run
        switched = False

        def switch_binding_after_stage(args, timeout_seconds):
            nonlocal switched
            result = original_run(args, timeout_seconds)
            command = tuple(args)
            if (
                not switched
                and command[0] == "compute2-backend"
                and command[command.index("--operation") + 1]
                == "verify-staged"
            ):
                switched = True
                write_snapshot(
                    self.master_state,
                    "master",
                    "healthy",
                    binding_host="master",
                    accel_role="observer",
                )
                write_snapshot(
                    self.compute_state,
                    "compute2",
                    "absent",
                    binding_host="master",
                    accel_role="observer",
                )
                self.runner.maps["compute2-backend"] = None
                self.runner.maps["master-backend"] = {
                    "epoch": 1,
                    "mode": 1,
                    "flags": 1,
                }
            return result

        self.runner.run = switch_binding_after_stage

        result = coordinator.reconcile("dual", NOW_MS)

        self.assertEqual(result.outcome, "gate_changed_bypass_recovered")
        self.assertEqual((result.state.mode, result.state.epoch), ("bypass", 3))
        self.assertFalse(
            any(
                command[command.index("--operation") + 1] == "commit"
                and command[command.index("--mode") + 1] == "dual"
                for command, _timeout in self.runner.calls
            )
        )
        self.assertEqual(
            self.runner.maps["master-backend"],
            {"epoch": 3, "mode": 1, "flags": 1},
        )

    def test_observer_compute_publish_rejects_host_switch_before_final_readback(self):
        write_snapshot(
            self.master_state,
            "master",
            "absent",
            binding_host="compute2",
            accel_role="observer",
        )
        write_snapshot(
            self.compute_state,
            "compute2",
            "healthy",
            ifindex=21,
            binding_host="compute2",
            accel_role="observer",
        )
        self.runner.maps = {
            "master-backend": None,
            "compute2-backend": {"epoch": 1, "mode": 1, "flags": 1},
        }
        self.runner.map_counts = {
            "master-backend": 1,
            "compute2-backend": 1,
        }
        coordinator = EpochCoordinator(
            observer_compute_config(self.master_state, self.compute_state),
            self.runtime_state,
            runner=self.runner,
        )
        original_run = self.runner.run
        final_readback_armed = False
        switched = False

        def switch_binding_before_final_readback(args, timeout_seconds):
            nonlocal final_readback_armed, switched
            command = tuple(args)
            operation = command[command.index("--operation") + 1]
            if final_readback_armed and not switched and operation == "read-current":
                switched = True
                write_snapshot(
                    self.master_state,
                    "master",
                    "healthy",
                    ifindex=31,
                    binding_host="master",
                    accel_role="observer",
                )
                write_snapshot(
                    self.compute_state,
                    "compute2",
                    "absent",
                    binding_host="master",
                    accel_role="observer",
                )
            result = original_run(args, timeout_seconds)
            if operation == "verify-committed":
                final_readback_armed = True
            return result

        self.runner.run = switch_binding_before_final_readback

        result = coordinator.reconcile("server", NOW_MS)

        self.assertTrue(switched)
        self.assertNotEqual(result.outcome, "policy_published")
        self.assertNotEqual(result.exit_code, 0)
        self.assertEqual(result.state.mode, "bypass")
        self.assertFalse(result.state.known)
        self.assertEqual(
            self.runner.maps["compute2-backend"],
            {"epoch": 2, "mode": 1, "flags": 1},
        )

    def test_observer_compute_unchanged_policy_rechecks_host_after_readback(self):
        write_snapshot(
            self.master_state,
            "master",
            "absent",
            binding_host="compute2",
            accel_role="observer",
        )
        write_snapshot(
            self.compute_state,
            "compute2",
            "healthy",
            ifindex=21,
            binding_host="compute2",
            accel_role="observer",
        )
        self.runner.maps = {
            "master-backend": None,
            "compute2-backend": {"epoch": 1, "mode": 1, "flags": 1},
        }
        self.runner.map_counts = {
            "master-backend": 1,
            "compute2-backend": 1,
        }
        coordinator = EpochCoordinator(
            observer_compute_config(self.master_state, self.compute_state),
            self.runtime_state,
            runner=self.runner,
        )
        initial = coordinator.reconcile("server", NOW_MS)
        self.assertEqual(initial.outcome, "policy_published")
        self.runner.calls.clear()
        original_run = self.runner.run
        switched = False

        def switch_binding_during_readback(args, timeout_seconds):
            nonlocal switched
            command = tuple(args)
            operation = command[command.index("--operation") + 1]
            if not switched and operation == "read-current":
                switched = True
                write_snapshot(
                    self.master_state,
                    "master",
                    "healthy",
                    ifindex=31,
                    binding_host="master",
                    accel_role="observer",
                )
                write_snapshot(
                    self.compute_state,
                    "compute2",
                    "absent",
                    binding_host="master",
                    accel_role="observer",
                )
            return original_run(args, timeout_seconds)

        self.runner.run = switch_binding_during_readback

        result = coordinator.reconcile("server", NOW_MS)

        self.assertTrue(switched)
        self.assertEqual(result.outcome, "fail_safe_bypass_published")
        self.assertEqual(result.exit_code, 2)
        self.assertEqual(
            (result.state.mode, result.state.epoch, result.state.known),
            ("bypass", 3, True),
        )
        self.assertEqual(
            self.runner.maps["compute2-backend"],
            {"epoch": 3, "mode": 1, "flags": 1},
        )

    def test_observer_compute_plan_keeps_guest_and_bypasses_all_candidates(self):
        guest_state = Path(self.temp.name) / "backend-guest.json"
        write_guest_snapshot(guest_state, role="server")
        write_snapshot(
            self.master_state,
            "master",
            "absent",
            binding_host="compute2",
            accel_role="observer",
        )
        write_snapshot(
            self.compute_state,
            "compute2",
            "healthy",
            ifindex=21,
            binding_host="compute2",
            accel_role="observer",
        )
        base = observer_compute_config(self.master_state, self.compute_state)
        config = CoordinatorConfig(
            required_endpoints=(
                RequiredEndpoint(
                    SERVER_ID,
                    PORT_ID,
                    compute_role="observer",
                    guest_cache_role="server",
                ),
            ),
            state_sources=(
                *base.state_sources,
                StateSource(
                    "backend-guest",
                    path=guest_state,
                    kind="guest_endpoint",
                ),
            ),
            publishers=(
                *base.publishers,
                PublisherEndpoint(
                    "backend-guest",
                    "backend-guest",
                    SERVER_ID,
                    PORT_ID,
                    ("backend-guest",),
                    actor_id="backend-guest-caches",
                    target_kind="guest_endpoint",
                    services=("dns", "grpc"),
                    cache_role="server",
                ),
            ),
            max_state_age_ms=base.max_state_age_ms,
            command_timeout_seconds=base.command_timeout_seconds,
        )
        self.runner.maps = {
            "master-backend": None,
            "compute2-backend": {"epoch": 1, "mode": 1, "flags": 1},
            "backend-guest": {"epoch": 1, "mode": 1, "flags": 1},
        }
        self.runner.map_counts = {
            "master-backend": 1,
            "compute2-backend": 1,
            "backend-guest": 2,
        }
        coordinator = EpochCoordinator(
            config,
            self.runtime_state,
            runner=self.runner,
        )

        published = coordinator.reconcile("server", NOW_MS)

        self.assertEqual(
            published.outcome,
            "policy_published",
            published.gate.reason,
        )
        accelerated = {
            command[0]
            for command, _timeout in self.runner.calls
            if command[command.index("--operation") + 1] == "commit"
            and command[command.index("--mode") + 1] == "server"
        }
        self.assertEqual(accelerated, {"compute2-backend", "backend-guest"})
        read_back = {
            command[0]
            for command, _timeout in self.runner.calls
            if command[command.index("--operation") + 1] == "read-current"
        }
        self.assertEqual(
            read_back,
            {"master-backend", "compute2-backend", "backend-guest"},
        )

        self.runner.calls.clear()
        write_snapshot(
            self.compute_state,
            "compute2",
            "transition",
            ifindex=21,
            binding_host="compute2",
            accel_role="observer",
        )
        frozen = coordinator.reconcile("server", NOW_MS)

        self.assertEqual(frozen.outcome, "migration_forced_bypass")
        bypassed = {
            command[0]
            for command, _timeout in self.runner.calls
            if command[command.index("--operation") + 1] == "force-bypass"
        }
        self.assertEqual(
            bypassed,
            {"master-backend", "compute2-backend", "backend-guest"},
        )

    def test_observer_compute_publish_rebases_a_new_backend_map_after_migration(self):
        write_snapshot(
            self.master_state,
            "master",
            "absent",
            binding_host="compute2",
            accel_role="observer",
        )
        write_snapshot(
            self.compute_state,
            "compute2",
            "healthy",
            ifindex=21,
            binding_host="compute2",
            accel_role="observer",
        )
        self.runner.maps = {
            "master-backend": None,
            "compute2-backend": {"epoch": 1, "mode": 1, "flags": 1},
        }
        self.runner.map_counts = {
            "master-backend": 1,
            "compute2-backend": 1,
        }
        coordinator = EpochCoordinator(
            observer_compute_config(self.master_state, self.compute_state),
            self.runtime_state,
            runner=self.runner,
        )
        initial = coordinator.reconcile("server", NOW_MS)
        self.assertEqual((initial.state.mode, initial.state.epoch), ("server", 2))

        write_snapshot(
            self.compute_state,
            "compute2",
            "transition",
            ifindex=21,
            binding_host="compute2",
            accel_role="observer",
        )
        frozen = coordinator.reconcile("server", NOW_MS)
        self.assertEqual(frozen.outcome, "migration_forced_bypass")
        self.assertEqual((frozen.state.mode, frozen.state.epoch), ("bypass", 3))

        self.runner.maps["compute2-backend"] = None
        self.runner.maps["master-backend"] = {
            "epoch": 1,
            "mode": 1,
            "flags": 1,
        }
        write_snapshot(
            self.master_state,
            "master",
            "healthy",
            ifindex=31,
            binding_host="master",
            accel_role="observer",
        )
        write_snapshot(
            self.compute_state,
            "compute2",
            "absent",
            binding_host="master",
            accel_role="observer",
        )
        self.runner.calls.clear()

        recovered = coordinator.reconcile("server", NOW_MS)

        self.assertEqual(recovered.outcome, "policy_published")
        self.assertEqual((recovered.state.mode, recovered.state.epoch), ("server", 5))
        accelerated_endpoints = {
            command[0]
            for command, _timeout in self.runner.calls
            if command[command.index("--operation") + 1]
            in {"stage", "verify-staged", "commit", "verify-committed"}
        }
        self.assertEqual(accelerated_endpoints, {"master-backend"})
        self.assertEqual(
            self.runner.maps["master-backend"],
            {"epoch": 5, "mode": 2, "flags": 1},
        )

    def test_partial_publish_failure_is_overwritten_with_bypass_same_epoch(self):
        self.coordinator.reconcile("server", NOW_MS)
        self.runner.fail.add(("publisher-b", "stage", "dual"))
        failed = self.coordinator.reconcile("dual", NOW_MS)

        self.assertEqual(failed.exit_code, 2)
        self.assertEqual(failed.outcome, "publish_failed_bypass_recovered")
        self.assertEqual((failed.state.mode, failed.state.epoch), ("bypass", 3))
        operations = [
            (
                command[0],
                command[command.index("--operation") + 1],
                command[command.index("--mode") + 1],
                int(command[command.index("--epoch") + 1]),
            )
            for command, _timeout in self.runner.calls
        ]
        self.assertIn(("publisher-a", "stage", "dual", 3), operations)
        self.assertIn(("publisher-b", "stage", "dual", 3), operations)
        self.assertIn(("publisher-a", "force-bypass", "bypass", 3), operations)
        self.assertIn(("publisher-b", "force-bypass", "bypass", 3), operations)

    def test_topology_change_after_staging_prevents_accelerated_commit(self):
        self.runner.seed("bypass", 1)
        self.runtime_state.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "mode": "bypass",
                    "epoch": 1,
                    "known": True,
                }
            ),
            encoding="utf-8",
        )
        original_run = self.runner.run
        changed = False

        def change_topology_after_verify(args, timeout_seconds):
            nonlocal changed
            result = original_run(args, timeout_seconds)
            command = tuple(args)
            if (
                not changed
                and command[0] == "publisher-b"
                and command[command.index("--operation") + 1]
                == "verify-staged"
            ):
                changed = True
                write_snapshot(self.master_state, "master", "transition")
            return result

        self.runner.run = change_topology_after_verify
        result = self.coordinator.reconcile("server", NOW_MS)

        self.assertEqual(result.outcome, "gate_changed_bypass_recovered")
        self.assertEqual((result.state.mode, result.state.epoch), ("bypass", 2))
        self.assertIn("migration_transition", result.gate.reason)
        accelerated_commits = [
            command
            for command, _timeout in self.runner.calls
            if command[command.index("--operation") + 1] == "commit"
            and command[command.index("--mode") + 1] == "server"
        ]
        self.assertEqual(accelerated_commits, [])

    def test_topology_change_during_commit_recovers_every_map_to_bypass(self):
        self.runner.seed("bypass", 1)
        self.runtime_state.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "mode": "bypass",
                    "epoch": 1,
                    "known": True,
                }
            ),
            encoding="utf-8",
        )
        original_run = self.runner.run
        changed = False

        def change_topology_during_commit(args, timeout_seconds):
            nonlocal changed
            result = original_run(args, timeout_seconds)
            command = tuple(args)
            if (
                not changed
                and command[0] == "publisher-a"
                and command[command.index("--operation") + 1] == "commit"
            ):
                changed = True
                write_snapshot(self.master_state, "master", "transition")
            return result

        self.runner.run = change_topology_during_commit
        result = self.coordinator.reconcile("server", NOW_MS)

        self.assertEqual(result.outcome, "gate_changed_bypass_recovered")
        self.assertEqual((result.state.mode, result.state.epoch), ("bypass", 2))
        self.assertIn("migration_transition", result.gate.reason)
        self.assertEqual(self.runner.maps["publisher-a"]["mode"], 1)
        self.assertEqual(self.runner.maps["publisher-b"]["mode"], 1)
        self.assertTrue(
            all(item["flags"] == 1 for item in self.runner.maps.values())
        )
        self.assertFalse(
            any(
                command[command.index("--operation") + 1]
                == "verify-committed"
                and command[command.index("--mode") + 1] == "server"
                for command, _timeout in self.runner.calls
            )
        )

    def test_closed_gate_bypasses_local_before_concurrent_ssh_timeouts(self):
        timeout_seconds = 0.15
        base = test_config(self.master_state, self.compute_state)
        config = CoordinatorConfig(
            required_endpoints=base.required_endpoints,
            state_sources=base.state_sources,
            publishers=(
                PublisherEndpoint(
                    "local",
                    "master",
                    SERVER_ID,
                    PORT_ID,
                    ("local",),
                    actor_id="local-actor",
                    target_kind="guest_endpoint",
                ),
                PublisherEndpoint(
                    "remote-a",
                    "compute2",
                    SERVER_ID,
                    PORT_ID,
                    ("/usr/bin/ssh", "remote-a"),
                    actor_id="remote-a-actor",
                    target_kind="guest_endpoint",
                ),
                PublisherEndpoint(
                    "remote-b",
                    "compute3",
                    SERVER_ID,
                    PORT_ID,
                    ("/usr/bin/ssh", "remote-b"),
                    actor_id="remote-b-actor",
                    target_kind="guest_endpoint",
                ),
            ),
            max_state_age_ms=base.max_state_age_ms,
            command_timeout_seconds=timeout_seconds,
        )
        runner = LostSshRunner()
        coordinator = EpochCoordinator(
            config,
            self.runtime_state,
            runner=runner,
        )
        self.runtime_state.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "mode": "server",
                    "epoch": 7,
                    "known": True,
                }
            ),
            encoding="utf-8",
        )
        write_snapshot(self.master_state, "master", "transition")

        started_at = time.monotonic()
        result = coordinator.reconcile("server", NOW_MS)
        elapsed = time.monotonic() - started_at

        self.assertEqual(result.effective_mode, "bypass")
        self.assertFalse(result.state.known)
        self.assertEqual(runner.local_map["mode"], 1)
        self.assertIsNotNone(runner.local_force_at)
        self.assertLess(runner.local_force_at - started_at, timeout_seconds / 2)
        self.assertEqual(runner.max_remote_active, 2)
        self.assertLess(elapsed, timeout_seconds * 3)
        force_records = [
            item.endpoint
            for item in result.publications
            if item.operation == "force-bypass"
        ]
        self.assertEqual(force_records, ["local", "remote-a", "remote-b"])

    def test_guest_endpoint_health_is_required_for_accelerated_publish(self):
        guest_state = Path(self.temp.name) / "client-guest.json"
        write_guest_snapshot(guest_state)
        base = test_config(self.master_state, self.compute_state)
        config = CoordinatorConfig(
            required_endpoints=(
                RequiredEndpoint(
                    SERVER_ID,
                    PORT_ID,
                    compute_role="client",
                    guest_cache_role="client",
                ),
            ),
            state_sources=(
                *base.state_sources,
                StateSource(
                    "client-guest",
                    path=guest_state,
                    kind="guest_endpoint",
                ),
            ),
            publishers=base.publishers,
            max_state_age_ms=base.max_state_age_ms,
            command_timeout_seconds=base.command_timeout_seconds,
        )
        coordinator = EpochCoordinator(
            config,
            self.runtime_state,
            runner=self.runner,
        )

        published = coordinator.reconcile("client", NOW_MS)
        self.assertEqual(published.outcome, "policy_published")
        self.assertEqual(
            published.gate.healthy_guest_observations[0].source,
            "client-guest",
        )

        write_guest_snapshot(
            guest_state,
            updated_ms=NOW_MS - 10_001,
        )
        stale = coordinator.reconcile("dual", NOW_MS)
        self.assertEqual(stale.effective_mode, "bypass")
        self.assertEqual(stale.state.mode, "bypass")
        self.assertIn("stale_guest_snapshot", stale.gate.reason)

    @unittest.skipIf(
        os.name == "nt" or coordinator_module.fcntl is None,
        "requires POSIX fcntl.flock",
    )
    def test_shared_state_lock_blocks_runner_and_uses_fresh_time_after_wait(self):
        runner = BlockingFirstRunner()
        first = EpochCoordinator(
            test_config(self.master_state, self.compute_state),
            self.runtime_state,
            runner=runner,
        )
        second = EpochCoordinator(
            test_config(self.master_state, self.compute_state),
            self.runtime_state,
            runner=runner,
        )
        clock = {"now_ms": NOW_MS}
        results = {}
        errors = []
        second_lock_attempted = threading.Event()
        original_flock = coordinator_module.fcntl.flock

        def observe_flock(fd, operation):
            if (
                threading.current_thread().name == "epoch-coordinator-second"
                and operation == coordinator_module.fcntl.LOCK_EX
            ):
                second_lock_attempted.set()
            return original_flock(fd, operation)

        def reconcile(name, coordinator, mode):
            try:
                results[name] = coordinator.reconcile(mode)
            except BaseException as error:  # Keep thread failures observable.
                errors.append(error)

        with (
            mock.patch.object(
                coordinator_module.fcntl,
                "flock",
                side_effect=observe_flock,
            ),
            mock.patch.object(
                coordinator_module.time,
                "time",
                side_effect=lambda: clock["now_ms"] / 1000,
            ),
        ):
            first_thread = threading.Thread(
                target=reconcile,
                args=("first", first, "bypass"),
                name="epoch-coordinator-first",
            )
            second_thread = threading.Thread(
                target=reconcile,
                args=("second", second, "server"),
                name="epoch-coordinator-second",
            )
            first_thread.start()
            try:
                self.assertTrue(runner.first_run_entered.wait(timeout=2))
                second_thread.start()
                self.assertTrue(second_lock_attempted.wait(timeout=2))
                self.assertFalse(runner.follow_on_run_entered.wait(timeout=0.2))

                # The second coordinator must evaluate this after its lock wait.
                clock["now_ms"] = NOW_MS + 20_000
            finally:
                runner.release_first_run.set()
                first_thread.join(timeout=5)
                second_thread.join(timeout=5)

        self.assertFalse(first_thread.is_alive())
        self.assertFalse(second_thread.is_alive())
        self.assertEqual(errors, [])
        self.assertIn("first", results)
        self.assertIn("second", results)
        self.assertEqual(results["first"].state.mode, "bypass")
        self.assertEqual(results["second"].effective_mode, "bypass")
        self.assertEqual(results["second"].state.mode, "bypass")
        self.assertEqual(results["second"].exit_code, 2)
        accelerated_publications = [
            command
            for command, _timeout in runner.calls
            if command[command.index("--operation") + 1] in {"stage", "commit"}
            and command[command.index("--mode") + 1] == "server"
        ]
        self.assertEqual(accelerated_publications, [])

    def test_stale_agent_state_forces_bypass(self):
        self.coordinator.reconcile("server", NOW_MS)
        write_snapshot(
            self.master_state,
            "master",
            "absent",
            updated_ms=NOW_MS - 10_001,
        )
        result = self.coordinator.reconcile("server", NOW_MS)
        self.assertEqual(result.exit_code, 2)
        self.assertEqual(result.state.mode, "bypass")
        self.assertIn("stale_snapshot", result.gate.reason)

    def test_failed_bootstrap_never_claims_known_state(self):
        self.runner.fail.add(("publisher-b", "force-bypass", "bypass"))
        result = self.coordinator.reconcile("server", NOW_MS)
        self.assertEqual(result.exit_code, 1)
        self.assertFalse(result.state.known)
        self.assertEqual(result.outcome, "bootstrap_bypass_failed")

    def test_corrupt_journal_adopts_higher_committed_map_epoch(self):
        self.runner.seed("server", 9)
        self.runtime_state.write_text("{not-json", encoding="utf-8")

        result = self.coordinator.reconcile("server", NOW_MS)

        self.assertEqual(result.outcome, "policy_unchanged")
        self.assertEqual(result.state.mode, "server")
        self.assertEqual(result.state.epoch, 9)
        self.assertIn("state_invalid", result.state_input_error)
        self.assertFalse(
            any(
                "--operation" in command
                and command[command.index("--operation") + 1] == "stage"
                for command, _timeout in self.runner.calls
            )
        )

    def test_missing_journal_uses_map_epoch_for_next_policy(self):
        self.runner.seed("server", 9)

        result = self.coordinator.reconcile("dual", NOW_MS)

        self.assertEqual(result.outcome, "policy_published")
        self.assertEqual((result.state.mode, result.state.epoch), ("dual", 10))

    def test_rebuilt_low_epoch_maps_are_rebased_above_journal_floor(self):
        self.runner.seed("bypass", 1)
        self.runtime_state.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "mode": "server",
                    "epoch": 10,
                    "known": True,
                }
            ),
            encoding="utf-8",
        )

        result = self.coordinator.reconcile("server", NOW_MS)

        self.assertEqual(result.outcome, "policy_published")
        self.assertEqual((result.state.mode, result.state.epoch), ("server", 12))
        operations = [
            (
                command[command.index("--operation") + 1],
                command[command.index("--mode") + 1],
                int(command[command.index("--epoch") + 1]),
            )
            for command, _timeout in self.runner.calls
        ]
        self.assertIn(("force-bypass", "bypass", 11), operations)
        self.assertIn(("commit", "server", 12), operations)

    def test_readback_failure_forces_bypass_before_recovery(self):
        self.runner.seed("server", 5)
        self.runner.fail_once.add(("publisher-b", "read-current", "bypass"))
        write_snapshot(self.master_state, "master", "transition")

        result = self.coordinator.reconcile("server", NOW_MS)

        self.assertEqual(result.effective_mode, "bypass")
        self.assertTrue(result.state.known)
        self.assertEqual((result.state.mode, result.state.epoch), ("bypass", 6))
        operations = [
            command[command.index("--operation") + 1]
            for command, _timeout in self.runner.calls
        ]
        self.assertIn("force-bypass", operations)

    def test_no_active_maps_does_not_claim_policy_publication(self):
        self.runner.maps = {"publisher-a": None, "publisher-b": None}
        write_snapshot(self.compute_state, "compute2", "absent", ifindex=21)
        config = CoordinatorConfig(
            required_endpoints=(RequiredEndpoint(SERVER_ID, PORT_ID),),
            state_sources=(
                StateSource("master-state", path=self.master_state),
                StateSource("compute2-state", path=self.compute_state),
            ),
            publishers=(
                PublisherEndpoint(
                    "publisher-a",
                    "master",
                    SERVER_ID,
                    PORT_ID,
                    ("publisher-a",),
                    actor_id="dns-client-cache",
                    target_kind="compute_port",
                ),
                PublisherEndpoint(
                    "publisher-b",
                    "compute2",
                    SERVER_ID,
                    PORT_ID,
                    ("publisher-b",),
                    actor_id="dns-client-cache",
                    target_kind="compute_port",
                ),
            ),
            max_state_age_ms=10_000,
            command_timeout_seconds=3.0,
        )
        coordinator = EpochCoordinator(
            config,
            self.runtime_state,
            runner=self.runner,
        )

        result = coordinator.reconcile("server", NOW_MS)

        self.assertEqual(result.outcome, "no_active_maps")
        self.assertEqual(result.exit_code, 2)
        self.assertFalse(result.state.known)
        self.assertEqual(
            {
                command[command.index("--operation") + 1]
                for command, _timeout in self.runner.calls
            },
            {"read-current"},
        )

    def test_healthy_binding_with_missing_maps_cannot_publish(self):
        self.runner.maps = {"publisher-a": None, "publisher-b": None}

        result = self.coordinator.reconcile("server", NOW_MS)

        self.assertEqual(result.outcome, "bootstrap_bypass_failed")
        self.assertEqual(result.exit_code, 1)
        self.assertFalse(result.state.known)
        self.assertFalse(
            any(
                command[command.index("--operation") + 1] == "stage"
                for command, _timeout in self.runner.calls
            )
        )

    def test_accelerated_commit_with_journal_failure_recovers_to_next_bypass(self):
        self.runner.seed("bypass", 1)
        self.runtime_state.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "mode": "bypass",
                    "epoch": 1,
                    "known": True,
                }
            ),
            encoding="utf-8",
        )

        def fail_write(_state):
            raise OSError("disk full")

        self.coordinator._write_runtime_state = fail_write
        result = self.coordinator.reconcile("server", NOW_MS)

        self.assertEqual(result.outcome, "state_write_failed_bypass_recovered")
        self.assertEqual((result.state.mode, result.state.epoch), ("bypass", 3))
        self.assertEqual(self.runner.maps["publisher-a"]["mode"], 1)
        self.assertEqual(self.runner.maps["publisher-b"]["mode"], 1)
        self.assertIn("state_write_error", result.state_input_error)

    def test_watch_shutdown_forces_all_maps_back_to_bypass(self):
        desired = self.runtime_state.with_name("desired.json")
        desired.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "mode": "server",
                    "updated_ms": int(__import__("time").time() * 1000),
                }
            ),
            encoding="utf-8",
        )
        self.coordinator.reconcile("server", NOW_MS)
        stopping = threading.Event()
        stopping.set()

        exit_code = _run_watch_loop(
            self.coordinator,
            desired,
            None,
            0.01,
            10_000,
            stopping,
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual(self.runner.maps["publisher-a"]["mode"], 1)
        self.assertEqual(self.runner.maps["publisher-b"]["mode"], 1)

    def test_watch_shutdown_republishes_fresh_bypass_when_already_bypass(self):
        now_ms = int(time.time() * 1000)
        write_snapshot(self.master_state, "master", "absent", updated_ms=now_ms)
        write_snapshot(
            self.compute_state,
            "compute2",
            "healthy",
            ifindex=21,
            updated_ms=now_ms,
        )
        initial = self.coordinator.reconcile("bypass", now_ms)
        baseline_epoch = initial.state.epoch
        unchanged = self.coordinator.reconcile("bypass", now_ms)
        self.assertEqual(unchanged.outcome, "policy_unchanged")
        self.assertEqual(unchanged.state.epoch, baseline_epoch)
        audit_log = self.runtime_state.with_name("audit.jsonl")
        stopping = threading.Event()
        stopping.set()

        exit_code = _run_watch_loop(
            self.coordinator,
            self.runtime_state.with_name("desired.json"),
            audit_log,
            0.01,
            10_000,
            stopping,
        )

        record = json.loads(audit_log.read_text(encoding="utf-8"))
        shutdown_epoch = baseline_epoch + 1
        assessment = coordinator_module._assess_committed_audit(
            [record],
            test_config(self.master_state, self.compute_state),
            "bypass",
            shutdown_epoch,
            2,
            True,
        )
        self.assertEqual(exit_code, 0)
        self.assertTrue(assessment.ready, assessment.reason)
        self.assertIs(record["shutdown"], True)
        self.assertEqual(record["outcome"], "policy_published")
        self.assertEqual(
            (record["state"]["mode"], record["state"]["epoch"]),
            ("bypass", shutdown_epoch),
        )
        self.assertEqual(
            (
                self.runner.maps["publisher-a"]["mode"],
                self.runner.maps["publisher-a"]["epoch"],
            ),
            (1, shutdown_epoch),
        )
        self.assertEqual(
            (
                self.runner.maps["publisher-b"]["mode"],
                self.runner.maps["publisher-b"]["epoch"],
            ),
            (1, shutdown_epoch),
        )

    def test_shutdown_barrier_accepts_fresh_bypass_during_migration_freeze(self):
        now_ms = int(time.time() * 1000)
        write_snapshot(
            self.master_state,
            "master",
            "healthy",
            updated_ms=now_ms,
        )
        write_snapshot(
            self.compute_state,
            "compute2",
            "absent",
            binding_host="master",
            updated_ms=now_ms,
        )
        initial = self.coordinator.reconcile("server", now_ms)
        write_snapshot(
            self.master_state,
            "master",
            "transition",
            binding_host="compute2",
            updated_ms=now_ms,
        )
        audit_log = self.runtime_state.with_name("freeze-audit.jsonl")
        stopping = threading.Event()
        stopping.set()

        exit_code = _run_watch_loop(
            self.coordinator,
            self.runtime_state.with_name("desired.json"),
            audit_log,
            0.01,
            10_000,
            stopping,
        )

        record = json.loads(audit_log.read_text(encoding="utf-8"))
        assessment = coordinator_module._assess_committed_audit(
            [record],
            test_config(self.master_state, self.compute_state),
            "bypass",
            initial.state.epoch + 1,
            2,
            True,
        )
        self.assertEqual(exit_code, 0)
        self.assertEqual(record["outcome"], "migration_forced_bypass")
        self.assertEqual(record["gate"]["action"], "freeze")
        self.assertIs(record["shutdown"], True)
        self.assertTrue(assessment.ready, assessment.reason)

    def test_watch_audit_failure_still_forces_bypass_before_error(self):
        desired = self.runtime_state.with_name("desired.json")
        desired.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "mode": "server",
                    "updated_ms": int(__import__("time").time() * 1000),
                }
            ),
            encoding="utf-8",
        )
        self.coordinator.reconcile("server", NOW_MS)
        stopping = threading.Event()

        with (
            mock.patch.object(
                coordinator_module,
                "_emit",
                side_effect=OSError("audit disk full"),
            ),
            self.assertRaisesRegex(OSError, "audit disk full"),
        ):
            _run_watch_loop(
                self.coordinator,
                desired,
                Path("/unwritable/audit.jsonl"),
                0.01,
                10_000,
                stopping,
            )

        self.assertEqual(self.runner.maps["publisher-a"]["mode"], 1)
        self.assertEqual(self.runner.maps["publisher-b"]["mode"], 1)

    def test_short_host_preserves_ip_addresses_and_shortens_fqdn(self):
        self.assertEqual(_short_host("172.24.4.203"), "172.24.4.203")
        self.assertEqual(_short_host("2001:db8::1"), "2001:db8::1")
        self.assertEqual(_short_host("master.example.test"), "master")


class PublicationWaitCommandTest(unittest.TestCase):
    @staticmethod
    def _config_path():
        return (
            Path(__file__).resolve().parents[1]
            / "deploy"
            / "examples"
            / "coordinator.json.example"
        )

    def _publication(self, epoch=8, mode="server", outcome="policy_published"):
        config = load_config(self._config_path())
        mode_value = {"bypass": 1, "server": 2, "client": 3, "dual": 4}[mode]
        readbacks = []
        active_actors = set()
        for publisher in config.publishers:
            present = publisher.actor_id not in active_actors
            active_actors.add(publisher.actor_id)
            readbacks.append(
                {
                    "endpoint": publisher.name,
                    "host": publisher.host,
                    "server_id": publisher.server_id,
                    "port_id": publisher.port_id,
                    "actor_id": publisher.actor_id,
                    "target_kind": publisher.target_kind,
                    "services": list(publisher.services),
                    "cache_role": publisher.cache_role,
                    "present": present,
                    "maps": len(publisher.services) if present else 0,
                    "epoch": epoch if present else 0,
                    "mode": mode_value if present else 0,
                    "flags": 1 if present else 0,
                }
            )
        return {
            "outcome": outcome,
            "requested_mode": mode,
            "effective_mode": mode,
            "exit_code": 0,
            "desired_input_error": "",
            "state_input_error": "",
            "state": {"mode": mode, "epoch": epoch, "known": True},
            "gate": {
                "action": "publish",
                "reason": "all_required_endpoints_healthy",
            },
            "map_readbacks": readbacks,
        }, len(active_actors)

    def _fail_safe_shutdown_publication(self, epoch=76):
        publication, present_count = self._publication(
            epoch=epoch,
            mode="bypass",
            outcome="fail_safe_bypass_published",
        )
        publication.update(
            {
                "shutdown": True,
                "requested_mode": "bypass",
                "effective_mode": "bypass",
                "exit_code": 2,
                "state_input_error": "CoordinatorError:state journal missing",
                "gate": {
                    "action": "bypass",
                    "force_bypass": True,
                    "reason": "state_input_error:GateError:agent state missing",
                },
            }
        )
        del publication["desired_input_error"]
        return publication, present_count

    @staticmethod
    def _write_desired(root, mode="server"):
        (root / "desired.json").write_text(
            json.dumps({"schema_version": 1, "mode": mode}),
            encoding="utf-8",
        )

    @staticmethod
    def _write_state(root, mode, epoch, known=True):
        (root / "state.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "mode": mode,
                    "epoch": epoch,
                    "known": known,
                }
            ),
            encoding="utf-8",
        )

    def _run_wait(
        self,
        root,
        min_present,
        timeout="0.08",
        after_epoch="7",
        target_mode="server",
        require_shutdown=False,
    ):
        command = [
                sys.executable,
                str(Path(coordinator_module.__file__).resolve()),
                "wait-committed",
                "--config",
                str(self._config_path()),
                "--desired-mode-file",
                str(root / "desired.json"),
                "--state-file",
                str(root / "state.json"),
                "--audit-log",
                str(root / "audit.jsonl"),
                "--target-mode",
                target_mode,
                "--after-epoch",
                after_epoch,
                "--min-present-readbacks",
                str(min_present),
                "--timeout",
                timeout,
                "--interval",
                "0.01",
            ]
        if require_shutdown:
            command.append("--require-shutdown")
        return subprocess.run(
            command,
            text=True,
            capture_output=True,
            check=False,
        )

    def _run_transition_wait(
        self,
        root,
        *,
        after_offset,
        audit_device,
        audit_inode,
        timeout="0.08",
    ):
        return subprocess.run(
            [
                sys.executable,
                str(Path(coordinator_module.__file__).resolve()),
                "wait-transition",
                "--config",
                str(self._config_path()),
                "--audit-log",
                str(root / "audit.jsonl"),
                "--after-offset",
                str(after_offset),
                "--audit-device",
                str(audit_device),
                "--audit-inode",
                str(audit_inode),
                "--server-id",
                "REPLACE_BACKEND_SERVER_UUID",
                "--port-id",
                "REPLACE_BACKEND_PORT_UUID",
                "--source-host",
                "master",
                "--after-epoch",
                "8",
                "--timeout",
                timeout,
                "--interval",
                "0.01",
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def _forced_transition(self, epoch=9):
        transition, _present_count = self._publication(
            epoch=epoch,
            mode="bypass",
            outcome="migration_forced_bypass",
        )
        transition.update(
            {
                "requested_mode": "server",
                "effective_mode": "bypass",
                "exit_code": 2,
                "gate": {
                    "action": "freeze",
                    "reason": (
                        "migration_transition:REPLACE_BACKEND_SERVER_UUID:"
                        "REPLACE_BACKEND_PORT_UUID:master"
                    ),
                },
            }
        )
        config = load_config(self._config_path())
        transition["publications"] = [
            {
                "endpoint": publisher.name,
                "operation": "force-bypass",
                "mode": "bypass",
                "epoch": epoch,
                "returncode": 0,
                "detail": "published",
            }
            for publisher in config.publishers
        ]
        return transition

    def test_wait_transition_matches_forced_bypass_after_exact_offset(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            audit = root / "audit.jsonl"
            audit.write_bytes(b'{"outcome":"older"}\n')
            after_offset = audit.stat().st_size
            identity = audit.stat()
            transition = self._forced_transition()
            with audit.open("ab") as output:
                output.write(
                    json.dumps(
                        transition, separators=(",", ":"), sort_keys=True
                    ).encode("utf-8")
                    + b"\n"
                )
            matched_end = audit.stat().st_size

            result = self._run_transition_wait(
                root,
                after_offset=after_offset,
                audit_device=identity.st_dev,
                audit_inode=identity.st_ino,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(result.stdout),
                {
                    "epoch": 9,
                    "matched_byte_end": matched_end,
                    "matched_byte_start": after_offset,
                    "outcome": "migration_forced_bypass",
                    "ready": True,
                },
            )

    def test_wait_transition_rejects_audit_identity_change(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            audit = root / "audit.jsonl"
            audit.write_bytes(b'{"outcome":"older"}\n')
            identity = audit.stat()

            result = self._run_transition_wait(
                root,
                after_offset=identity.st_size,
                audit_device=identity.st_dev,
                audit_inode=identity.st_ino + 1,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("audit log identity changed", result.stderr)

    def test_wait_transition_rejects_truncation_below_offset(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            audit = root / "audit.jsonl"
            audit.write_bytes(b"{}\n")
            identity = audit.stat()

            result = self._run_transition_wait(
                root,
                after_offset=identity.st_size + 1,
                audit_device=identity.st_dev,
                audit_inode=identity.st_ino,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "audit log truncated below after-offset", result.stderr
            )

    def test_wait_transition_requires_the_exact_migration_reason(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            audit = root / "audit.jsonl"
            audit.touch()
            identity = audit.stat()
            transition = self._forced_transition()
            transition["gate"]["reason"] += ":unexpected"
            audit.write_text(
                json.dumps(transition) + "\n", encoding="utf-8"
            )

            result = self._run_transition_wait(
                root,
                after_offset=0,
                audit_device=identity.st_dev,
                audit_inode=identity.st_ino,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "audit_has_no_matching_transition", result.stderr
            )

    def test_wait_transition_requires_fresh_known_bypass_state(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            audit = root / "audit.jsonl"
            audit.touch()
            identity = audit.stat()
            transition = self._forced_transition()
            transition["state"]["known"] = False
            audit.write_text(
                json.dumps(transition) + "\n", encoding="utf-8"
            )

            result = self._run_transition_wait(
                root,
                after_offset=0,
                audit_device=identity.st_dev,
                audit_inode=identity.st_ino,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "audit_transition_state_not_fresh_known_bypass",
                result.stderr,
            )

    def test_wait_transition_requires_every_forced_publisher(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            audit = root / "audit.jsonl"
            audit.touch()
            identity = audit.stat()
            transition = self._forced_transition()
            transition["publications"].pop()
            audit.write_text(
                json.dumps(transition) + "\n", encoding="utf-8"
            )

            result = self._run_transition_wait(
                root,
                after_offset=0,
                audit_device=identity.st_dev,
                audit_inode=identity.st_ino,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "audit_transition_force_set_mismatch", result.stderr
            )

    def test_wait_transition_requires_same_epoch_bypass_readback(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            audit = root / "audit.jsonl"
            audit.touch()
            identity = audit.stat()
            transition = self._forced_transition()
            present = next(
                item
                for item in transition["map_readbacks"]
                if item["present"]
            )
            present["epoch"] = 10
            audit.write_text(
                json.dumps(transition) + "\n", encoding="utf-8"
            )

            result = self._run_transition_wait(
                root,
                after_offset=0,
                audit_device=identity.st_dev,
                audit_inode=identity.st_ino,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "audit_transition_readback_not_bypass", result.stderr
            )

    def test_wait_transition_accepts_already_frozen_known_bypass(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            audit = root / "audit.jsonl"
            audit.touch()
            identity = audit.stat()
            transition = self._forced_transition()
            transition["outcome"] = "migration_frozen_in_bypass"
            transition["publications"] = []
            audit.write_text(
                json.dumps(transition) + "\n", encoding="utf-8"
            )

            result = self._run_transition_wait(
                root,
                after_offset=0,
                audit_device=identity.st_dev,
                audit_inode=identity.st_ino,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            output = json.loads(result.stdout)
            self.assertEqual(output["outcome"], "migration_frozen_in_bypass")
            self.assertEqual(output["epoch"], 9)

    def test_waits_for_a_fresh_committed_epoch(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_desired(root)
            self._write_state(root, "bypass", 7)
            publication, present_count = self._publication()

            def publish_after_wait_started():
                time.sleep(0.15)
                self._write_state(root, "server", 8)
                (root / "audit.jsonl").write_text(
                    json.dumps(publication) + "\n" + '{"partial"',
                    encoding="utf-8",
                )

            writer = threading.Thread(target=publish_after_wait_started)
            writer.start()
            result = self._run_wait(root, present_count, timeout="2")
            writer.join()

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(result.stdout),
                {
                    "epoch": 8,
                    "mode": "server",
                    "present_readbacks": present_count,
                    "ready": True,
                },
            )

    def test_accepts_bypass_rebase_proven_by_force_publications(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_desired(root, mode="bypass")
            self._write_state(root, "bypass", 70)
            publication, present_count = self._publication(
                epoch=70,
                mode="bypass",
                outcome="policy_unchanged",
            )
            config = load_config(self._config_path())
            publication["publications"] = [
                {
                    "endpoint": publisher.name,
                    "operation": "force-bypass",
                    "mode": "bypass",
                    "epoch": 70,
                    "returncode": 0,
                    "detail": "published",
                }
                for publisher in config.publishers
            ]
            (root / "audit.jsonl").write_text(
                json.dumps(publication) + "\n", encoding="utf-8"
            )

            result = self._run_wait(
                root,
                present_count,
                after_epoch="69",
                target_mode="bypass",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(result.stdout),
                {
                    "epoch": 70,
                    "mode": "bypass",
                    "present_readbacks": present_count,
                    "ready": True,
                },
            )

    def test_shutdown_barrier_accepts_committed_bypass_without_desired_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_state(root, "bypass", 75)
            publication, present_count = self._publication(
                epoch=75,
                mode="bypass",
            )
            del publication["desired_input_error"]
            publication["shutdown"] = True
            (root / "audit.jsonl").write_text(
                json.dumps(publication) + "\n", encoding="utf-8"
            )

            result = self._run_wait(
                root,
                present_count,
                after_epoch="74",
                target_mode="bypass",
                require_shutdown=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            output = json.loads(result.stdout)
            self.assertEqual(output["epoch"], 75)
            self.assertIs(output.get("shutdown"), True)

    def test_shutdown_barrier_rejects_regular_bypass_publication(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_desired(root, mode="bypass")
            self._write_state(root, "bypass", 75)
            publication, present_count = self._publication(
                epoch=75,
                mode="bypass",
            )
            (root / "audit.jsonl").write_text(
                json.dumps(publication) + "\n", encoding="utf-8"
            )

            result = self._run_wait(
                root,
                present_count,
                after_epoch="74",
                target_mode="bypass",
                require_shutdown=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("audit_shutdown_proof_missing", result.stderr)

    def test_shutdown_barrier_accepts_committed_fail_safe_bypass(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_state(root, "bypass", 76)
            publication, present_count = (
                self._fail_safe_shutdown_publication()
            )
            (root / "audit.jsonl").write_text(
                json.dumps(publication) + "\n", encoding="utf-8"
            )

            result = self._run_wait(
                root,
                present_count,
                after_epoch="75",
                target_mode="bypass",
                require_shutdown=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(result.stdout),
                {
                    "epoch": 76,
                    "mode": "bypass",
                    "present_readbacks": present_count,
                    "ready": True,
                    "shutdown": True,
                },
            )

    def test_regular_barrier_rejects_fail_safe_bypass(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_desired(root, mode="bypass")
            self._write_state(root, "bypass", 76)
            publication, present_count = (
                self._fail_safe_shutdown_publication()
            )
            (root / "audit.jsonl").write_text(
                json.dumps(publication) + "\n", encoding="utf-8"
            )

            result = self._run_wait(
                root,
                present_count,
                after_epoch="75",
                target_mode="bypass",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "audit_outcome_not_policy_published", result.stderr
            )

    def test_shutdown_fail_safe_barrier_requires_forced_bypass_gate(self):
        invalid_gates = (
            {
                "action": "publish",
                "force_bypass": True,
                "reason": "state_input_error:GateError:agent state missing",
            },
            {
                "action": "bypass",
                "force_bypass": False,
                "reason": "state_input_error:GateError:agent state missing",
            },
            {
                "action": "bypass",
                "force_bypass": True,
                "reason": "   ",
            },
        )
        for gate in invalid_gates:
            with self.subTest(gate=gate), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                self._write_state(root, "bypass", 76)
                publication, present_count = (
                    self._fail_safe_shutdown_publication()
                )
                publication["gate"] = gate
                (root / "audit.jsonl").write_text(
                    json.dumps(publication) + "\n", encoding="utf-8"
                )

                result = self._run_wait(
                    root,
                    present_count,
                    after_epoch="75",
                    target_mode="bypass",
                    require_shutdown=True,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "audit_shutdown_fail_safe_gate_invalid", result.stderr
                )

    def test_shutdown_fail_safe_barrier_requires_exact_result_fields(self):
        invalid_fields = (
            ("requested_mode", "server"),
            ("effective_mode", "server"),
            ("exit_code", 0),
        )
        for field, value in invalid_fields:
            with (
                self.subTest(field=field, value=value),
                tempfile.TemporaryDirectory() as temp,
            ):
                root = Path(temp)
                self._write_state(root, "bypass", 76)
                publication, present_count = (
                    self._fail_safe_shutdown_publication()
                )
                publication[field] = value
                (root / "audit.jsonl").write_text(
                    json.dumps(publication) + "\n", encoding="utf-8"
                )

                result = self._run_wait(
                    root,
                    present_count,
                    after_epoch="75",
                    target_mode="bypass",
                    require_shutdown=True,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "audit_shutdown_fail_safe_result_mismatch",
                    result.stderr,
                )

    def test_shutdown_fail_safe_barrier_requires_typed_state_error(self):
        invalid_inputs = (
            ("state_input_error", None),
            ("state_input_error", 1),
            ("desired_input_error", "CoordinatorError:desired mode invalid"),
        )
        for field, value in invalid_inputs:
            with (
                self.subTest(field=field, value=value),
                tempfile.TemporaryDirectory() as temp,
            ):
                root = Path(temp)
                self._write_state(root, "bypass", 76)
                publication, present_count = (
                    self._fail_safe_shutdown_publication()
                )
                publication[field] = value
                (root / "audit.jsonl").write_text(
                    json.dumps(publication) + "\n", encoding="utf-8"
                )

                result = self._run_wait(
                    root,
                    present_count,
                    after_epoch="75",
                    target_mode="bypass",
                    require_shutdown=True,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "audit_shutdown_fail_safe_input_invalid", result.stderr
                )

    def test_shutdown_barrier_rejects_unchanged_fail_safe_bypass(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_state(root, "bypass", 76)
            publication, present_count = (
                self._fail_safe_shutdown_publication()
            )
            publication["outcome"] = "fail_safe_bypass_unchanged"
            (root / "audit.jsonl").write_text(
                json.dumps(publication) + "\n", encoding="utf-8"
            )

            result = self._run_wait(
                root,
                present_count,
                after_epoch="75",
                target_mode="bypass",
                require_shutdown=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "audit_outcome_not_policy_published", result.stderr
            )

    def test_shutdown_fail_safe_barrier_keeps_strict_readback_checks(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_state(root, "bypass", 76)
            publication, present_count = (
                self._fail_safe_shutdown_publication()
            )
            present = next(
                item for item in publication["map_readbacks"] if item["present"]
            )
            present["flags"] = 0
            (root / "audit.jsonl").write_text(
                json.dumps(publication) + "\n", encoding="utf-8"
            )

            result = self._run_wait(
                root,
                present_count,
                after_epoch="75",
                target_mode="bypass",
                require_shutdown=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                f"audit_present_readback_not_committed:{present['endpoint']}",
                result.stderr,
            )

    def test_non_bypass_policy_unchanged_never_satisfies_the_barrier(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_desired(root)
            self._write_state(root, "server", 8)
            publication, present_count = self._publication(
                outcome="policy_unchanged"
            )
            (root / "audit.jsonl").write_text(
                json.dumps(publication) + "\n", encoding="utf-8"
            )

            result = self._run_wait(root, present_count)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "audit_outcome_not_policy_published", result.stderr
            )

    def test_bypass_policy_unchanged_without_force_proof_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_desired(root, mode="bypass")
            self._write_state(root, "bypass", 70)
            publication, present_count = self._publication(
                epoch=70,
                mode="bypass",
                outcome="policy_unchanged",
            )
            publication["publications"] = []
            (root / "audit.jsonl").write_text(
                json.dumps(publication) + "\n", encoding="utf-8"
            )

            result = self._run_wait(
                root,
                present_count,
                after_epoch="69",
                target_mode="bypass",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "audit_bypass_rebase_force_set_mismatch", result.stderr
            )

    def test_wrong_readback_flags_never_satisfy_the_barrier(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_desired(root)
            self._write_state(root, "server", 8)
            publication, present_count = self._publication()
            present = next(
                item for item in publication["map_readbacks"] if item["present"]
            )
            present["flags"] = 0
            (root / "audit.jsonl").write_text(
                json.dumps(publication) + "\n", encoding="utf-8"
            )

            result = self._run_wait(root, present_count)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                f"audit_present_readback_not_committed:{present['endpoint']}",
                result.stderr,
            )

    def test_missing_desired_input_status_never_satisfies_the_barrier(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_desired(root)
            self._write_state(root, "server", 8)
            publication, present_count = self._publication()
            del publication["desired_input_error"]
            (root / "audit.jsonl").write_text(
                json.dumps(publication) + "\n", encoding="utf-8"
            )

            result = self._run_wait(root, present_count)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("audit_input_error_present", result.stderr)

    def test_boolean_audit_epoch_never_satisfies_the_barrier(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_desired(root)
            self._write_state(root, "server", 1)
            publication, present_count = self._publication(epoch=1)
            publication["state"]["epoch"] = True
            (root / "audit.jsonl").write_text(
                json.dumps(publication) + "\n", encoding="utf-8"
            )

            result = self._run_wait(
                root, present_count, after_epoch="0"
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("audit_state_fields_invalid", result.stderr)

    def test_stale_epoch_never_satisfies_the_barrier(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_desired(root)
            self._write_state(root, "server", 7)
            publication, present_count = self._publication(epoch=7)
            (root / "audit.jsonl").write_text(
                json.dumps(publication) + "\n", encoding="utf-8"
            )

            result = self._run_wait(root, present_count)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("runtime_epoch_not_fresh:7:7", result.stderr)

    def test_missing_audit_never_satisfies_the_barrier(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_desired(root)
            self._write_state(root, "server", 8)
            _publication, present_count = self._publication()

            result = self._run_wait(root, present_count)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("audit_log_missing", result.stderr)


class CoordinatorConfigTest(unittest.TestCase):
    def test_controller_unit_does_not_depend_on_a_local_compute_agent(self):
        unit = (
            Path(__file__).resolve().parents[1]
            / "deploy"
            / "systemd"
            / "vnet-dataplane-epoch-coordinator.service"
        ).read_text(encoding="utf-8")
        self.assertNotIn("vnet-dataplane-agent.service", unit)

    def test_controller_units_keep_cli_shutdown_budget_below_systemd_timeout(self):
        unit_dir = Path(__file__).resolve().parents[1] / "deploy" / "systemd"
        for name in (
            "vnet-dataplane-epoch-coordinator.service",
            "vnet-dataplane-shared-epoch-coordinator.service",
        ):
            with self.subTest(unit=name):
                unit = (unit_dir / name).read_text(encoding="utf-8")
                shutdown_budget = float(
                    next(
                        line.rsplit("=", 1)[1]
                        for line in unit.splitlines()
                        if line.startswith(
                            "Environment=VNET_COORDINATOR_SHUTDOWN_TIMEOUT="
                        )
                    )
                )
                systemd_timeout = float(
                    next(
                        line.split("=", 1)[1]
                        for line in unit.splitlines()
                        if line.startswith("TimeoutStopSec=")
                    )
                )
                self.assertIn(
                    "--shutdown-timeout-seconds "
                    "${VNET_COORDINATOR_SHUTDOWN_TIMEOUT}",
                    unit,
                )
                self.assertLess(shutdown_budget, systemd_timeout)

    def test_desired_mode_freshness_uses_atomic_payload_timestamp(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "desired.json"
            path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "mode": "client",
                        "updated_ms": 1_000,
                    }
                ),
                encoding="utf-8",
            )
            self.assertEqual(
                _read_desired_mode(path, max_age_ms=1_000, now_ms=1_500),
                "client",
            )
            with self.assertRaisesRegex(CoordinatorError, "stale"):
                _read_desired_mode(path, max_age_ms=1_000, now_ms=2_001)
            with self.assertRaisesRegex(CoordinatorError, "future"):
                _read_desired_mode(path, max_age_ms=1_000, now_ms=-5_001)

    def test_direct_script_import_exposes_guest_gate_symbols(self):
        agent_dir = Path(__file__).resolve().parents[1] / "agent"
        probe = (
            "import sys;"
            f"sys.path.insert(0, {str(agent_dir)!r});"
            "import openstack_epoch_coordinator as module;"
            "assert hasattr(module, 'GuestEndpointSnapshot');"
            "assert hasattr(module, 'parse_guest_endpoint_snapshot')"
        )
        result = subprocess.run(
            [sys.executable, "-c", probe],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    @staticmethod
    def _example_payload():
        example = (
            Path(__file__).resolve().parents[1]
            / "deploy"
            / "examples"
            / "coordinator.json.example"
        )
        return json.loads(example.read_text(encoding="utf-8"))

    def test_example_config_passes_integrity_validation(self):
        example = (
            Path(__file__).resolve().parents[1]
            / "deploy"
            / "examples"
            / "coordinator.json.example"
        )
        config = load_config(example)
        self.assertEqual(len(config.publishers), 6)
        self.assertEqual(
            config.policy_lock_root, "/run/vnet-dataplane-policy"
        )
        self.assertEqual(
            config.required_endpoints[0].grpc_backend_server_id,
            config.required_endpoints[1].server_id,
        )

    def test_observer_compute_publisher_uses_server_cache_role(self):
        payload = json.loads(
            (
                Path(__file__).resolve().parents[1]
                / "deploy"
                / "lab"
                / "shuka1-p1"
                / "coordinator.json"
            ).read_text(encoding="utf-8")
        )
        publisher = next(
            item
            for item in payload["publishers"]
            if item["name"] == "backend-host-caches"
        )
        with tempfile.TemporaryDirectory() as temp:
            config_path = Path(temp) / "coordinator.json"
            config_path.write_text(json.dumps(payload), encoding="utf-8")

            config = load_config(config_path)

        observed = next(
            item
            for item in config.publishers
            if item.name == "backend-host-caches"
        )
        self.assertEqual(observed.target_kind, "compute_port")
        self.assertEqual(observed.cache_role, "server")

    def test_observer_compute_publisher_rejects_client_cache_role(self):
        payload = json.loads(
            (
                Path(__file__).resolve().parents[1]
                / "deploy"
                / "lab"
                / "shuka1-p1"
                / "coordinator.json"
            ).read_text(encoding="utf-8")
        )
        publisher = next(
            item
            for item in payload["publishers"]
            if item["name"] == "backend-host-caches"
        )
        publisher["target_kind"] = "compute_port"
        publisher["cache_role"] = "client"
        with tempfile.TemporaryDirectory() as temp:
            config_path = Path(temp) / "coordinator.json"
            config_path.write_text(json.dumps(payload), encoding="utf-8")

            with self.assertRaisesRegex(
                CoordinatorError,
                "compute_port cache_role does not match",
            ):
                load_config(config_path)

    def test_shuka1_config_accepts_the_pinned_ssh_prefix(self):
        config_path = (
            Path(__file__).resolve().parents[1]
            / "deploy"
            / "lab"
            / "shuka1-p1"
            / "coordinator.json"
        )

        config = load_config(config_path)

        remote = next(
            publisher
            for publisher in config.publishers
            if publisher.host == "compute2"
        )
        self.assertIn(
            "UserKnownHostsFile=/etc/vnet-dataplane-agent/lab-known-hosts.p1",
            remote.command,
        )

    def test_remote_publisher_can_separate_nova_host_from_ssh_destination(self):
        payload = self._example_payload()
        remote = next(
            item for item in payload["publishers"] if item["host"] == "compute2"
        )
        remote["ssh_destination"] = "ubuntu@172.25.6.13"
        remote["command"][9] = remote["ssh_destination"]
        with tempfile.TemporaryDirectory() as directory:
            candidate = Path(directory) / "coordinator.json"
            candidate.write_text(json.dumps(payload), encoding="utf-8")

            config = load_config(candidate)

        observed = next(item for item in config.publishers if item.name == remote["name"])
        self.assertEqual(observed.host, "compute2")
        self.assertEqual(observed.ssh_destination, "ubuntu@172.25.6.13")

    def test_remote_publisher_rejects_mismatched_explicit_ssh_destination(self):
        payload = self._example_payload()
        remote = next(
            item for item in payload["publishers"] if item["host"] == "compute2"
        )
        remote["ssh_destination"] = "ubuntu@172.25.6.13"
        with tempfile.TemporaryDirectory() as directory:
            candidate = Path(directory) / "coordinator.json"
            candidate.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(CoordinatorError, "ssh destination"):
                load_config(candidate)

    def test_remote_publisher_rejects_disabled_host_key_checking(self):
        config_path = (
            Path(__file__).resolve().parents[1]
            / "deploy"
            / "lab"
            / "shuka1-p1"
            / "coordinator.json"
        )
        payload = json.loads(config_path.read_text(encoding="utf-8"))
        remote = next(
            publisher
            for publisher in payload["publishers"]
            if publisher["host"] == "compute2"
        )
        index = remote["command"].index("StrictHostKeyChecking=yes")
        remote["command"][index] = "StrictHostKeyChecking=no"

        with tempfile.TemporaryDirectory() as directory:
            candidate = Path(directory) / "coordinator.json"
            candidate.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(CoordinatorError, "strict host-key"):
                load_config(candidate)

    def test_remote_publisher_rejects_known_hosts_outside_config_root(self):
        config_path = (
            Path(__file__).resolve().parents[1]
            / "deploy"
            / "lab"
            / "shuka1-p1"
            / "coordinator.json"
        )
        payload = json.loads(config_path.read_text(encoding="utf-8"))
        remote = next(
            publisher
            for publisher in payload["publishers"]
            if publisher["host"] == "compute2"
        )
        index = next(
            i
            for i, argument in enumerate(remote["command"])
            if argument.startswith("UserKnownHostsFile=")
        )
        remote["command"][index] = "UserKnownHostsFile=/tmp/known_hosts"

        with tempfile.TemporaryDirectory() as directory:
            candidate = Path(directory) / "coordinator.json"
            candidate.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(CoordinatorError, "direct child"):
                load_config(candidate)

    def test_config_rejects_a_non_production_policy_root(self):
        payload = self._example_payload()
        payload["policy_lock_root"] = "/tmp/vnet-dataplane-policy"

        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "coordinator.json"
            config.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(CoordinatorError, "must be exactly"):
                load_config(config)

    def test_publisher_lock_and_quiesce_must_share_policy_root(self):
        payload = self._example_payload()
        command = payload["publishers"][0]["command"]
        command[command.index("--lock-file") + 1] = (
            f"/tmp/vnet-dataplane-{payload['publishers'][0]['port_id']}.lock"
        )
        command[command.index("--quiesce-file") + 1] = (
            f"/tmp/vnet-dataplane-{payload['publishers'][0]['port_id']}.quiesce"
        )

        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "coordinator.json"
            config.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(CoordinatorError, "policy_lock_root"):
                load_config(config)

    def test_publisher_control_map_must_match_its_port(self):
        payload = self._example_payload()
        command = payload["publishers"][0]["command"]
        first_map = command.index("--control-map") + 1
        command[first_map] = command[first_map].replace(
            payload["publishers"][0]["port_id"],
            payload["publishers"][3]["port_id"],
        )

        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "coordinator.json"
            config.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(CoordinatorError, "control map"):
                load_config(config)

    def test_publisher_requires_declared_protocol_and_direct_txn_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "coordinator.json"
            config.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "required_endpoints": [
                            {"server_id": SERVER_ID, "port_id": PORT_ID}
                        ],
                        "state_sources": [
                            {"name": "state", "path": str(root / "state.json")}
                        ],
                        "publishers": [
                            {
                                "name": "bad",
                                "host": "master",
                                "server_id": SERVER_ID,
                                "port_id": PORT_ID,
                                "protocol": "cache-policy-txn-v1",
                                "command": ["/bin/sh", "-c", "cache_policy_txn"],
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaises(CoordinatorError):
                load_config(config)

    def test_publisher_cannot_hide_txn_name_behind_noop_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "coordinator.json"
            config.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "required_endpoints": [
                            {"server_id": SERVER_ID, "port_id": PORT_ID}
                        ],
                        "state_sources": [
                            {"name": "state", "path": str(root / "state.json")}
                        ],
                        "publishers": [
                            {
                                "name": "bad",
                                "host": "master",
                                "server_id": SERVER_ID,
                                "port_id": PORT_ID,
                                "protocol": "cache-policy-txn-v1",
                                "command": ["/bin/true", "cache_policy_txn"],
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaises(CoordinatorError):
                load_config(config)

    def test_remote_publisher_rejects_shell_comment_injection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "coordinator.json"
            config.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "required_endpoints": [
                            {"server_id": SERVER_ID, "port_id": PORT_ID}
                        ],
                        "state_sources": [
                            {"name": "state", "path": str(root / "state.json")}
                        ],
                        "publishers": [
                            {
                                "name": "bad-remote",
                                "host": "compute2",
                                "server_id": SERVER_ID,
                                "port_id": PORT_ID,
                                "protocol": "cache-policy-txn-v1",
                                "command": [
                                    "/usr/bin/ssh",
                                    "-o",
                                    "BatchMode=yes",
                                    "compute2",
                                    "printf",
                                    "#",
                                    "/usr/bin/sudo",
                                    "-n",
                                    "/opt/cache_policy_txn",
                                    "--allow-all-missing",
                                    "--lock-file",
                                    "/run/vnet-dataplane-policy/test.lock",
                                    "--quiesce-file",
                                    "/run/vnet-dataplane-policy/test.quiesce",
                                    "--control-map",
                                    "/sys/fs/bpf/a",
                                    "--control-map",
                                    "/sys/fs/bpf/b",
                                ],
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaises(CoordinatorError):
                load_config(config)


if __name__ == "__main__":
    unittest.main()
