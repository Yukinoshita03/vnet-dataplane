#!/usr/bin/env python3
"""Discover OpenStack VM interfaces and keep eBPF attachments reconciled."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Protocol, Sequence


class AgentError(RuntimeError):
    pass


@dataclass(frozen=True)
class Binding:
    server_id: str
    port_id: str
    host: str
    interface: str
    ifindex: int


@dataclass(frozen=True)
class AttachmentConfig:
    dns_monitor: Path
    dns_bpf: Path
    grpc_monitor: Path
    grpc_bpf: Path
    trusted_dns: str
    grpc_port: int
    pin_root: Path
    log_root: Path
    settle_seconds: float = 0.5


class CommandRunner:
    def run(self, args: Sequence[str]) -> str:
        result = subprocess.run(
            list(args),
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip()
            raise AgentError(
                f"command failed ({result.returncode}): {' '.join(args)}: "
                f"{detail}"
            )
        return result.stdout


def _normalized_key(value: str) -> str:
    return value.lower().replace(" ", "_").replace("-", "_")


def _field(record: dict[str, Any], *names: str) -> Any:
    normalized = {_normalized_key(str(key)): value for key, value in record.items()}
    for name in names:
        key = _normalized_key(name)
        if key in normalized:
            return normalized[key]
    return None


def _short_host(value: str) -> str:
    return value.strip().lower().split(".", 1)[0]


class OpenStackOvsResolver:
    def __init__(self, runner: CommandRunner, local_host: str):
        self._runner = runner
        self._local_host = _short_host(local_host)

    def discover(self, server_id: str) -> list[Binding]:
        port_rows = self._json(
            [
                "openstack",
                "port",
                "list",
                "--server",
                server_id,
                "-f",
                "json",
                "-c",
                "ID",
            ]
        )
        bindings: list[Binding] = []
        for row in port_rows:
            port_id = str(_field(row, "id") or "")
            if not port_id:
                raise AgentError("OpenStack port list returned a row without ID")
            port = self._json_object(
                ["openstack", "port", "show", port_id, "-f", "json"]
            )
            if str(_field(port, "device_id") or "") != server_id:
                continue
            if str(_field(port, "status") or "").upper() != "ACTIVE":
                continue
            binding_host = str(_field(port, "binding_host_id") or "")
            if _short_host(binding_host) != self._local_host:
                continue
            if str(_field(port, "binding_vif_type") or "") != "ovs":
                raise AgentError(
                    f"port {port_id} is local but VIF type is not ovs"
                )
            interface = self._ovs_interface(port_id)
            ifindex = self._ifindex(interface)
            bindings.append(
                Binding(
                    server_id=server_id,
                    port_id=port_id,
                    host=binding_host,
                    interface=interface,
                    ifindex=ifindex,
                )
            )
        return sorted(bindings, key=lambda item: item.port_id)

    def _ovs_interface(self, port_id: str) -> str:
        payload = self._json_object(
            [
                "ovs-vsctl",
                "--format=json",
                "--columns=name",
                "find",
                "Interface",
                f"external_ids:iface-id={port_id}",
            ]
        )
        headings = payload.get("headings", [])
        rows = payload.get("data", [])
        if "name" not in headings:
            raise AgentError("OVSDB response has no name heading")
        column = headings.index("name")
        names = [
            str(row[column])
            for row in rows
            if isinstance(row, list) and len(row) > column and row[column]
        ]
        if len(names) != 1:
            raise AgentError(
                f"port {port_id} maps to {len(names)} OVS interfaces"
            )
        return names[0]

    def _ifindex(self, interface: str) -> int:
        rows = self._json(["ip", "-j", "link", "show", "dev", interface])
        if len(rows) != 1 or "ifindex" not in rows[0]:
            raise AgentError(f"interface {interface} has no unique ifindex")
        return int(rows[0]["ifindex"])

    def _json(self, args: Sequence[str]) -> list[dict[str, Any]]:
        value = json.loads(self._runner.run(args))
        if not isinstance(value, list) or not all(
            isinstance(row, dict) for row in value
        ):
            raise AgentError(f"expected JSON array from {' '.join(args)}")
        return value

    def _json_object(self, args: Sequence[str]) -> dict[str, Any]:
        value = json.loads(self._runner.run(args))
        if not isinstance(value, dict):
            raise AgentError(f"expected JSON object from {' '.join(args)}")
        return value


class AttachmentDriver(Protocol):
    def attach(self, binding: Binding) -> None:
        ...

    def detach(self, binding: Binding) -> None:
        ...

    def healthy(self, binding: Binding) -> bool:
        ...

    def snapshot(self) -> dict[str, Any]:
        ...


@dataclass
class _ManagedAttachment:
    binding: Binding
    dns_process: subprocess.Popen[bytes]
    grpc_process: subprocess.Popen[bytes]


class ProcessAttachmentDriver:
    def __init__(self, config: AttachmentConfig):
        self._config = config
        self._managed: dict[str, _ManagedAttachment] = {}
        self._validate_config()

    def attach(self, binding: Binding) -> None:
        if binding.port_id in self._managed:
            raise AgentError(f"port {binding.port_id} is already attached")
        port_pin = self._port_path(self._config.pin_root, binding.port_id)
        port_log = self._port_path(self._config.log_root, binding.port_id)
        self._remove_pin_tree(port_pin)
        (port_pin / "dns").mkdir(parents=True, exist_ok=True)
        (port_pin / "grpc").mkdir(parents=True, exist_ok=True)
        port_log.mkdir(parents=True, exist_ok=True)

        dns_command, grpc_command = self.commands(binding)
        dns_process = self._start(
            dns_command, port_log / f"dns-{binding.interface}.log"
        )
        try:
            grpc_process = self._start(
                grpc_command, port_log / f"grpc-{binding.interface}.log"
            )
        except Exception:
            self._stop(dns_process)
            self._cleanup_hooks(binding)
            self._remove_pin_tree(port_pin)
            self._remove_empty_pin_root()
            raise

        time.sleep(self._config.settle_seconds)
        if dns_process.poll() is not None or grpc_process.poll() is not None:
            self._stop(grpc_process)
            self._stop(dns_process)
            self._cleanup_hooks(binding)
            self._remove_pin_tree(port_pin)
            self._remove_empty_pin_root()
            raise AgentError(
                f"monitor exited while attaching {binding.interface}"
            )
        self._managed[binding.port_id] = _ManagedAttachment(
            binding=binding,
            dns_process=dns_process,
            grpc_process=grpc_process,
        )

    def detach(self, binding: Binding) -> None:
        managed = self._managed.pop(binding.port_id, None)
        if managed is not None:
            self._stop(managed.grpc_process)
            self._stop(managed.dns_process)
        self._cleanup_hooks(binding)
        self._remove_pin_tree(
            self._port_path(self._config.pin_root, binding.port_id)
        )
        self._remove_empty_pin_root()

    def healthy(self, binding: Binding) -> bool:
        managed = self._managed.get(binding.port_id)
        return bool(
            managed
            and managed.binding == binding
            and managed.dns_process.poll() is None
            and managed.grpc_process.poll() is None
        )

    def snapshot(self) -> dict[str, Any]:
        return {
            port_id: {
                "binding": asdict(value.binding),
                "dns_pid": value.dns_process.pid,
                "grpc_pid": value.grpc_process.pid,
                "healthy": self.healthy(value.binding),
            }
            for port_id, value in sorted(self._managed.items())
        }

    def commands(self, binding: Binding) -> tuple[list[str], list[str]]:
        port_pin = self._port_path(self._config.pin_root, binding.port_id)
        dns = [
            str(self._config.dns_monitor),
            "--dev",
            binding.interface,
            "--hook",
            "xdp",
            "--role",
            "client",
            "--xdp-mode",
            "generic",
            "--bpf-object",
            str(self._config.dns_bpf),
            "--trusted-dns",
            self._config.trusted_dns,
            "--pin-dir",
            str(port_pin / "dns"),
            "--verbose-events",
        ]
        grpc = [
            str(self._config.grpc_monitor),
            "--dev",
            binding.interface,
            "--bpf-object",
            str(self._config.grpc_bpf),
            "--port",
            str(self._config.grpc_port),
            "--pin-dir",
            str(port_pin / "grpc"),
            "--verbose-events",
        ]
        return dns, grpc

    def _validate_config(self) -> None:
        for path in (
            self._config.dns_monitor,
            self._config.dns_bpf,
            self._config.grpc_monitor,
            self._config.grpc_bpf,
        ):
            if not path.is_file():
                raise AgentError(f"missing attachment input: {path}")
        if not self._config.pin_root.is_absolute():
            raise AgentError("pin root must be absolute")
        if self._config.pin_root == Path("/sys/fs/bpf"):
            raise AgentError("pin root must be below /sys/fs/bpf")

    @staticmethod
    def _port_path(root: Path, port_id: str) -> Path:
        if not port_id or any(char not in "0123456789abcdef-" for char in port_id):
            raise AgentError(f"unsafe port ID: {port_id}")
        candidate = (root / port_id).resolve()
        root_resolved = root.resolve()
        if candidate.parent != root_resolved:
            raise AgentError(f"unsafe managed path: {candidate}")
        return candidate

    @staticmethod
    def _start(command: Sequence[str], log_path: Path) -> subprocess.Popen[bytes]:
        with log_path.open("ab", buffering=0) as log:
            return subprocess.Popen(
                list(command),
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )

    @staticmethod
    def _stop(process: subprocess.Popen[bytes]) -> None:
        if process.poll() is not None:
            return
        for sig, timeout in (
            (signal.SIGINT, 3.0),
            (signal.SIGTERM, 2.0),
            (signal.SIGKILL, 1.0),
        ):
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                return
            try:
                process.wait(timeout=timeout)
                return
            except subprocess.TimeoutExpired:
                continue

    @staticmethod
    def _remove_pin_tree(path: Path) -> None:
        if path.exists():
            shutil.rmtree(path)

    def _remove_empty_pin_root(self) -> None:
        try:
            self._config.pin_root.rmdir()
        except FileNotFoundError:
            pass
        except OSError:
            pass

    @staticmethod
    def _cleanup_hooks(binding: Binding) -> None:
        for direction in ("ingress", "egress"):
            for handle in ("1", "2"):
                subprocess.run(
                    [
                        "tc",
                        "filter",
                        "del",
                        "dev",
                        binding.interface,
                        direction,
                        "pref",
                        "1",
                        "handle",
                        handle,
                        "bpf",
                    ],
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
        subprocess.run(
            ["ip", "link", "set", "dev", binding.interface, "xdp", "off"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        for direction in ("ingress", "egress"):
            result = subprocess.run(
                ["tc", "filter", "show", "dev", binding.interface, direction],
                check=False,
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                continue
            if "handle 0x1 " in result.stdout or "handle 0x2 " in result.stdout:
                raise AgentError(
                    f"owned TC filters remain on "
                    f"{binding.interface}/{direction}"
                )


@dataclass
class ReconcileEvent:
    action: str
    port_id: str
    reason: str
    binding: Binding | None = None


class Reconciler:
    def __init__(
        self,
        driver: AttachmentDriver,
        missing_grace_cycles: int = 2,
    ):
        if missing_grace_cycles < 1:
            raise AgentError("missing grace cycles must be positive")
        self._driver = driver
        self._missing_grace_cycles = missing_grace_cycles
        self._current: dict[str, Binding] = {}
        self._missing: dict[str, int] = {}

    def reconcile(self, desired: Sequence[Binding]) -> list[ReconcileEvent]:
        desired_by_port = {binding.port_id: binding for binding in desired}
        events: list[ReconcileEvent] = []

        for port_id, current in list(self._current.items()):
            wanted = desired_by_port.get(port_id)
            if wanted is None:
                missing = self._missing.get(port_id, 0) + 1
                self._missing[port_id] = missing
                if missing < self._missing_grace_cycles:
                    events.append(
                        ReconcileEvent(
                            "wait",
                            port_id,
                            f"missing_grace_{missing}",
                            current,
                        )
                    )
                    continue
                self._driver.detach(current)
                del self._current[port_id]
                self._missing.pop(port_id, None)
                events.append(
                    ReconcileEvent("detach", port_id, "binding_left_host", current)
                )
                continue

            self._missing.pop(port_id, None)
            if wanted != current:
                self._driver.detach(current)
                del self._current[port_id]
                events.append(
                    ReconcileEvent("detach", port_id, "binding_changed", current)
                )
            elif not self._driver.healthy(current):
                self._driver.detach(current)
                del self._current[port_id]
                events.append(
                    ReconcileEvent("detach", port_id, "monitor_unhealthy", current)
                )

        for port_id, wanted in desired_by_port.items():
            if port_id in self._current:
                continue
            try:
                self._driver.attach(wanted)
            except Exception as error:
                events.append(
                    ReconcileEvent(
                        "error",
                        port_id,
                        f"attach_failed:{error}",
                        wanted,
                    )
                )
                continue
            self._current[port_id] = wanted
            events.append(ReconcileEvent("attach", port_id, "binding_local", wanted))
        return events

    def close(self) -> list[ReconcileEvent]:
        events: list[ReconcileEvent] = []
        for port_id, binding in list(self._current.items()):
            self._driver.detach(binding)
            events.append(ReconcileEvent("detach", port_id, "agent_stopped", binding))
        self._current.clear()
        self._missing.clear()
        return events

    def bindings(self) -> list[Binding]:
        return [self._current[key] for key in sorted(self._current)]


class JsonAudit:
    def __init__(self, path: Path | None):
        self._path = path
        if path is not None:
            path.parent.mkdir(parents=True, exist_ok=True)

    def emit(self, event: str, **fields: Any) -> None:
        record = {
            "timestamp_ms": int(time.time() * 1000),
            "event": event,
            **fields,
        }
        line = json.dumps(record, sort_keys=True, separators=(",", ":"))
        print(line, flush=True)
        if self._path is not None:
            with self._path.open("a", encoding="utf-8") as output:
                output.write(line + "\n")


def _write_state(
    path: Path,
    server_id: str,
    local_host: str,
    reconciler: Reconciler,
    driver: AttachmentDriver,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "server_id": server_id,
        "local_host": local_host,
        "bindings": [asdict(binding) for binding in reconciler.bindings()],
        "attachments": driver.snapshot(),
        "updated_ms": int(time.time() * 1000),
    }
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def _local_host(argument: str | None) -> str:
    if argument:
        return argument
    return subprocess.run(
        ["hostname", "-s"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def _add_discovery_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--server-id", required=True)
    parser.add_argument("--local-host")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    discover = subparsers.add_parser("discover", help="resolve local VM bindings")
    _add_discovery_args(discover)

    watch = subparsers.add_parser("watch", help="reconcile attachments continuously")
    _add_discovery_args(watch)
    watch.add_argument("--dns-monitor", required=True, type=Path)
    watch.add_argument("--dns-bpf", required=True, type=Path)
    watch.add_argument("--grpc-monitor", required=True, type=Path)
    watch.add_argument("--grpc-bpf", required=True, type=Path)
    watch.add_argument("--trusted-dns", required=True)
    watch.add_argument("--grpc-port", type=int, default=50052)
    watch.add_argument(
        "--pin-root",
        type=Path,
        default=Path("/sys/fs/bpf/vnet-dataplane-agent"),
    )
    watch.add_argument(
        "--log-root",
        type=Path,
        default=Path("/var/log/vnet-dataplane-agent"),
    )
    watch.add_argument(
        "--state-file",
        type=Path,
        default=Path("/run/vnet-dataplane-agent/state.json"),
    )
    watch.add_argument("--audit-log", type=Path)
    watch.add_argument("--interval", type=float, default=2.0)
    watch.add_argument("--missing-grace-cycles", type=int, default=2)
    watch.add_argument("--max-cycles", type=int, default=0)
    return parser


def _discover(args: argparse.Namespace) -> int:
    host = _local_host(args.local_host)
    resolver = OpenStackOvsResolver(CommandRunner(), host)
    bindings = resolver.discover(args.server_id)
    print(
        json.dumps(
            {
                "server_id": args.server_id,
                "local_host": host,
                "bindings": [asdict(binding) for binding in bindings],
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


def _watch(args: argparse.Namespace) -> int:
    if os.geteuid() != 0:
        raise AgentError("watch must run as root")
    if args.interval <= 0:
        raise AgentError("interval must be positive")
    host = _local_host(args.local_host)
    resolver = OpenStackOvsResolver(CommandRunner(), host)
    config = AttachmentConfig(
        dns_monitor=args.dns_monitor,
        dns_bpf=args.dns_bpf,
        grpc_monitor=args.grpc_monitor,
        grpc_bpf=args.grpc_bpf,
        trusted_dns=args.trusted_dns,
        grpc_port=args.grpc_port,
        pin_root=args.pin_root,
        log_root=args.log_root,
    )
    driver = ProcessAttachmentDriver(config)
    reconciler = Reconciler(driver, args.missing_grace_cycles)
    audit = JsonAudit(args.audit_log)
    stopping = threading.Event()

    def request_stop(_signum: int, _frame: Any) -> None:
        stopping.set()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    audit.emit("agent_started", server_id=args.server_id, local_host=host)
    cycles = 0
    try:
        while not stopping.is_set():
            try:
                desired = resolver.discover(args.server_id)
            except Exception as error:
                audit.emit("discovery_failed", error=str(error))
            else:
                for event in reconciler.reconcile(desired):
                    audit.emit(
                        "reconcile",
                        action=event.action,
                        port_id=event.port_id,
                        reason=event.reason,
                        binding=asdict(event.binding) if event.binding else None,
                    )
                _write_state(
                    args.state_file,
                    args.server_id,
                    host,
                    reconciler,
                    driver,
                )
            cycles += 1
            if args.max_cycles and cycles >= args.max_cycles:
                break
            stopping.wait(args.interval)
    finally:
        for event in reconciler.close():
            audit.emit(
                "reconcile",
                action=event.action,
                port_id=event.port_id,
                reason=event.reason,
                binding=asdict(event.binding) if event.binding else None,
            )
        _write_state(
            args.state_file,
            args.server_id,
            host,
            reconciler,
            driver,
        )
        audit.emit("agent_stopped", server_id=args.server_id, local_host=host)
    return 0


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.command == "discover":
            return _discover(args)
        return _watch(args)
    except (AgentError, json.JSONDecodeError, OSError) as error:
        print(f"openstack_dataplane_agent: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
