#!/usr/bin/env python3
"""Feed production DNS/gRPC snapshots to dynamic_cache_controller."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import math
import os
import queue
import re
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Any, Callable, Mapping, Sequence


SCHEMA_VERSION = 1
SNAPSHOT_SCHEMA_VERSION = 1
MAX_SNAPSHOT_BYTES = 8 * 1024 * 1024
SNAPSHOT_LOG_ROOTS = (
    PurePosixPath("/var/log/vnet-dataplane-agent"),
    PurePosixPath("/var/log/vnet-dataplane-guest"),
)
METRIC_KINDS = frozenset({"dns_metrics", "grpc_metrics", "grpc_fast_cache"})
METRIC_ROLES = frozenset({"client", "server"})
DESIRED_MODES = frozenset({"bypass", "server", "client", "dual"})
_DECISION_MODES = {
    "BYPASS": "bypass",
    "SERVER_CACHE": "server",
    "CLIENT_CACHE": "client",
    "DUAL_CACHE": "dual",
}
_SOURCE_KEYS = frozenset(
    {"name", "kind", "role", "path", "command", "error_authoritative"}
)
_CONFIG_KEYS = frozenset(
    {
        "schema_version",
        "desired_mode_file",
        "controller_mode_file",
        "controller_command",
        "sources",
        "poll_interval_seconds",
        "source_timeout_seconds",
        "decision_timeout_seconds",
        "stop_timeout_seconds",
        "max_snapshot_age_seconds",
        "max_future_skew_seconds",
        "max_snapshot_bytes",
    }
)
_SOURCE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
_METRIC_PREFIX_RE = {
    kind: re.compile(rf"(?<!\S)({re.escape(kind)})\s+") for kind in METRIC_KINDS
}


class BridgeError(RuntimeError):
    """Base error for fail-safe bridge failures."""


class ConfigError(BridgeError):
    """Raised for an invalid bridge configuration."""


class SnapshotError(BridgeError):
    """Raised when a source snapshot cannot be read safely."""


class MetricParseError(BridgeError):
    """Raised when a selected metric line is invalid."""


class ControllerError(BridgeError):
    """Raised when the owned controller process violates its protocol."""


@dataclass(frozen=True)
class SourceConfig:
    name: str
    kind: str
    role: str
    path: Path | None = None
    command: tuple[str, ...] | None = None
    error_authoritative: bool = True

    @property
    def group(self) -> tuple[str, str]:
        return self.kind, self.role


@dataclass(frozen=True)
class BridgeConfig:
    desired_mode_file: Path
    controller_mode_file: Path
    controller_command: tuple[str, ...]
    sources: tuple[SourceConfig, ...]
    poll_interval_seconds: float = 1.0
    source_timeout_seconds: float = 3.0
    decision_timeout_seconds: float = 3.0
    stop_timeout_seconds: float = 5.0
    max_snapshot_age_seconds: float = 5.0
    max_future_skew_seconds: float = 2.0
    max_snapshot_bytes: int = 256 * 1024


@dataclass(frozen=True)
class LogSnapshot:
    source_name: str
    path: str
    mtime_ns: int
    size: int
    generation: str
    tail: str


@dataclass(frozen=True)
class ParsedMetric:
    source_name: str
    kind: str
    role: str
    mtime_ns: int
    generation: str
    fields: Mapping[str, int | float | str]
    error_authoritative: bool = True


@dataclass(frozen=True)
class MetricSample:
    timestamp_ms: int
    dns_hits: int
    dns_misses: int
    dns_p95_us: float
    grpc_hits: int
    grpc_misses: int
    grpc_p95_us: float
    backend_qps: float
    error_rate: float

    def to_csv(self) -> str:
        fields = (
            str(self.timestamp_ms),
            str(self.dns_hits),
            str(self.dns_misses),
            _format_float(self.dns_p95_us),
            str(self.grpc_hits),
            str(self.grpc_misses),
            _format_float(self.grpc_p95_us),
            _format_float(self.backend_qps),
            _format_float(self.error_rate),
        )
        if len(fields) != 9:
            raise AssertionError("controller sample must contain exactly 9 columns")
        return ",".join(fields)


@dataclass(frozen=True)
class ControllerDecision:
    timestamp_ms: int
    mode: str


@dataclass
class PreparedWindow:
    sample: MetricSample
    signature: tuple[tuple[str, str, str, str], ...]
    counter_updates: dict[tuple[str, str], int]
    _owner: "MetricsCollector"
    _committed: bool = False

    def commit(self) -> None:
        if self._committed:
            raise BridgeError("metrics window was committed more than once")
        self._owner._commit(self)
        self._committed = True


def _format_float(value: float) -> str:
    if not math.isfinite(value) or value < 0:
        raise BridgeError("metric values must be finite and non-negative")
    return f"{value:.6f}"


def _is_number(value: Any) -> bool:
    return not isinstance(value, bool) and isinstance(value, (int, float))


def _positive_float(value: Any, field: str) -> float:
    if not _is_number(value):
        raise ConfigError(f"{field} must be a number")
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise ConfigError(f"{field} must be finite and positive")
    return parsed


def _nonnegative_float(value: Any, field: str) -> float:
    if not _is_number(value):
        raise ConfigError(f"{field} must be a number")
    parsed = float(value)
    if not math.isfinite(parsed) or parsed < 0:
        raise ConfigError(f"{field} must be finite and non-negative")
    return parsed


def _absolute_path(value: Any, field: str) -> Path:
    if not isinstance(value, str) or not value:
        raise ConfigError(f"{field} must be a non-empty absolute path")
    if not _is_absolute_path_text(value):
        raise ConfigError(f"{field} must be an absolute path")
    return Path(value)


def _command(value: Any, field: str) -> tuple[str, ...]:
    if (
        not isinstance(value, list)
        or not value
        or any(not isinstance(item, str) or not item for item in value)
    ):
        raise ConfigError(f"{field} must be a non-empty argv string array")
    return tuple(value)


def _reject_unknown_keys(
    value: Mapping[str, Any], allowed: frozenset[str], field: str
) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise ConfigError(f"{field} has unknown fields: {', '.join(unknown)}")


def _same_path(left: str | Path, right: str | Path) -> bool:
    return os.path.normcase(os.path.abspath(os.fspath(left))) == os.path.normcase(
        os.path.abspath(os.fspath(right))
    )


def _validate_controller_command(
    command: tuple[str, ...],
    controller_mode_file: Path,
    desired_mode_file: Path,
) -> None:
    executable = Path(command[0])
    executable_name = PurePosixPath(command[0]).name
    if PureWindowsPath(command[0]).name == "dynamic_cache_controller":
        executable_name = PureWindowsPath(command[0]).name
    if (
        not _is_absolute_path_text(command[0])
        or executable_name != "dynamic_cache_controller"
    ):
        raise ConfigError(
            "controller_command[0] must directly name an absolute "
            "dynamic_cache_controller executable"
        )
    forbidden = {"--control-map", "--dry-run", "--metrics-file"}
    present = forbidden.intersection(command)
    if present:
        raise ConfigError(
            "controller_command contains bridge-incompatible options: "
            + ", ".join(sorted(present))
        )
    if _same_path(controller_mode_file, desired_mode_file):
        raise ConfigError(
            "controller_mode_file must differ from authoritative "
            "desired_mode_file"
        )
    desired_indexes = [
        index for index, item in enumerate(command) if item == "--desired-mode-file"
    ]
    if len(desired_indexes) != 1:
        raise ConfigError(
            "controller_command must contain exactly one --desired-mode-file"
        )
    desired_index = desired_indexes[0]
    if desired_index + 1 >= len(command) or not _same_path(
        command[desired_index + 1], controller_mode_file
    ):
        raise ConfigError(
            "controller --desired-mode-file must match controller_mode_file"
        )
    initial_indexes = [
        index for index, item in enumerate(command) if item == "--initial-mode"
    ]
    if len(initial_indexes) > 1:
        raise ConfigError("controller_command repeats --initial-mode")
    if initial_indexes:
        index = initial_indexes[0]
        if index + 1 >= len(command) or command[index + 1].lower() != "bypass":
            raise ConfigError("controller initial mode must be bypass")


def _validate_source_groups(sources: Sequence[SourceConfig]) -> None:
    groups = {source.group for source in sources}
    required = {
        ("dns_metrics", "client"),
        ("dns_metrics", "server"),
        ("grpc_fast_cache", "client"),
        ("grpc_fast_cache", "server"),
    }
    missing = sorted(required - groups)
    if missing:
        detail = ", ".join(f"{kind}/{role}" for kind, role in missing)
        raise ConfigError(f"sources are missing required groups: {detail}")
    if not any(kind == "grpc_metrics" for kind, _role in groups):
        raise ConfigError("sources require at least one grpc_metrics group")


def load_config(path: Path) -> BridgeConfig:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ConfigError(f"cannot read config {path}: {error}") from error
    if not isinstance(value, dict):
        raise ConfigError("config must be a JSON object")
    _reject_unknown_keys(value, _CONFIG_KEYS, "config")
    if value.get("schema_version") != SCHEMA_VERSION:
        raise ConfigError(f"config schema_version must be {SCHEMA_VERSION}")

    desired_mode_file = _absolute_path(
        value.get("desired_mode_file"), "desired_mode_file"
    )
    controller_mode_file = _absolute_path(
        value.get("controller_mode_file"), "controller_mode_file"
    )
    controller_command = _command(
        value.get("controller_command"), "controller_command"
    )
    _validate_controller_command(
        controller_command, controller_mode_file, desired_mode_file
    )

    raw_sources = value.get("sources")
    if not isinstance(raw_sources, list) or not raw_sources:
        raise ConfigError("sources must be a non-empty array")
    sources: list[SourceConfig] = []
    names: set[str] = set()
    for index, raw_source in enumerate(raw_sources):
        field = f"sources[{index}]"
        if not isinstance(raw_source, dict):
            raise ConfigError(f"{field} must be an object")
        _reject_unknown_keys(raw_source, _SOURCE_KEYS, field)
        name = raw_source.get("name")
        kind = raw_source.get("kind")
        role = raw_source.get("role")
        if not isinstance(name, str) or not _SOURCE_NAME_RE.fullmatch(name):
            raise ConfigError(f"{field}.name is invalid")
        if name in names:
            raise ConfigError(f"duplicate source name: {name}")
        names.add(name)
        if kind not in METRIC_KINDS:
            raise ConfigError(f"{field}.kind is unsupported")
        if role not in METRIC_ROLES:
            raise ConfigError(f"{field}.role is unsupported")
        has_path = "path" in raw_source
        has_command = "command" in raw_source
        if has_path == has_command:
            raise ConfigError(f"{field} must contain exactly one of path or command")
        source_path = (
            _absolute_path(raw_source["path"], f"{field}.path") if has_path else None
        )
        source_command = (
            _command(raw_source["command"], f"{field}.command")
            if has_command
            else None
        )
        error_authoritative = raw_source.get("error_authoritative", True)
        if not isinstance(error_authoritative, bool):
            raise ConfigError(f"{field}.error_authoritative must be a boolean")
        if source_command is not None and not _is_absolute_path_text(
            source_command[0]
        ):
            raise ConfigError(f"{field}.command[0] must be an absolute executable")
        sources.append(
            SourceConfig(
                name=name,
                kind=kind,
                role=role,
                path=source_path,
                command=source_command,
                error_authoritative=error_authoritative,
            )
        )
    _validate_source_groups(sources)

    max_snapshot_bytes = value.get("max_snapshot_bytes", 256 * 1024)
    if (
        isinstance(max_snapshot_bytes, bool)
        or not isinstance(max_snapshot_bytes, int)
        or max_snapshot_bytes <= 0
        or max_snapshot_bytes > MAX_SNAPSHOT_BYTES
    ):
        raise ConfigError(
            f"max_snapshot_bytes must be in [1, {MAX_SNAPSHOT_BYTES}]"
        )
    return BridgeConfig(
        desired_mode_file=desired_mode_file,
        controller_mode_file=controller_mode_file,
        controller_command=controller_command,
        sources=tuple(sources),
        poll_interval_seconds=_positive_float(
            value.get("poll_interval_seconds", 1.0), "poll_interval_seconds"
        ),
        source_timeout_seconds=_positive_float(
            value.get("source_timeout_seconds", 3.0), "source_timeout_seconds"
        ),
        decision_timeout_seconds=_positive_float(
            value.get("decision_timeout_seconds", 3.0),
            "decision_timeout_seconds",
        ),
        stop_timeout_seconds=_positive_float(
            value.get("stop_timeout_seconds", 5.0), "stop_timeout_seconds"
        ),
        max_snapshot_age_seconds=_positive_float(
            value.get("max_snapshot_age_seconds", 5.0),
            "max_snapshot_age_seconds",
        ),
        max_future_skew_seconds=_nonnegative_float(
            value.get("max_future_skew_seconds", 2.0),
            "max_future_skew_seconds",
        ),
        max_snapshot_bytes=max_snapshot_bytes,
    )


def preflight_config(config: BridgeConfig) -> None:
    executable = Path(config.controller_command[0])
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ConfigError(f"controller is not executable: {executable}")
    for label, path in (
        ("desired mode", config.desired_mode_file),
        ("controller mode", config.controller_mode_file),
    ):
        parent = path.parent
        if not parent.is_dir():
            raise ConfigError(f"{label} parent does not exist: {parent}")


def _is_absolute_path_text(value: str) -> bool:
    return PurePosixPath(value).is_absolute() or PureWindowsPath(value).is_absolute()


def _snapshot_log_root(path: Path, allowed_roots: Sequence[Path]) -> Path:
    if not path.is_absolute():
        raise SnapshotError("snapshot-log path must be absolute")
    if ".." in path.parts:
        raise SnapshotError(f"snapshot-log path is outside allowed log roots: {path}")
    for root in allowed_roots:
        candidate = Path(root)
        if not _is_absolute_path_text(str(root)):
            raise SnapshotError(f"snapshot-log root must be absolute: {candidate}")
        try:
            relative = path.relative_to(candidate)
        except ValueError:
            continue
        if relative.parts:
            return candidate
    raise SnapshotError(f"snapshot-log path is outside allowed log roots: {path}")


def _reject_snapshot_symlinks(path: Path, root: Path) -> None:
    relative = path.relative_to(root)
    current = root
    components = (None, *relative.parts)
    for component in components:
        if component is not None:
            current /= component
        try:
            metadata = os.lstat(current)
        except OSError as error:
            raise SnapshotError(f"cannot stat snapshot path {current}: {error}") from error
        if stat.S_ISLNK(metadata.st_mode):
            raise SnapshotError(
                f"snapshot-log path must not contain a symlink: {current}"
            )


def read_log_snapshot(
    path: Path,
    max_bytes: int,
    *,
    allowed_roots: Sequence[Path] = SNAPSHOT_LOG_ROOTS,
) -> LogSnapshot:
    root = _snapshot_log_root(path, allowed_roots)
    _reject_snapshot_symlinks(path, root)
    try:
        preliminary = os.lstat(path)
    except OSError as error:
        raise SnapshotError(f"cannot stat snapshot path {path}: {error}") from error
    if not stat.S_ISREG(preliminary.st_mode):
        raise SnapshotError(f"snapshot-log path is not a regular file: {path}")
    if max_bytes <= 0 or max_bytes > MAX_SNAPSHOT_BYTES:
        raise SnapshotError(
            f"snapshot-log max bytes must be in [1, {MAX_SNAPSHOT_BYTES}]"
        )
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    fd = -1
    try:
        fd = os.open(path, flags)
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode):
            raise SnapshotError(f"snapshot-log path is not a regular file: {path}")
        size = metadata.st_size
        offset = max(0, size - max_bytes)
        os.lseek(fd, offset, os.SEEK_SET)
        remaining = min(size, max_bytes)
        chunks: list[bytes] = []
        while remaining:
            chunk = os.read(fd, min(remaining, 64 * 1024))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
    except OSError as error:
        raise SnapshotError(f"cannot read snapshot path {path}: {error}") from error
    finally:
        if fd >= 0:
            os.close(fd)
    if offset:
        newline = data.find(b"\n")
        data = b"" if newline < 0 else data[newline + 1 :]
    try:
        tail = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SnapshotError(f"snapshot path is not valid UTF-8: {path}") from error
    mtime_ns = metadata.st_mtime_ns
    generation = f"{mtime_ns}:{size}"
    return LogSnapshot("", str(path), mtime_ns, size, generation, tail)


def snapshot_payload(snapshot: LogSnapshot) -> dict[str, Any]:
    return {
        "schema_version": SNAPSHOT_SCHEMA_VERSION,
        "path": snapshot.path,
        "mtime_ns": snapshot.mtime_ns,
        "size": snapshot.size,
        "generation": snapshot.generation,
        "tail": snapshot.tail,
    }


def parse_snapshot_payload(text: str, source_name: str) -> LogSnapshot:
    try:
        value = json.loads(text)
    except json.JSONDecodeError as error:
        raise SnapshotError(
            f"source {source_name} returned invalid snapshot JSON"
        ) from error
    expected = {
        "schema_version",
        "path",
        "mtime_ns",
        "size",
        "generation",
        "tail",
    }
    if not isinstance(value, dict) or set(value) != expected:
        raise SnapshotError(f"source {source_name} returned invalid snapshot schema")
    if value.get("schema_version") != SNAPSHOT_SCHEMA_VERSION:
        raise SnapshotError(
            f"source {source_name} returned unsupported snapshot schema"
        )
    path = value.get("path")
    mtime_ns = value.get("mtime_ns")
    size = value.get("size")
    generation = value.get("generation")
    tail = value.get("tail")
    if not isinstance(path, str) or not _is_absolute_path_text(path):
        raise SnapshotError(f"source {source_name} returned an invalid path")
    if (
        isinstance(mtime_ns, bool)
        or not isinstance(mtime_ns, int)
        or mtime_ns < 0
        or isinstance(size, bool)
        or not isinstance(size, int)
        or size < 0
        or not isinstance(tail, str)
    ):
        raise SnapshotError(f"source {source_name} returned invalid metadata")
    expected_generation = f"{mtime_ns}:{size}"
    if generation != expected_generation:
        raise SnapshotError(f"source {source_name} returned invalid generation")
    return LogSnapshot(source_name, path, mtime_ns, size, generation, tail)


class SnapshotReader:
    def __init__(
        self,
        timeout_seconds: float,
        max_bytes: int,
        run_command: Callable[..., subprocess.CompletedProcess[Any]] = subprocess.run,
    ):
        self._timeout_seconds = timeout_seconds
        self._max_bytes = max_bytes
        self._run_command = run_command

    def read(self, source: SourceConfig) -> LogSnapshot:
        if source.path is not None:
            snapshot = read_log_snapshot(source.path, self._max_bytes)
            return LogSnapshot(
                source.name,
                snapshot.path,
                snapshot.mtime_ns,
                snapshot.size,
                snapshot.generation,
                snapshot.tail,
            )
        if source.command is None:
            raise AssertionError("validated source has neither path nor command")
        try:
            result = self._run_command(
                list(source.command),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=self._timeout_seconds,
                check=False,
                shell=False,
            )
        except subprocess.TimeoutExpired as error:
            raise SnapshotError(
                f"source {source.name} command timed out after "
                f"{self._timeout_seconds:.3f}s"
            ) from error
        except OSError as error:
            raise SnapshotError(
                f"source {source.name} command could not start: {error}"
            ) from error
        stdout = result.stdout
        stderr = result.stderr
        if isinstance(stdout, str):
            encoded = stdout.encode("utf-8")
            output = stdout
        else:
            encoded = bytes(stdout or b"")
            try:
                output = encoded.decode("utf-8")
            except UnicodeDecodeError as error:
                raise SnapshotError(
                    f"source {source.name} command output is not UTF-8"
                ) from error
        if result.returncode != 0:
            if isinstance(stderr, bytes):
                detail = stderr.decode("utf-8", errors="replace")
            else:
                detail = str(stderr or "")
            raise SnapshotError(
                f"source {source.name} command failed ({result.returncode}): "
                f"{detail.strip()[:300]}"
            )
        if len(encoded) > self._max_bytes * 6 + 4096:
            raise SnapshotError(f"source {source.name} snapshot JSON is too large")
        snapshot = parse_snapshot_payload(output, source.name)
        if len(snapshot.tail.encode("utf-8")) > self._max_bytes:
            raise SnapshotError(f"source {source.name} snapshot tail is too large")
        return snapshot


def _parse_uint(fields: Mapping[str, str], key: str, source: str) -> int:
    value = fields.get(key)
    if value is None or not re.fullmatch(r"[0-9]+", value):
        raise MetricParseError(f"{source} has invalid {key}")
    return int(value)


def _parse_latency_us(fields: Mapping[str, str], key: str, source: str) -> float:
    value = fields.get(key)
    if value is None:
        raise MetricParseError(f"{source} is missing {key}")
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)(us|ms)", value)
    if match is None:
        raise MetricParseError(f"{source} has invalid {key}")
    parsed = float(match.group(1))
    return parsed if match.group(2) == "us" else parsed * 1000.0


def _key_values(payload: str, source: str) -> dict[str, str]:
    tokens = payload.split()
    if len(tokens) < 2:
        raise MetricParseError(f"{source} metric line has no fields")
    fields: dict[str, str] = {}
    for token in tokens[1:]:
        if token.count("=") != 1:
            raise MetricParseError(f"{source} has malformed token: {token}")
        key, value = token.split("=", 1)
        if not key or not value or key in fields:
            raise MetricParseError(f"{source} has invalid or duplicate field: {key}")
        fields[key] = value
    return fields


def parse_metric_line(
    line: str, kind: str, role: str, source_name: str = "metric"
) -> Mapping[str, int | float | str]:
    if kind not in METRIC_KINDS or role not in METRIC_ROLES:
        raise MetricParseError("unsupported metric kind or role")
    match = _METRIC_PREFIX_RE[kind].search(line)
    if match is None:
        raise MetricParseError(f"{source_name} has no {kind} payload")
    payload = line[match.start(1) :].strip()
    fields = _key_values(payload, source_name)
    parsed: dict[str, int | float | str] = {}
    if kind == "dns_metrics":
        if fields.get("role") != role:
            raise MetricParseError(f"{source_name} DNS role does not match config")
        for key in (
            "qps",
            "rps",
            "timeout",
            "unmatched",
            "ringbuf_drop",
            "cache_hit",
            "cache_miss",
            "shadow_hit",
            "shadow_miss",
        ):
            parsed[key] = _parse_uint(fields, key, source_name)
        parsed["p95_us"] = _parse_latency_us(fields, "p95", source_name)
    elif kind == "grpc_metrics":
        for key in ("reqps", "resps", "timeout", "unmatched", "ringbuf_drop"):
            parsed[key] = _parse_uint(fields, key, source_name)
        parsed["p95_us"] = _parse_latency_us(fields, "p95", source_name)
    else:
        if fields.get("cache_role") != role:
            raise MetricParseError(
                f"{source_name} gRPC cache role does not match config"
            )
        for key in (
            "accepted",
            "policy_miss",
            "response_cache_miss",
            "cache_hit",
            "shadow_hit",
            "shadow_miss",
            "fallback",
            "parse_error",
            "fallback_error",
            "tx_error",
        ):
            parsed[key] = _parse_uint(fields, key, source_name)
    return parsed


def parse_metric_snapshot(snapshot: LogSnapshot, source: SourceConfig) -> ParsedMetric:
    matching: list[str] = []
    pattern = _METRIC_PREFIX_RE[source.kind]
    for line in snapshot.tail.splitlines():
        if pattern.search(line):
            matching.append(line)
    if not matching:
        raise MetricParseError(
            f"source {source.name} has no {source.kind} line in bounded tail"
        )
    fields = parse_metric_line(matching[-1], source.kind, source.role, source.name)
    return ParsedMetric(
        source_name=source.name,
        kind=source.kind,
        role=source.role,
        mtime_ns=snapshot.mtime_ns,
        generation=snapshot.generation,
        fields=fields,
        error_authoritative=source.error_authoritative,
    )


class MetricsCollector:
    def __init__(
        self,
        config: BridgeConfig,
        snapshot_reader: SnapshotReader | None = None,
    ):
        self._config = config
        self._reader = snapshot_reader or SnapshotReader(
            config.source_timeout_seconds, config.max_snapshot_bytes
        )
        self._counter_baselines: dict[tuple[str, str], int] = {}
        self._last_signature: tuple[tuple[str, str, str, str], ...] | None = None

    def reset(self) -> None:
        self._counter_baselines.clear()
        self._last_signature = None

    def _read_all(self) -> tuple[dict[str, LogSnapshot], dict[str, str]]:
        snapshots: dict[str, LogSnapshot] = {}
        errors: dict[str, str] = {}
        workers = min(len(self._config.sources), 32)
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
            pending = {
                executor.submit(self._reader.read, source): source
                for source in self._config.sources
            }
            for future in concurrent.futures.as_completed(pending):
                source = pending[future]
                try:
                    snapshots[source.name] = future.result()
                except (SnapshotError, OSError) as error:
                    errors[source.name] = str(error)
        return snapshots, errors

    def _select(self, now_ns: int) -> list[ParsedMetric]:
        snapshots, errors = self._read_all()
        by_group: dict[tuple[str, str], list[SourceConfig]] = {}
        for source in self._config.sources:
            by_group.setdefault(source.group, []).append(source)
        selected: list[ParsedMetric] = []
        max_age_ns = int(self._config.max_snapshot_age_seconds * 1_000_000_000)
        max_future_ns = int(self._config.max_future_skew_seconds * 1_000_000_000)
        for group, sources in sorted(by_group.items()):
            fresh: list[tuple[LogSnapshot, SourceConfig]] = []
            diagnostics: list[str] = []
            for source in sources:
                snapshot = snapshots.get(source.name)
                if snapshot is None:
                    diagnostics.append(
                        f"{source.name}:{errors.get(source.name, 'missing snapshot')}"
                    )
                    continue
                age_ns = now_ns - snapshot.mtime_ns
                if age_ns > max_age_ns:
                    diagnostics.append(f"{source.name}:stale")
                    continue
                if age_ns < -max_future_ns:
                    diagnostics.append(f"{source.name}:future timestamp")
                    continue
                fresh.append((snapshot, source))
            if not fresh:
                kind, role = group
                detail = "; ".join(diagnostics)
                raise SnapshotError(
                    f"no fresh source for {kind}/{role}"
                    + (f": {detail}" if detail else "")
                )
            snapshot, source = max(
                fresh,
                key=lambda item: (
                    item[0].mtime_ns,
                    item[0].size,
                    item[1].name,
                ),
            )
            selected.append(parse_metric_snapshot(snapshot, source))
        return selected

    def _delta(
        self,
        metric: ParsedMetric,
        field: str,
        updates: dict[tuple[str, str], int],
    ) -> int:
        current = int(metric.fields[field])
        key = (metric.source_name, field)
        previous = self._counter_baselines.get(key)
        updates[key] = current
        if previous is None:
            return 0
        return current - previous if current >= previous else current

    def prepare(
        self, now_ns: int, elapsed_seconds: float
    ) -> PreparedWindow | None:
        if not math.isfinite(elapsed_seconds) or elapsed_seconds <= 0:
            raise BridgeError("window duration must be finite and positive")
        metrics = self._select(now_ns)
        signature = tuple(
            sorted(
                (
                    metric.kind,
                    metric.role,
                    metric.source_name,
                    metric.generation,
                )
                for metric in metrics
            )
        )
        if self._last_signature is not None:
            previous = {
                (kind, role): (source_name, generation)
                for kind, role, source_name, generation in self._last_signature
            }
            current = {
                (kind, role): (source_name, generation)
                for kind, role, source_name, generation in signature
            }
            # A window is consumable only after every selected metric group
            # advances. This prevents an asynchronous source from causing the
            # other groups' per-window counters to be fed more than once.
            if any(current[group] == previous.get(group) for group in current):
                return None

        by_group = {(metric.kind, metric.role): metric for metric in metrics}
        dns_client = by_group[("dns_metrics", "client")]
        dns_server = by_group[("dns_metrics", "server")]
        grpc_client = by_group[("grpc_fast_cache", "client")]
        grpc_server = by_group[("grpc_fast_cache", "server")]
        updates: dict[tuple[str, str], int] = {}

        dns_hits = int(dns_client.fields["cache_hit"]) + int(
            dns_client.fields["shadow_hit"]
        )
        dns_misses = int(dns_client.fields["cache_miss"]) + int(
            dns_client.fields["shadow_miss"]
        )
        grpc_hits = self._delta(grpc_client, "cache_hit", updates) + self._delta(
            grpc_client, "shadow_hit", updates
        )
        grpc_misses = (
            self._delta(grpc_client, "policy_miss", updates)
            + self._delta(grpc_client, "response_cache_miss", updates)
            + self._delta(grpc_client, "shadow_miss", updates)
        )
        server_dns_misses = int(dns_server.fields["cache_miss"]) + int(
            dns_server.fields["shadow_miss"]
        )
        server_grpc_fallback = self._delta(grpc_server, "fallback", updates)

        error_count = 0
        request_count = 0
        dns_p95_us = 0.0
        grpc_p95_us = 0.0
        for metric in metrics:
            if metric.kind == "dns_metrics":
                if metric.error_authoritative:
                    request_count += int(metric.fields["qps"])
                    error_count += (
                        int(metric.fields["timeout"])
                        + int(metric.fields["unmatched"])
                        + int(metric.fields["ringbuf_drop"])
                    )
                dns_p95_us = max(dns_p95_us, float(metric.fields["p95_us"]))
            elif metric.kind == "grpc_metrics":
                if metric.error_authoritative:
                    request_count += int(metric.fields["reqps"])
                    error_count += (
                        int(metric.fields["timeout"])
                        + int(metric.fields["unmatched"])
                        + int(metric.fields["ringbuf_drop"])
                    )
                grpc_p95_us = max(grpc_p95_us, float(metric.fields["p95_us"]))
            else:
                accepted = self._delta(metric, "accepted", updates)
                parse_errors = self._delta(metric, "parse_error", updates)
                fallback_errors = self._delta(
                    metric, "fallback_error", updates
                )
                # A connection can close after the HTTP/2 preface or a
                # partial frame. grpc_fast_cache records that as both
                # parse_error and fallback_error, but it is not a backend
                # failure when no complete request existed to forward.
                if metric.error_authoritative:
                    request_count += accepted
                    error_count += max(0, fallback_errors - parse_errors)
                    error_count += self._delta(metric, "tx_error", updates)
        if request_count:
            error_rate = error_count / request_count
        else:
            error_rate = 1.0 if error_count else 0.0
        error_rate = min(1.0, max(0.0, error_rate))

        sample = MetricSample(
            timestamp_ms=now_ns // 1_000_000,
            dns_hits=dns_hits,
            dns_misses=dns_misses,
            dns_p95_us=dns_p95_us,
            grpc_hits=grpc_hits,
            grpc_misses=grpc_misses,
            grpc_p95_us=grpc_p95_us,
            backend_qps=(
                server_dns_misses + server_grpc_fallback
            )
            / elapsed_seconds,
            error_rate=error_rate,
        )
        return PreparedWindow(sample, signature, updates, self)

    def _commit(self, prepared: PreparedWindow) -> None:
        if prepared.signature == self._last_signature:
            raise BridgeError("metrics generation was already consumed")
        self._counter_baselines.update(prepared.counter_updates)
        self._last_signature = prepared.signature


def _atomic_replace_json(path: Path, value: Mapping[str, Any]) -> None:
    if not path.is_absolute():
        raise BridgeError("mode path must be absolute")
    parent = path.parent
    if not parent.is_dir():
        raise BridgeError(f"mode parent does not exist: {parent}")
    payload = (
        json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")
    fd = -1
    temporary_path: str | None = None
    try:
        fd, temporary_path = tempfile.mkstemp(
            prefix=f".{path.name}.", suffix=".tmp", dir=parent
        )
        if hasattr(os, "fchmod"):
            os.fchmod(fd, 0o644)
        elif temporary_path is not None:
            os.chmod(temporary_path, 0o644)
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                raise OSError("desired mode write made no progress")
            offset += written
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(temporary_path, path)
        temporary_path = None
        if os.name == "posix":
            directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
            directory_fd = os.open(parent, directory_flags)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    finally:
        if fd >= 0:
            os.close(fd)
        if temporary_path is not None:
            try:
                os.unlink(temporary_path)
            except FileNotFoundError:
                pass


def _atomic_write_mode(path: Path, mode: str, updated_ms: int) -> None:
    if mode not in DESIRED_MODES:
        raise BridgeError(f"unsupported desired mode: {mode}")
    if (
        isinstance(updated_ms, bool)
        or not isinstance(updated_ms, int)
        or updated_ms < 0
    ):
        raise BridgeError("updated_ms must be a non-negative integer")
    _atomic_replace_json(
        path,
        {
            "schema_version": SCHEMA_VERSION,
            "mode": mode,
            "updated_ms": updated_ms,
        },
    )


def _atomic_write_controller_mode(path: Path, mode: str) -> None:
    if mode not in DESIRED_MODES:
        raise BridgeError(f"unsupported controller mode: {mode}")
    _atomic_replace_json(
        path,
        {
            "schema_version": SCHEMA_VERSION,
            "mode": mode,
        },
    )


def read_controller_mode(path: Path, expected_mode: str) -> str:
    if expected_mode not in DESIRED_MODES:
        raise ControllerError(f"unsupported expected controller mode: {expected_mode}")
    if not path.is_absolute():
        raise ControllerError("controller mode path must be absolute")
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise ControllerError(f"cannot stat controller mode file: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ControllerError("controller mode file must be a regular non-symlink")
    if metadata.st_size <= 0 or metadata.st_size > 4096:
        raise ControllerError("controller mode file has invalid size")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    fd = -1
    try:
        fd = os.open(path, flags)
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            raise ControllerError("controller mode file is not regular")
        if opened.st_size <= 0 or opened.st_size > 4096:
            raise ControllerError("controller mode file has invalid size")
        chunks: list[bytes] = []
        remaining = opened.st_size
        while remaining:
            chunk = os.read(fd, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
    except OSError as error:
        raise ControllerError(f"cannot read controller mode file: {error}") from error
    finally:
        if fd >= 0:
            os.close(fd)
    if len(data) != opened.st_size:
        raise ControllerError("controller mode file changed while reading")
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ControllerError("controller mode file is not valid JSON") from error
    if (
        not isinstance(value, dict)
        or set(value) != {"schema_version", "mode"}
        or value.get("schema_version") != SCHEMA_VERSION
        or value.get("mode") not in DESIRED_MODES
    ):
        raise ControllerError("controller mode file has invalid schema")
    mode = value["mode"]
    if mode != expected_mode:
        raise ControllerError(
            f"controller mode mismatch: {mode} != {expected_mode}"
        )
    return mode


def write_bypass(path: Path, updated_ms: int | None = None) -> None:
    if updated_ms is None:
        updated_ms = time.time_ns() // 1_000_000
    _atomic_write_mode(path, "bypass", updated_ms)


def parse_controller_decision(
    line: str, expected_timestamp_ms: int
) -> ControllerDecision:
    tokens = line.strip().split()
    if not tokens or tokens[0] != "dynamic_cache_decision":
        raise ControllerError("controller returned an unexpected stdout line")
    fields: dict[str, str] = {}
    for token in tokens[1:]:
        if token.count("=") != 1:
            raise ControllerError("controller decision contains a malformed field")
        key, value = token.split("=", 1)
        if not key or not value or key in fields:
            raise ControllerError("controller decision contains an invalid field")
        fields[key] = value
    try:
        timestamp_ms = int(fields["timestamp_ms"])
    except (KeyError, ValueError) as error:
        raise ControllerError("controller decision has invalid timestamp_ms") from error
    if timestamp_ms != expected_timestamp_ms:
        raise ControllerError(
            f"controller decision timestamp mismatch: "
            f"{timestamp_ms} != {expected_timestamp_ms}"
        )
    raw_mode = fields.get("mode")
    if raw_mode not in _DECISION_MODES:
        raise ControllerError("controller decision has invalid mode")
    if fields.get("publish_failed") not in {"0", "false"}:
        raise ControllerError("controller reported a publication failure")
    return ControllerDecision(timestamp_ms, _DECISION_MODES[raw_mode])


_CONTROLLER_EOF = object()


class ControllerSession:
    def __init__(
        self,
        command: Sequence[str],
        decision_timeout_seconds: float,
        stop_timeout_seconds: float,
        popen_factory: Callable[..., subprocess.Popen[str]] = subprocess.Popen,
    ):
        self._command = tuple(command)
        self._decision_timeout_seconds = decision_timeout_seconds
        self._stop_timeout_seconds = stop_timeout_seconds
        self._popen_factory = popen_factory
        self._process: subprocess.Popen[str] | None = None
        self._stdout_queue: queue.Queue[object] = queue.Queue()
        self._stdout_thread: threading.Thread | None = None

    def start(self) -> None:
        if self._process is not None:
            raise ControllerError("controller session is already started")
        try:
            process = self._popen_factory(
                list(self._command),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=None,
                text=True,
                encoding="utf-8",
                errors="strict",
                bufsize=1,
                shell=False,
            )
        except OSError as error:
            raise ControllerError(
                f"cannot start dynamic_cache_controller: {error}"
            ) from error
        if process.stdin is None or process.stdout is None:
            process.kill()
            process.wait()
            raise ControllerError("controller pipes were not created")
        self._process = process
        self._stdout_thread = threading.Thread(
            target=self._read_stdout,
            name="dynamic-cache-controller-stdout",
            daemon=True,
        )
        self._stdout_thread.start()

    def _read_stdout(self) -> None:
        process = self._process
        if process is None or process.stdout is None:
            self._stdout_queue.put(_CONTROLLER_EOF)
            return
        try:
            for line in process.stdout:
                self._stdout_queue.put(line)
        except (OSError, UnicodeError) as error:
            self._stdout_queue.put(error)
        finally:
            self._stdout_queue.put(_CONTROLLER_EOF)

    def alive(self) -> bool:
        return self._process is not None and self._process.poll() is None

    def wait_for_initial_publish(
        self,
        path: Path,
        previous_identity: tuple[int, int, int, int] | None,
    ) -> None:
        deadline = time.monotonic() + self._decision_timeout_seconds
        while time.monotonic() < deadline:
            if not self.alive():
                raise ControllerError(
                    "controller exited before publishing its initial bypass"
                )
            try:
                metadata = path.stat()
            except OSError:
                identity = None
            else:
                identity = (
                    metadata.st_dev,
                    metadata.st_ino,
                    metadata.st_mtime_ns,
                    metadata.st_size,
                )
            if identity is not None and identity != previous_identity:
                return
            time.sleep(0.01)
        raise ControllerError(
            "controller did not publish its initial bypass before timeout"
        )

    def send(self, sample: MetricSample) -> ControllerDecision:
        process = self._process
        if process is None or process.stdin is None or not self.alive():
            raise ControllerError("dynamic_cache_controller is not running")
        try:
            process.stdin.write(sample.to_csv() + "\n")
            process.stdin.flush()
        except (BrokenPipeError, OSError, UnicodeError) as error:
            raise ControllerError("controller stdin write failed") from error
        try:
            output = self._stdout_queue.get(timeout=self._decision_timeout_seconds)
        except queue.Empty as error:
            raise ControllerError(
                f"controller decision timed out after "
                f"{self._decision_timeout_seconds:.3f}s"
            ) from error
        if output is _CONTROLLER_EOF:
            raise ControllerError("controller stdout closed before a decision")
        if isinstance(output, BaseException):
            raise ControllerError(f"controller stdout failed: {output}") from output
        decision = parse_controller_decision(str(output), sample.timestamp_ms)
        if not self.alive():
            raise ControllerError("controller exited after returning a decision")
        return decision

    def stop(self) -> None:
        process = self._process
        if process is None:
            return
        if process.stdin is not None:
            try:
                process.stdin.close()
            except OSError:
                pass
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=self._stop_timeout_seconds)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        self._process = None


class MetricsBridge:
    def __init__(
        self,
        config: BridgeConfig,
        collector: MetricsCollector | None = None,
        controller_factory: Callable[[], ControllerSession] | None = None,
        wall_time_ns: Callable[[], int] = time.time_ns,
        monotonic: Callable[[], float] = time.monotonic,
    ):
        self._config = config
        self._collector = collector or MetricsCollector(config)
        self._controller_factory = controller_factory or (
            lambda: ControllerSession(
                config.controller_command,
                config.decision_timeout_seconds,
                config.stop_timeout_seconds,
            )
        )
        self._wall_time_ns = wall_time_ns
        self._monotonic = monotonic
        self._controller: ControllerSession | None = None
        self._window_anchor = monotonic()

    def _write_mode(self, mode: str, now_ns: int | None = None) -> None:
        if now_ns is None:
            now_ns = self._wall_time_ns()
        _atomic_write_mode(
            self._config.desired_mode_file, mode, now_ns // 1_000_000
        )

    def start(self) -> None:
        now_ns = self._wall_time_ns()
        self._write_mode("bypass", now_ns)
        _atomic_write_controller_mode(
            self._config.controller_mode_file, "bypass"
        )
        metadata = self._config.controller_mode_file.stat()
        previous_identity = (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_mtime_ns,
            metadata.st_size,
        )
        session = self._controller_factory()
        try:
            session.start()
            wait_for_initial_publish = getattr(
                session, "wait_for_initial_publish", None
            )
            if wait_for_initial_publish is not None:
                wait_for_initial_publish(
                    self._config.controller_mode_file, previous_identity
                )
            read_controller_mode(
                self._config.controller_mode_file, "bypass"
            )
            self._write_mode("bypass", self._wall_time_ns())
        except (BridgeError, OSError):
            try:
                self._write_mode("bypass", self._wall_time_ns())
            finally:
                try:
                    session.stop()
                finally:
                    _atomic_write_controller_mode(
                        self._config.controller_mode_file, "bypass"
                    )
            raise
        self._controller = session
        self._window_anchor = self._monotonic()

    def _stop_controller(self) -> None:
        if self._controller is not None:
            self._controller.stop()
            self._controller = None

    def _degrade(self, now_ns: int) -> None:
        try:
            self._write_mode("bypass", now_ns)
        finally:
            try:
                self._stop_controller()
            finally:
                _atomic_write_controller_mode(
                    self._config.controller_mode_file, "bypass"
                )
                self._collector.reset()
                self._window_anchor = self._monotonic()

    def poll_once(
        self, now_ns: int | None = None, elapsed_seconds: float | None = None
    ) -> bool:
        if now_ns is None:
            now_ns = self._wall_time_ns()
        if self._controller is not None and not self._controller.alive():
            self._degrade(now_ns)
            raise ControllerError("dynamic_cache_controller exited")
        if elapsed_seconds is None:
            elapsed_seconds = self._monotonic() - self._window_anchor
        try:
            prepared = self._collector.prepare(now_ns, elapsed_seconds)
        except (SnapshotError, MetricParseError) as error:
            self._degrade(now_ns)
            print(f"openstack_metrics_bridge: degraded: {error}", file=sys.stderr)
            return False
        if prepared is None:
            return False
        if self._controller is None:
            self.start()
        controller = self._controller
        if controller is None:
            raise AssertionError("controller did not start")
        try:
            decision = controller.send(prepared.sample)
            read_controller_mode(
                self._config.controller_mode_file, decision.mode
            )
            self._write_mode(decision.mode, self._wall_time_ns())
        except (BridgeError, OSError):
            self._degrade(self._wall_time_ns())
            raise
        prepared.commit()
        self._window_anchor = self._monotonic()
        return True

    def stop(self) -> None:
        self._degrade(self._wall_time_ns())

    def run(self, stopping: threading.Event) -> None:
        self.start()
        try:
            while not stopping.wait(self._config.poll_interval_seconds):
                self.poll_once()
        finally:
            self.stop()


def _positive_int_argument(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer") from error
    if parsed <= 0 or parsed > MAX_SNAPSHOT_BYTES:
        raise argparse.ArgumentTypeError(
            f"must be in [1, {MAX_SNAPSHOT_BYTES}]"
        )
    return parsed


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--config", required=True, type=Path)
    check_parser = subparsers.add_parser("check-config")
    check_parser.add_argument("--config", required=True, type=Path)
    snapshot_parser = subparsers.add_parser("snapshot-log")
    snapshot_parser.add_argument("--path", required=True, type=Path)
    snapshot_parser.add_argument(
        "--max-bytes", type=_positive_int_argument, default=256 * 1024
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "snapshot-log":
            snapshot = read_log_snapshot(args.path, args.max_bytes)
            print(
                json.dumps(
                    snapshot_payload(snapshot),
                    sort_keys=True,
                    separators=(",", ":"),
                ),
                flush=True,
            )
            return 0
        config = load_config(args.config)
        if args.command == "check-config":
            preflight_config(config)
            return 0
        stopping = threading.Event()

        def request_stop(_signum: int, _frame: Any) -> None:
            stopping.set()

        signal.signal(signal.SIGINT, request_stop)
        signal.signal(signal.SIGTERM, request_stop)
        MetricsBridge(config).run(stopping)
        return 0
    except (BridgeError, OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"openstack_metrics_bridge: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
