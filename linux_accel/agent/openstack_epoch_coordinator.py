#!/usr/bin/env python3
"""Coordinate health-gated cache policy epochs across OpenStack endpoints."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Protocol, Sequence

try:
    import fcntl
except ImportError:
    fcntl = None  # type: ignore[assignment]

try:
    from .openstack_epoch_gate import (
        DEFAULT_MAX_SNAPSHOT_SKEW_MS,
        AgentSnapshot,
        GateAction,
        GateDecision,
        GateError,
        GuestEndpointSnapshot,
        RequiredEndpoint,
        bypass_decision,
        evaluate_gate,
        parse_agent_snapshot,
        parse_guest_endpoint_snapshot,
    )
except ImportError:
    from openstack_epoch_gate import (  # type: ignore[no-redef]
        DEFAULT_MAX_SNAPSHOT_SKEW_MS,
        AgentSnapshot,
        GateAction,
        GateDecision,
        GateError,
        GuestEndpointSnapshot,
        RequiredEndpoint,
        bypass_decision,
        evaluate_gate,
        parse_agent_snapshot,
        parse_guest_endpoint_snapshot,
    )


class CoordinatorError(RuntimeError):
    pass


_MODES = {"bypass", "server", "client", "dual"}
_MODE_VALUES = {"bypass": 1, "server": 2, "client": 3, "dual": 4}
_VALUE_MODES = {value: mode for mode, value in _MODE_VALUES.items()}
_COMMITTED_FLAG = 1
_PUBLISHER_PROTOCOL = "cache-policy-txn-v1"
_PUBLISHER_TARGET_KINDS = {"compute_port", "guest_endpoint"}
_PUBLISHER_SERVICES = {"dns", "grpc"}
POLICY_LOCK_ROOT = "/run/vnet-dataplane-policy"
SSH_KNOWN_HOSTS_ROOT = PurePosixPath("/etc/vnet-dataplane-agent")
_AUDIT_TAIL_LIMIT = 4 * 1024 * 1024


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""


class CommandRunner(Protocol):
    def run(self, args: Sequence[str], timeout_seconds: float) -> CommandResult:
        ...


class SubprocessRunner:
    def run(self, args: Sequence[str], timeout_seconds: float) -> CommandResult:
        result = subprocess.run(
            list(args),
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )
        return CommandResult(result.returncode, result.stdout, result.stderr)


class _CoordinatorLock:
    def __init__(self, path: Path):
        self._path = path
        self._file: Any = None

    def __enter__(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._file = self._path.open("a+b")
        if fcntl is not None:
            fcntl.flock(self._file.fileno(), fcntl.LOCK_EX)

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        if self._file is None:
            return
        if fcntl is not None:
            fcntl.flock(self._file.fileno(), fcntl.LOCK_UN)
        self._file.close()


@dataclass(frozen=True)
class StateSource:
    name: str
    path: Path | None = None
    command: tuple[str, ...] = ()
    kind: str = "compute_agent"


@dataclass(frozen=True)
class PublisherEndpoint:
    name: str
    host: str
    server_id: str
    port_id: str
    command: tuple[str, ...]
    protocol: str = _PUBLISHER_PROTOCOL
    actor_id: str = ""
    target_kind: str = "compute_port"
    services: tuple[str, ...] = ("dns", "grpc")
    cache_role: str = "client"


@dataclass(frozen=True)
class CoordinatorConfig:
    required_endpoints: tuple[RequiredEndpoint, ...]
    state_sources: tuple[StateSource, ...]
    publishers: tuple[PublisherEndpoint, ...]
    max_state_age_ms: int
    command_timeout_seconds: float
    max_desired_mode_age_ms: int = 0
    max_snapshot_skew_ms: int = DEFAULT_MAX_SNAPSHOT_SKEW_MS
    policy_lock_root: str = POLICY_LOCK_ROOT


@dataclass(frozen=True)
class RuntimeState:
    mode: str = "bypass"
    epoch: int = 0
    known: bool = False


@dataclass(frozen=True)
class PublishRecord:
    endpoint: str
    operation: str
    mode: str
    epoch: int
    returncode: int
    detail: str


@dataclass(frozen=True)
class MapReadback:
    endpoint: str
    host: str
    server_id: str
    port_id: str
    actor_id: str
    target_kind: str
    services: tuple[str, ...]
    cache_role: str
    present: bool
    maps: int
    epoch: int
    mode: int
    flags: int


@dataclass(frozen=True)
class _ReadbackAssessment:
    state: RuntimeState
    readbacks: tuple[MapReadback, ...]
    records: tuple[PublishRecord, ...]
    complete: bool
    any_present: bool
    max_epoch: int
    reason: str


@dataclass(frozen=True)
class CoordinatorResult:
    requested_mode: str
    effective_mode: str
    outcome: str
    exit_code: int
    previous_state: RuntimeState
    state: RuntimeState
    gate: GateDecision
    publications: tuple[PublishRecord, ...]
    map_readbacks: tuple[MapReadback, ...] = ()
    state_input_error: str = ""

    def asdict(self) -> dict[str, Any]:
        return {
            "requested_mode": self.requested_mode,
            "effective_mode": self.effective_mode,
            "outcome": self.outcome,
            "exit_code": self.exit_code,
            "previous_state": asdict(self.previous_state),
            "state": asdict(self.state),
            "gate": self.gate.asdict(),
            "publications": [asdict(item) for item in self.publications],
            "map_readbacks": [asdict(item) for item in self.map_readbacks],
            "state_input_error": self.state_input_error,
        }


class EpochCoordinator:
    def __init__(
        self,
        config: CoordinatorConfig,
        state_file: Path,
        runner: CommandRunner | None = None,
        initial_epoch: int = 1,
    ):
        if initial_epoch <= 0:
            raise CoordinatorError("initial epoch must be positive")
        self._config = config
        self._state_file = state_file
        self._runner = runner or SubprocessRunner()
        self._initial_epoch = initial_epoch

    def reconcile(
        self, desired_mode: str, now_ms: int | None = None
    ) -> CoordinatorResult:
        desired = _normalize_mode(desired_mode)
        lock_file = self._state_file.with_name(self._state_file.name + ".lock")
        with _CoordinatorLock(lock_file):
            return self._reconcile_locked(desired, now_ms)

    def reconcile_shutdown(self, now_ms: int | None = None) -> CoordinatorResult:
        """Publish a fresh BYPASS epoch that can fence service shutdown."""
        lock_file = self._state_file.with_name(self._state_file.name + ".lock")
        with _CoordinatorLock(lock_file):
            return self._reconcile_locked(
                "bypass",
                now_ms,
                force_bypass_epoch=True,
            )

    def _reconcile_locked(
        self,
        desired: str,
        now_ms: int | None,
        *,
        force_bypass_epoch: bool = False,
    ) -> CoordinatorResult:
        journal, state_input_error = self._load_runtime_state()
        gate = self._read_gate(now_ms)
        publications: list[PublishRecord] = []
        if (
            not force_bypass_epoch
            and gate.action is not GateAction.PUBLISH
            and journal.known
            and journal.mode != "bypass"
        ):
            recovery_epoch = max(self._initial_epoch, journal.epoch + 1)
            recovered, recovery_records = self._force_and_read_bypass(
                recovery_epoch, gate
            )
            publications.extend(recovery_records)
            if _is_confirmed(
                recovered, "bypass", minimum_epoch=recovery_epoch
            ):
                write_error = self._try_write_runtime_state(recovered.state)
                if write_error:
                    return CoordinatorResult(
                        desired,
                        "bypass",
                        "state_write_failed_bypass_preserved",
                        1,
                        journal,
                        recovered.state,
                        gate,
                        tuple(publications),
                        recovered.readbacks,
                        _join_errors(state_input_error, write_error),
                    )
                outcome = (
                    "migration_forced_bypass"
                    if gate.action is GateAction.FREEZE
                    else "fail_safe_bypass_published"
                )
                return CoordinatorResult(
                    desired,
                    "bypass",
                    outcome,
                    2,
                    journal,
                    recovered.state,
                    gate,
                    tuple(publications),
                    recovered.readbacks,
                    state_input_error,
                )
            unknown = RuntimeState(
                "bypass",
                max(journal.epoch, recovered.max_epoch),
                False,
            )
            write_error = self._try_write_runtime_state(unknown)
            return CoordinatorResult(
                desired,
                "bypass",
                "bypass_publication_failed",
                1,
                journal,
                unknown,
                gate,
                tuple(publications),
                recovered.readbacks,
                _join_errors(state_input_error, write_error),
            )

        observed = self._read_current_all(gate)
        publications.extend(observed.records)
        map_readbacks = observed.readbacks
        previous = observed.state
        if not previous.known:
            previous = RuntimeState(
                "bypass", max(journal.epoch, observed.max_epoch), False
            )

        if observed.complete and not observed.any_present:
            return CoordinatorResult(
                desired,
                "bypass",
                "no_active_maps",
                2,
                previous,
                previous,
                gate,
                tuple(publications),
                map_readbacks,
                state_input_error,
            )

        state = observed.state
        if not state.known:
            bootstrap_epoch = max(
                self._initial_epoch,
                journal.epoch + 1,
                observed.max_epoch + 1,
            )
            recovered, recovery_records = self._force_and_read_bypass(
                bootstrap_epoch, gate
            )
            publications.extend(recovery_records)
            map_readbacks = recovered.readbacks
            if not _is_confirmed(recovered, "bypass", minimum_epoch=bootstrap_epoch):
                unknown = RuntimeState(
                    "bypass",
                    max(journal.epoch, observed.max_epoch, recovered.max_epoch),
                    False,
                )
                write_error = self._try_write_runtime_state(unknown)
                return CoordinatorResult(
                    desired,
                    "bypass",
                    "bootstrap_bypass_failed",
                    1,
                    previous,
                    unknown,
                    gate,
                    tuple(publications),
                    map_readbacks,
                    _join_errors(state_input_error, write_error),
                )
            state = recovered.state
            write_error = self._try_write_runtime_state(state)
            if write_error:
                return CoordinatorResult(
                    desired,
                    "bypass",
                    "bootstrap_state_write_failed",
                    1,
                    previous,
                    state,
                    gate,
                    tuple(publications),
                    map_readbacks,
                    _join_errors(state_input_error, write_error),
                )
            journal = state
        elif state.epoch < journal.epoch:
            rebase_epoch = max(
                self._initial_epoch,
                journal.epoch + 1,
                observed.max_epoch + 1,
            )
            recovered, recovery_records = self._force_and_read_bypass(
                rebase_epoch, gate
            )
            publications.extend(recovery_records)
            map_readbacks = recovered.readbacks
            if not _is_confirmed(recovered, "bypass", minimum_epoch=rebase_epoch):
                unknown = RuntimeState(
                    "bypass",
                    max(journal.epoch, observed.max_epoch, recovered.max_epoch),
                    False,
                )
                write_error = self._try_write_runtime_state(unknown)
                return CoordinatorResult(
                    desired,
                    "bypass",
                    "journal_epoch_rebase_failed",
                    1,
                    previous,
                    unknown,
                    gate,
                    tuple(publications),
                    map_readbacks,
                    _join_errors(state_input_error, write_error),
                )
            state = recovered.state
            write_error = self._try_write_runtime_state(state)
            if write_error:
                return CoordinatorResult(
                    desired,
                    "bypass",
                    "journal_epoch_rebase_state_write_failed",
                    1,
                    previous,
                    state,
                    gate,
                    tuple(publications),
                    map_readbacks,
                    _join_errors(state_input_error, write_error),
                )
            journal = state
        elif state_input_error or state != journal:
            write_error = self._try_write_runtime_state(state)
            if write_error:
                return self._recover_after_state_write_failure(
                    desired,
                    previous,
                    state,
                    journal,
                    gate,
                    publications,
                    map_readbacks,
                    _join_errors(state_input_error, write_error),
                )
            journal = state

        effective = desired if gate.action is GateAction.PUBLISH else "bypass"
        if state.mode == effective and not force_bypass_epoch:
            if gate.action is GateAction.PUBLISH:
                outcome = "policy_unchanged"
                exit_code = 0
            elif gate.action is GateAction.FREEZE:
                outcome = "migration_frozen_in_bypass"
                exit_code = 2
            else:
                outcome = "fail_safe_bypass_unchanged"
                exit_code = 2
            return CoordinatorResult(
                desired,
                effective,
                outcome,
                exit_code,
                previous,
                state,
                gate,
                tuple(publications),
                map_readbacks,
                state_input_error,
            )

        next_epoch = max(
            self._initial_epoch,
            state.epoch + 1,
            journal.epoch + 1,
        )
        attempted, gate, transaction_gate_valid = self._publish_transaction(
            effective,
            next_epoch,
            gate,
            now_ms,
        )
        publications.extend(attempted)
        confirmed = self._read_current_all(gate)
        publications.extend(confirmed.records)
        map_readbacks = confirmed.readbacks
        if transaction_gate_valid and _all_succeeded(attempted) and _is_confirmed(
            confirmed, effective, exact_epoch=next_epoch
        ):
            state = confirmed.state
            write_error = self._try_write_runtime_state(state)
            if write_error:
                return self._recover_after_state_write_failure(
                    desired,
                    previous,
                    state,
                    journal,
                    gate,
                    publications,
                    map_readbacks,
                    _join_errors(state_input_error, write_error),
                )
            if gate.action is GateAction.PUBLISH:
                outcome = "policy_published"
                exit_code = 0
            elif gate.action is GateAction.FREEZE:
                outcome = "migration_forced_bypass"
                exit_code = 2
            else:
                outcome = "fail_safe_bypass_published"
                exit_code = 2
            return CoordinatorResult(
                desired,
                effective,
                outcome,
                exit_code,
                previous,
                state,
                gate,
                tuple(publications),
                map_readbacks,
                state_input_error,
            )

        recovery_epoch = max(
            next_epoch,
            confirmed.max_epoch,
            journal.epoch,
        )
        recovered, recovery_records = self._force_and_read_bypass(
            recovery_epoch, gate
        )
        publications.extend(recovery_records)
        map_readbacks = recovered.readbacks
        if _is_confirmed(recovered, "bypass", minimum_epoch=recovery_epoch):
            state = recovered.state
            write_error = self._try_write_runtime_state(state)
            if write_error:
                return CoordinatorResult(
                    desired,
                    "bypass",
                    "publish_failed_bypass_recovered_state_write_failed",
                    1,
                    previous,
                    state,
                    gate,
                    tuple(publications),
                    map_readbacks,
                    _join_errors(state_input_error, write_error),
                )
            outcome = (
                "gate_changed_bypass_recovered"
                if not transaction_gate_valid
                else "publish_failed_bypass_recovered"
            )
            return CoordinatorResult(
                desired,
                "bypass",
                outcome,
                2,
                previous,
                state,
                gate,
                tuple(publications),
                map_readbacks,
                state_input_error,
            )

        state = RuntimeState(
            "bypass",
            max(journal.epoch, confirmed.max_epoch, recovered.max_epoch),
            False,
        )
        write_error = self._try_write_runtime_state(state)
        return CoordinatorResult(
            desired,
            "bypass",
            "bypass_publication_failed",
            1,
            previous,
            state,
            gate,
            tuple(publications),
            map_readbacks,
            _join_errors(state_input_error, write_error),
        )

    def _recover_after_state_write_failure(
        self,
        desired: str,
        previous: RuntimeState,
        state: RuntimeState,
        journal: RuntimeState,
        gate: GateDecision,
        publications: list[PublishRecord],
        map_readbacks: tuple[MapReadback, ...],
        state_input_error: str,
    ) -> CoordinatorResult:
        if state.mode == "bypass":
            return CoordinatorResult(
                desired,
                "bypass",
                "state_write_failed_bypass_preserved",
                1,
                previous,
                state,
                gate,
                tuple(publications),
                map_readbacks,
                state_input_error,
            )

        recovery_epoch = max(
            self._initial_epoch,
            state.epoch + 1,
            journal.epoch + 1,
        )
        recovered, recovery_records = self._force_and_read_bypass(
            recovery_epoch, gate
        )
        publications.extend(recovery_records)
        if _is_confirmed(recovered, "bypass", minimum_epoch=recovery_epoch):
            return CoordinatorResult(
                desired,
                "bypass",
                "state_write_failed_bypass_recovered",
                1,
                previous,
                recovered.state,
                gate,
                tuple(publications),
                recovered.readbacks,
                state_input_error,
            )
        unknown = RuntimeState(
            "bypass",
            max(state.epoch, journal.epoch, recovered.max_epoch),
            False,
        )
        return CoordinatorResult(
            desired,
            "bypass",
            "state_write_failed_bypass_unconfirmed",
            1,
            previous,
            unknown,
            gate,
            tuple(publications),
            recovered.readbacks,
            state_input_error,
        )

    def _read_gate(self, now_ms: int | None) -> GateDecision:
        snapshots: list[AgentSnapshot] = []
        guest_snapshots: list[GuestEndpointSnapshot] = []
        try:
            for source in self._config.state_sources:
                value = self._read_snapshot_value(source)
                if source.kind == "compute_agent":
                    snapshots.append(parse_agent_snapshot(value, source.name))
                else:
                    guest_snapshots.append(
                        parse_guest_endpoint_snapshot(value, source.name)
                    )
            observed_at = (
                int(time.time() * 1000) if now_ms is None else now_ms
            )
            return evaluate_gate(
                snapshots,
                self._config.required_endpoints,
                observed_at,
                self._config.max_state_age_ms,
                self._config.max_snapshot_skew_ms,
                guest_snapshots,
            )
        except (
            GateError,
            CoordinatorError,
            OSError,
            subprocess.TimeoutExpired,
            json.JSONDecodeError,
        ) as error:
            return bypass_decision(
                self._config.required_endpoints,
                f"state_input_error:{type(error).__name__}:{error}",
            )

    def _read_snapshot_value(self, source: StateSource) -> Any:
        if source.path is not None:
            text = source.path.read_text(encoding="utf-8")
        else:
            result = self._runner.run(
                source.command, self._config.command_timeout_seconds
            )
            if result.returncode != 0:
                raise CoordinatorError(
                    f"state source {source.name} failed: {_command_detail(result)}"
                )
            text = result.stdout
        return json.loads(text)

    def _publish_transaction(
        self,
        mode: str,
        epoch: int,
        gate: GateDecision,
        now_ms: int | None,
    ) -> tuple[list[PublishRecord], GateDecision, bool]:
        records: list[PublishRecord] = []
        for operation in ("stage", "verify-staged"):
            phase = self._invoke_all(operation, mode, epoch)
            records.extend(phase)
            if not _all_succeeded(phase):
                return records, gate, True

        if mode != "bypass":
            gate = self._read_gate(now_ms)
            if gate.action is not GateAction.PUBLISH:
                return records, gate, False

        phase = self._invoke_all("commit", mode, epoch)
        records.extend(phase)
        if not _all_succeeded(phase):
            return records, gate, True
        if mode != "bypass":
            gate = self._read_gate(now_ms)
            if gate.action is not GateAction.PUBLISH:
                return records, gate, False

        phase = self._invoke_all("verify-committed", mode, epoch)
        records.extend(phase)
        if not _all_succeeded(phase):
            return records, gate, True
        if mode != "bypass":
            gate = self._read_gate(now_ms)
            if gate.action is not GateAction.PUBLISH:
                return records, gate, False
        return records, gate, True

    def _force_bypass_all(self, epoch: int) -> list[PublishRecord]:
        return self._invoke_all("force-bypass", "bypass", epoch)

    def _force_and_read_bypass(
        self, epoch: int, gate: GateDecision
    ) -> tuple[_ReadbackAssessment, list[PublishRecord]]:
        records = self._force_bypass_all(epoch)
        observed = self._read_current_all(gate)
        records.extend(observed.records)
        return observed, records

    def _invoke_all(
        self, operation: str, mode: str, epoch: int
    ) -> list[PublishRecord]:
        records: list[PublishRecord] = []
        for endpoint, result in self._run_publisher_commands(
            operation, mode, epoch
        ):
            if isinstance(result, (OSError, subprocess.TimeoutExpired)):
                records.append(
                    PublishRecord(
                        endpoint.name,
                        operation,
                        mode,
                        epoch,
                        1,
                        str(result)[:400],
                    )
                )
                continue
            records.append(
                PublishRecord(
                    endpoint.name,
                    operation,
                    mode,
                    epoch,
                    result.returncode,
                    _command_detail(result),
                )
            )
        return records

    def _read_current_all(self, gate: GateDecision) -> _ReadbackAssessment:
        records: list[PublishRecord] = []
        readbacks: list[MapReadback] = []
        complete = True
        max_epoch = 0
        for endpoint, result in self._run_publisher_commands(
            "read-current", "bypass", 1
        ):
            if isinstance(result, (OSError, subprocess.TimeoutExpired)):
                complete = False
                records.append(
                    PublishRecord(
                        endpoint.name,
                        "read-current",
                        "bypass",
                        1,
                        1,
                        str(result)[:400],
                    )
                )
                continue
            if result.returncode != 0:
                complete = False
                records.append(
                    PublishRecord(
                        endpoint.name,
                        "read-current",
                        "bypass",
                        1,
                        result.returncode,
                        _command_detail(result),
                    )
                )
                continue
            try:
                readback = _parse_map_readback(endpoint, result.stdout)
            except (CoordinatorError, json.JSONDecodeError) as error:
                complete = False
                records.append(
                    PublishRecord(
                        endpoint.name,
                        "read-current",
                        "bypass",
                        1,
                        1,
                        str(error)[:400],
                    )
                )
                continue
            readbacks.append(readback)
            max_epoch = max(max_epoch, readback.epoch)
            records.append(
                PublishRecord(
                    endpoint.name,
                    "read-current",
                    "bypass",
                    1,
                    0,
                    _command_detail(result),
                )
            )

        active = [item for item in readbacks if item.present]
        if not complete:
            return _ReadbackAssessment(
                RuntimeState("bypass", max_epoch, False),
                tuple(readbacks),
                tuple(records),
                False,
                bool(active),
                max_epoch,
                "readback_incomplete",
            )

        publishers_by_actor: dict[str, list[PublisherEndpoint]] = {}
        active_by_actor: dict[str, list[MapReadback]] = {}
        for publisher in self._config.publishers:
            publishers_by_actor.setdefault(publisher.actor_id, []).append(
                publisher
            )
        for readback in active:
            active_by_actor.setdefault(readback.actor_id, []).append(readback)

        healthy_hosts = {
            (item.server_id, item.port_id): _short_host(item.local_host)
            for item in gate.healthy_observations
        }
        for actor_id, publishers in publishers_by_actor.items():
            contract = publishers[0]
            actor_active = active_by_actor.get(actor_id, [])
            if contract.target_kind == "guest_endpoint":
                if len(actor_active) != 1:
                    return _ReadbackAssessment(
                        RuntimeState("bypass", max_epoch, False),
                        tuple(readbacks),
                        tuple(records),
                        False,
                        bool(active),
                        max_epoch,
                        f"guest_actor_presence_invalid:{actor_id}:"
                        f"{len(actor_active)}",
                    )
                continue
            if gate.action is not GateAction.PUBLISH:
                continue
            expected_host = healthy_hosts.get(
                (contract.server_id, contract.port_id)
            )
            if expected_host is None:
                return _ReadbackAssessment(
                    RuntimeState("bypass", max_epoch, False),
                    tuple(readbacks),
                    tuple(records),
                    False,
                    bool(active),
                    max_epoch,
                    f"compute_actor_has_no_healthy_binding:{actor_id}",
                )
            if (
                len(actor_active) != 1
                or _short_host(actor_active[0].host) != expected_host
            ):
                return _ReadbackAssessment(
                    RuntimeState("bypass", max_epoch, False),
                    tuple(readbacks),
                    tuple(records),
                    False,
                    bool(active),
                    max_epoch,
                    f"compute_actor_presence_invalid:{actor_id}:"
                    f"{expected_host}:{len(actor_active)}",
                )
        if not active:
            return _ReadbackAssessment(
                RuntimeState("bypass", max_epoch, False),
                tuple(readbacks),
                tuple(records),
                True,
                False,
                max_epoch,
                "no_active_maps",
            )
        first = active[0]
        agreed = all(
            (item.epoch, item.mode, item.flags)
            == (first.epoch, first.mode, first.flags)
            for item in active[1:]
        )
        mode = _VALUE_MODES.get(first.mode)
        if (
            not agreed
            or first.epoch <= 0
            or mode is None
            or first.flags != _COMMITTED_FLAG
        ):
            return _ReadbackAssessment(
                RuntimeState("bypass", max_epoch, False),
                tuple(readbacks),
                tuple(records),
                True,
                True,
                max_epoch,
                "runtime_maps_not_consistent_committed",
            )
        return _ReadbackAssessment(
            RuntimeState(mode, first.epoch, True),
            tuple(readbacks),
            tuple(records),
            True,
            True,
            max_epoch,
            "runtime_maps_consistent",
        )

    def _run_publisher_commands(
        self, operation: str, mode: str, epoch: int
    ) -> list[
        tuple[
            PublisherEndpoint,
            CommandResult | OSError | subprocess.TimeoutExpired,
        ]
    ]:
        def invoke(
            endpoint: PublisherEndpoint,
        ) -> CommandResult | OSError | subprocess.TimeoutExpired:
            command = [
                *endpoint.command,
                "--operation",
                operation,
                "--mode",
                mode,
                "--epoch",
                str(epoch),
            ]
            try:
                return self._runner.run(
                    command, self._config.command_timeout_seconds
                )
            except (OSError, subprocess.TimeoutExpired) as error:
                return error

        results: list[
            CommandResult | OSError | subprocess.TimeoutExpired | None
        ] = [None] * len(self._config.publishers)
        remote_indexes: list[int] = []
        for index, endpoint in enumerate(self._config.publishers):
            if (
                endpoint.command
                and PurePosixPath(endpoint.command[0]).name.lower() == "ssh"
            ):
                remote_indexes.append(index)
            else:
                results[index] = invoke(endpoint)

        if remote_indexes:
            with ThreadPoolExecutor(max_workers=len(remote_indexes)) as executor:
                futures = {
                    index: executor.submit(
                        invoke, self._config.publishers[index]
                    )
                    for index in remote_indexes
                }
                for index in remote_indexes:
                    results[index] = futures[index].result()

        ordered: list[
            tuple[
                PublisherEndpoint,
                CommandResult | OSError | subprocess.TimeoutExpired,
            ]
        ] = []
        for endpoint, result in zip(self._config.publishers, results):
            if result is None:
                raise AssertionError("publisher command result is missing")
            ordered.append((endpoint, result))
        return ordered

    def _load_runtime_state(self) -> tuple[RuntimeState, str]:
        try:
            value = json.loads(self._state_file.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return RuntimeState(), "state_missing"
        except (OSError, json.JSONDecodeError) as error:
            return RuntimeState(), f"state_invalid:{type(error).__name__}:{error}"
        try:
            if not isinstance(value, dict) or value.get("schema_version") != 1:
                raise CoordinatorError("unsupported schema")
            mode = _normalize_mode(value.get("mode"))
            epoch = value.get("epoch")
            known = value.get("known")
            if not isinstance(epoch, int) or epoch < 0 or not isinstance(known, bool):
                raise CoordinatorError("invalid fields")
            return RuntimeState(mode, epoch, known), ""
        except CoordinatorError as error:
            return RuntimeState(), f"state_invalid:{error}"

    def _try_write_runtime_state(self, state: RuntimeState) -> str:
        try:
            self._write_runtime_state(state)
        except OSError as error:
            return f"state_write_error:{type(error).__name__}:{error}"
        return ""

    def _write_runtime_state(self, state: RuntimeState) -> None:
        self._state_file.parent.mkdir(parents=True, exist_ok=True)
        temporary = self._state_file.with_name(
            f"{self._state_file.name}.tmp.{os.getpid()}.{threading.get_ident()}"
        )
        try:
            temporary.write_text(
                json.dumps(
                    {"schema_version": 1, **asdict(state)},
                    sort_keys=True,
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            os.replace(temporary, self._state_file)
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def load_config(path: Path) -> CoordinatorConfig:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise CoordinatorError(f"config does not exist: {path}") from error
    if not isinstance(value, dict) or value.get("schema_version") != 2:
        raise CoordinatorError("coordinator config has unsupported schema")

    policy_lock_root_value = _required_text(value, "policy_lock_root")
    policy_lock_root = PurePosixPath(policy_lock_root_value)
    if (
        not policy_lock_root.is_absolute()
        or policy_lock_root == PurePosixPath("/")
        or any(part in {".", ".."} for part in policy_lock_root.parts)
        or str(policy_lock_root) != policy_lock_root_value
    ):
        raise CoordinatorError(
            "policy_lock_root must be a canonical absolute directory below /"
        )
    if policy_lock_root != PurePosixPath(POLICY_LOCK_ROOT):
        raise CoordinatorError(
            f"policy_lock_root must be exactly {POLICY_LOCK_ROOT}"
        )

    required: list[RequiredEndpoint] = []
    for item in _required_list(value, "required_endpoints"):
        if not isinstance(item, dict):
            raise CoordinatorError("required endpoint must be an object")
        backend_server_id = item.get("grpc_backend_server_id")
        if backend_server_id is not None:
            if not isinstance(backend_server_id, str) or not backend_server_id.strip():
                raise CoordinatorError(
                    "grpc_backend_server_id must be a non-empty string"
                )
            backend_server_id = backend_server_id.strip()
        required.append(
            RequiredEndpoint(
                _required_text(item, "server_id"),
                _required_text(item, "port_id"),
                _required_text(item, "compute_role"),
                _required_text(item, "guest_cache_role"),
                backend_server_id,
            )
        )

    state_sources: list[StateSource] = []
    for item in _required_list(value, "state_sources"):
        if not isinstance(item, dict):
            raise CoordinatorError("state source must be an object")
        name = _required_text(item, "name")
        kind = _required_text(item, "kind")
        if kind not in {"compute_agent", "guest_endpoint"}:
            raise CoordinatorError(
                f"state source {name} has unsupported kind: {kind}"
            )
        path_value = item.get("path")
        command_value = item.get("command")
        if (path_value is None) == (command_value is None):
            raise CoordinatorError(
                f"state source {name} must use exactly one of path or command"
            )
        if path_value is not None:
            path_value = _required_text(item, "path")
            path = Path(path_value)
            if not path.is_absolute() and not PurePosixPath(path_value).is_absolute():
                raise CoordinatorError(f"state source {name} path must be absolute")
            state_sources.append(StateSource(name, path=path, kind=kind))
        else:
            state_sources.append(
                StateSource(
                    name,
                    command=_command_list(command_value, name),
                    kind=kind,
                )
            )

    publishers: list[PublisherEndpoint] = []
    required_keys = {
        (item.server_id, item.port_id)
        for item in required
    }
    required_by_key = {
        (item.server_id, item.port_id): item for item in required
    }
    for item in _required_list(value, "publishers"):
        if not isinstance(item, dict):
            raise CoordinatorError("publisher must be an object")
        name = _required_text(item, "name")
        host = _short_host(_required_text(item, "host"))
        server_id = _required_text(item, "server_id")
        port_id = _required_text(item, "port_id")
        actor_id = _required_text(item, "actor_id")
        target_kind = _required_text(item, "target_kind")
        if target_kind not in _PUBLISHER_TARGET_KINDS:
            raise CoordinatorError(
                f"publisher {name} has unsupported target_kind: {target_kind}"
            )
        services_value = item.get("services")
        if (
            not isinstance(services_value, list)
            or not services_value
            or not all(
                isinstance(service, str) and service in _PUBLISHER_SERVICES
                for service in services_value
            )
            or len(services_value) != len(set(services_value))
        ):
            raise CoordinatorError(
                f"publisher {name} services must be unique dns/grpc values"
            )
        services = tuple(services_value)
        if (server_id, port_id) not in required_keys:
            raise CoordinatorError(
                f"publisher {name} does not match a required endpoint"
            )
        cache_role = _required_text(item, "cache_role")
        if cache_role not in {"client", "server"}:
            raise CoordinatorError(
                f"publisher {name} has unsupported cache_role: {cache_role}"
            )
        required_endpoint = required_by_key[(server_id, port_id)]
        if target_kind == "compute_port":
            if (
                required_endpoint.compute_role != "client"
                or cache_role != "client"
            ):
                raise CoordinatorError(
                    f"publisher {name} compute_port target must be the "
                    "client cache endpoint"
                )
        elif cache_role != required_endpoint.guest_cache_role:
            raise CoordinatorError(
                f"publisher {name} guest cache_role does not match the "
                "required endpoint"
            )
        protocol = _required_text(item, "protocol")
        if protocol != _PUBLISHER_PROTOCOL:
            raise CoordinatorError(
                f"publisher {name} has unsupported protocol: {protocol}"
            )
        command = _command_list(item.get("command"), name)
        if "--dry-run" in command:
            raise CoordinatorError(f"publisher {name} must not be dry-run")
        if any(
            argument in command
            for argument in ("--operation", "--mode", "--epoch")
        ):
            raise CoordinatorError(
                f"publisher {name} must not preconfigure operation, mode, or epoch"
            )
        _validate_publisher_command(
            name,
            host,
            port_id,
            command,
            policy_lock_root,
            services,
        )
        publishers.append(
            PublisherEndpoint(
                name,
                host,
                server_id,
                port_id,
                command,
                protocol,
                actor_id,
                target_kind,
                services,
                cache_role,
            )
        )

    _require_unique([item.name for item in state_sources], "state source")
    _require_unique([item.name for item in publishers], "publisher")
    _require_unique(
        [
            f"{item.host}\0{item.actor_id}"
            for item in publishers
        ],
        "publisher host and actor",
    )
    actor_contracts: dict[
        str, tuple[str, str, str, tuple[str, ...], str]
    ] = {}
    actor_counts: dict[str, int] = {}
    for publisher in publishers:
        contract = (
            publisher.server_id,
            publisher.port_id,
            publisher.target_kind,
            publisher.services,
            publisher.cache_role,
        )
        previous = actor_contracts.setdefault(publisher.actor_id, contract)
        if previous != contract:
            raise CoordinatorError(
                f"publisher actor {publisher.actor_id} has inconsistent contract"
            )
        actor_counts[publisher.actor_id] = (
            actor_counts.get(publisher.actor_id, 0) + 1
        )
    multi_guest = sorted(
        actor_id
        for actor_id, contract in actor_contracts.items()
        if contract[2] == "guest_endpoint" and actor_counts[actor_id] != 1
    )
    if multi_guest:
        raise CoordinatorError(
            "guest endpoint actor must have exactly one publisher: "
            + ", ".join(multi_guest)
        )
    published_keys = {
        (contract[0], contract[1]) for contract in actor_contracts.values()
    }
    if published_keys != required_keys:
        raise CoordinatorError(
            "every required endpoint must have at least one publisher actor"
        )
    _validate_no_publisher_path_aliases(publishers)
    max_age_seconds = value.get("max_state_age_seconds", 10.0)
    max_skew_seconds = value.get(
        "max_snapshot_skew_seconds",
        DEFAULT_MAX_SNAPSHOT_SKEW_MS / 1000,
    )
    timeout_seconds = value.get("command_timeout_seconds", 10.0)
    desired_mode_age_seconds = value.get(
        "max_desired_mode_age_seconds", 0.0
    )
    if not isinstance(max_age_seconds, (int, float)) or max_age_seconds <= 0:
        raise CoordinatorError("max_state_age_seconds must be positive")
    if not isinstance(max_skew_seconds, (int, float)) or max_skew_seconds <= 0:
        raise CoordinatorError("max_snapshot_skew_seconds must be positive")
    if not isinstance(timeout_seconds, (int, float)) or timeout_seconds <= 0:
        raise CoordinatorError("command_timeout_seconds must be positive")
    if (
        isinstance(desired_mode_age_seconds, bool)
        or not isinstance(desired_mode_age_seconds, (int, float))
        or desired_mode_age_seconds < 0
    ):
        raise CoordinatorError(
            "max_desired_mode_age_seconds must be non-negative"
        )
    return CoordinatorConfig(
        required_endpoints=tuple(required),
        state_sources=tuple(state_sources),
        publishers=tuple(publishers),
        max_state_age_ms=int(max_age_seconds * 1000),
        command_timeout_seconds=float(timeout_seconds),
        max_desired_mode_age_ms=int(desired_mode_age_seconds * 1000),
        max_snapshot_skew_ms=int(max_skew_seconds * 1000),
        policy_lock_root=str(policy_lock_root),
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("once", "watch"):
        command = subparsers.add_parser(name)
        command.add_argument("--config", required=True, type=Path)
        command.add_argument("--state-file", required=True, type=Path)
        command.add_argument("--initial-epoch", type=int, default=1)
        command.add_argument("--audit-log", type=Path)
        if name == "once":
            command.add_argument("--desired-mode", required=True)
        else:
            command.add_argument("--desired-mode-file", required=True, type=Path)
            command.add_argument("--interval", type=float, default=2.0)
    wait = subparsers.add_parser("wait-committed")
    wait.add_argument("--config", required=True, type=Path)
    wait.add_argument("--desired-mode-file", required=True, type=Path)
    wait.add_argument("--state-file", required=True, type=Path)
    wait.add_argument("--audit-log", required=True, type=Path)
    wait.add_argument("--target-mode", required=True)
    wait.add_argument("--after-epoch", required=True, type=int)
    wait.add_argument("--min-present-readbacks", type=int, default=1)
    wait.add_argument("--timeout", type=float, default=30.0)
    wait.add_argument("--interval", type=float, default=0.1)
    wait.add_argument("--require-shutdown", action="store_true")
    return parser


def _emit(result: CoordinatorResult, audit_log: Path | None, **fields: Any) -> None:
    payload = {
        "timestamp_ms": int(time.time() * 1000),
        **result.asdict(),
        **fields,
    }
    line = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    print(line, flush=True)
    if audit_log is not None:
        audit_log.parent.mkdir(parents=True, exist_ok=True)
        with audit_log.open("a", encoding="utf-8") as output:
            output.write(line + "\n")


def _read_desired_mode(
    path: Path,
    max_age_ms: int = 0,
    now_ms: int | None = None,
) -> str:
    with path.open("rb") as stream:
        value = json.loads(stream.read())
        file_updated_ms = os.fstat(stream.fileno()).st_mtime_ns // 1_000_000
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise CoordinatorError("desired mode file has unsupported schema")
    if max_age_ms > 0:
        updated_ms = value.get("updated_ms", file_updated_ms)
        if isinstance(updated_ms, bool) or not isinstance(updated_ms, int):
            raise CoordinatorError("desired mode file has invalid updated_ms")
        current_ms = int(time.time() * 1000) if now_ms is None else now_ms
        if updated_ms - current_ms > DEFAULT_MAX_SNAPSHOT_SKEW_MS:
            raise CoordinatorError("desired mode file is from the future")
        if max(0, current_ms - updated_ms) > max_age_ms:
            raise CoordinatorError("desired mode file is stale")
    return _normalize_mode(value.get("mode"))


def _run_watch_loop(
    coordinator: EpochCoordinator,
    desired_mode_file: Path,
    audit_log: Path | None,
    interval: float,
    max_desired_mode_age_ms: int,
    stopping: threading.Event,
) -> int:
    cleanup_ok = False
    try:
        while not stopping.is_set():
            desired_error = ""
            try:
                desired_mode = _read_desired_mode(
                    desired_mode_file,
                    max_desired_mode_age_ms,
                )
            except (CoordinatorError, OSError, json.JSONDecodeError) as error:
                desired_mode = "bypass"
                desired_error = f"{type(error).__name__}:{error}"
            result = coordinator.reconcile(desired_mode)
            _emit(result, audit_log, desired_input_error=desired_error)
            stopping.wait(interval)
    finally:
        try:
            shutdown_result = coordinator.reconcile_shutdown()
            cleanup_ok = (
                shutdown_result.effective_mode == "bypass"
                and shutdown_result.exit_code != 1
            )
        except (
            CoordinatorError,
            GateError,
            OSError,
            subprocess.TimeoutExpired,
            json.JSONDecodeError,
        ) as error:
            print(
                "openstack_epoch_coordinator: shutdown BYPASS failed: "
                f"{type(error).__name__}:{error}",
                file=sys.stderr,
            )
        else:
            try:
                _emit(shutdown_result, audit_log, shutdown=True)
            except OSError as error:
                cleanup_ok = False
                print(
                    "openstack_epoch_coordinator: shutdown audit failed: "
                    f"{error}",
                    file=sys.stderr,
                )
    return 0 if cleanup_ok else 1


@dataclass(frozen=True)
class _CommitWaitAssessment:
    ready: bool
    reason: str
    epoch: int = 0
    present_readbacks: int = 0


def _read_wait_runtime_state(path: Path) -> RuntimeState:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise CoordinatorError("runtime state has unsupported schema")
    mode = _normalize_mode(value.get("mode"))
    epoch = value.get("epoch")
    known = value.get("known")
    if (
        isinstance(epoch, bool)
        or not isinstance(epoch, int)
        or epoch < 0
        or not isinstance(known, bool)
    ):
        raise CoordinatorError("runtime state has invalid fields")
    return RuntimeState(mode, epoch, known)


def _read_audit_tail(path: Path) -> list[dict[str, Any]]:
    with path.open("rb") as stream:
        stream.seek(0, os.SEEK_END)
        size = stream.tell()
        start = max(0, size - _AUDIT_TAIL_LIMIT)
        stream.seek(start)
        data = stream.read()
    if start > 0:
        newline = data.find(b"\n")
        data = b"" if newline < 0 else data[newline + 1 :]
    if not data:
        return []
    lines = data.splitlines()
    records: list[dict[str, Any]] = []
    for index, line in enumerate(lines):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError):
            if index == len(lines) - 1 and not data.endswith(b"\n"):
                continue
            raise CoordinatorError("audit log contains invalid JSON")
        if not isinstance(value, dict):
            raise CoordinatorError("audit log record must be an object")
        records.append(value)
    return records


def _readback_contract_matches(
    value: dict[str, Any], publisher: PublisherEndpoint
) -> bool:
    return (
        value.get("endpoint") == publisher.name
        and value.get("host") == publisher.host
        and value.get("server_id") == publisher.server_id
        and value.get("port_id") == publisher.port_id
        and value.get("actor_id") == publisher.actor_id
        and value.get("target_kind") == publisher.target_kind
        and value.get("services") == list(publisher.services)
        and value.get("cache_role") == publisher.cache_role
    )


def _bypass_rebase_publication_error(
    record: dict[str, Any], config: CoordinatorConfig, epoch: int
) -> str:
    publications = record.get("publications")
    if not isinstance(publications, list) or not all(
        isinstance(item, dict) for item in publications
    ):
        return "audit_bypass_rebase_publications_invalid"
    force_by_endpoint: dict[str, dict[str, Any]] = {}
    for item in publications:
        if item.get("operation") != "force-bypass":
            continue
        endpoint = item.get("endpoint")
        if not isinstance(endpoint, str) or endpoint in force_by_endpoint:
            return "audit_bypass_rebase_force_set_mismatch"
        force_by_endpoint[endpoint] = item
    expected = {publisher.name for publisher in config.publishers}
    if set(force_by_endpoint) != expected:
        return "audit_bypass_rebase_force_set_mismatch"
    for endpoint, item in force_by_endpoint.items():
        publication_epoch = item.get("epoch")
        returncode = item.get("returncode")
        if (
            item.get("mode") != "bypass"
            or isinstance(publication_epoch, bool)
            or not isinstance(publication_epoch, int)
            or publication_epoch != epoch
            or isinstance(returncode, bool)
            or not isinstance(returncode, int)
            or returncode != 0
        ):
            return f"audit_bypass_rebase_force_invalid:{endpoint}"
    return ""


def _assess_committed_audit(
    records: Sequence[dict[str, Any]],
    config: CoordinatorConfig,
    target_mode: str,
    epoch: int,
    min_present_readbacks: int,
    require_shutdown: bool,
) -> _CommitWaitAssessment:
    expected_publishers = {item.name: item for item in config.publishers}
    matching_epoch_seen = False
    last_reason = "audit_has_no_matching_publication"
    for record in reversed(records):
        state = record.get("state")
        if not isinstance(state, dict):
            continue
        audit_epoch = state.get("epoch")
        audit_known = state.get("known")
        if (
            isinstance(audit_epoch, bool)
            or not isinstance(audit_epoch, int)
            or audit_epoch < 0
            or not isinstance(audit_known, bool)
        ):
            matching_epoch_seen = True
            last_reason = "audit_state_fields_invalid"
            continue
        if audit_epoch != epoch:
            continue
        matching_epoch_seen = True
        if require_shutdown and record.get("shutdown") is not True:
            last_reason = "audit_shutdown_proof_missing"
            continue
        outcome = record.get("outcome")
        bypass_rebase = (
            target_mode == "bypass" and outcome == "policy_unchanged"
        )
        if outcome != "policy_published" and not bypass_rebase:
            last_reason = "audit_outcome_not_policy_published"
            continue
        if (
            record.get("requested_mode") != target_mode
            or record.get("effective_mode") != target_mode
            or record.get("exit_code") != 0
        ):
            last_reason = "audit_publication_result_mismatch"
            continue
        desired_input_error = record.get("desired_input_error")
        desired_error_present = (
            desired_input_error not in (None, "")
            if require_shutdown
            else desired_input_error != ""
        )
        if desired_error_present or record.get("state_input_error") != "":
            last_reason = "audit_input_error_present"
            continue
        if (
            state.get("mode") != target_mode
            or not audit_known
        ):
            last_reason = "audit_state_mismatch"
            continue
        if bypass_rebase:
            rebase_error = _bypass_rebase_publication_error(
                record, config, epoch
            )
            if rebase_error:
                last_reason = rebase_error
                continue
        gate = record.get("gate")
        if not isinstance(gate, dict) or (
            gate.get("action"), gate.get("reason")
        ) != ("publish", "all_required_endpoints_healthy"):
            last_reason = "audit_gate_not_healthy_publish"
            continue
        readbacks = record.get("map_readbacks")
        if not isinstance(readbacks, list) or not all(
            isinstance(item, dict) for item in readbacks
        ):
            last_reason = "audit_readbacks_invalid"
            continue
        by_endpoint: dict[str, dict[str, Any]] = {}
        duplicate = False
        for item in readbacks:
            endpoint = item.get("endpoint")
            if not isinstance(endpoint, str) or endpoint in by_endpoint:
                duplicate = True
                break
            by_endpoint[endpoint] = item
        if duplicate or set(by_endpoint) != set(expected_publishers):
            last_reason = "audit_readback_set_mismatch"
            continue
        present_count = 0
        readback_error = ""
        for endpoint, publisher in expected_publishers.items():
            item = by_endpoint[endpoint]
            if not _readback_contract_matches(item, publisher):
                readback_error = f"audit_readback_contract_mismatch:{endpoint}"
                break
            present = item.get("present")
            maps = item.get("maps")
            readback_epoch = item.get("epoch")
            mode = item.get("mode")
            flags = item.get("flags")
            numeric = (maps, readback_epoch, mode, flags)
            if not isinstance(present, bool) or any(
                isinstance(value, bool) or not isinstance(value, int)
                for value in numeric
            ):
                readback_error = f"audit_readback_fields_invalid:{endpoint}"
                break
            if present:
                if (
                    maps <= 0
                    or maps != len(publisher.services)
                    or readback_epoch != epoch
                    or mode != _MODE_VALUES[target_mode]
                    or flags != _COMMITTED_FLAG
                ):
                    readback_error = (
                        f"audit_present_readback_not_committed:{endpoint}"
                    )
                    break
                present_count += 1
            elif (maps, readback_epoch, mode, flags) != (0, 0, 0, 0):
                readback_error = f"audit_absent_readback_not_zero:{endpoint}"
                break
        if readback_error:
            last_reason = readback_error
            continue
        if present_count < min_present_readbacks:
            last_reason = (
                f"audit_present_readbacks_below_minimum:{present_count}:"
                f"{min_present_readbacks}"
            )
            continue
        return _CommitWaitAssessment(True, "committed", epoch, present_count)
    if matching_epoch_seen:
        return _CommitWaitAssessment(False, last_reason)
    return _CommitWaitAssessment(False, "audit_has_no_matching_publication")


def _assess_committed_epoch(
    config: CoordinatorConfig,
    desired_mode_file: Path,
    state_file: Path,
    audit_log: Path,
    target_mode: str,
    after_epoch: int,
    min_present_readbacks: int,
    require_shutdown: bool,
) -> _CommitWaitAssessment:
    if not require_shutdown:
        try:
            desired = _read_desired_mode(desired_mode_file)
        except FileNotFoundError:
            return _CommitWaitAssessment(False, "desired_mode_missing")
        except (OSError, CoordinatorError, json.JSONDecodeError) as error:
            return _CommitWaitAssessment(
                False, f"desired_mode_invalid:{type(error).__name__}:{error}"
            )
        if desired != target_mode:
            return _CommitWaitAssessment(
                False, f"desired_mode_mismatch:{desired}:{target_mode}"
            )
    try:
        state = _read_wait_runtime_state(state_file)
    except FileNotFoundError:
        return _CommitWaitAssessment(False, "runtime_state_missing")
    except (OSError, CoordinatorError, json.JSONDecodeError) as error:
        return _CommitWaitAssessment(
            False, f"runtime_state_invalid:{type(error).__name__}:{error}"
        )
    if not state.known:
        return _CommitWaitAssessment(False, "runtime_state_unknown")
    if state.mode != target_mode:
        return _CommitWaitAssessment(
            False, f"runtime_mode_mismatch:{state.mode}:{target_mode}"
        )
    if state.epoch <= after_epoch:
        return _CommitWaitAssessment(
            False, f"runtime_epoch_not_fresh:{state.epoch}:{after_epoch}"
        )
    try:
        records = _read_audit_tail(audit_log)
    except FileNotFoundError:
        return _CommitWaitAssessment(False, "audit_log_missing")
    except (OSError, CoordinatorError) as error:
        return _CommitWaitAssessment(
            False, f"audit_log_invalid:{type(error).__name__}:{error}"
        )
    return _assess_committed_audit(
        records,
        config,
        target_mode,
        state.epoch,
        min_present_readbacks,
        require_shutdown,
    )


def _run_wait_committed(
    config: CoordinatorConfig,
    desired_mode_file: Path,
    state_file: Path,
    audit_log: Path,
    target_mode: str,
    after_epoch: int,
    min_present_readbacks: int,
    timeout: float,
    interval: float,
    require_shutdown: bool,
) -> int:
    deadline = time.monotonic() + timeout
    last = _CommitWaitAssessment(False, "not_checked")
    while True:
        last = _assess_committed_epoch(
            config,
            desired_mode_file,
            state_file,
            audit_log,
            target_mode,
            after_epoch,
            min_present_readbacks,
            require_shutdown,
        )
        if last.ready:
            output = {
                "ready": True,
                "mode": target_mode,
                "epoch": last.epoch,
                "present_readbacks": last.present_readbacks,
            }
            if require_shutdown:
                output["shutdown"] = True
            print(
                json.dumps(
                    output,
                    sort_keys=True,
                    separators=(",", ":"),
                ),
                flush=True,
            )
            return 0
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print(
                "openstack_epoch_coordinator: wait-committed timeout: "
                f"{last.reason}",
                file=sys.stderr,
            )
            return 1
        time.sleep(min(interval, remaining))


def main() -> int:
    args = _parser().parse_args()
    try:
        config = load_config(args.config)
        if args.command == "wait-committed":
            target_mode = _normalize_mode(args.target_mode)
            if args.after_epoch < 0:
                raise CoordinatorError("after-epoch must be non-negative")
            if args.min_present_readbacks <= 0:
                raise CoordinatorError(
                    "min-present-readbacks must be positive"
                )
            if args.min_present_readbacks > len(config.publishers):
                raise CoordinatorError(
                    "min-present-readbacks exceeds configured publishers"
                )
            if args.timeout <= 0:
                raise CoordinatorError("timeout must be positive")
            if args.interval <= 0:
                raise CoordinatorError("interval must be positive")
            if args.require_shutdown and target_mode != "bypass":
                raise CoordinatorError(
                    "require-shutdown is valid only for BYPASS"
                )
            return _run_wait_committed(
                config,
                args.desired_mode_file,
                args.state_file,
                args.audit_log,
                target_mode,
                args.after_epoch,
                args.min_present_readbacks,
                args.timeout,
                args.interval,
                args.require_shutdown,
            )
        coordinator = EpochCoordinator(
            config,
            args.state_file,
            initial_epoch=args.initial_epoch,
        )
        if args.command == "once":
            result = coordinator.reconcile(args.desired_mode)
            _emit(result, args.audit_log)
            return result.exit_code
        if args.interval <= 0:
            raise CoordinatorError("interval must be positive")
        stopping = threading.Event()

        def request_stop(_signum: int, _frame: Any) -> None:
            stopping.set()

        signal.signal(signal.SIGINT, request_stop)
        signal.signal(signal.SIGTERM, request_stop)
        return _run_watch_loop(
            coordinator,
            args.desired_mode_file,
            args.audit_log,
            args.interval,
            config.max_desired_mode_age_ms,
            stopping,
        )
    except (CoordinatorError, GateError, OSError, json.JSONDecodeError) as error:
        print(f"openstack_epoch_coordinator: {error}", file=sys.stderr)
        return 1


def _normalize_mode(value: Any) -> str:
    if not isinstance(value, str):
        raise CoordinatorError("cache mode must be a string")
    mode = value.strip().lower().replace("_cache", "")
    if mode not in _MODES:
        raise CoordinatorError(f"unsupported cache mode: {value}")
    return mode


def _all_succeeded(records: Sequence[PublishRecord]) -> bool:
    return bool(records) and all(item.returncode == 0 for item in records)


def _command_detail(result: CommandResult) -> str:
    return (result.stderr.strip() or result.stdout.strip())[:400]


def _parse_map_readback(endpoint: PublisherEndpoint, text: str) -> MapReadback:
    value = json.loads(text)
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise CoordinatorError(
            f"publisher {endpoint.name} returned unsupported read-current schema"
        )
    present = value.get("present")
    maps = value.get("maps")
    epoch = value.get("epoch")
    mode = value.get("mode")
    flags = value.get("flags")
    if not isinstance(present, bool):
        raise CoordinatorError(
            f"publisher {endpoint.name} returned invalid present"
        )
    numeric_fields = (maps, epoch, mode, flags)
    if any(isinstance(item, bool) for item in numeric_fields) or (
        not isinstance(maps, int)
        or maps < 0
        or not isinstance(epoch, int)
        or epoch < 0
        or not isinstance(mode, int)
        or mode < 0
        or not isinstance(flags, int)
        or flags < 0
    ):
        raise CoordinatorError(
            f"publisher {endpoint.name} returned invalid read-current fields"
        )
    if present != (maps > 0):
        raise CoordinatorError(
            f"publisher {endpoint.name} returned inconsistent map presence"
        )
    if present and maps != len(endpoint.services):
        raise CoordinatorError(
            f"publisher {endpoint.name} returned map count that does not "
            "match declared services"
        )
    if not present and (epoch != 0 or mode != 0 or flags != 0):
        raise CoordinatorError(
            f"publisher {endpoint.name} returned values for missing maps"
        )
    return MapReadback(
        endpoint.name,
        endpoint.host,
        endpoint.server_id,
        endpoint.port_id,
        endpoint.actor_id,
        endpoint.target_kind,
        endpoint.services,
        endpoint.cache_role,
        present,
        maps,
        epoch,
        mode,
        flags,
    )


def _is_confirmed(
    assessment: _ReadbackAssessment,
    mode: str,
    *,
    exact_epoch: int | None = None,
    minimum_epoch: int | None = None,
) -> bool:
    if not assessment.complete or not assessment.any_present:
        return False
    if not assessment.state.known or assessment.state.mode != mode:
        return False
    if exact_epoch is not None and assessment.state.epoch != exact_epoch:
        return False
    if minimum_epoch is not None and assessment.state.epoch < minimum_epoch:
        return False
    return True


def _join_errors(*values: str) -> str:
    return ";".join(value for value in values if value)


def _short_host(value: str) -> str:
    normalized = value.strip().lower()
    try:
        return str(ipaddress.ip_address(normalized))
    except ValueError:
        return normalized.split(".", 1)[0]


def _required_list(value: dict[str, Any], field: str) -> list[Any]:
    result = value.get(field)
    if not isinstance(result, list) or not result:
        raise CoordinatorError(f"{field} must be a non-empty list")
    return result


def _required_text(value: dict[str, Any], field: str) -> str:
    result = value.get(field)
    if not isinstance(result, str) or not result.strip():
        raise CoordinatorError(f"{field} must be a non-empty string")
    return result.strip()


def _command_list(value: Any, name: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value or not all(
        isinstance(item, str) and item for item in value
    ):
        raise CoordinatorError(f"command for {name} must be a non-empty string list")
    return tuple(value)


def _validate_publisher_command(
    name: str,
    host: str,
    port_id: str,
    command: Sequence[str],
    policy_lock_root: PurePosixPath,
    services: Sequence[str],
) -> None:
    shell_control = set(" \t\r\n;|&<>$`(){}[]*?!#'\"\\")
    if any(any(character in shell_control for character in item) for item in command):
        raise CoordinatorError(
            f"publisher {name} command contains shell control characters"
        )
    executables = [
        PurePosixPath(argument).name
        for argument in command
        if argument and not argument.startswith("-")
    ]
    blocked = {
        "bash",
        "cmd",
        "dash",
        "env",
        "powershell",
        "pwsh",
        "python",
        "python3",
        "sh",
        "zsh",
    }
    wrapper = next((item for item in executables if item.lower() in blocked), None)
    if wrapper is not None:
        raise CoordinatorError(
            f"publisher {name} must not use interpreter wrapper: {wrapper}"
        )
    if executables.count("cache_policy_txn") != 1:
        raise CoordinatorError(
            f"publisher {name} must invoke cache_policy_txn exactly once"
        )
    first = PurePosixPath(command[0]).name
    if not PurePosixPath(command[0]).is_absolute():
        raise CoordinatorError(
            f"publisher {name} executable path must be absolute"
        )
    transaction_index = next(
        index
        for index, argument in enumerate(command)
        if PurePosixPath(argument).name == "cache_policy_txn"
    )
    if first == "cache_policy_txn":
        if transaction_index != 0:
            raise CoordinatorError(
                f"publisher {name} has an invalid local transaction command"
            )
        _validate_transaction_arguments(
            name,
            port_id,
            command[1:],
            policy_lock_root,
            services,
        )
        return
    if first != "ssh":
        raise CoordinatorError(
            f"publisher {name} must directly invoke cache_policy_txn or ssh"
        )
    expected_prefix_length = 12
    if transaction_index != expected_prefix_length:
        raise CoordinatorError(
            f"remote publisher {name} must use the fixed ssh command prefix"
        )
    if command[1:3] != ("-o", "BatchMode=yes"):
        raise CoordinatorError(
            f"remote publisher {name} must require BatchMode=yes"
        )
    if command[3:5] != ("-o", "StrictHostKeyChecking=yes"):
        raise CoordinatorError(
            f"remote publisher {name} must require strict host-key checking"
        )
    known_hosts_prefix = "UserKnownHostsFile="
    if command[5] != "-o" or not command[6].startswith(known_hosts_prefix):
        raise CoordinatorError(
            f"remote publisher {name} must use a pinned known-hosts file"
        )
    known_hosts_file = PurePosixPath(
        command[6][len(known_hosts_prefix) :]
    )
    if (
        not known_hosts_file.is_absolute()
        or known_hosts_file.parent != SSH_KNOWN_HOSTS_ROOT
    ):
        raise CoordinatorError(
            f"remote publisher {name} known-hosts file must be a direct child "
            f"of {SSH_KNOWN_HOSTS_ROOT}"
        )
    if command[7:9] != ("-o", "HostKeyAlgorithms=ssh-ed25519"):
        raise CoordinatorError(
            f"remote publisher {name} must pin the ed25519 host-key algorithm"
        )
    if _short_host(command[9]) != host:
        raise CoordinatorError(
            f"remote publisher {name} ssh destination must match its host"
        )
    if (
        PurePosixPath(command[10]).name != "sudo"
        or not PurePosixPath(command[10]).is_absolute()
        or command[11] != "-n"
    ):
        raise CoordinatorError(
            f"remote publisher {name} must invoke sudo -n cache_policy_txn"
        )
    if not PurePosixPath(command[transaction_index]).is_absolute():
        raise CoordinatorError(
            f"remote publisher {name} transaction path must be absolute"
        )
    _validate_transaction_arguments(
        name,
        port_id,
        command[transaction_index + 1 :],
        policy_lock_root,
        services,
    )


def _validate_transaction_arguments(
    name: str,
    port_id: str,
    arguments: Sequence[str],
    policy_lock_root: PurePosixPath,
    services: Sequence[str],
) -> None:
    if arguments.count("--allow-all-missing") != 1:
        raise CoordinatorError(
            f"publisher {name} must opt in to all-missing map handling"
        )
    if arguments.count("--lock-file") != 1:
        raise CoordinatorError(f"publisher {name} must configure one lock file")
    lock_index = arguments.index("--lock-file")
    if lock_index + 1 >= len(arguments) or not PurePosixPath(
        arguments[lock_index + 1]
    ).is_absolute():
        raise CoordinatorError(f"publisher {name} lock file must be absolute")
    expected_lock = policy_lock_root / f"vnet-dataplane-{port_id}.lock"
    if PurePosixPath(arguments[lock_index + 1]) != expected_lock:
        raise CoordinatorError(
            f"publisher {name} lock file does not match policy_lock_root and port_id"
        )
    if arguments.count("--quiesce-file") != 1:
        raise CoordinatorError(
            f"publisher {name} must configure one quiesce file"
        )
    quiesce_index = arguments.index("--quiesce-file")
    if quiesce_index + 1 >= len(arguments) or not PurePosixPath(
        arguments[quiesce_index + 1]
    ).is_absolute():
        raise CoordinatorError(
            f"publisher {name} quiesce file must be absolute"
        )
    expected_quiesce = (
        policy_lock_root / f"vnet-dataplane-{port_id}.quiesce"
    )
    if PurePosixPath(arguments[quiesce_index + 1]) != expected_quiesce:
        raise CoordinatorError(
            f"publisher {name} quiesce file does not match "
            "policy_lock_root and port_id"
        )
    map_paths = [
        arguments[index + 1]
        for index, value in enumerate(arguments)
        if value == "--control-map" and index + 1 < len(arguments)
    ]
    if not map_paths or len(map_paths) != arguments.count("--control-map"):
        raise CoordinatorError(
            f"publisher {name} must configure at least one control map"
        )
    if len(map_paths) != len(set(map_paths)) or any(
        not PurePosixPath(path).is_absolute() for path in map_paths
    ):
        raise CoordinatorError(
            f"publisher {name} control maps must be unique absolute paths"
        )
    observed_services: set[str] = set()
    for path in map_paths:
        parts = PurePosixPath(path).parts
        if (
            len(parts) < 4
            or parts[-1] != "cache_runtime_control"
            or parts[-3] != port_id
            or parts[-2] not in {"dns", "grpc"}
        ):
            raise CoordinatorError(
                f"publisher {name} control map does not match port_id"
            )
        observed_services.add(parts[-2])
    declared_services = set(services)
    if (
        observed_services != declared_services
        or len(map_paths) != len(declared_services)
    ):
        raise CoordinatorError(
            f"publisher {name} control maps do not match declared services"
        )


def _validate_no_publisher_path_aliases(
    publishers: Sequence[PublisherEndpoint],
) -> None:
    owners: dict[tuple[str, str], tuple[str, str]] = {}
    for publisher in publishers:
        transaction_index = next(
            index
            for index, argument in enumerate(publisher.command)
            if PurePosixPath(argument).name == "cache_policy_txn"
        )
        arguments = publisher.command[transaction_index + 1 :]
        paths: list[str] = []
        for option in ("--lock-file", "--quiesce-file", "--control-map"):
            paths.extend(
                arguments[index + 1]
                for index, value in enumerate(arguments)
                if value == option and index + 1 < len(arguments)
            )
        identity = (publisher.actor_id, publisher.target_kind)
        for path in paths:
            key = (publisher.host, path)
            owner = owners.setdefault(key, identity)
            if owner != identity:
                raise CoordinatorError(
                    f"publisher path alias on host {publisher.host}: {path}"
                )


def _require_unique(values: Sequence[str], kind: str) -> None:
    if len(values) != len(set(values)):
        raise CoordinatorError(f"duplicate {kind} name")


if __name__ == "__main__":
    raise SystemExit(main())
