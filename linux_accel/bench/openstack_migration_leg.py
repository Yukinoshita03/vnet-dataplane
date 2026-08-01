#!/usr/bin/env python3
"""Execute and audit one directed OpenStack live-migration leg."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _normalized_key(value: str) -> str:
    return "".join(character.lower() for character in value if character.isalnum())


def _field(record: dict[str, Any], *names: str) -> Any:
    normalized = {_normalized_key(str(key)): value for key, value in record.items()}
    for name in names:
        key = _normalized_key(name)
        if key in normalized:
            return normalized[key]
    return None


def _as_text(value: str | bytes | None) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value or ""


class EvidenceLog:
    def __init__(self, directory: Path):
        directory.mkdir(parents=True, exist_ok=True)
        self.path = directory / "events.jsonl"

    def emit(self, event: str, **fields: Any) -> None:
        record = {"schema": 1, "timestamp": _utc_now(), "event": event, **fields}
        with self.path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")


class OpenStackCommandError(RuntimeError):
    pass


class MigrationDeadlineExceeded(RuntimeError):
    pass


class OpenStackClient:
    def __init__(
        self,
        binary: str,
        api_version: str,
        log: EvidenceLog,
        command_timeout: float,
    ):
        self._prefix = [binary, "--os-compute-api-version", api_version]
        self._log = log
        self._command_timeout = max(command_timeout, 0.001)
        self._deadline: float | None = None

    def set_deadline(self, deadline: float) -> None:
        self._deadline = deadline

    def run(self, arguments: Sequence[str], *, expect_json: bool = False) -> Any:
        command = [*self._prefix, *arguments]
        timeout = self._command_timeout
        if self._deadline is not None:
            remaining = self._deadline - time.monotonic()
            if remaining <= 0:
                raise MigrationDeadlineExceeded("migration deadline exceeded")
            timeout = min(timeout, remaining)
        try:
            result = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as error:
            self._log.emit(
                "openstack_command_timeout",
                command=command,
                timeout_seconds=timeout,
                stdout=_as_text(error.stdout),
                stderr=_as_text(error.stderr),
            )
            raise OpenStackCommandError(
                f"OpenStack command timed out after {timeout:g} seconds"
            ) from error
        except OSError as error:
            self._log.emit(
                "openstack_command_start_error",
                command=command,
                detail=str(error),
            )
            raise OpenStackCommandError(
                f"could not start OpenStack command: {error}"
            ) from error
        parsed: Any = None
        if result.stdout.strip():
            try:
                parsed = json.loads(result.stdout)
            except json.JSONDecodeError:
                parsed = None
        self._log.emit(
            "openstack_command",
            command=command,
            returncode=result.returncode,
            stdout=result.stdout,
            stderr=result.stderr,
            json=parsed,
        )
        if result.returncode != 0:
            raise OpenStackCommandError(
                result.stderr.strip() or f"command failed with {result.returncode}"
            )
        if expect_json and parsed is None:
            raise OpenStackCommandError("OpenStack command returned invalid JSON")
        return parsed if expect_json else result.stdout

    def migration_list(self, server_id: str) -> list[dict[str, Any]]:
        value = self.run(
            ["server", "migration", "list", "--server", server_id, "-f", "json"],
            expect_json=True,
        )
        if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
            raise OpenStackCommandError("server migration list did not return a JSON array")
        return value

    def server_show(self, server_id: str) -> dict[str, Any]:
        value = self.run(["server", "show", server_id, "-f", "json"], expect_json=True)
        if not isinstance(value, dict):
            raise OpenStackCommandError("server show did not return a JSON object")
        return value

    def port_show(self, port_id: str) -> dict[str, Any]:
        value = self.run(["port", "show", port_id, "-f", "json"], expect_json=True)
        if not isinstance(value, dict):
            raise OpenStackCommandError("port show did not return a JSON object")
        return value

    def start_live_migration(self, server_id: str, target_host: str) -> None:
        self.run(
            [
                "server",
                "migrate",
                "--live-migration",
                "--host",
                target_host,
                "--block-migration",
                server_id,
            ]
        )


def _migration_id(record: dict[str, Any]) -> str:
    value = _field(record, "id")
    return "" if value is None else str(value)


def _matching_migration(
    migrations: list[dict[str, Any]],
    baseline_ids: set[str],
    source_host: str,
    target_host: str,
) -> dict[str, Any] | None:
    for migration in migrations:
        if _migration_id(migration) in baseline_ids:
            continue
        migration_type = str(_field(migration, "type", "migration type") or "").lower()
        source = str(_field(migration, "source node", "source compute") or "")
        destination = str(_field(migration, "dest node", "destination node", "dest compute") or "")
        if migration_type == "live-migration" and source == source_host and destination == target_host:
            return migration
    return None


def _host(record: dict[str, Any], *names: str) -> str:
    return str(_field(record, *names) or "")


def _live_migration_in_flight(migrations: list[dict[str, Any]]) -> bool:
    terminal = {
        "completed",
        "error",
        "failed",
        "cancel",
        "canceled",
        "cancelled",
    }
    for migration in migrations:
        migration_type = str(
            _field(migration, "type", "migration type") or ""
        ).lower()
        status = str(_field(migration, "status") or "").lower()
        if migration_type == "live-migration" and status not in terminal:
            return True
    return False


def _write_summary(directory: Path, summary: dict[str, Any]) -> None:
    (directory / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _failed(
    args: argparse.Namespace,
    log: EvidenceLog,
    started: float,
    reason: str,
    detail: str,
    migration_id: str | None = None,
) -> int:
    summary = {
        "schema": 1,
        "phase": args.phase,
        "status": "failed",
        "outcome": "failed",
        "reason": reason,
        "detail": detail,
        "server_id": args.server_id,
        "port_id": args.port_id,
        "source_host": args.source_host,
        "requested_source_host": getattr(
            args, "requested_source_host", args.source_host
        ),
        "target_host": args.target_host,
        "final_host": None,
        "migration_id": migration_id,
        "duration_ms": round((time.monotonic() - started) * 1000),
    }
    log.emit("migration_failed", **summary)
    _write_summary(args.evidence_dir, summary)
    print(json.dumps(summary, sort_keys=True))
    return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--phase", required=True, choices=("forward", "reverse", "restore")
    )
    parser.add_argument("--server-id", required=True)
    parser.add_argument("--port-id", required=True)
    parser.add_argument("--source-host", required=True)
    parser.add_argument("--target-host", required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--openstack-bin", default="openstack")
    parser.add_argument("--api-version", default="2.30")
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument("--command-timeout", type=float, default=30.0)
    parser.add_argument("--poll", type=float, default=2.0)
    return parser


def _run(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    args.requested_source_host = args.source_host
    started = time.monotonic()
    log = EvidenceLog(args.evidence_dir)
    client = OpenStackClient(
        args.openstack_bin, args.api_version, log, args.command_timeout
    )
    deadline = started + args.timeout
    client.set_deadline(deadline)
    server = client.server_show(args.server_id)
    port = client.port_show(args.port_id)
    server_status = _host(server, "status").upper()
    server_host = _host(server, "OS-EXT-SRV-ATTR:host", "host")
    port_status = _host(port, "status").upper()
    port_host = _host(port, "binding_host_id", "binding:host_id")
    log.emit(
        "source_placement",
        phase=args.phase,
        server_status=server_status,
        server_host=server_host,
        port_status=port_status,
        port_host=port_host,
    )
    if args.phase == "restore":
        stable_host = ""
        stable_observations = 0
        while True:
            if server_status == "ERROR":
                break
            migrations = client.migration_list(args.server_id)
            in_flight = _live_migration_in_flight(migrations)
            placement_ready = (
                server_status == "ACTIVE"
                and port_status == "ACTIVE"
                and bool(server_host)
                and server_host == port_host
            )
            if placement_ready and not in_flight:
                if stable_host == server_host:
                    stable_observations += 1
                else:
                    stable_host = server_host
                    stable_observations = 1
            else:
                stable_host = ""
                stable_observations = 0
            log.emit(
                "restore_placement_observation",
                server_status=server_status,
                server_host=server_host,
                port_status=port_status,
                port_host=port_host,
                live_migration_in_flight=in_flight,
                stable_observations=stable_observations,
            )
            if stable_observations >= 2:
                break
            if time.monotonic() >= deadline:
                return _failed(
                    args,
                    log,
                    started,
                    "restore_placement_timeout",
                    (
                        "restore source did not reach two stable observations: "
                        f"server={server_status}/{server_host},"
                        f"port={port_status}/{port_host}"
                    ),
                )
            time.sleep(args.poll)
            server = client.server_show(args.server_id)
            port = client.port_show(args.port_id)
            server_status = _host(server, "status").upper()
            server_host = _host(server, "OS-EXT-SRV-ATTR:host", "host")
            port_status = _host(port, "status").upper()
            port_host = _host(port, "binding_host_id", "binding:host_id")
    if server_status == "ERROR":
        return _failed(
            args,
            log,
            started,
            "server_status_error",
            "OpenStack server is already in ERROR state",
        )
    if args.phase == "restore":
        if (
            server_status == "ACTIVE"
            and server_host == args.target_host
            and port_status == "ACTIVE"
            and port_host == args.target_host
        ):
            summary = {
                "schema": 1,
                "phase": args.phase,
                "status": "completed",
                "outcome": "already_on_target",
                "server_id": args.server_id,
                "port_id": args.port_id,
                "source_host": args.source_host,
                "requested_source_host": args.requested_source_host,
                "target_host": args.target_host,
                "final_host": args.target_host,
                "migration_id": None,
                "duration_ms": round((time.monotonic() - started) * 1000),
            }
            log.emit("migration_already_on_target", **summary)
            _write_summary(args.evidence_dir, summary)
            print(json.dumps(summary, sort_keys=True))
            return 0
        if (
            server_status == "ACTIVE"
            and port_status == "ACTIVE"
            and server_host
            and server_host == port_host
            and server_host != args.target_host
            and server_host != args.source_host
        ):
            log.emit(
                "restore_source_reconciled",
                requested_source_host=args.source_host,
                observed_source_host=server_host,
                target_host=args.target_host,
            )
            args.source_host = server_host
    if (
        server_status != "ACTIVE"
        or server_host != args.source_host
        or port_status != "ACTIVE"
        or port_host != args.source_host
    ):
        return _failed(
            args,
            log,
            started,
            "source_placement_mismatch",
            (
                "source placement does not match request: "
                f"server={server_status}/{server_host},"
                f"port={port_status}/{port_host},expected={args.source_host}"
            ),
        )
    baseline = client.migration_list(args.server_id)
    baseline_ids = {_migration_id(record) for record in baseline}
    log.emit("migration_baseline", phase=args.phase, migration_ids=sorted(baseline_ids))
    client.start_live_migration(args.server_id, args.target_host)
    log.emit("migration_requested", phase=args.phase, source_host=args.source_host, target_host=args.target_host)

    while time.monotonic() <= deadline:
        migration = _matching_migration(
            client.migration_list(args.server_id),
            baseline_ids,
            args.source_host,
            args.target_host,
        )
        server = client.server_show(args.server_id)
        port = client.port_show(args.port_id)
        server_status = _host(server, "status").upper()
        server_host = _host(server, "OS-EXT-SRV-ATTR:host", "host")
        port_status = _host(port, "status").upper()
        port_host = _host(port, "binding_host_id", "binding:host_id")
        if server_status == "ERROR":
            return _failed(
                args,
                log,
                started,
                "server_status_error",
                "OpenStack server entered ERROR state",
                _migration_id(migration) if migration is not None else None,
            )
        if migration is not None:
            status = str(_field(migration, "status") or "").lower()
            if status in {"error", "failed"}:
                return _failed(
                    args,
                    log,
                    started,
                    f"migration_status_{status}",
                    f"OpenStack reported terminal migration status {status}",
                    _migration_id(migration),
                )
            if status in {"cancel", "canceled", "cancelled"}:
                return _failed(
                    args,
                    log,
                    started,
                    "migration_status_cancelled",
                    f"OpenStack reported terminal migration status {status}",
                    _migration_id(migration),
                )
            if (
                status == "completed"
                and server_status == "ACTIVE"
                and server_host == args.target_host
                and port_status == "ACTIVE"
                and port_host == args.target_host
            ):
                summary = {
                    "schema": 1,
                    "phase": args.phase,
                    "status": "completed",
                    "outcome": "completed",
                    "server_id": args.server_id,
                    "port_id": args.port_id,
                    "source_host": args.source_host,
                    "requested_source_host": args.requested_source_host,
                    "target_host": args.target_host,
                    "final_host": args.target_host,
                    "migration_id": _migration_id(migration),
                    "duration_ms": round((time.monotonic() - started) * 1000),
                }
                log.emit("migration_completed", **summary)
                _write_summary(args.evidence_dir, summary)
                print(json.dumps(summary, sort_keys=True))
                return 0
        time.sleep(args.poll)
    return _failed(
        args,
        log,
        started,
        "timeout",
        f"migration did not converge within {args.timeout:g} seconds",
    )


def main(argv: Sequence[str] | None = None) -> int:
    try:
        return _run(argv)
    except MigrationDeadlineExceeded as error:
        args = build_parser().parse_args(argv)
        return _failed(
            args,
            EvidenceLog(args.evidence_dir),
            time.monotonic(),
            "timeout",
            str(error),
        )
    except OpenStackCommandError as error:
        args = build_parser().parse_args(argv)
        return _failed(
            args,
            EvidenceLog(args.evidence_dir),
            time.monotonic(),
            "openstack_command_error",
            str(error),
        )


if __name__ == "__main__":
    sys.exit(main())
