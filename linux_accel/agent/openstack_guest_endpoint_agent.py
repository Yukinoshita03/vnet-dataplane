#!/usr/bin/env python3
"""Supervise one role-aware acceleration endpoint inside an OpenStack guest."""

from __future__ import annotations

import argparse
import errno
import ipaddress
import json
import math
import os
import re
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol, Sequence

try:
    import fcntl
except ImportError:  # pragma: no cover - Windows development host
    fcntl = None


CONFIG_SCHEMA_VERSION = 1
DEFAULT_SHUTDOWN_TIMEOUT_SECONDS = 45.0
STATE_SCHEMA_VERSION = 1
GRPC_CAPABILITY = "userspace_fast_cache"
RUNTIME_MODE_MIN = 1
RUNTIME_MODE_MAX = 4
RUNTIME_COMMITTED = 1
RUNTIME_VALUE_SIZE = 16
PRODUCTION_PIN_ROOT = Path("/sys/fs/bpf/vnet-dataplane-guest")
POLICY_LOCK_ROOT = Path("/run/vnet-dataplane-policy")
_INTERFACE_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,15}$")
_METHOD_RE = re.compile(r"^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_MAP_PATH_KEYS = frozenset(
    {
        "grpc_runtime_control",
        "dns_runtime_control",
        "dns_cache_stats",
        "dns_cache_entries",
    }
)


class GuestEndpointError(RuntimeError):
    pass


@dataclass(frozen=True)
class GrpcConfig:
    listen: str
    backend: str
    method: str
    cache_file: Path


@dataclass(frozen=True)
class EndpointConfig:
    server_id: str
    port_id: str
    accel_role: str
    interface: str
    grpc: GrpcConfig
    dns_cache_file: Path | None = None
    verbose_events: bool = False


@dataclass(frozen=True)
class ToolPaths:
    dns_monitor: Path
    dns_server_bpf: Path
    grpc_fast_cache: Path
    cache_policy_txn: Path
    bpftool: Path = Path("/usr/sbin/bpftool")
    ip: Path = Path("/usr/sbin/ip")


@dataclass(frozen=True)
class EndpointPaths:
    port_id: str
    pin_root: Path = PRODUCTION_PIN_ROOT
    lock_root: Path = POLICY_LOCK_ROOT
    log_root: Path = Path("/var/log/vnet-dataplane-guest")

    def __post_init__(self) -> None:
        _validate_uuid(self.port_id, "port_id")
        for label, root in (
            ("pin_root", self.pin_root),
            ("lock_root", self.lock_root),
            ("log_root", self.log_root),
        ):
            if not root.is_absolute() or root == Path(root.anchor):
                raise GuestEndpointError(
                    f"{label} must be a non-root absolute directory"
                )

    @property
    def port_root(self) -> Path:
        return _direct_child(self.pin_root, self.port_id)

    @property
    def dns_dir(self) -> Path:
        return self.port_root / "dns"

    @property
    def grpc_dir(self) -> Path:
        return self.port_root / "grpc"

    @property
    def grpc_runtime_map(self) -> Path:
        return self.grpc_dir / "cache_runtime_control"

    @property
    def dns_runtime_map(self) -> Path:
        return self.dns_dir / "cache_runtime_control"

    @property
    def dns_stats_map(self) -> Path:
        return self.dns_dir / "dns_cache_stats"

    @property
    def dns_entries_map(self) -> Path:
        return self.dns_dir / "dns_cache_entries"

    @property
    def lock_file(self) -> Path:
        return _direct_child(
            self.lock_root, f"vnet-dataplane-{self.port_id}.lock"
        )

    @property
    def quiesce_file(self) -> Path:
        return _direct_child(
            self.lock_root, f"vnet-dataplane-{self.port_id}.quiesce"
        )

    @property
    def port_log_dir(self) -> Path:
        return _direct_child(self.log_root, self.port_id)

    def required_pins(self, role: str) -> tuple[Path, ...]:
        if role == "client":
            return (self.grpc_runtime_map,)
        return (
            self.dns_runtime_map,
            self.dns_stats_map,
            self.dns_entries_map,
            self.grpc_runtime_map,
        )

    def runtime_maps(self, role: str) -> tuple[Path, ...]:
        if role == "client":
            return (self.grpc_runtime_map,)
        return (self.dns_runtime_map, self.grpc_runtime_map)


@dataclass
class ManagedRuntime:
    grpc_pid: int | None = None
    dns_pid: int | None = None
    dns_xdp_prog_id: int | None = None
    runtime_readback: dict[str, Any] | None = None


@dataclass(frozen=True)
class HealthReport:
    healthy: bool
    reason: str
    process_alive: dict[str, bool]
    pins_present: dict[str, bool]
    interface_ipv4: tuple[str, ...]
    grpc_listener_owned: bool
    grpc_backend_ready: bool
    current_dns_xdp_prog_id: int | None
    runtime_readback: dict[str, Any] | None


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""


class CommandRunner(Protocol):
    def run(self, args: Sequence[str], timeout: float = 10.0) -> CommandResult:
        ...


class SubprocessCommandRunner:
    def run(self, args: Sequence[str], timeout: float = 10.0) -> CommandResult:
        result = subprocess.run(
            list(args),
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return CommandResult(result.returncode, result.stdout, result.stderr)


class EndpointDriver(Protocol):
    def enter_quiesce(self) -> None:
        ...

    def leave_quiesce(self) -> None:
        ...

    def quiesced(self) -> bool:
        ...

    def ensure_interface(self, interface: str) -> None:
        ...

    def interface_ipv4(self, interface: str) -> tuple[str, ...]:
        ...

    def ensure_grpc_runtime_map(self) -> None:
        ...

    def path_exists(self, path: Path) -> bool:
        ...

    def force_bypass_and_read(
        self, map_paths: Sequence[Path]
    ) -> dict[str, Any]:
        ...

    def read_runtime(self, map_paths: Sequence[Path]) -> dict[str, Any]:
        ...

    def start_process(
        self, name: str, command: Sequence[str], log_path: Path
    ) -> int:
        ...

    def listener_owned(self, pid: int, listen: str) -> bool:
        ...

    def wait_listener_owned(self, pid: int, listen: str) -> bool:
        ...

    def backend_ready(self, backend: str) -> bool:
        ...

    def process_alive(self, pid: int) -> bool:
        ...

    def stop_process(self, pid: int) -> bool:
        ...

    def current_xdp_program_id(self, interface: str) -> int:
        ...

    def wait_dns_ready(self, interface: str, dns_pid: int) -> int:
        ...

    def remove_owned_port_pins(self) -> None:
        ...


def _validate_uuid(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise GuestEndpointError(f"{label} must be a canonical UUID")
    try:
        normalized = str(uuid.UUID(value))
    except (ValueError, AttributeError) as error:
        raise GuestEndpointError(f"{label} must be a canonical UUID") from error
    if value != normalized:
        raise GuestEndpointError(f"{label} must be a canonical lowercase UUID")
    return normalized


def _validate_absolute_file(value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise GuestEndpointError(f"{label} must be an absolute file path")
    path = Path(value)
    if (not path.is_absolute() and not value.startswith("/")) or value == "/":
        raise GuestEndpointError(f"{label} must be an absolute file path")
    return path


def _direct_child(root: Path, name: str) -> Path:
    root_resolved = root.resolve()
    candidate = root_resolved / name
    if candidate.parent != root_resolved:
        raise GuestEndpointError(f"unsafe managed path: {candidate}")
    return candidate


def _expected_state_pin_paths(
    state: dict[str, Any], role: str, port_id: str, pin_root: Path
) -> frozenset[str] | None:
    map_paths = state.get("map_paths")
    if not isinstance(map_paths, dict) or set(map_paths) != _MAP_PATH_KEYS:
        return None
    if not pin_root.is_absolute() or pin_root == Path(pin_root.anchor):
        return None
    port_root = _direct_child(pin_root, port_id)
    expected_map_paths = {
        "grpc_runtime_control": str(
            port_root / "grpc" / "cache_runtime_control"
        ),
        "dns_runtime_control": None,
        "dns_cache_stats": None,
        "dns_cache_entries": None,
    }
    if role == "server":
        expected_map_paths.update(
            dns_runtime_control=str(
                port_root / "dns" / "cache_runtime_control"
            ),
            dns_cache_stats=str(port_root / "dns" / "dns_cache_stats"),
            dns_cache_entries=str(
                port_root / "dns" / "dns_cache_entries"
            ),
        )
    if map_paths != expected_map_paths:
        return None
    return frozenset(
        value for value in expected_map_paths.values() if value is not None
    )


def _parse_ipv4_endpoint(value: Any, label: str, allow_any: bool) -> str:
    if not isinstance(value, str) or value.count(":") != 1:
        raise GuestEndpointError(f"{label} must be IPv4:port")
    host, port_text = value.split(":", 1)
    try:
        address = ipaddress.IPv4Address(host)
    except (ipaddress.AddressValueError, ValueError) as error:
        raise GuestEndpointError(f"{label} must be IPv4:port") from error
    if not allow_any and address.is_unspecified:
        raise GuestEndpointError(f"{label} must not use 0.0.0.0")
    if not port_text.isdigit() or not 1 <= int(port_text) <= 65535:
        raise GuestEndpointError(f"{label} port must be in 1..65535")
    return f"{address}:{int(port_text)}"


def parse_endpoint_config(value: Any, source: str = "endpoint config") -> EndpointConfig:
    if not isinstance(value, dict):
        raise GuestEndpointError(f"{source} must be a JSON object")
    allowed = {
        "schema_version",
        "server_id",
        "port_id",
        "accel_role",
        "interface",
        "grpc",
        "dns_cache_file",
        "verbose_events",
    }
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise GuestEndpointError(
            f"{source} has unknown fields: {', '.join(unknown)}"
        )
    schema = value.get("schema_version")
    if (
        not isinstance(schema, int)
        or isinstance(schema, bool)
        or schema != CONFIG_SCHEMA_VERSION
    ):
        raise GuestEndpointError(
            f"{source} schema_version must be {CONFIG_SCHEMA_VERSION}"
        )
    server_id = _validate_uuid(value.get("server_id"), "server_id")
    port_id = _validate_uuid(value.get("port_id"), "port_id")
    role = value.get("accel_role")
    if role not in {"client", "server"}:
        raise GuestEndpointError("accel_role must be exactly client or server")
    interface = value.get("interface")
    if not isinstance(interface, str) or not _INTERFACE_RE.fullmatch(interface):
        raise GuestEndpointError("interface is not a valid Linux interface name")
    if role == "server" and interface != "ens3":
        raise GuestEndpointError("server DNS XDP interface must be ens3")
    verbose_events = value.get("verbose_events", False)
    if not isinstance(verbose_events, bool):
        raise GuestEndpointError("verbose_events must be a boolean")

    grpc_value = value.get("grpc")
    if not isinstance(grpc_value, dict):
        raise GuestEndpointError("grpc must be a JSON object")
    grpc_unknown = sorted(
        set(grpc_value) - {"listen", "backend", "method", "cache_file"}
    )
    if grpc_unknown:
        raise GuestEndpointError(
            f"grpc has unknown fields: {', '.join(grpc_unknown)}"
        )
    if set(grpc_value) != {"listen", "backend", "method", "cache_file"}:
        raise GuestEndpointError(
            "grpc requires listen, backend, method, and cache_file"
        )
    listen = _parse_ipv4_endpoint(grpc_value["listen"], "grpc.listen", True)
    backend = _parse_ipv4_endpoint(
        grpc_value["backend"], "grpc.backend", False
    )
    method = grpc_value["method"]
    if not isinstance(method, str) or not _METHOD_RE.fullmatch(method):
        raise GuestEndpointError("grpc.method must be /Service/Method")
    grpc_cache_file = _validate_absolute_file(
        grpc_value["cache_file"], "grpc.cache_file"
    )

    dns_cache_file: Path | None = None
    if role == "client":
        if "dns_cache_file" in value:
            raise GuestEndpointError("client role forbids dns_cache_file")
    else:
        if "dns_cache_file" not in value:
            raise GuestEndpointError("server role requires dns_cache_file")
        dns_cache_file = _validate_absolute_file(
            value["dns_cache_file"], "dns_cache_file"
        )

    return EndpointConfig(
        server_id=server_id,
        port_id=port_id,
        accel_role=role,
        interface=interface,
        grpc=GrpcConfig(
            listen=listen,
            backend=backend,
            method=method,
            cache_file=grpc_cache_file,
        ),
        dns_cache_file=dns_cache_file,
        verbose_events=verbose_events,
    )


def load_endpoint_config(path: Path) -> EndpointConfig:
    if not path.is_absolute():
        raise GuestEndpointError("config path must be absolute")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise GuestEndpointError(f"config does not exist: {path}") from error
    except json.JSONDecodeError as error:
        raise GuestEndpointError(f"config is not valid JSON: {error}") from error
    return parse_endpoint_config(value, f"endpoint config {path}")


def build_dns_command(
    config: EndpointConfig, tools: ToolPaths, paths: EndpointPaths
) -> list[str] | None:
    if config.accel_role == "client":
        return None
    if config.dns_cache_file is None:
        raise GuestEndpointError("server role has no DNS cache file")
    command = [
        str(tools.dns_monitor),
        "--dev",
        config.interface,
        "--hook",
        "xdp",
        "--role",
        "server",
        "--xdp-mode",
        "generic",
        "--bpf-object",
        str(tools.dns_server_bpf),
        "--cache-file",
        str(config.dns_cache_file),
        "--cache-refresh-ms",
        "1000",
        "--initial-runtime-bypass",
        "--pin-dir",
        str(paths.dns_dir),
    ]
    if config.verbose_events:
        command.append("--verbose-events")
    return command


def build_grpc_command(
    config: EndpointConfig, tools: ToolPaths, paths: EndpointPaths
) -> list[str]:
    return [
        str(tools.grpc_fast_cache),
        "--runtime-control-map",
        str(paths.grpc_runtime_map),
        "--cache-role",
        config.accel_role,
        "--listen",
        config.grpc.listen,
        "--backend",
        config.grpc.backend,
        "--cache-file",
        str(config.grpc.cache_file),
        "--method",
        config.grpc.method,
    ]


def build_txn_command(
    tools: ToolPaths,
    paths: EndpointPaths,
    operation: str,
    epoch: int,
    map_paths: Sequence[Path],
) -> list[str]:
    if operation not in {"force-bypass", "read-current"}:
        raise GuestEndpointError(f"unsupported endpoint transaction: {operation}")
    if epoch < 1:
        raise GuestEndpointError("transaction epoch must be positive")
    if not map_paths:
        raise GuestEndpointError("transaction needs at least one runtime map")
    command = [
        str(tools.cache_policy_txn),
        "--lock-file",
        str(paths.lock_file),
        "--quiesce-file",
        str(paths.quiesce_file),
    ]
    for path in map_paths:
        if not path.is_absolute():
            raise GuestEndpointError(f"runtime map path must be absolute: {path}")
        command.extend(["--control-map", str(path)])
    command.extend(
        [
            "--operation",
            operation,
            "--mode",
            "bypass",
            "--epoch",
            str(epoch),
        ]
    )
    return command


class SystemEndpointDriver:
    def __init__(
        self,
        config: EndpointConfig,
        tools: ToolPaths,
        paths: EndpointPaths,
        runner: CommandRunner | None = None,
        ready_timeout: float = 10.0,
    ):
        self.config = config
        self.tools = tools
        self.paths = paths
        self.runner = runner or SubprocessCommandRunner()
        self.ready_timeout = ready_timeout
        self._processes: dict[int, subprocess.Popen[bytes]] = {}
        self._quiesce_fd: int | None = None
        self._quiesce_identity: tuple[int, int] | None = None
        self._shutdown_deadline: float | None = None
        self._validate_inputs()

    def begin_shutdown(self, deadline: float) -> None:
        self._shutdown_deadline = deadline

    def _remaining_timeout(self, maximum: float = 10.0) -> float:
        if self._shutdown_deadline is None:
            return maximum
        remaining = self._shutdown_deadline - time.monotonic()
        if remaining <= 0:
            raise GuestEndpointError(
                "shutdown deadline expired during guest cleanup"
            )
        return min(maximum, remaining)

    def _run_command(
        self, args: Sequence[str], timeout: float = 10.0
    ) -> CommandResult:
        return self.runner.run(args, timeout=self._remaining_timeout(timeout))

    def _validate_inputs(self) -> None:
        executables = [
            self.tools.grpc_fast_cache,
            self.tools.cache_policy_txn,
            self.tools.bpftool,
            self.tools.ip,
        ]
        files = [self.config.grpc.cache_file]
        if self.config.accel_role == "server":
            executables.append(self.tools.dns_monitor)
            files.extend([self.tools.dns_server_bpf, self.config.dns_cache_file])
        for path in executables:
            if not path.is_absolute() or not path.is_file():
                raise GuestEndpointError(f"required executable is missing: {path}")
            if not os.access(path, os.X_OK):
                raise GuestEndpointError(f"required executable is not executable: {path}")
        for path in files:
            if path is None or not path.is_absolute() or not path.is_file():
                raise GuestEndpointError(f"required input file is missing: {path}")
            if not os.access(path, os.R_OK):
                raise GuestEndpointError(f"required input file is not readable: {path}")

    def _open_policy_lock(self) -> int:
        self.paths.lock_root.mkdir(parents=True, exist_ok=True)
        named_root = os.lstat(self.paths.lock_root)
        if not stat.S_ISDIR(named_root.st_mode):
            raise GuestEndpointError("lock root is not a real directory")
        if os.name != "nt":
            current_uid = os.geteuid()
            if named_root.st_uid not in {0, current_uid}:
                raise GuestEndpointError("lock root has an unsafe owner")
            if stat.S_IMODE(named_root.st_mode) & 0o022:
                raise GuestEndpointError("lock root is writable by other users")

        root_descriptor: int | None = None
        lock_descriptor = -1
        try:
            if os.name != "nt":
                root_flags = (
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                )
                root_descriptor = os.open(self.paths.lock_root, root_flags)
                opened_root = os.fstat(root_descriptor)
                if (
                    not stat.S_ISDIR(opened_root.st_mode)
                    or self._file_identity(opened_root)
                    != self._file_identity(named_root)
                ):
                    raise GuestEndpointError("lock root changed during open")

            lock_name: str | Path = (
                self.paths.lock_file.name
                if root_descriptor is not None
                else self.paths.lock_file
            )
            flags = (
                os.O_RDWR
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
            )

            def open_lock(open_flags: int) -> int:
                if root_descriptor is None:
                    return os.open(lock_name, open_flags, 0o600)
                return os.open(
                    lock_name,
                    open_flags,
                    0o600,
                    dir_fd=root_descriptor,
                )

            try:
                lock_descriptor = open_lock(flags | os.O_CREAT | os.O_EXCL)
                if os.name != "nt":
                    os.fchmod(lock_descriptor, 0o600)
            except FileExistsError:
                lock_descriptor = open_lock(flags)

            opened_lock = os.fstat(lock_descriptor)
            self._validate_policy_lock_status(opened_lock)
            self._acquire_policy_lock(lock_descriptor)

            opened_lock = os.fstat(lock_descriptor)
            self._validate_policy_lock_status(opened_lock)
            if root_descriptor is None:
                named_lock = os.lstat(self.paths.lock_file)
            else:
                named_lock = os.stat(
                    self.paths.lock_file.name,
                    dir_fd=root_descriptor,
                    follow_symlinks=False,
                )
            self._validate_policy_lock_status(named_lock)
            if self._file_identity(named_lock) != self._file_identity(opened_lock):
                raise GuestEndpointError("policy lock changed during acquisition")
            return lock_descriptor
        except Exception:
            if lock_descriptor >= 0:
                os.close(lock_descriptor)
            raise
        finally:
            if root_descriptor is not None:
                os.close(root_descriptor)

    @staticmethod
    def _validate_policy_lock_status(status: os.stat_result) -> None:
        if not stat.S_ISREG(status.st_mode):
            raise GuestEndpointError("policy lock is not a regular file")
        if status.st_nlink != 1:
            raise GuestEndpointError("policy lock has an unsafe link count")
        if os.name != "nt":
            if status.st_uid != os.geteuid():
                raise GuestEndpointError("policy lock has an unsafe owner")
            if stat.S_IMODE(status.st_mode) != 0o600:
                raise GuestEndpointError("policy lock has unsafe permissions")

    def _acquire_policy_lock(self, descriptor: int) -> None:
        if fcntl is None:
            return
        while True:
            try:
                fcntl.flock(
                    descriptor,
                    fcntl.LOCK_EX | fcntl.LOCK_NB,
                )
                return
            except OSError as error:
                if error.errno not in {errno.EACCES, errno.EAGAIN}:
                    raise
            deadline = self._shutdown_deadline
            if deadline is None:
                time.sleep(0.05)
                continue
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise GuestEndpointError(
                    "shutdown deadline expired waiting for policy lock"
                )
            time.sleep(min(0.05, remaining))

    def enter_quiesce(self) -> None:
        policy_descriptor = self._open_policy_lock()
        try:
            try:
                current = os.lstat(self.paths.quiesce_file)
            except FileNotFoundError:
                current = None
            if current is not None:
                self._validate_quiesce_status(current)
            if self._quiesce_identity is not None:
                if (
                    current is None
                    or self._file_identity(current) != self._quiesce_identity
                ):
                    raise GuestEndpointError("quiesce file was replaced")
                self._validate_quiesce_status(current)
                return

            flags = (
                os.O_RDWR
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
            )
            descriptor = -1
            try:
                try:
                    descriptor = os.open(
                        self.paths.quiesce_file,
                        flags | os.O_CREAT | os.O_EXCL,
                        0o600,
                    )
                    if os.name != "nt":
                        os.fchmod(descriptor, 0o600)
                except FileExistsError:
                    descriptor = os.open(self.paths.quiesce_file, flags)
                opened = os.fstat(descriptor)
                self._validate_quiesce_status(opened)
                if fcntl is not None:
                    try:
                        fcntl.flock(
                            descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB
                        )
                    except OSError as error:
                        if error.errno in {errno.EACCES, errno.EAGAIN}:
                            raise GuestEndpointError(
                                "quiesce file is owned by another agent"
                            ) from error
                        raise
                named = os.lstat(self.paths.quiesce_file)
                if self._file_identity(named) != self._file_identity(opened):
                    raise GuestEndpointError("quiesce file was replaced")
                if os.name == "nt":
                    os.close(descriptor)
                    descriptor = -1
                else:
                    self._quiesce_fd = descriptor
                self._quiesce_identity = self._file_identity(opened)
            except Exception:
                if descriptor >= 0:
                    os.close(descriptor)
                raise
        finally:
            os.close(policy_descriptor)

    def leave_quiesce(self) -> None:
        policy_descriptor = self._open_policy_lock()
        try:
            expected = self._quiesce_identity
            descriptor = self._quiesce_fd
            if expected is None:
                if os.path.lexists(self.paths.quiesce_file):
                    raise GuestEndpointError(
                        "quiesce file ownership is unknown"
                    )
                return
            if (
                descriptor is not None
                and self._file_identity(os.fstat(descriptor)) != expected
            ):
                raise GuestEndpointError(
                    "quiesce file descriptor was replaced"
                )
            try:
                named = os.lstat(self.paths.quiesce_file)
            except FileNotFoundError:
                raise GuestEndpointError("quiesce file disappeared") from None
            self._validate_quiesce_status(named)
            if self._file_identity(named) != expected:
                raise GuestEndpointError("quiesce file was replaced")

            release_path = self.paths.quiesce_file.with_name(
                f".{self.paths.quiesce_file.name}.{os.getpid()}."
                f"{uuid.uuid4().hex}.release"
            )
            try:
                os.replace(self.paths.quiesce_file, release_path)
                released = os.lstat(release_path)
                if self._file_identity(released) != expected:
                    raise GuestEndpointError("quiesce file was replaced")
                release_path.unlink()
            except Exception as error:
                try:
                    if (
                        os.path.lexists(release_path)
                        and not os.path.lexists(self.paths.quiesce_file)
                    ):
                        os.replace(release_path, self.paths.quiesce_file)
                except Exception as restore_error:
                    raise GuestEndpointError(
                        "quiesce release failed and fence restoration failed: "
                        f"{restore_error}"
                    ) from error
                raise
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError as error:
                    print(
                        "openstack_guest_endpoint_agent: warning: close "
                        f"quiesce descriptor failed after release: {error}",
                        file=sys.stderr,
                    )
            self._quiesce_fd = None
            self._quiesce_identity = None
            if os.path.lexists(self.paths.quiesce_file):
                raise GuestEndpointError("quiesce file was replaced")
        finally:
            os.close(policy_descriptor)

    def quiesced(self) -> bool:
        return os.path.lexists(self.paths.quiesce_file)

    @staticmethod
    def _file_identity(status: os.stat_result) -> tuple[int, int]:
        return status.st_dev, status.st_ino

    @staticmethod
    def _validate_quiesce_status(status: os.stat_result) -> None:
        if not stat.S_ISREG(status.st_mode):
            raise GuestEndpointError("quiesce file is not a regular file")
        if status.st_nlink != 1:
            raise GuestEndpointError("quiesce file has an unsafe link count")
        if os.name != "nt":
            if status.st_uid != os.geteuid():
                raise GuestEndpointError("quiesce file has an unsafe owner")
            if stat.S_IMODE(status.st_mode) != 0o600:
                raise GuestEndpointError("quiesce file has unsafe permissions")

    def ensure_interface(self, interface: str) -> None:
        result = self._run_command(
            [str(self.tools.ip), "-j", "link", "show", "dev", interface]
        )
        if result.returncode != 0:
            raise GuestEndpointError(
                f"interface {interface} is unavailable: {_command_detail(result)}"
            )
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise GuestEndpointError("ip link returned invalid JSON") from error
        if not isinstance(value, list) or len(value) != 1:
            raise GuestEndpointError(f"interface {interface} is not unique")

    def interface_ipv4(self, interface: str) -> tuple[str, ...]:
        result = self._run_command(
            [str(self.tools.ip), "-j", "addr", "show", "dev", interface]
        )
        if result.returncode != 0:
            raise GuestEndpointError(
                f"interface {interface} address lookup failed: "
                f"{_command_detail(result)}"
            )
        try:
            rows = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise GuestEndpointError("ip addr returned invalid JSON") from error
        if not isinstance(rows, list) or len(rows) != 1:
            raise GuestEndpointError(
                f"interface {interface} address is not unique"
            )
        addr_info = rows[0].get("addr_info")
        if not isinstance(addr_info, list):
            raise GuestEndpointError(
                f"interface {interface} has invalid addr_info"
            )
        addresses: set[str] = set()
        for item in addr_info:
            if not isinstance(item, dict) or item.get("family") != "inet":
                continue
            local = item.get("local")
            try:
                address = ipaddress.IPv4Address(local)
            except (ipaddress.AddressValueError, ValueError):
                continue
            if not _invalid_guest_ipv4(str(address)):
                addresses.add(str(address))
        return tuple(sorted(addresses))

    def ensure_grpc_runtime_map(self) -> None:
        self.paths.grpc_dir.mkdir(parents=True, exist_ok=True)
        if self.paths.grpc_runtime_map.is_symlink():
            raise GuestEndpointError(
                "gRPC runtime map path must not be a symlink"
            )
        if not self.paths.grpc_runtime_map.exists():
            result = self._run_command(
                [
                    str(self.tools.bpftool),
                    "map",
                    "create",
                    str(self.paths.grpc_runtime_map),
                    "type",
                    "array",
                    "key",
                    "4",
                    "value",
                    str(RUNTIME_VALUE_SIZE),
                    "entries",
                    "1",
                    "name",
                    "vnet_grpc_ctl",
                ]
            )
            if result.returncode != 0:
                raise GuestEndpointError(
                    "failed to create gRPC runtime map: "
                    + _command_detail(result)
                )
        self._validate_runtime_map(self.paths.grpc_runtime_map)

    def _validate_runtime_map(self, path: Path) -> None:
        result = self._run_command(
            [str(self.tools.bpftool), "-j", "map", "show", "pinned", str(path)]
        )
        if result.returncode != 0:
            raise GuestEndpointError(
                f"failed to inspect runtime map {path}: {_command_detail(result)}"
            )
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise GuestEndpointError(
                f"bpftool returned invalid JSON for {path}"
            ) from error
        if isinstance(value, list) and len(value) == 1:
            value = value[0]
        if not isinstance(value, dict):
            raise GuestEndpointError(f"runtime map metadata is invalid: {path}")
        map_type = value.get("type")
        key_size = value.get(
            "bytes_key", value.get("key", value.get("key_size"))
        )
        value_size = value.get(
            "bytes_value", value.get("value", value.get("value_size"))
        )
        max_entries = value.get("max_entries")
        if (
            map_type != "array"
            or key_size != 4
            or value_size != RUNTIME_VALUE_SIZE
            or max_entries != 1
        ):
            raise GuestEndpointError(f"incompatible runtime map: {path}")

    def path_exists(self, path: Path) -> bool:
        return path.exists()

    def force_bypass_and_read(
        self, map_paths: Sequence[Path]
    ) -> dict[str, Any]:
        if not map_paths:
            raise GuestEndpointError("no runtime maps are available for BYPASS")
        epochs = []
        for path in map_paths:
            current = self._read_txn((path,), 1, require_committed=False)
            epochs.append(current["epoch"])
        epoch = max([1, *epochs])
        force = self._run_command(
            build_txn_command(
                self.tools, self.paths, "force-bypass", epoch, map_paths
            )
        )
        if force.returncode != 0:
            raise GuestEndpointError(
                "failed to force committed BYPASS: " + _command_detail(force)
            )
        observed = self._read_txn(map_paths, epoch, require_committed=True)
        if observed["mode"] != 1:
            raise GuestEndpointError("runtime maps did not enter BYPASS")
        return observed

    def read_runtime(self, map_paths: Sequence[Path]) -> dict[str, Any]:
        # A coordinator publishes in two phases.  During the short staged
        # phase flags are zero; the endpoint must observe that state without
        # treating it as a failed runtime or tearing down its processes.
        return self._read_txn(map_paths, 1, require_committed=False)

    def _read_txn(
        self,
        map_paths: Sequence[Path],
        epoch: int,
        require_committed: bool,
    ) -> dict[str, Any]:
        result = self._run_command(
            build_txn_command(
                self.tools, self.paths, "read-current", epoch, map_paths
            )
        )
        if result.returncode != 0:
            raise GuestEndpointError(
                "failed to read runtime maps: " + _command_detail(result)
            )
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise GuestEndpointError(
                "cache_policy_txn returned invalid JSON"
            ) from error
        if (
            not isinstance(value, dict)
            or value.get("schema_version") != 1
            or value.get("present") is not True
            or value.get("maps") != len(map_paths)
            or not _plain_int(value.get("epoch"))
            or not _plain_int(value.get("mode"))
            or not _plain_int(value.get("flags"))
        ):
            raise GuestEndpointError("cache_policy_txn returned invalid readback")
        if value["flags"] not in {0, RUNTIME_COMMITTED}:
            raise GuestEndpointError("runtime maps have invalid commit flags")
        if require_committed and (
            value["epoch"] < 1
            or not RUNTIME_MODE_MIN <= value["mode"] <= RUNTIME_MODE_MAX
            or value["flags"] != RUNTIME_COMMITTED
        ):
            raise GuestEndpointError("runtime maps are not consistently committed")
        return value

    def start_process(
        self, name: str, command: Sequence[str], log_path: Path
    ) -> int:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("ab", buffering=0) as log:
            process = subprocess.Popen(
                list(command),
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        self._processes[process.pid] = process
        return process.pid

    def listener_owned(self, pid: int, listen: str) -> bool:
        if not self.process_alive(pid):
            return False
        try:
            socket_inodes: set[str] = set()
            for descriptor in Path(f"/proc/{pid}/fd").iterdir():
                try:
                    target = os.readlink(descriptor)
                except FileNotFoundError:
                    continue
                match = re.fullmatch(r"socket:\[(\d+)\]", target)
                if match:
                    socket_inodes.add(match.group(1))
            tcp_table = Path(f"/proc/{pid}/net/tcp").read_text(
                encoding="ascii"
            )
        except (FileNotFoundError, PermissionError, OSError):
            return False
        return bool(socket_inodes & _tcp_listener_inodes(tcp_table, listen))

    def wait_listener_owned(self, pid: int, listen: str) -> bool:
        deadline = time.monotonic() + self.ready_timeout
        while time.monotonic() < deadline:
            if not self.process_alive(pid):
                return False
            if self.listener_owned(pid, listen):
                return True
            time.sleep(0.05)
        return False

    def backend_ready(self, backend: str) -> bool:
        host, port_text = backend.rsplit(":", 1)
        try:
            with socket.create_connection(
                (host, int(port_text)), timeout=min(self.ready_timeout, 1.0)
            ):
                return True
        except OSError:
            return False

    def process_alive(self, pid: int) -> bool:
        process = self._processes.get(pid)
        if process is not None:
            return process.poll() is None
        try:
            os.kill(pid, 0)
        except (ProcessLookupError, PermissionError):
            return False
        return True

    def stop_process(self, pid: int) -> bool:
        process = self._processes.get(pid)
        if process is None:
            return not self.process_alive(pid)
        if process.poll() is not None:
            self._processes.pop(pid, None)
            return True
        for sig_value, timeout in (
            (signal.SIGINT, 3.0),
            (signal.SIGTERM, 2.0),
            (signal.SIGKILL, 1.0),
        ):
            try:
                os.killpg(pid, sig_value)
            except ProcessLookupError:
                self._processes.pop(pid, None)
                return process.poll() is not None
            try:
                process.wait(timeout=self._remaining_timeout(timeout))
                self._processes.pop(pid, None)
                return True
            except (GuestEndpointError, subprocess.TimeoutExpired):
                if (
                    self._shutdown_deadline is not None
                    and time.monotonic() >= self._shutdown_deadline
                ):
                    return False
                continue
        return False

    def current_xdp_program_id(self, interface: str) -> int:
        result = self._run_command(
            [
                str(self.tools.ip),
                "-j",
                "-details",
                "link",
                "show",
                "dev",
                interface,
            ]
        )
        if result.returncode != 0:
            raise GuestEndpointError(
                f"failed to inspect XDP on {interface}: {_command_detail(result)}"
            )
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise GuestEndpointError("ip link returned invalid XDP JSON") from error
        if not isinstance(value, list) or len(value) != 1:
            raise GuestEndpointError(f"interface {interface} is not unique")
        return _extract_xdp_program_id(value[0])

    def wait_dns_ready(self, interface: str, dns_pid: int) -> int:
        deadline = time.monotonic() + self.ready_timeout
        required = (
            self.paths.dns_runtime_map,
            self.paths.dns_stats_map,
            self.paths.dns_entries_map,
        )
        while time.monotonic() < deadline:
            if not self.process_alive(dns_pid):
                raise GuestEndpointError("DNS monitor exited before readiness")
            if all(path.exists() for path in required):
                program_id = self.current_xdp_program_id(interface)
                if program_id > 0:
                    return program_id
            time.sleep(0.05)
        raise GuestEndpointError("DNS pins and owned XDP hook did not become ready")

    def remove_owned_port_pins(self) -> None:
        path = self.paths.port_root
        if path.is_symlink():
            raise GuestEndpointError(f"refusing to remove symlink pin root: {path}")
        if not path.exists():
            return
        allowed_directories = {self.paths.dns_dir, self.paths.grpc_dir}
        allowed_files = set(self.paths.required_pins(self.config.accel_role))
        directories: list[Path] = []
        for child in path.iterdir():
            if child.is_symlink() or child not in allowed_directories:
                raise GuestEndpointError(
                    f"refusing to remove unknown pin entry: {child}"
                )
            if not child.is_dir():
                raise GuestEndpointError(
                    f"expected managed pin directory: {child}"
                )
            directories.append(child)
            for entry in child.iterdir():
                if entry.is_symlink() or entry not in allowed_files:
                    raise GuestEndpointError(
                        f"refusing to remove unknown pin entry: {entry}"
                    )
                if entry.is_dir():
                    raise GuestEndpointError(
                        f"refusing to remove nested pin directory: {entry}"
                    )
        for entry in allowed_files:
            try:
                entry.unlink()
            except FileNotFoundError:
                pass
        for directory in directories:
            directory.rmdir()
        path.rmdir()


def _plain_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _runtime_readback_is_committed(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and value.get("schema_version") == 1
        and value.get("present") is True
        and _plain_int(value.get("maps"))
        and value["maps"] > 0
        and _plain_int(value.get("epoch"))
        and value["epoch"] > 0
        and _plain_int(value.get("mode"))
        and RUNTIME_MODE_MIN <= value["mode"] <= RUNTIME_MODE_MAX
        and value.get("flags") == RUNTIME_COMMITTED
    )


def _invalid_guest_ipv4(value: str) -> bool:
    try:
        address = ipaddress.IPv4Address(value)
    except ipaddress.AddressValueError:
        return True
    return (
        address.is_loopback
        or address.is_link_local
        or address.is_multicast
        or address.is_unspecified
    )


def _command_detail(result: CommandResult) -> str:
    return (result.stderr.strip() or result.stdout.strip() or "command failed")[:400]


def _extract_xdp_program_id(link: Any) -> int:
    if not isinstance(link, dict):
        raise GuestEndpointError("ip link XDP record is not an object")
    xdp = link.get("xdp")
    if xdp is None:
        return 0
    if not isinstance(xdp, dict):
        raise GuestEndpointError("ip link XDP metadata is invalid")
    candidates: set[int] = set()

    def collect(value: Any) -> None:
        if not isinstance(value, dict):
            return
        for key in ("prog_id", "id"):
            candidate = value.get(key)
            if _plain_int(candidate) and candidate > 0:
                candidates.add(candidate)

    collect(xdp)
    for key in (
        "prog",
        "drv",
        "driver",
        "skb",
        "generic",
        "hw",
        "offload",
        "programs",
    ):
        nested = xdp.get(key)
        if isinstance(nested, list):
            for item in nested:
                collect(item)
        else:
            collect(nested)
    if len(candidates) > 1:
        raise GuestEndpointError("interface has ambiguous XDP program IDs")
    return next(iter(candidates), 0)


def _tcp_listener_inodes(table: str, listen: str) -> set[str]:
    host, port_text = listen.split(":", 1)
    encoded_host = socket.inet_aton(host)[::-1].hex().upper()
    encoded_port = f"{int(port_text):04X}"
    expected_local = f"{encoded_host}:{encoded_port}"
    inodes: set[str] = set()
    for line in table.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 10:
            continue
        local_address = fields[1].upper()
        tcp_state = fields[3].upper()
        inode = fields[9]
        if (
            local_address == expected_local
            and tcp_state == "0A"
            and inode.isdigit()
        ):
            inodes.add(inode)
    return inodes


class GuestEndpointAgent:
    def __init__(
        self,
        config: EndpointConfig,
        tools: ToolPaths,
        paths: EndpointPaths,
        driver: EndpointDriver,
    ):
        if config.port_id != paths.port_id:
            raise GuestEndpointError("config port_id does not match endpoint paths")
        self.config = config
        self.tools = tools
        self.paths = paths
        self.driver = driver
        self.runtime = ManagedRuntime()
        self.state = "idle"
        self.reason = "not_started"

    def start(self, hold_quiesce: bool = False) -> HealthReport:
        self.state = "starting"
        self.reason = "initializing"
        try:
            self.driver.enter_quiesce()
            self.driver.ensure_interface(self.config.interface)
            if not self.driver.interface_ipv4(self.config.interface):
                raise GuestEndpointError(
                    f"interface {self.config.interface} has no usable IPv4 address"
                )
            if not self.driver.backend_ready(self.config.grpc.backend):
                raise GuestEndpointError(
                    f"gRPC backend is not reachable: {self.config.grpc.backend}"
                )
            if self.config.accel_role == "server":
                existing_xdp = self.driver.current_xdp_program_id(
                    self.config.interface
                )
                if existing_xdp != 0:
                    raise GuestEndpointError(
                        f"unowned XDP program {existing_xdp} is already attached "
                        f"to {self.config.interface}"
                    )
                stale_dns_pins = [
                    str(path)
                    for path in (
                        self.paths.dns_runtime_map,
                        self.paths.dns_stats_map,
                        self.paths.dns_entries_map,
                    )
                    if self.driver.path_exists(path)
                ]
                if stale_dns_pins:
                    self.driver.remove_owned_port_pins()

            self.driver.ensure_grpc_runtime_map()
            self.runtime.runtime_readback = self.driver.force_bypass_and_read(
                (self.paths.grpc_runtime_map,)
            )

            if self.config.accel_role == "server":
                dns_command = build_dns_command(self.config, self.tools, self.paths)
                if dns_command is None:
                    raise GuestEndpointError("server DNS command is missing")
                self.runtime.dns_pid = self.driver.start_process(
                    "dns_monitor",
                    dns_command,
                    self.paths.port_log_dir / "dns-monitor.log",
                )
                self.runtime.dns_xdp_prog_id = self.driver.wait_dns_ready(
                    self.config.interface, self.runtime.dns_pid
                )
                self.runtime.runtime_readback = (
                    self.driver.force_bypass_and_read(
                        (
                            self.paths.dns_runtime_map,
                            self.paths.grpc_runtime_map,
                        )
                    )
                )

            self.runtime.grpc_pid = self.driver.start_process(
                "grpc_fast_cache",
                build_grpc_command(self.config, self.tools, self.paths),
                self.paths.port_log_dir / "grpc-fast-cache.log",
            )
            if not self.driver.wait_listener_owned(
                self.runtime.grpc_pid, self.config.grpc.listen
            ):
                raise GuestEndpointError(
                    "gRPC fast-cache did not own its configured listener"
                )
            report = self.inspect(allow_quiesce=True)
            if not report.healthy:
                raise GuestEndpointError(
                    f"endpoint failed pre-publication health: {report.reason}"
                )
            self.reason = "awaiting_state_publication"
            if hold_quiesce:
                return report
            return self.activate()
        except Exception as error:
            self.state = "degraded"
            self.reason = f"startup_failed:{error}"
            self.fail_closed_cleanup(preserve_pins=True)
            raise

    def activate(self) -> HealthReport:
        if self.state != "starting" or self.reason != "awaiting_state_publication":
            raise GuestEndpointError("endpoint is not awaiting publication")
        self.driver.leave_quiesce()
        report = self.inspect()
        if not report.healthy:
            raise GuestEndpointError(
                f"endpoint failed health publication: {report.reason}"
            )
        self.state = "healthy"
        self.reason = "ready"
        return report

    def inspect(self, allow_quiesce: bool = False) -> HealthReport:
        reasons: list[str] = []
        try:
            interface_ipv4 = self.driver.interface_ipv4(
                self.config.interface
            )
        except Exception as error:
            interface_ipv4 = ()
            reasons.append(f"interface_address_inspection_failed:{error}")
        if not interface_ipv4:
            reasons.append("interface_ipv4_missing")
        process_alive = {
            "grpc_fast_cache": bool(
                self.runtime.grpc_pid is not None
                and self.driver.process_alive(self.runtime.grpc_pid)
            )
        }
        if not process_alive["grpc_fast_cache"]:
            reasons.append("grpc_process_not_alive")
        try:
            grpc_listener_owned = bool(
                self.runtime.grpc_pid is not None
                and process_alive["grpc_fast_cache"]
                and self.driver.listener_owned(
                    self.runtime.grpc_pid, self.config.grpc.listen
                )
            )
        except Exception as error:
            grpc_listener_owned = False
            reasons.append(f"grpc_listener_inspection_failed:{error}")
        if not grpc_listener_owned:
            reasons.append("grpc_listener_not_owned")
        try:
            grpc_backend_ready = self.driver.backend_ready(
                self.config.grpc.backend
            )
        except Exception as error:
            grpc_backend_ready = False
            reasons.append(f"grpc_backend_inspection_failed:{error}")
        if not grpc_backend_ready:
            reasons.append("grpc_backend_not_ready")
        if self.config.accel_role == "server":
            process_alive["dns_monitor"] = bool(
                self.runtime.dns_pid is not None
                and self.driver.process_alive(self.runtime.dns_pid)
            )
            if not process_alive["dns_monitor"]:
                reasons.append("dns_process_not_alive")

        pins_present = {
            str(path): self.driver.path_exists(path)
            for path in self.paths.required_pins(self.config.accel_role)
        }
        missing = [path for path, present in pins_present.items() if not present]
        if missing:
            reasons.append("missing_pins:" + ",".join(missing))
        if self.driver.quiesced() and not allow_quiesce:
            reasons.append("quiesced")

        current_xdp: int | None = None
        if self.config.accel_role == "server":
            try:
                current_xdp = self.driver.current_xdp_program_id(
                    self.config.interface
                )
                if (
                    self.runtime.dns_xdp_prog_id is None
                    or current_xdp != self.runtime.dns_xdp_prog_id
                ):
                    reasons.append("dns_xdp_ownership_drift")
            except Exception as error:
                reasons.append(f"dns_xdp_inspection_failed:{error}")

        readback: dict[str, Any] | None = None
        if not missing:
            try:
                readback = self.driver.read_runtime(
                    self.paths.runtime_maps(self.config.accel_role)
                )
                if readback["flags"] == RUNTIME_COMMITTED:
                    self.runtime.runtime_readback = readback
                else:
                    committed = self.runtime.runtime_readback
                    if (
                        not _runtime_readback_is_committed(committed)
                        or readback["epoch"] < committed["epoch"]
                    ):
                        reasons.append("runtime_transition_invalid")
                    else:
                        # Keep the last committed snapshot in the health file.
                        # The coordinator can then finish stage/commit without
                        # the supervisor mistaking flags=0 for endpoint failure.
                        readback = committed
            except Exception as error:
                reasons.append(f"runtime_readback_failed:{error}")
        return HealthReport(
            healthy=not reasons,
            reason="ready" if not reasons else ";".join(reasons),
            process_alive=process_alive,
            pins_present=pins_present,
            interface_ipv4=interface_ipv4,
            grpc_listener_owned=grpc_listener_owned,
            grpc_backend_ready=grpc_backend_ready,
            current_dns_xdp_prog_id=current_xdp,
            runtime_readback=readback,
        )

    def prepare_stop(
        self, reason: str = "service_stopped"
    ) -> HealthReport:
        self.driver.enter_quiesce()
        self.state = "stopping"
        self.reason = reason
        return self.inspect(allow_quiesce=True)

    def finish_stop(self, reason: str = "service_stopped") -> bool:
        if not self.fail_closed_cleanup(preserve_pins=False):
            self.state = "degraded"
            if not self.reason.startswith("cleanup_failed:"):
                self.reason = f"cleanup_failed:{reason}"
            return False
        self.state = "stopped"
        self.reason = reason
        return True

    def stop(self, reason: str = "service_stopped") -> bool:
        self.prepare_stop(reason)
        return self.finish_stop(reason)

    def fail_closed_cleanup(self, preserve_pins: bool = True) -> bool:
        try:
            self.driver.enter_quiesce()
            required_maps = self.paths.runtime_maps(self.config.accel_role)
            maps = tuple(
                path for path in required_maps if self.driver.path_exists(path)
            )
            has_managed_process = any(
                pid is not None
                for pid in (self.runtime.grpc_pid, self.runtime.dns_pid)
            )
            if has_managed_process and len(maps) != len(required_maps):
                missing = [str(path) for path in required_maps if path not in maps]
                raise GuestEndpointError(
                    "managed runtime map is missing: " + ",".join(missing)
                )
            if maps:
                self.runtime.runtime_readback = (
                    self.driver.force_bypass_and_read(maps)
                )
        except Exception as error:
            self.state = "degraded"
            self.reason = f"cleanup_failed:bypass_unconfirmed:{error}"
            return False

        if self.config.accel_role == "server":
            try:
                current_xdp = self.driver.current_xdp_program_id(
                    self.config.interface
                )
            except Exception as error:
                self.reason = f"cleanup_failed:xdp_inspection:{error}"
                return False
            if self.runtime.dns_pid is None:
                has_dns_pins = any(
                    self.driver.path_exists(path)
                    for path in (
                        self.paths.dns_runtime_map,
                        self.paths.dns_stats_map,
                        self.paths.dns_entries_map,
                    )
                )
                if current_xdp != 0:
                    self.reason = "cleanup_failed:dns_xdp_owner_unknown"
                    return False
                if has_dns_pins and self.runtime.dns_xdp_prog_id is None:
                    self.reason = "cleanup_failed:dns_pin_owner_unknown"
                    return False
            else:
                dns_alive = self.driver.process_alive(self.runtime.dns_pid)
                if self.runtime.dns_xdp_prog_id is None:
                    self.reason = "cleanup_failed:dns_xdp_owner_unknown"
                    return False
                if dns_alive and current_xdp != self.runtime.dns_xdp_prog_id:
                    self.reason = "cleanup_failed:dns_xdp_ownership_drift"
                    return False
                if not dns_alive and current_xdp not in {
                    0,
                    self.runtime.dns_xdp_prog_id,
                }:
                    self.reason = "cleanup_failed:dns_xdp_ownership_drift"
                    return False

        if self.runtime.grpc_pid is not None:
            if not self.driver.stop_process(self.runtime.grpc_pid):
                self.reason = "cleanup_failed:grpc_process_not_stopped"
                return False
            self.runtime.grpc_pid = None

        if self.runtime.dns_pid is not None:
            if not self.driver.stop_process(self.runtime.dns_pid):
                self.reason = "cleanup_failed:dns_process_not_stopped"
                return False
            self.runtime.dns_pid = None
            try:
                if self.driver.current_xdp_program_id(self.config.interface) != 0:
                    self.reason = "cleanup_failed:dns_xdp_still_attached"
                    return False
            except Exception as error:
                self.reason = f"cleanup_failed:xdp_postcheck:{error}"
                return False

        if not preserve_pins:
            try:
                self.driver.remove_owned_port_pins()
            except Exception as error:
                self.reason = f"cleanup_failed:pin_removal:{error}"
                return False
            # A successful stop has already forced committed BYPASS and
            # removed every owned pin/process.  The fence is no longer needed.
            self.driver.leave_quiesce()
        return True

    def state_payload(
        self, report: HealthReport | None = None
    ) -> dict[str, Any]:
        if report is None:
            report = self._best_effort_report()
        runtime = report.runtime_readback or self.runtime.runtime_readback
        return {
            "schema_version": STATE_SCHEMA_VERSION,
            "source_kind": "guest_endpoint",
            "server_id": self.config.server_id,
            "port_id": self.config.port_id,
            "accel_role": self.config.accel_role,
            "interface": self.config.interface,
            "interface_ipv4": list(report.interface_ipv4),
            "updated_ms": int(time.time() * 1000),
            "state": self.state,
            "reason": self.reason,
            "grpc_capability": GRPC_CAPABILITY,
            "grpc": {
                "listen": self.config.grpc.listen,
                "backend": self.config.grpc.backend,
                "method": self.config.grpc.method,
                "cache_file": str(self.config.grpc.cache_file),
                "listener_owned": report.grpc_listener_owned,
                "backend_ready": report.grpc_backend_ready,
            },
            "processes": {
                "grpc_fast_cache": {
                    "pid": self.runtime.grpc_pid,
                    "alive": report.process_alive.get(
                        "grpc_fast_cache", False
                    ),
                },
                "dns_monitor": {
                    "pid": self.runtime.dns_pid,
                    "alive": report.process_alive.get("dns_monitor", False),
                },
            },
            "dns_xdp_prog_id": self.runtime.dns_xdp_prog_id,
            "current_dns_xdp_prog_id": report.current_dns_xdp_prog_id,
            "map_paths": {
                "grpc_runtime_control": str(self.paths.grpc_runtime_map),
                "dns_runtime_control": (
                    str(self.paths.dns_runtime_map)
                    if self.config.accel_role == "server"
                    else None
                ),
                "dns_cache_stats": (
                    str(self.paths.dns_stats_map)
                    if self.config.accel_role == "server"
                    else None
                ),
                "dns_cache_entries": (
                    str(self.paths.dns_entries_map)
                    if self.config.accel_role == "server"
                    else None
                ),
            },
            "pins_present": report.pins_present,
            "runtime_readback": runtime,
            "quiesced": self.driver.quiesced(),
        }

    def _best_effort_report(self) -> HealthReport:
        try:
            return self.inspect()
        except Exception as error:
            return HealthReport(
                healthy=False,
                reason=f"inspection_failed:{error}",
                process_alive={},
                pins_present={},
                interface_ipv4=(),
                grpc_listener_owned=False,
                grpc_backend_ready=False,
                current_dns_xdp_prog_id=None,
                runtime_readback=None,
            )


def _sync_state_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_DIRECTORY", 0)
    try:
        directory_fd = os.open(path.parent, flags)
    except PermissionError:
        if os.name == "nt":
            return
        raise
    try:
        os.fsync(directory_fd)
    except OSError:
        if os.name != "nt":
            raise
    finally:
        os.close(directory_fd)


def write_state(path: Path, payload: dict[str, Any]) -> None:
    if not path.is_absolute() or path == Path("/"):
        raise GuestEndpointError("state file must be an absolute file path")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    rollback = path.with_name(
        f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.rollback"
    )
    encoded = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()
    descriptor = os.open(
        temporary,
        os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        had_previous = False
        try:
            os.link(path, rollback, follow_symlinks=False)
            had_previous = True
        except FileNotFoundError:
            pass
        if had_previous:
            try:
                _sync_state_directory(path)
            except Exception:
                rollback.unlink()
                raise
        try:
            os.replace(temporary, path)
        except Exception:
            if had_previous:
                try:
                    rollback.unlink()
                    _sync_state_directory(path)
                except Exception as cleanup_error:
                    print(
                        "openstack_guest_endpoint_agent: warning: failed to "
                        f"remove unused state rollback: {cleanup_error}",
                        file=sys.stderr,
                    )
            raise
        try:
            _sync_state_directory(path)
        except Exception as publish_error:
            invalidation_errors: list[str] = []
            try:
                path.unlink(missing_ok=True)
            except Exception as error:
                invalidation_errors.append(f"remove public state: {error}")
            if had_previous:
                try:
                    rollback.unlink(missing_ok=True)
                except Exception as error:
                    invalidation_errors.append(
                        f"remove state rollback: {error}"
                    )
            try:
                _sync_state_directory(path)
            except Exception as error:
                invalidation_errors.append(f"sync state invalidation: {error}")
            if invalidation_errors:
                raise GuestEndpointError(
                    "state publication failed and fail-closed invalidation was "
                    "not durable: " + "; ".join(invalidation_errors)
                ) from publish_error
            raise
        if had_previous:
            try:
                rollback.unlink()
                _sync_state_directory(path)
            except Exception as error:
                print(
                    "openstack_guest_endpoint_agent: warning: state "
                    f"committed with rollback cleanup failure: {error}",
                    file=sys.stderr,
                )
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def invalidate_state(path: Path) -> None:
    if not path.is_absolute() or path == Path("/"):
        raise GuestEndpointError("state file must be an absolute file path")
    path.unlink(missing_ok=True)
    _sync_state_directory(path)


def evaluate_state_health(
    state: Any,
    config: EndpointConfig,
    max_age_seconds: float,
    now_ms: int | None = None,
    *,
    pin_root: Path = PRODUCTION_PIN_ROOT,
) -> dict[str, Any]:
    reasons: list[str] = []
    if not isinstance(state, dict):
        return {"ready": False, "reasons": ["state_not_object"]}
    expected_identity = {
        "schema_version": STATE_SCHEMA_VERSION,
        "source_kind": "guest_endpoint",
        "server_id": config.server_id,
        "port_id": config.port_id,
        "accel_role": config.accel_role,
        "interface": config.interface,
        "grpc_capability": GRPC_CAPABILITY,
    }
    for key, expected in expected_identity.items():
        if state.get(key) != expected:
            reasons.append(f"{key}_mismatch")
    interface_ipv4 = state.get("interface_ipv4")
    if (
        not isinstance(interface_ipv4, list)
        or not interface_ipv4
        or any(
            not isinstance(item, str)
            or _invalid_guest_ipv4(item)
            for item in interface_ipv4
        )
    ):
        reasons.append("interface_ipv4_invalid")
    updated_ms = state.get("updated_ms")
    current_ms = int(time.time() * 1000) if now_ms is None else now_ms
    if not _plain_int(updated_ms):
        reasons.append("updated_ms_invalid")
    else:
        age_ms = current_ms - updated_ms
        if age_ms < -5000:
            reasons.append("state_from_future")
        elif age_ms > max_age_seconds * 1000:
            reasons.append("state_stale")
    if state.get("state") != "healthy":
        reasons.append("state_not_healthy")
    if state.get("quiesced") is not False:
        reasons.append("endpoint_quiesced")
    grpc_state = state.get("grpc")
    expected_grpc = {
        "listen": config.grpc.listen,
        "backend": config.grpc.backend,
        "method": config.grpc.method,
        "cache_file": str(config.grpc.cache_file),
    }
    if not isinstance(grpc_state, dict):
        reasons.append("grpc_state_invalid")
    else:
        for key, expected in expected_grpc.items():
            if grpc_state.get(key) != expected:
                reasons.append(f"grpc_{key}_mismatch")
        if grpc_state.get("listener_owned") is not True:
            reasons.append("grpc_listener_not_owned")
        if grpc_state.get("backend_ready") is not True:
            reasons.append("grpc_backend_not_ready")

    processes = state.get("processes")
    required_processes = ["grpc_fast_cache"]
    if config.accel_role == "server":
        required_processes.append("dns_monitor")
    if not isinstance(processes, dict):
        reasons.append("processes_invalid")
    else:
        for name in required_processes:
            record = processes.get(name)
            if (
                not isinstance(record, dict)
                or not _plain_int(record.get("pid"))
                or record["pid"] <= 0
                or record.get("alive") is not True
            ):
                reasons.append(f"{name}_not_alive")

    readback = state.get("runtime_readback")
    expected_maps = 2 if config.accel_role == "server" else 1
    if (
        not isinstance(readback, dict)
        or readback.get("schema_version") != 1
        or readback.get("present") is not True
        or readback.get("maps") != expected_maps
        or not _plain_int(readback.get("epoch"))
        or readback["epoch"] < 1
        or not _plain_int(readback.get("mode"))
        or not RUNTIME_MODE_MIN <= readback["mode"] <= RUNTIME_MODE_MAX
        or readback.get("flags") != RUNTIME_COMMITTED
    ):
        reasons.append("runtime_readback_invalid")
    pins = state.get("pins_present")
    expected_pins = _expected_state_pin_paths(
        state, config.accel_role, config.port_id, pin_root
    )
    if (
        expected_pins is None
        or not isinstance(pins, dict)
        or set(pins) != expected_pins
    ):
        reasons.append("pins_invalid")
    elif not all(value is True for value in pins.values()):
        reasons.append("pins_missing")
    if config.accel_role == "server":
        recorded = state.get("dns_xdp_prog_id")
        current = state.get("current_dns_xdp_prog_id")
        if (
            not _plain_int(recorded)
            or recorded <= 0
            or current != recorded
        ):
            reasons.append("dns_xdp_ownership_invalid")
    elif state.get("dns_xdp_prog_id") is not None:
        reasons.append("client_has_dns_xdp")
    return {"ready": not reasons, "reasons": reasons}


class GuestEndpointSupervisor:
    def __init__(
        self,
        agent: GuestEndpointAgent,
        state_file: Path,
        interval: float,
    ):
        if interval <= 0:
            raise GuestEndpointError("interval must be positive")
        self.agent = agent
        self.state_file = state_file
        self.interval = interval
        self.stop_event = threading.Event()

    def request_stop(self, _signum: int | None = None, _frame: Any = None) -> None:
        self.stop_event.set()

    def _publish(self, report: HealthReport | None = None) -> bool:
        try:
            write_state(self.state_file, self.agent.state_payload(report))
        except (GuestEndpointError, OSError) as error:
            fail_closed_errors: list[str] = []
            try:
                self.agent.driver.enter_quiesce()
            except Exception as fence_error:
                fail_closed_errors.append(f"enter quiesce: {fence_error}")
            try:
                invalidate_state(self.state_file)
            except Exception as state_error:
                fail_closed_errors.append(f"invalidate state: {state_error}")
            detail = (
                "; fail-closed errors: " + "; ".join(fail_closed_errors)
                if fail_closed_errors
                else ""
            )
            print(
                "openstack_guest_endpoint_agent: state publication failed: "
                f"{error}{detail}",
                file=sys.stderr,
            )
            return False
        return True

    def _stop(self) -> int:
        try:
            stop_barrier = self.agent.prepare_stop()
        except Exception as error:
            self.agent.state = "degraded"
            self.agent.reason = f"stop_barrier_failed:{error}"
            self.agent.fail_closed_cleanup(preserve_pins=True)
            self._publish()
            return 1
        if not self._publish(stop_barrier):
            self.agent.state = "degraded"
            self.agent.reason = "stop_barrier_publication_failed"
            self.agent.fail_closed_cleanup(preserve_pins=True)
            self._publish()
            return 1
        stopped = self.agent.finish_stop()
        published = self._publish()
        return 0 if stopped and published else 1

    def run(self) -> int:
        try:
            barrier_report = self.agent.start(hold_quiesce=True)
            if not self._publish(barrier_report):
                raise GuestEndpointError(
                    "startup barrier publication failed"
                )
            if self.stop_event.is_set():
                return self._stop()
            report = self.agent.activate()
        except Exception as error:
            if self.agent.state != "degraded":
                self.agent.state = "degraded"
                self.agent.reason = f"startup_failed:{error}"
            self.agent.fail_closed_cleanup(preserve_pins=True)
            self._publish()
            return 1
        if self.stop_event.is_set():
            return self._stop()
        if not self._publish(report):
            self.agent.state = "degraded"
            self.agent.reason = "state_publication_failed"
            self.agent.fail_closed_cleanup(preserve_pins=True)
            self._publish()
            return 1

        while not self.stop_event.wait(self.interval):
            try:
                report = self.agent.inspect()
            except Exception as error:
                self.agent.state = "degraded"
                self.agent.reason = f"health_inspection_failed:{error}"
                self.agent.fail_closed_cleanup(preserve_pins=True)
                self._publish()
                return 1
            if not report.healthy:
                self.agent.state = "degraded"
                self.agent.reason = f"health_failed:{report.reason}"
                self.agent.fail_closed_cleanup(preserve_pins=True)
                report = self.agent._best_effort_report()
                self._publish(report)
                return 1
            if not self._publish(report):
                self.agent.state = "degraded"
                self.agent.reason = "state_publication_failed"
                self.agent.fail_closed_cleanup(preserve_pins=True)
                self._publish()
                return 1
        return self._stop()


def _add_tool_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--dns-monitor", required=True, type=Path)
    parser.add_argument("--dns-server-bpf", required=True, type=Path)
    parser.add_argument("--grpc-fast-cache", required=True, type=Path)
    parser.add_argument("--cache-policy-txn", required=True, type=Path)
    parser.add_argument(
        "--bpftool", type=Path, default=Path("/usr/sbin/bpftool")
    )
    parser.add_argument("--ip", type=Path, default=Path("/usr/sbin/ip"))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    run = subparsers.add_parser("run", help="supervise this guest endpoint")
    run.add_argument("--config", required=True, type=Path)
    _add_tool_args(run)
    run.add_argument(
        "--pin-root",
        type=Path,
        default=PRODUCTION_PIN_ROOT,
    )
    run.add_argument(
        "--lock-root", type=Path, default=POLICY_LOCK_ROOT
    )
    run.add_argument(
        "--log-root",
        type=Path,
        default=Path("/var/log/vnet-dataplane-guest"),
    )
    run.add_argument(
        "--state-file",
        type=Path,
        default=Path("/run/vnet-dataplane-guest/state.json"),
    )
    run.add_argument("--interval", type=float, default=2.0)
    run.add_argument(
        "--shutdown-timeout-seconds",
        type=float,
        default=DEFAULT_SHUTDOWN_TIMEOUT_SECONDS,
    )

    health = subparsers.add_parser("health", help="check a fresh state snapshot")
    health.add_argument("--config", required=True, type=Path)
    health.add_argument(
        "--state-file",
        type=Path,
        default=Path("/run/vnet-dataplane-guest/state.json"),
    )
    health.add_argument(
        "--pin-root", type=Path, default=PRODUCTION_PIN_ROOT
    )
    health.add_argument("--max-age-seconds", type=float, default=10.0)
    return parser


def _run(args: argparse.Namespace) -> int:
    config = load_endpoint_config(args.config)
    if args.pin_root != PRODUCTION_PIN_ROOT:
        raise GuestEndpointError(
            "production pin root must be /sys/fs/bpf/vnet-dataplane-guest"
        )
    if args.lock_root != POLICY_LOCK_ROOT:
        raise GuestEndpointError(
            "production lock root must be /run/vnet-dataplane-policy"
        )
    if (
        isinstance(args.shutdown_timeout_seconds, bool)
        or not isinstance(args.shutdown_timeout_seconds, (int, float))
        or not math.isfinite(args.shutdown_timeout_seconds)
        or args.shutdown_timeout_seconds <= 0
    ):
        raise GuestEndpointError("shutdown timeout seconds must be positive")
    tools = ToolPaths(
        dns_monitor=args.dns_monitor,
        dns_server_bpf=args.dns_server_bpf,
        grpc_fast_cache=args.grpc_fast_cache,
        cache_policy_txn=args.cache_policy_txn,
        bpftool=args.bpftool,
        ip=args.ip,
    )
    paths = EndpointPaths(
        port_id=config.port_id,
        pin_root=args.pin_root,
        lock_root=args.lock_root,
        log_root=args.log_root,
    )
    driver = SystemEndpointDriver(config, tools, paths)
    agent = GuestEndpointAgent(config, tools, paths, driver)
    supervisor = GuestEndpointSupervisor(agent, args.state_file, args.interval)
    def request_stop(signum: int, frame: Any) -> None:
        if not supervisor.stop_event.is_set():
            driver.begin_shutdown(
                time.monotonic() + args.shutdown_timeout_seconds
            )
            supervisor.request_stop(signum, frame)

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    return supervisor.run()


def _health(args: argparse.Namespace) -> int:
    if args.max_age_seconds <= 0:
        raise GuestEndpointError("max-age-seconds must be positive")
    config = load_endpoint_config(args.config)
    try:
        state = json.loads(args.state_file.read_text(encoding="utf-8"))
    except FileNotFoundError:
        state = None
    except json.JSONDecodeError as error:
        raise GuestEndpointError(f"state is not valid JSON: {error}") from error
    result = evaluate_state_health(
        state,
        config,
        args.max_age_seconds,
        pin_root=args.pin_root,
    )
    print(json.dumps(result, sort_keys=True))
    return 0 if result["ready"] else 2


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "run":
            return _run(args)
        return _health(args)
    except (GuestEndpointError, OSError, subprocess.SubprocessError) as error:
        print(f"openstack_guest_endpoint_agent: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
