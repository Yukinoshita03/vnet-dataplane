import contextlib
import io
import json
import os
import tempfile
import threading
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

try:
    import fcntl
except ImportError:
    fcntl = None

from agent.openstack_guest_endpoint_agent import (
    GRPC_CAPABILITY,
    CommandResult,
    EndpointPaths,
    GuestEndpointAgent,
    GuestEndpointError,
    GuestEndpointSupervisor,
    GrpcConfig,
    EndpointConfig,
    ToolPaths,
    SystemEndpointDriver,
    _extract_xdp_program_id,
    _tcp_listener_inodes,
    build_dns_command,
    build_grpc_command,
    build_txn_command,
    evaluate_state_health,
    load_endpoint_config,
    main,
    parse_endpoint_config,
    write_state,
)


SERVER_ID = "11111111-2222-3333-4444-555555555555"
PORT_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"


def config_value(role="client", root=Path("/etc/vnet-dataplane-guest")):
    root_text = str(root).replace("\\", "/")
    value = {
        "schema_version": 1,
        "server_id": SERVER_ID,
        "port_id": PORT_ID,
        "accel_role": role,
        "interface": "ens3",
        "grpc": {
            "listen": "0.0.0.0:50052",
            "backend": "10.0.0.55:50051",
            "method": "/grpc.health.v1.Health/Check",
            "cache_file": f"{root_text}/grpc-cache.policy",
        },
    }
    if role == "server":
        value["dns_cache_file"] = f"{root_text}/dns-cache.policy"
    return value


def endpoint_config(role="client", root=Path("/etc/vnet-dataplane-guest")):
    return parse_endpoint_config(config_value(role, root))


def tool_paths(root=Path("/opt/vnet-dataplane/linux_accel")):
    return ToolPaths(
        dns_monitor=root / "build/dns_monitor",
        dns_server_bpf=root / "build/dns_xdp_monitor.bpf.o",
        grpc_fast_cache=root / "build/grpc_fast_cache",
        cache_policy_txn=root / "build/cache_policy_txn",
        bpftool=Path("/usr/sbin/bpftool"),
        ip=Path("/usr/sbin/ip"),
    )


def endpoint_paths(root):
    return EndpointPaths(
        port_id=PORT_ID,
        pin_root=root / "bpffs",
        lock_root=root / "locks",
        log_root=root / "logs",
    )


class FakeDriver:
    def __init__(self, paths, role):
        self.paths = paths
        self.role = role
        self.events = []
        self.quiesce = False
        self.pins = set()
        self.processes = {}
        self.next_pid = 100
        self.xdp_id = 0
        self.force_calls = 0
        self.fail_force_calls = set()
        self.fail_stop_pid = None
        self.fail_runtime = False
        self.listener_ok = True
        self.backend_ok = True
        self.interface_addresses = (
            ("10.0.0.43",) if role == "client" else ("10.0.0.55",)
        )
        self.remove_called = False

    def enter_quiesce(self):
        self.events.append("quiesce:enter")
        self.quiesce = True

    def leave_quiesce(self):
        self.events.append("quiesce:leave")
        self.quiesce = False

    def quiesced(self):
        return self.quiesce

    def ensure_interface(self, interface):
        self.events.append(f"interface:{interface}")

    def interface_ipv4(self, interface):
        self.events.append(f"interface-address:{interface}")
        return self.interface_addresses

    def ensure_grpc_runtime_map(self):
        self.events.append("map:create-or-validate:grpc")
        self.pins.add(self.paths.grpc_runtime_map)

    def path_exists(self, path):
        return path in self.pins

    def _readback(self, maps, mode=1):
        return {
            "schema_version": 1,
            "present": True,
            "maps": len(maps),
            "epoch": 1,
            "mode": mode,
            "flags": 1,
        }

    def force_bypass_and_read(self, maps):
        self.force_calls += 1
        self.events.append(
            "txn:force-read:" + ",".join(path.parent.name for path in maps)
        )
        if self.force_calls in self.fail_force_calls:
            raise GuestEndpointError("injected transaction failure")
        return self._readback(maps)

    def read_runtime(self, maps):
        self.events.append(
            "txn:read:" + ",".join(path.parent.name for path in maps)
        )
        if self.fail_runtime:
            raise GuestEndpointError("runtime maps disagree")
        return self._readback(maps, mode=4)

    def start_process(self, name, command, log_path):
        self.next_pid += 1
        pid = self.next_pid
        self.processes[pid] = True
        self.events.append(f"start:{name}")
        return pid

    def listener_owned(self, pid, listen):
        self.events.append(f"listener:read:{pid}:{listen}")
        return self.processes.get(pid, False) and self.listener_ok

    def wait_listener_owned(self, pid, listen):
        self.events.append(f"wait:listener:{pid}:{listen}")
        return self.listener_owned(pid, listen)

    def backend_ready(self, backend):
        self.events.append(f"backend:read:{backend}")
        return self.backend_ok

    def process_alive(self, pid):
        return self.processes.get(pid, False)

    def stop_process(self, pid):
        self.events.append(f"stop:{pid}")
        if pid == self.fail_stop_pid:
            return False
        self.processes[pid] = False
        if pid == 101 and self.role == "server":
            self.xdp_id = 0
        return True

    def current_xdp_program_id(self, interface):
        self.events.append(f"xdp:read:{interface}")
        return self.xdp_id

    def wait_dns_ready(self, interface, dns_pid):
        self.events.append("wait:dns-ready")
        self.pins.update(
            {
                self.paths.dns_runtime_map,
                self.paths.dns_stats_map,
                self.paths.dns_entries_map,
            }
        )
        self.xdp_id = 42
        return 42

    def remove_owned_port_pins(self):
        self.events.append("pins:remove-port")
        self.remove_called = True
        self.pins.clear()


class ConfigTest(unittest.TestCase):
    def test_loads_complete_client_and_server_schema(self):
        client = parse_endpoint_config(config_value("client"))
        server = parse_endpoint_config(config_value("server"))

        self.assertEqual(client.accel_role, "client")
        self.assertIsNone(client.dns_cache_file)
        self.assertEqual(server.accel_role, "server")
        self.assertEqual(
            server.dns_cache_file,
            Path("/etc/vnet-dataplane-guest/dns-cache.policy"),
        )
        self.assertEqual(server.grpc.listen, "0.0.0.0:50052")
        self.assertEqual(server.grpc.backend, "10.0.0.55:50051")

    def test_role_specific_fields_fail_closed(self):
        client = config_value("client")
        client["dns_cache_file"] = "/etc/dns-cache.policy"
        with self.assertRaisesRegex(GuestEndpointError, "forbids"):
            parse_endpoint_config(client)

        server = config_value("server")
        del server["dns_cache_file"]
        with self.assertRaisesRegex(GuestEndpointError, "requires"):
            parse_endpoint_config(server)

        server = config_value("server")
        server["interface"] = "eth0"
        with self.assertRaisesRegex(GuestEndpointError, "must be ens3"):
            parse_endpoint_config(server)

    def test_rejects_unknown_fields_noncanonical_ids_and_bad_grpc(self):
        cases = []
        unknown = config_value()
        unknown["extra"] = True
        cases.append(unknown)
        bad_id = config_value()
        bad_id["port_id"] = PORT_ID.upper()
        cases.append(bad_id)
        bad_backend = config_value()
        bad_backend["grpc"]["backend"] = "0.0.0.0:50051"
        cases.append(bad_backend)
        bad_method = config_value()
        bad_method["grpc"]["method"] = "Health/Check"
        cases.append(bad_method)
        relative = config_value()
        relative["grpc"]["cache_file"] = "cache.policy"
        cases.append(relative)

        for value in cases:
            with self.subTest(value=value), self.assertRaises(GuestEndpointError):
                parse_endpoint_config(value)

    def test_load_requires_absolute_config_path_and_valid_json(self):
        with self.assertRaisesRegex(GuestEndpointError, "absolute"):
            load_endpoint_config(Path("relative.json"))
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "endpoint.json"
            path.write_text("{", encoding="utf-8")
            with self.assertRaisesRegex(GuestEndpointError, "valid JSON"):
                load_endpoint_config(path)


class CommandGenerationTest(unittest.TestCase):
    def test_client_only_builds_userspace_grpc_fast_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))
            config = endpoint_config("client")
            tools = tool_paths()
            self.assertIsNone(build_dns_command(config, tools, paths))
            command = build_grpc_command(config, tools, paths)

        self.assertEqual(
            command[command.index("--cache-role") + 1], "client"
        )
        self.assertEqual(
            command[command.index("--runtime-control-map") + 1],
            str(paths.grpc_runtime_map),
        )
        self.assertIn("--cache-file", command)
        self.assertNotIn("--verbose", command)
        self.assertNotIn("grpc_monitor", " ".join(command))

    def test_server_dns_command_is_xdp_initial_bypass_on_ens3(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))
            config = endpoint_config("server")
            command = build_dns_command(config, tool_paths(), paths)

        self.assertIsNotNone(command)
        self.assertEqual(command[command.index("--dev") + 1], "ens3")
        self.assertEqual(command[command.index("--hook") + 1], "xdp")
        self.assertEqual(command[command.index("--role") + 1], "server")
        self.assertIn("--initial-runtime-bypass", command)
        self.assertEqual(
            command[command.index("--cache-refresh-ms") + 1], "1000"
        )
        self.assertEqual(
            command[command.index("--pin-dir") + 1], str(paths.dns_dir)
        )
        self.assertNotIn("--verbose-events", command)

    def test_server_dns_verbose_events_are_explicit_opt_in(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))
            config = replace(endpoint_config("server"), verbose_events=True)
            command = build_dns_command(config, tool_paths(), paths)

        self.assertIsNotNone(command)
        self.assertEqual(command.count("--verbose-events"), 1)

    def test_transaction_uses_per_port_lock_quiesce_and_actual_maps(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))
            command = build_txn_command(
                tool_paths(),
                paths,
                "force-bypass",
                7,
                (paths.dns_runtime_map, paths.grpc_runtime_map),
            )

        self.assertEqual(
            command[command.index("--lock-file") + 1],
            str(paths.lock_file),
        )
        self.assertEqual(
            command[command.index("--quiesce-file") + 1],
            str(paths.quiesce_file),
        )
        self.assertEqual(command.count("--control-map"), 2)
        self.assertEqual(command[command.index("--epoch") + 1], "7")


class SystemDriverCommandTest(unittest.TestCase):
    def _driver(self, paths, role="client", secure_lock_root=True):
        paths.lock_root.mkdir(parents=True, exist_ok=True)
        if secure_lock_root and os.name != "nt":
            paths.lock_root.chmod(0o700)
        with patch.object(SystemEndpointDriver, "_validate_inputs"):
            return SystemEndpointDriver(
                endpoint_config(role),
                tool_paths(),
                paths,
            )

    @unittest.skipIf(os.name == "nt", "POSIX mode bits are required")
    def test_enter_quiesce_rejects_world_writable_lock_root(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))
            paths.lock_root.mkdir(parents=True)
            paths.lock_root.chmod(0o777)
            driver = self._driver(paths, secure_lock_root=False)

            with self.assertRaisesRegex(
                GuestEndpointError, "writable by other users"
            ):
                driver.enter_quiesce()

            self.assertFalse(paths.quiesce_file.exists())

    def test_enter_quiesce_rejects_symlink_without_touching_target(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))
            paths.lock_root.mkdir(parents=True)
            target = paths.lock_root / "target"
            target.write_text("keep", encoding="utf-8")
            try:
                paths.quiesce_file.symlink_to(target)
            except OSError as error:
                self.skipTest(f"symlinks unavailable: {error}")
            driver = self._driver(paths)

            with self.assertRaisesRegex(
                GuestEndpointError, "not a regular file"
            ):
                driver.enter_quiesce()

            self.assertEqual(target.read_text(encoding="utf-8"), "keep")
            self.assertTrue(paths.quiesce_file.is_symlink())

    @unittest.skipIf(os.name == "nt", "POSIX mode bits are required")
    def test_enter_quiesce_rejects_insecure_existing_mode(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))
            paths.lock_root.mkdir(parents=True)
            paths.quiesce_file.touch(mode=0o644)
            paths.quiesce_file.chmod(0o644)
            driver = self._driver(paths)

            with self.assertRaisesRegex(
                GuestEndpointError, "unsafe permissions"
            ):
                driver.enter_quiesce()

            self.assertTrue(paths.quiesce_file.exists())

    def test_enter_quiesce_adopts_safe_stale_fence_idempotently(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))
            paths.lock_root.mkdir(parents=True)
            paths.quiesce_file.touch(mode=0o600)
            paths.quiesce_file.chmod(0o600)
            driver = self._driver(paths)

            driver.enter_quiesce()
            descriptor = driver._quiesce_fd
            driver.enter_quiesce()
            self.assertEqual(driver._quiesce_fd, descriptor)
            self.assertTrue(driver.quiesced())

            driver.leave_quiesce()
            self.assertFalse(driver.quiesced())
            self.assertIsNone(driver._quiesce_fd)

    @unittest.skipIf(os.name == "nt", "POSIX flock is required")
    def test_second_driver_cannot_adopt_live_quiesce_fence(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))
            first = self._driver(paths)
            second = self._driver(paths)

            first.enter_quiesce()
            with self.assertRaisesRegex(
                GuestEndpointError, "owned by another agent"
            ):
                second.enter_quiesce()

            first.leave_quiesce()
            second.enter_quiesce()
            second.leave_quiesce()

    @unittest.skipIf(os.name == "nt", "POSIX flock is required")
    def test_enter_quiesce_waits_for_inflight_policy_transaction(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))
            paths.lock_root.mkdir(parents=True)
            paths.lock_file.touch(mode=0o600)
            paths.lock_file.chmod(0o600)
            holder = os.open(paths.lock_file, os.O_RDWR)
            fcntl.flock(holder, fcntl.LOCK_EX)
            driver = self._driver(paths)
            started = threading.Event()
            finished = threading.Event()
            errors = []

            def enter_fence():
                started.set()
                try:
                    driver.enter_quiesce()
                except Exception as error:
                    errors.append(error)
                finally:
                    finished.set()

            worker = threading.Thread(target=enter_fence)
            worker.start()
            self.assertTrue(started.wait(1))
            self.assertFalse(finished.wait(0.05))
            self.assertFalse(paths.quiesce_file.exists())

            fcntl.flock(holder, fcntl.LOCK_UN)
            os.close(holder)
            worker.join(1)
            self.assertFalse(worker.is_alive())
            self.assertFalse(errors)
            self.assertTrue(paths.quiesce_file.exists())
            driver.leave_quiesce()

    def test_leave_quiesce_restores_fence_when_release_unlink_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))
            driver = self._driver(paths)
            driver.enter_quiesce()
            original_unlink = Path.unlink

            def fail_release_unlink(path, *args, **kwargs):
                if path.name.endswith(".release"):
                    raise OSError("injected release unlink failure")
                return original_unlink(path, *args, **kwargs)

            with patch.object(Path, "unlink", new=fail_release_unlink):
                with self.assertRaisesRegex(
                    OSError, "injected release unlink failure"
                ):
                    driver.leave_quiesce()

            self.assertTrue(paths.quiesce_file.exists())
            self.assertFalse(list(paths.lock_root.glob("*.release")))
            self.assertTrue(driver.quiesced())
            driver.leave_quiesce()

    def test_leave_quiesce_refuses_replaced_fence(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))
            driver = self._driver(paths)

            driver.enter_quiesce()
            paths.quiesce_file.unlink()
            paths.quiesce_file.write_text("replacement", encoding="utf-8")
            if os.name != "nt":
                paths.quiesce_file.chmod(0o600)

            with patch(
                "agent.openstack_guest_endpoint_agent.os.replace"
            ) as replace:
                with self.assertRaisesRegex(
                    GuestEndpointError, "quiesce file was replaced"
                ):
                    driver.leave_quiesce()
                replace.assert_not_called()

            self.assertEqual(
                paths.quiesce_file.read_text(encoding="utf-8"),
                "replacement",
            )

    def test_creates_and_validates_exact_array_runtime_map(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))

            class Runner:
                def __init__(self):
                    self.commands = []

                def run(self, args, timeout=10):
                    command = list(args)
                    self.commands.append(command)
                    if "create" in command:
                        paths.grpc_runtime_map.parent.mkdir(
                            parents=True, exist_ok=True
                        )
                        paths.grpc_runtime_map.touch()
                        return CommandResult(0)
                    return CommandResult(
                        0,
                        json.dumps(
                            {
                                "type": "array",
                                "bytes_key": 4,
                                "bytes_value": 16,
                                "max_entries": 1,
                            }
                        ),
                    )

            runner = Runner()
            with patch.object(SystemEndpointDriver, "_validate_inputs"):
                driver = SystemEndpointDriver(
                    endpoint_config("client"),
                    tool_paths(),
                    paths,
                    runner=runner,
                )
            driver.ensure_grpc_runtime_map()

        create = runner.commands[0]
        self.assertEqual(create[create.index("type") + 1], "array")
        self.assertEqual(create[create.index("key") + 1], "4")
        self.assertEqual(create[create.index("value") + 1], "16")
        self.assertEqual(create[create.index("entries") + 1], "1")
        self.assertEqual(runner.commands[1][-2:], ["pinned", str(paths.grpc_runtime_map)])

    def test_bypass_uses_highest_observed_epoch_then_confirms_all_maps(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))

            class Runner:
                def __init__(self):
                    self.commands = []
                    self.reads = 0

                def run(self, args, timeout=10):
                    command = list(args)
                    self.commands.append(command)
                    operation = command[command.index("--operation") + 1]
                    if operation == "force-bypass":
                        return CommandResult(0, "forced\n")
                    maps = command.count("--control-map")
                    self.reads += 1
                    epoch = (3, 7, 7)[self.reads - 1]
                    mode = 0 if maps == 1 else 1
                    flags = 0 if maps == 1 else 1
                    return CommandResult(
                        0,
                        json.dumps(
                            {
                                "schema_version": 1,
                                "present": True,
                                "maps": maps,
                                "epoch": epoch,
                                "mode": mode,
                                "flags": flags,
                            }
                        ),
                    )

            runner = Runner()
            with patch.object(SystemEndpointDriver, "_validate_inputs"):
                driver = SystemEndpointDriver(
                    endpoint_config("server"),
                    tool_paths(),
                    paths,
                    runner=runner,
                )
            result = driver.force_bypass_and_read(
                (paths.dns_runtime_map, paths.grpc_runtime_map)
            )

        force = next(
            command
            for command in runner.commands
            if command[command.index("--operation") + 1] == "force-bypass"
        )
        self.assertEqual(force[force.index("--epoch") + 1], "7")
        self.assertEqual(force.count("--control-map"), 2)
        self.assertEqual(result["epoch"], 7)
        self.assertEqual(result["mode"], 1)
        self.assertEqual(result["flags"], 1)

    def test_read_runtime_accepts_staged_policy_snapshot(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))

            class Runner:
                def run(self, args, timeout=10):
                    return CommandResult(
                        0,
                        json.dumps(
                            {
                                "schema_version": 1,
                                "present": True,
                                "maps": 1,
                                "epoch": 2,
                                "mode": 4,
                                "flags": 0,
                            }
                        ),
                    )

            with patch.object(SystemEndpointDriver, "_validate_inputs"):
                driver = SystemEndpointDriver(
                    endpoint_config("client"),
                    tool_paths(),
                    paths,
                    runner=Runner(),
                )

            readback = driver.read_runtime((paths.grpc_runtime_map,))

        self.assertEqual(readback["epoch"], 2)
        self.assertEqual(readback["mode"], 4)
        self.assertEqual(readback["flags"], 0)

    def test_pin_cleanup_refuses_unknown_entries_before_unlinking(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = endpoint_paths(Path(temp))
            paths.grpc_dir.mkdir(parents=True)
            paths.grpc_runtime_map.touch()
            unknown = paths.grpc_dir / "foreign-map"
            unknown.touch()
            with patch.object(SystemEndpointDriver, "_validate_inputs"):
                driver = SystemEndpointDriver(
                    endpoint_config("client"),
                    tool_paths(),
                    paths,
                )
            with self.assertRaisesRegex(
                GuestEndpointError, "unknown pin entry"
            ):
                driver.remove_owned_port_pins()
            self.assertTrue(paths.grpc_runtime_map.exists())
            self.assertTrue(unknown.exists())

            unknown.unlink()
            driver.remove_owned_port_pins()
            self.assertFalse(paths.port_root.exists())


class LifecycleTest(unittest.TestCase):
    def _agent(self, root, role):
        config = endpoint_config(role, root)
        paths = endpoint_paths(root)
        driver = FakeDriver(paths, role)
        return (
            GuestEndpointAgent(config, tool_paths(), paths, driver),
            driver,
            paths,
        )

    def test_client_orders_bypass_before_userspace_listener(self):
        with tempfile.TemporaryDirectory() as temp:
            agent, driver, _paths = self._agent(Path(temp), "client")
            agent.start()

        self.assertEqual(agent.state, "healthy")
        self.assertFalse(driver.quiesce)
        self.assertLess(
            driver.events.index("txn:force-read:grpc"),
            driver.events.index("start:grpc_fast_cache"),
        )
        self.assertNotIn("start:dns_monitor", driver.events)
        self.assertLess(
            driver.events.index("start:grpc_fast_cache"),
            driver.events.index("quiesce:leave"),
        )

    def test_supervisor_publishes_barriers_before_clearing_fence(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            agent, driver, _paths = self._agent(root, "client")
            supervisor = GuestEndpointSupervisor(
                agent, root / "state.json", interval=0.01
            )
            publications = []

            def record_state(_path, payload):
                publications.append(
                    (
                        payload["state"],
                        payload["quiesced"],
                        driver.quiesce,
                    )
                )

            with patch(
                "agent.openstack_guest_endpoint_agent.write_state",
                side_effect=record_state,
            ), patch.object(supervisor.stop_event, "wait", return_value=True):
                result = supervisor.run()

        self.assertEqual(result, 0)
        self.assertEqual(
            publications,
            [
                ("starting", True, True),
                ("healthy", False, False),
                ("stopping", True, True),
                ("stopped", False, False),
            ],
        )

    def test_stop_requested_at_startup_barrier_never_publishes_healthy(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            agent, driver, _paths = self._agent(root, "client")
            supervisor = GuestEndpointSupervisor(
                agent, root / "state.json", interval=0.01
            )
            publications = []

            def record_state(_path, payload):
                state = payload["state"]
                publications.append((state, payload["quiesced"]))
                driver.events.append(f"publish:{state}")
                if state == "starting":
                    supervisor.request_stop()

            with patch(
                "agent.openstack_guest_endpoint_agent.write_state",
                side_effect=record_state,
            ):
                result = supervisor.run()

        self.assertEqual(result, 0)
        self.assertEqual(
            publications,
            [("starting", True), ("stopping", True), ("stopped", False)],
        )
        self.assertNotIn("publish:healthy", driver.events)
        self.assertEqual(driver.events.count("quiesce:leave"), 1)
        self.assertLess(
            driver.events.index("publish:stopping"),
            driver.events.index("stop:101"),
        )
        self.assertLess(
            driver.events.index("stop:101"),
            driver.events.index("pins:remove-port"),
        )
        self.assertLess(
            driver.events.index("pins:remove-port"),
            driver.events.index("quiesce:leave"),
        )

    def test_server_waits_for_dns_hook_then_cross_map_bypass_before_grpc(self):
        with tempfile.TemporaryDirectory() as temp:
            agent, driver, _paths = self._agent(Path(temp), "server")
            agent.start()

        first_force = driver.events.index("txn:force-read:grpc")
        dns_start = driver.events.index("start:dns_monitor")
        dns_ready = driver.events.index("wait:dns-ready")
        cross_force = driver.events.index("txn:force-read:dns,grpc")
        grpc_start = driver.events.index("start:grpc_fast_cache")
        clear = driver.events.index("quiesce:leave")
        self.assertLess(first_force, dns_start)
        self.assertLess(dns_start, dns_ready)
        self.assertLess(dns_ready, cross_force)
        self.assertLess(cross_force, grpc_start)
        self.assertLess(grpc_start, clear)
        self.assertEqual(agent.runtime.dns_xdp_prog_id, 42)

    def test_bypass_failure_does_not_start_listener_and_preserves_fence(self):
        with tempfile.TemporaryDirectory() as temp:
            agent, driver, paths = self._agent(Path(temp), "client")
            driver.fail_force_calls = {1}
            with self.assertRaisesRegex(
                GuestEndpointError, "transaction failure"
            ):
                agent.start()

        self.assertEqual(agent.state, "degraded")
        self.assertNotIn("start:grpc_fast_cache", driver.events)
        self.assertTrue(driver.quiesce)
        self.assertIn(paths.grpc_runtime_map, driver.pins)
        self.assertFalse(driver.remove_called)

    def test_unreachable_backend_blocks_listener_and_keeps_quiesce(self):
        with tempfile.TemporaryDirectory() as temp:
            agent, driver, _paths = self._agent(Path(temp), "client")
            driver.backend_ok = False
            with self.assertRaisesRegex(
                GuestEndpointError, "backend is not reachable"
            ):
                agent.start()

        self.assertNotIn("start:grpc_fast_cache", driver.events)
        self.assertNotIn("map:create-or-validate:grpc", driver.events)
        self.assertTrue(driver.quiesce)
        self.assertEqual(agent.state, "degraded")

    def test_missing_interface_address_blocks_startup(self):
        with tempfile.TemporaryDirectory() as temp:
            agent, driver, _paths = self._agent(Path(temp), "client")
            driver.interface_addresses = ()
            with self.assertRaisesRegex(
                GuestEndpointError, "has no usable IPv4 address"
            ):
                agent.start()

        self.assertNotIn("start:grpc_fast_cache", driver.events)
        self.assertTrue(driver.quiesce)

    def test_stale_server_dns_pins_are_not_removed_with_unknown_xdp_owner(self):
        with tempfile.TemporaryDirectory() as temp:
            agent, driver, paths = self._agent(Path(temp), "server")
            driver.pins.add(paths.dns_runtime_map)
            driver.xdp_id = 77
            with self.assertRaisesRegex(GuestEndpointError, "unowned XDP"):
                agent.start()

        self.assertNotIn("start:dns_monitor", driver.events)
        self.assertIn(paths.dns_runtime_map, driver.pins)
        self.assertTrue(driver.quiesce)
        self.assertFalse(driver.remove_called)

    def test_server_restart_reclaims_confirmed_detached_owned_pins(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            agent, driver, paths = self._agent(root, "server")
            agent.start()
            self.assertTrue(agent.fail_closed_cleanup(preserve_pins=True))
            self.assertEqual(driver.xdp_id, 0)
            self.assertTrue(driver.pins)

            restarted = GuestEndpointAgent(
                agent.config,
                agent.tools,
                paths,
                driver,
            )
            restarted.start()

        self.assertTrue(driver.remove_called)
        self.assertEqual(restarted.state, "healthy")
        self.assertEqual(restarted.reason, "ready")
        self.assertEqual(driver.xdp_id, 42)
        self.assertTrue(set(paths.required_pins("server")).issubset(driver.pins))

    def test_stop_failure_keeps_processes_pins_and_quiesce(self):
        with tempfile.TemporaryDirectory() as temp:
            agent, driver, paths = self._agent(Path(temp), "client")
            agent.start()
            grpc_pid = agent.runtime.grpc_pid
            driver.fail_force_calls = {driver.force_calls + 1}
            self.assertFalse(agent.stop())

        self.assertEqual(agent.runtime.grpc_pid, grpc_pid)
        self.assertTrue(driver.processes[grpc_pid])
        self.assertIn(paths.grpc_runtime_map, driver.pins)
        self.assertTrue(driver.quiesce)
        self.assertFalse(driver.remove_called)

    def test_xdp_ownership_drift_prevents_process_or_pin_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            agent, driver, paths = self._agent(Path(temp), "server")
            agent.start()
            dns_pid = agent.runtime.dns_pid
            grpc_pid = agent.runtime.grpc_pid
            driver.xdp_id = 99
            self.assertFalse(agent.stop())

        self.assertTrue(driver.processes[dns_pid])
        self.assertTrue(driver.processes[grpc_pid])
        self.assertTrue(driver.pins)
        self.assertTrue(driver.quiesce)
        self.assertFalse(driver.remove_called)
        self.assertIn("ownership_drift", agent.reason)
        self.assertIn(paths.dns_runtime_map, driver.pins)

    def test_confirmed_stop_removes_owned_pins_and_clears_fence(self):
        with tempfile.TemporaryDirectory() as temp:
            agent, driver, _paths = self._agent(Path(temp), "server")
            agent.start()
            self.assertTrue(agent.stop())

        self.assertEqual(agent.state, "stopped")
        self.assertTrue(driver.remove_called)
        self.assertFalse(driver.pins)
        self.assertFalse(driver.quiesce)
        self.assertIsNone(agent.runtime.grpc_pid)
        self.assertIsNone(agent.runtime.dns_pid)

    def test_staged_policy_does_not_replace_committed_health_readback(self):
        with tempfile.TemporaryDirectory() as temp:
            agent, driver, _paths = self._agent(Path(temp), "client")
            agent.start()
            staged = driver._readback((agent.paths.grpc_runtime_map,), mode=4)
            staged["epoch"] = 2
            staged["flags"] = 0
            with patch.object(driver, "read_runtime", return_value=staged):
                report = agent.inspect()

        self.assertTrue(report.healthy)
        self.assertFalse(driver.quiesce)
        self.assertEqual(report.runtime_readback["epoch"], 1)
        self.assertEqual(report.runtime_readback["flags"], 1)

    def test_state_publication_failure_quiesces_and_preserves_pins(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            agent, driver, paths = self._agent(root, "client")
            supervisor = GuestEndpointSupervisor(
                agent, root / "state.json", interval=0.01
            )
            supervisor.stop_event.set()
            with (
                patch(
                    "agent.openstack_guest_endpoint_agent.write_state",
                    side_effect=[OSError("disk full"), None, None],
                ),
                contextlib.redirect_stderr(io.StringIO()),
            ):
                result = supervisor.run()

        self.assertEqual(result, 1)
        self.assertEqual(agent.state, "degraded")
        self.assertTrue(driver.quiesce)
        self.assertIn(paths.grpc_runtime_map, driver.pins)
        self.assertFalse(driver.remove_called)
        self.assertIsNone(agent.runtime.grpc_pid)

    def test_runtime_health_failure_exits_for_systemd_restart(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            agent, driver, paths = self._agent(root, "client")
            supervisor = GuestEndpointSupervisor(
                agent, root / "state.json", interval=0.01
            )

            def fail_listener_after_start(_timeout):
                driver.listener_ok = False
                return False

            with patch.object(
                supervisor.stop_event,
                "wait",
                side_effect=fail_listener_after_start,
            ) as wait:
                result = supervisor.run()

        self.assertEqual(result, 1)
        self.assertEqual(wait.call_count, 1)
        self.assertEqual(agent.state, "degraded")
        self.assertIn("grpc_listener_not_owned", agent.reason)
        self.assertTrue(driver.quiesce)
        self.assertIn(paths.grpc_runtime_map, driver.pins)
        self.assertIsNone(agent.runtime.grpc_pid)


class HealthAndStateTest(unittest.TestCase):
    def _started(self, root, role):
        config = endpoint_config(role, root)
        paths = endpoint_paths(root)
        driver = FakeDriver(paths, role)
        agent = GuestEndpointAgent(config, tool_paths(), paths, driver)
        agent.start()
        return agent, driver, config

    def test_health_detects_process_pin_runtime_and_xdp_drift(self):
        cases = (
            "interface",
            "process",
            "listener",
            "backend",
            "pin",
            "runtime",
            "xdp",
        )
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temp:
                agent, driver, _config = self._started(Path(temp), "server")
                if case == "interface":
                    driver.interface_addresses = ()
                elif case == "process":
                    driver.processes[agent.runtime.grpc_pid] = False
                elif case == "listener":
                    driver.listener_ok = False
                elif case == "backend":
                    driver.backend_ok = False
                elif case == "pin":
                    driver.pins.remove(agent.paths.grpc_runtime_map)
                elif case == "runtime":
                    driver.fail_runtime = True
                else:
                    driver.xdp_id = 999
                report = agent.inspect()
                self.assertFalse(report.healthy)
                self.assertNotEqual(report.reason, "ready")

    def test_state_schema_is_atomic_and_labels_grpc_userspace_capability(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            agent, _driver, _config = self._started(root, "server")
            state_file = root / "run" / "state.json"
            payload = agent.state_payload(agent.inspect())
            write_state(state_file, payload)
            value = json.loads(state_file.read_text(encoding="utf-8"))

            self.assertEqual(value["schema_version"], 1)
            self.assertEqual(value["source_kind"], "guest_endpoint")
            self.assertEqual(value["server_id"], SERVER_ID)
            self.assertEqual(value["port_id"], PORT_ID)
            self.assertEqual(value["accel_role"], "server")
            self.assertEqual(value["grpc_capability"], GRPC_CAPABILITY)
            self.assertEqual(value["interface_ipv4"], ["10.0.0.55"])
            self.assertTrue(value["grpc"]["listener_owned"])
            self.assertTrue(value["grpc"]["backend_ready"])
            self.assertEqual(value["processes"]["dns_monitor"]["pid"], 101)
            self.assertEqual(value["processes"]["grpc_fast_cache"]["pid"], 102)
            self.assertEqual(value["dns_xdp_prog_id"], 42)
            self.assertEqual(value["runtime_readback"]["maps"], 2)
            self.assertFalse(list(state_file.parent.glob("*.tmp")))

    def test_state_write_invalidates_previous_snapshot_after_sync_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            state_file = root / "state.json"
            agent, driver, config = self._started(root, "client")
            healthy = agent.state_payload(agent.inspect())
            write_state(state_file, healthy)
            stopping = agent.state_payload(agent.prepare_stop())
            sync_calls = 0

            def fail_post_replace_sync(_path):
                nonlocal sync_calls
                sync_calls += 1
                if sync_calls == 2:
                    raise OSError("injected directory sync failure")

            with patch(
                "agent.openstack_guest_endpoint_agent._sync_state_directory",
                side_effect=fail_post_replace_sync,
            ):
                with self.assertRaisesRegex(
                    OSError, "injected directory sync failure"
                ):
                    write_state(state_file, stopping)

            self.assertTrue(driver.quiesce)
            self.assertFalse(state_file.exists())
            self.assertFalse(
                evaluate_state_health(
                    None,
                    config,
                    10,
                    healthy["updated_ms"],
                    pin_root=agent.paths.pin_root,
                )["ready"]
            )
            self.assertFalse(list(state_file.parent.glob("*.tmp")))
            self.assertFalse(list(state_file.parent.glob("*.rollback")))

    def test_state_write_reports_nondurable_fail_closed_invalidation(self):
        with tempfile.TemporaryDirectory() as temp:
            state_file = Path(temp) / "state.json"
            write_state(state_file, {"schema_version": 1, "state": "healthy"})
            sync_calls = 0

            def fail_publish_and_invalidation_sync(_path):
                nonlocal sync_calls
                sync_calls += 1
                if sync_calls >= 2:
                    raise OSError("injected persistent directory sync failure")

            with patch(
                "agent.openstack_guest_endpoint_agent._sync_state_directory",
                side_effect=fail_publish_and_invalidation_sync,
            ):
                with self.assertRaisesRegex(
                    GuestEndpointError, "fail-closed invalidation was not durable"
                ):
                    write_state(
                        state_file,
                        {"schema_version": 1, "state": "stopping"},
                    )

            self.assertFalse(state_file.exists())

    def test_first_state_write_disappears_after_directory_sync_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            state_file = Path(temp) / "state.json"
            sync_calls = 0

            def fail_first_sync(_path):
                nonlocal sync_calls
                sync_calls += 1
                if sync_calls == 1:
                    raise OSError("injected directory sync failure")

            with patch(
                "agent.openstack_guest_endpoint_agent._sync_state_directory",
                side_effect=fail_first_sync,
            ):
                with self.assertRaisesRegex(
                    OSError, "injected directory sync failure"
                ):
                    write_state(
                        state_file,
                        {"schema_version": 1, "state": "healthy"},
                    )

            self.assertFalse(state_file.exists())
            self.assertFalse(list(state_file.parent.glob("*.tmp")))
            self.assertFalse(list(state_file.parent.glob("*.rollback")))

    def test_health_state_requires_fresh_exact_identity_and_committed_maps(self):
        with tempfile.TemporaryDirectory() as temp:
            agent, _driver, config = self._started(Path(temp), "client")
            state = agent.state_payload(agent.inspect())
            now_ms = state["updated_ms"]
            self.assertTrue(
                evaluate_state_health(
                    state,
                    config,
                    10,
                    now_ms,
                    pin_root=agent.paths.pin_root,
                )["ready"]
            )

            stale = dict(state)
            stale["updated_ms"] = now_ms - 10_001
            self.assertIn(
                "state_stale",
                evaluate_state_health(
                    stale,
                    config,
                    10,
                    now_ms,
                    pin_root=agent.paths.pin_root,
                )["reasons"],
            )
            wrong = dict(state)
            wrong["port_id"] = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
            self.assertIn(
                "port_id_mismatch",
                evaluate_state_health(
                    wrong,
                    config,
                    10,
                    now_ms,
                    pin_root=agent.paths.pin_root,
                )["reasons"],
            )
            backend_down = json.loads(json.dumps(state))
            backend_down["grpc"]["backend_ready"] = False
            self.assertIn(
                "grpc_backend_not_ready",
                evaluate_state_health(
                    backend_down,
                    config,
                    10,
                    now_ms,
                    pin_root=agent.paths.pin_root,
                )["reasons"],
            )
            uncommitted = json.loads(json.dumps(state))
            uncommitted["runtime_readback"]["flags"] = 0
            self.assertIn(
                "runtime_readback_invalid",
                evaluate_state_health(
                    uncommitted,
                    config,
                    10,
                    now_ms,
                    pin_root=agent.paths.pin_root,
                )["reasons"],
            )

    def test_health_rejects_substituted_pin_with_same_count(self):
        for role in ("client", "server"):
            with self.subTest(role=role), tempfile.TemporaryDirectory() as temp:
                agent, _driver, config = self._started(Path(temp), role)
                state = agent.state_payload(agent.inspect())
                pins = state["pins_present"]
                removed = next(iter(pins))
                del pins[removed]
                pins[f"{removed}.foreign"] = True

                result = evaluate_state_health(
                    state,
                    config,
                    10,
                    state["updated_ms"],
                    pin_root=agent.paths.pin_root,
                )

                self.assertFalse(result["ready"])
                self.assertIn("pins_invalid", result["reasons"])

    def test_health_rejects_map_paths_and_pins_moved_to_untrusted_root(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            agent, _driver, config = self._started(root, "server")
            state = agent.state_payload(agent.inspect())
            forged = EndpointPaths(
                PORT_ID,
                pin_root=root / "forged-bpffs",
                lock_root=root / "forged-locks",
                log_root=root / "forged-logs",
            )
            state["map_paths"] = {
                "grpc_runtime_control": str(forged.grpc_runtime_map),
                "dns_runtime_control": str(forged.dns_runtime_map),
                "dns_cache_stats": str(forged.dns_stats_map),
                "dns_cache_entries": str(forged.dns_entries_map),
            }
            state["pins_present"] = {
                str(path): True for path in forged.required_pins("server")
            }

            result = evaluate_state_health(
                state,
                config,
                10,
                state["updated_ms"],
                pin_root=agent.paths.pin_root,
            )

            self.assertFalse(result["ready"])
            self.assertIn("pins_invalid", result["reasons"])

    def test_state_from_far_future_is_not_healthy(self):
        with tempfile.TemporaryDirectory() as temp:
            agent, _driver, config = self._started(Path(temp), "client")
            state = agent.state_payload(agent.inspect())
            state["updated_ms"] = 1_010_001
            result = evaluate_state_health(
                state,
                config,
                10,
                now_ms=1_000_000,
                pin_root=agent.paths.pin_root,
            )
        self.assertFalse(result["ready"])
        self.assertIn("state_from_future", result["reasons"])

    def test_health_command_accepts_only_owned_listener_state(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            agent, _driver, _config = self._started(root, "client")
            config_path = root / "endpoint.json"
            state_path = root / "state.json"
            config_path.write_text(
                json.dumps(config_value("client", root)), encoding="utf-8"
            )
            write_state(state_path, agent.state_payload(agent.inspect()))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = main(
                    [
                        "health",
                        "--config",
                        str(config_path),
                        "--state-file",
                        str(state_path),
                        "--pin-root",
                        str(agent.paths.pin_root),
                    ]
                )
            self.assertEqual(result, 0)
            self.assertTrue(json.loads(output.getvalue())["ready"])

            state = json.loads(state_path.read_text(encoding="utf-8"))
            state["grpc"]["listener_owned"] = False
            state_path.write_text(json.dumps(state), encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = main(
                    [
                        "health",
                        "--config",
                        str(config_path),
                        "--state-file",
                        str(state_path),
                        "--pin-root",
                        str(agent.paths.pin_root),
                    ]
                )
            self.assertEqual(result, 2)
            self.assertIn(
                "grpc_listener_not_owned",
                json.loads(output.getvalue())["reasons"],
            )


class XdpParsingTest(unittest.TestCase):
    def test_extracts_supported_iproute2_shapes(self):
        self.assertEqual(_extract_xdp_program_id({}), 0)
        self.assertEqual(
            _extract_xdp_program_id({"xdp": {"prog_id": 41}}), 41
        )
        self.assertEqual(
            _extract_xdp_program_id({"xdp": {"skb": {"id": 42}}}), 42
        )
        self.assertEqual(
            _extract_xdp_program_id({"xdp": {"prog": {"id": 43}}}), 43
        )

    def test_rejects_ambiguous_xdp_ownership(self):
        with self.assertRaisesRegex(GuestEndpointError, "ambiguous"):
            _extract_xdp_program_id(
                {"xdp": {"drv": {"id": 41}, "skb": {"id": 42}}}
            )


class ListenerParsingTest(unittest.TestCase):
    def test_matches_only_ipv4_listen_socket_inodes(self):
        table = """  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:C384 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 12345 1 0000000000000000
   1: 3700000A:C383 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 23456 1 0000000000000000
   2: 00000000:C384 00000000:0000 01 00000000:00000000 00:00000000 00000000 0 0 34567 1 0000000000000000
"""
        self.assertEqual(
            _tcp_listener_inodes(table, "0.0.0.0:50052"), {"12345"}
        )
        self.assertEqual(
            _tcp_listener_inodes(table, "10.0.0.55:50051"), {"23456"}
        )


if __name__ == "__main__":
    unittest.main()
