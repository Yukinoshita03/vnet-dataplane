#!/usr/bin/env python3
"""Stage an isolated shared-cluster deployment without activating services."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import importlib.util
import json
import math
import os
import re
import secrets
import shlex
import stat
import subprocess
import sys
import tempfile
import zlib
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Sequence


SCHEMA_VERSION = 1
ROLES = ("controller", "source", "target")
STAGE_ORDER = ("source", "target", "controller")
ROLE_UNITS = {
    "controller": (
        "vnet-dataplane-shared-epoch-coordinator.service",
        "vnet-dataplane-shared-metrics-controller.service",
    ),
    "source": ("vnet-dataplane-shared-agent.service",),
    "target": ("vnet-dataplane-shared-agent.service",),
}
UNIT_TARGETS = {
    name: f"/etc/systemd/system/{name}"
    for names in ROLE_UNITS.values()
    for name in names
}
PENDING_SUDOERS_TARGET = (
    "/etc/vnet-dataplane-shared/vnet-dataplane-shared.sudoers.pending"
)
ACTIVATION_MARKER = "/run/vnet-dataplane-shared-activation/approved"
ALLOWED_MODES = {"0440", "0600", "0640", "0644", "0700", "0750", "0755"}
_SHA256_RE = re.compile(r"[0-9a-f]{64}")
_BACKUP_ID_RE = re.compile(
    r"codex-backup-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}-[0-9a-f]{32}"
)
PREFLIGHT_SNAPSHOT_COMMAND_COUNT = 19
PREFLIGHT_MAX_SNAPSHOT_SECONDS = 60.0
REQUIRED_PREFLIGHT_GATES = frozenset(
    {
        "inventory.valid",
        "host_key.controller",
        "host_key.source",
        "host_key.target",
        "snapshot.confirmed",
        "commands.success",
        "hostname.controller",
        "hostname.source",
        "hostname.target",
        "clock.synchronized",
        "sessions.clear",
        "nova.services",
        "neutron.agents",
        "migrations.idle",
        "workloads.clear",
        "resources.servers",
        "resources.ports",
        "capacity.target",
        "ovs.source",
        "tap.source",
        "ovs.target",
        "tap.target",
    }
)
ACTIVATION_PENDING_GATES = (
    "runtime_host_keys_verified",
    "runtime_pin_state_cleanup_verified",
    "runtime_sudoers_activation_authorized",
    "systemd_manager_reload_authorized",
    "activation_receipt_published",
    "resource_specific_start_authorized",
)


class DeploymentError(RuntimeError):
    """The requested stage operation cannot meet its safety contract."""


class StageDeploymentError(DeploymentError):
    """A remote stage failed and may require an exact manifest rollback."""

    def __init__(
        self,
        message: str,
        *,
        backup_id: str,
        failed_role: str,
        rollback_incomplete: bool,
    ):
        super().__init__(message)
        self.backup_id = backup_id
        self.failed_role = failed_role
        self.rollback_incomplete = rollback_incomplete


class RollbackDeploymentError(DeploymentError):
    """An explicit rollback could not restore every staged node."""

    def __init__(self, backup_id: str, nodes: list[dict[str, Any]]):
        super().__init__("shared rollback is incomplete")
        self.backup_id = backup_id
        self.nodes = nodes


class UnsafeEvidencePathError(DeploymentError):
    """The requested evidence path could overwrite a recovery credential."""


class RunnerError(RuntimeError):
    """The SSH boundary failed without exposing remote output."""


_REMOTE_HELPER_SOURCE = r'''
import base64
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile

ROLES = ("controller", "source", "target")
ROLE_UNITS = {
    "controller": (
        "vnet-dataplane-shared-epoch-coordinator.service",
        "vnet-dataplane-shared-metrics-controller.service",
    ),
    "source": ("vnet-dataplane-shared-agent.service",),
    "target": ("vnet-dataplane-shared-agent.service",),
}
UNIT_TARGETS = {
    name: "/etc/systemd/system/" + name
    for names in ROLE_UNITS.values()
    for name in names
}
PENDING_SUDOERS_TARGET = "/etc/vnet-dataplane-shared/vnet-dataplane-shared.sudoers.pending"
ACTIVATION_MARKER = "/run/vnet-dataplane-shared-activation/approved"
BACKUP_BASE = "/var/backups/vnet-dataplane-shared"
ALLOWED_MODES = {"0440", "0600", "0640", "0644", "0700", "0750", "0755"}
SHA_RE = re.compile(r"[0-9a-f]{64}")
BACKUP_RE = re.compile(
    r"codex-backup-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}-[0-9a-f]{32}"
)
LOCK_PATH = "/run/lock/vnet-dataplane-shared-stage.lock"


def fail():
    raise RuntimeError("rejected")


def target_allowed(role, target):
    if role not in ROLES or not isinstance(target, str):
        return False
    if target in UNIT_TARGETS.values():
        return os.path.basename(target) in ROLE_UNITS[role]
    if target == PENDING_SUDOERS_TARGET:
        return role in ("source", "target")
    return (
        target.startswith("/opt/vnet-dataplane-shared/")
        or target.startswith("/etc/vnet-dataplane-shared/")
    ) and os.path.normpath(target) == target


def lstat(path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None


def require_root_directory(path):
    info = lstat(path)
    if (
        info is None
        or stat.S_ISLNK(info.st_mode)
        or not stat.S_ISDIR(info.st_mode)
        or info.st_uid != 0
        or info.st_gid != 0
        or stat.S_IMODE(info.st_mode) & 0o022
    ):
        fail()


def check_chain(path):
    current = "/"
    for part in path.strip("/").split("/"):
        current = os.path.join(current, part)
        info = lstat(current)
        if info is None:
            return
        if (
            stat.S_ISLNK(info.st_mode)
            or info.st_uid != 0
            or info.st_gid != 0
            or stat.S_IMODE(info.st_mode) & 0o022
        ):
            fail()
        if current != path and not stat.S_ISDIR(info.st_mode):
            fail()


def ensure_owned_tree(path, mode):
    parent = os.path.dirname(path)
    require_root_directory(parent)
    try:
        os.mkdir(path, mode)
    except FileExistsError:
        info = lstat(path)
        if (
            info is None
            or stat.S_ISLNK(info.st_mode)
            or not stat.S_ISDIR(info.st_mode)
            or info.st_uid != 0
            or info.st_gid != 0
            or stat.S_IMODE(info.st_mode) & 0o022
        ):
            fail()


def ensure_target_parent(target):
    if target.startswith("/opt/vnet-dataplane-shared/"):
        root = "/opt/vnet-dataplane-shared"
        require_root_directory("/opt")
    elif target.startswith("/etc/vnet-dataplane-shared/"):
        root = "/etc/vnet-dataplane-shared"
        require_root_directory("/etc")
    else:
        require_root_directory(os.path.dirname(target))
        return
    ensure_owned_tree(root, 0o755)
    relative_parent = os.path.relpath(os.path.dirname(target), root)
    current = root
    if relative_parent != ".":
        for part in relative_parent.split(os.sep):
            current = os.path.join(current, part)
            ensure_owned_tree(current, 0o755)


def read_regular(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_gid != 0:
            fail()
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks), stat.S_IMODE(info.st_mode)
    finally:
        os.close(descriptor)


def atomic_write(path, payload, mode, validate_sudoers=False):
    ensure_target_parent(path)
    parent = os.path.dirname(path)
    descriptor, temporary = tempfile.mkstemp(prefix=".codex-stage-", dir=parent)
    try:
        os.fchmod(descriptor, mode)
        os.fchown(descriptor, 0, 0)
        view = memoryview(payload)
        while view:
            count = os.write(descriptor, view)
            view = view[count:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        if validate_sudoers:
            checked = subprocess.run(
                ["/usr/sbin/visudo", "-cf", temporary],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if checked.returncode != 0:
                fail()
        os.replace(temporary, path)
        directory = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def prepare_file(path, temporary, payload, mode, validate_sudoers=False):
    ensure_target_parent(path)
    check_chain(path)
    if os.path.dirname(path) != os.path.dirname(temporary):
        fail()
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    descriptor = -1
    try:
        descriptor = os.open(temporary, flags, mode)
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = -1
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode, follow_symlinks=False)
        os.chown(temporary, 0, 0, follow_symlinks=False)
        if validate_sudoers:
            result = subprocess.run(
                ["/usr/sbin/visudo", "-cf", temporary],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if result.returncode != 0:
                fail()
        info = os.lstat(temporary)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != 0
            or info.st_gid != 0
            or stat.S_IMODE(info.st_mode) != mode
        ):
            fail()
        return info.st_dev, info.st_ino
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        raise


def fsync_parent(path):
    parent = os.path.dirname(path)
    directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def publish_prepared(path, temporary, device, inode):
    temporary_info = os.lstat(temporary)
    if (
        not stat.S_ISREG(temporary_info.st_mode)
        or temporary_info.st_uid != 0
        or temporary_info.st_gid != 0
        or temporary_info.st_dev != device
        or temporary_info.st_ino != inode
    ):
        fail()
    os.link(temporary, path, follow_symlinks=False)
    published = os.lstat(path)
    if published.st_dev != device or published.st_ino != inode:
        fail()
    fsync_parent(path)


def write_manifest(path, manifest):
    atomic_write(
        path,
        (json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii"),
        0o600,
    )


def systemctl_state(unit):
    if unit not in UNIT_TARGETS:
        fail()

    expected = {
        "is-active": {
            (0, "active"),
            (3, "inactive"),
            (3, "failed"),
            (4, "unknown"),
        },
        "is-enabled": {
            (0, "enabled"),
            (1, "disabled"),
            (1, "not-found"),
        },
    }

    def query(operation):
        try:
            result = subprocess.run(
                ["/usr/bin/systemctl", operation, unit],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
        except (OSError, subprocess.TimeoutExpired):
            fail()
        if not isinstance(result.stdout, str):
            fail()
        values = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if len(values) != 1 or (result.returncode, values[0]) not in expected[operation]:
            fail()
        return values[0]

    return {
        "active": query("is-active"),
        "enabled": query("is-enabled"),
    }


def inspect(role, files, units):
    if lstat(ACTIVATION_MARKER) is not None:
        fail()
    targets = []
    for item in files:
        if not isinstance(item, dict) or set(item) != {"target"}:
            fail()
        target = item["target"]
        if not target_allowed(role, target):
            fail()
        check_chain(target)
        info = lstat(target)
        if info is not None and (
            stat.S_ISLNK(info.st_mode)
            or not stat.S_ISREG(info.st_mode)
            or info.st_uid != 0
            or info.st_gid != 0
        ):
            fail()
        targets.append(
            {"target": target, "exists": info is not None, "symlink": False}
        )
    if tuple(units) != ROLE_UNITS[role]:
        fail()
    states = {unit: systemctl_state(unit) for unit in units}
    for state in states.values():
        if state["active"] not in ("inactive", "unknown"):
            fail()
        if state["enabled"] not in ("disabled", "not-found"):
            fail()
    return {
        "ok": True,
        "activation_marker_absent": True,
        "targets": targets,
        "units": states,
    }


def validate_stage_files(role, files):
    result = []
    seen = set()
    for item in files:
        if not isinstance(item, dict) or set(item) != {
            "target", "mode", "sha256", "payload_b64"
        }:
            fail()
        target = item["target"]
        mode = item["mode"]
        digest = item["sha256"]
        if (
            target in seen
            or not target_allowed(role, target)
            or mode not in ALLOWED_MODES
            or not isinstance(digest, str)
            or SHA_RE.fullmatch(digest) is None
        ):
            fail()
        seen.add(target)
        try:
            payload = base64.b64decode(item["payload_b64"], validate=True)
        except Exception:
            fail()
        if hashlib.sha256(payload).hexdigest() != digest:
            fail()
        if target in UNIT_TARGETS.values() and mode != "0644":
            fail()
        if target == PENDING_SUDOERS_TARGET and mode != "0600":
            fail()
        result.append(
            {"target": target, "mode": mode, "sha256": digest, "payload": payload}
        )
    return result


def create_backup(role, files, backup_id, units, bundle_manifest_sha256):
    if (
        BACKUP_RE.fullmatch(backup_id) is None
        or not isinstance(bundle_manifest_sha256, str)
        or SHA_RE.fullmatch(bundle_manifest_sha256) is None
        or ("-" + bundle_manifest_sha256[:12] + "-") not in backup_id
    ):
        fail()
    require_root_directory("/var")
    require_root_directory("/var/backups")
    ensure_owned_tree(BACKUP_BASE, 0o700)
    fsync_parent(BACKUP_BASE)
    backup_root = os.path.join(BACKUP_BASE, backup_id)
    if lstat(backup_root) is not None:
        fail()
    os.mkdir(backup_root, 0o700)
    os.chown(backup_root, 0, 0)
    fsync_parent(backup_root)
    files_root = os.path.join(backup_root, "files")
    os.mkdir(files_root, 0o700)
    os.chown(files_root, 0, 0)
    fsync_parent(files_root)
    records = []
    transactions = []
    for index, item in enumerate(files):
        target = item["target"]
        check_chain(target)
        info = lstat(target)
        if info is not None:
            fail()
        record = {
            "target": target,
            "existed": False,
            "staged_sha256": item["sha256"],
        }
        records.append(record)
        transactions.append(
            {
                "target": target,
                "temporary": os.path.join(
                    os.path.dirname(target),
                    ".codex-stage-" + backup_id + "-%04d" % index,
                ),
                "staged_sha256": item["sha256"],
                "device": None,
                "inode": None,
                "published": False,
            }
        )
    manifest = {
        "schema_version": 1,
        "role": role,
        "backup_id": backup_id,
        "bundle_manifest_sha256": bundle_manifest_sha256,
        "files": records,
        "units": list(units),
        "transactions": transactions,
    }
    manifest_path = os.path.join(backup_root, "rollback-manifest.json")
    write_manifest(manifest_path, manifest)
    return backup_root, manifest_path, manifest


def restore(manifest):
    records = {record["target"]: record for record in manifest["files"]}
    changed_directories = set()
    for transaction in reversed(manifest["transactions"]):
        target = transaction["target"]
        record = records[target]
        if not target_allowed(manifest["role"], target):
            fail()
        device = transaction["device"]
        inode = transaction["inode"]
        target_info = lstat(target)
        if target_info is not None:
            if device is None or inode is None:
                fail()
            if (
                stat.S_ISLNK(target_info.st_mode)
                or not stat.S_ISREG(target_info.st_mode)
                or target_info.st_uid != 0
                or target_info.st_gid != 0
                or target_info.st_dev != device
                or target_info.st_ino != inode
            ):
                fail()
            payload, _mode = read_regular(target)
            if hashlib.sha256(payload).hexdigest() != record["staged_sha256"]:
                fail()
            os.unlink(target)
            changed_directories.add(os.path.dirname(target))
        temporary = transaction["temporary"]
        temporary_info = lstat(temporary)
        if temporary_info is not None:
            if (
                stat.S_ISLNK(temporary_info.st_mode)
                or not stat.S_ISREG(temporary_info.st_mode)
                or temporary_info.st_uid != 0
                or temporary_info.st_gid != 0
                or (device is not None and temporary_info.st_dev != device)
                or (inode is not None and temporary_info.st_ino != inode)
            ):
                fail()
            payload, _mode = read_regular(temporary)
            if hashlib.sha256(payload).hexdigest() != record["staged_sha256"]:
                fail()
            os.unlink(temporary)
            changed_directories.add(os.path.dirname(temporary))
    for directory_path in sorted(changed_directories):
        fsync_parent(os.path.join(directory_path, "."))
def stage(role, raw_files, units, backup_id, bundle_manifest_sha256):
    if tuple(units) != ROLE_UNITS[role]:
        fail()
    before = inspect(role, [{"target": item["target"]} for item in raw_files], units)
    if any(item["exists"] for item in before["targets"]):
        fail()
    files = validate_stage_files(role, raw_files)
    backup_root, manifest_path, manifest = create_backup(
        role, files, backup_id, units, bundle_manifest_sha256
    )
    try:
        for item, transaction in zip(files, manifest["transactions"]):
            device, inode = prepare_file(
                item["target"],
                transaction["temporary"],
                item["payload"],
                int(item["mode"], 8),
                item["target"] == PENDING_SUDOERS_TARGET,
            )
            transaction["device"] = device
            transaction["inode"] = inode
            write_manifest(manifest_path, manifest)
            publish_prepared(
                item["target"], transaction["temporary"], device, inode
            )
            transaction["published"] = True
            write_manifest(manifest_path, manifest)
            os.unlink(transaction["temporary"])
            fsync_parent(transaction["temporary"])
        verified = []
        for item in files:
            payload, mode = read_regular(item["target"])
            if (
                hashlib.sha256(payload).hexdigest() != item["sha256"]
                or "%04o" % mode != item["mode"]
            ):
                fail()
            verified.append(
                {
                    "target": item["target"],
                    "sha256": item["sha256"],
                    "mode": item["mode"],
                    "owner": "root:root",
                    "symlink": False,
                }
            )
        states = {unit: systemctl_state(unit) for unit in units}
        if any(
            state["active"] not in ("inactive", "unknown")
            or state["enabled"] not in ("disabled", "not-found")
            for state in states.values()
        ):
            fail()
        return {
            "ok": True,
            "status": "staged",
            "backup_root": backup_root,
            "rollback_manifest": manifest_path,
            "manager_reloaded": False,
            "targets": verified,
            "units": states,
        }
    except Exception:
        restore(manifest)
        return {"ok": False, "code": "stage_failed_and_rolled_back"}


def rollback(role, backup_id, units, bundle_manifest_sha256):
    if (
        role not in ROLES
        or tuple(units) != ROLE_UNITS[role]
        or BACKUP_RE.fullmatch(backup_id) is None
        or not isinstance(bundle_manifest_sha256, str)
        or SHA_RE.fullmatch(bundle_manifest_sha256) is None
        or ("-" + bundle_manifest_sha256[:12] + "-") not in backup_id
    ):
        fail()
    backup_root = os.path.join(BACKUP_BASE, backup_id)
    if lstat(backup_root) is None:
        return {"ok": True, "status": "no_transaction", "manager_reloaded": False}
    before_states = {unit: systemctl_state(unit) for unit in units}
    if any(
        state["active"] not in ("inactive", "unknown")
        or state["enabled"] not in ("disabled", "not-found")
        for state in before_states.values()
    ):
        fail()
    manifest_path = os.path.join(backup_root, "rollback-manifest.json")
    payload, mode = read_regular(manifest_path)
    if mode != 0o600:
        fail()
    manifest = json.loads(payload.decode("ascii"))
    if (
        not isinstance(manifest, dict)
        or manifest.get("schema_version") != 1
        or manifest.get("role") != role
        or manifest.get("backup_id") != backup_id
        or manifest.get("bundle_manifest_sha256") != bundle_manifest_sha256
        or manifest.get("units") != list(units)
        or not isinstance(manifest.get("files"), list)
        or not isinstance(manifest.get("transactions"), list)
    ):
        fail()
    targets = [record.get("target") for record in manifest["files"] if isinstance(record, dict)]
    transactions = manifest["transactions"]
    transaction_targets = [
        item.get("target") for item in transactions if isinstance(item, dict)
    ]
    if (
        len(targets) != len(manifest["files"])
        or len(set(targets)) != len(targets)
        or len(transaction_targets) != len(transactions)
        or len(set(transaction_targets)) != len(transaction_targets)
        or set(transaction_targets) != set(targets)
    ):
        fail()
    records = {record["target"]: record for record in manifest["files"]}
    for item in transactions:
        if set(item) != {
            "target",
            "temporary",
            "staged_sha256",
            "device",
            "inode",
            "published",
        }:
            fail()
        target = item["target"]
        temporary = item["temporary"]
        expected_prefix = os.path.join(
            os.path.dirname(target), ".codex-stage-" + backup_id + "-"
        )
        if (
            not isinstance(temporary, str)
            or not temporary.startswith(expected_prefix)
            or os.path.dirname(temporary) != os.path.dirname(target)
            or item["staged_sha256"] != records[target].get("staged_sha256")
            or not isinstance(item["published"], bool)
            or (item["device"] is None) != (item["inode"] is None)
            or (
                item["device"] is not None
                and (
                    isinstance(item["device"], bool)
                    or not isinstance(item["device"], int)
                    or item["device"] < 0
                    or isinstance(item["inode"], bool)
                    or not isinstance(item["inode"], int)
                    or item["inode"] <= 0
                )
            )
        ):
            fail()
    restore(manifest)
    states = {unit: systemctl_state(unit) for unit in units}
    if any(
        state["active"] not in ("inactive", "unknown")
        or state["enabled"] not in ("disabled", "not-found")
        for state in states.values()
    ):
        fail()
    return {"ok": True, "status": "rolled_back", "manager_reloaded": False}


def run_locked(operation, *args):
    if operation not in (stage, rollback):
        fail()
    lock_descriptor = os.open(
        LOCK_PATH,
        os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    try:
        lock_info = os.fstat(lock_descriptor)
        if (
            not stat.S_ISREG(lock_info.st_mode)
            or lock_info.st_uid != 0
            or lock_info.st_gid != 0
            or stat.S_IMODE(lock_info.st_mode) != 0o600
        ):
            fail()
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX)
        return operation(*args)
    finally:
        os.close(lock_descriptor)


def main():
    if os.geteuid() != 0:
        fail()
    request = json.load(sys.stdin)
    if not isinstance(request, dict) or request.get("schema_version") != 1:
        fail()
    role = request.get("role")
    if role not in ROLES:
        fail()
    expected_hostname = request.get("expected_hostname")
    actual_hostname = os.uname().nodename.rstrip(".").split(".", 1)[0].lower()
    if not isinstance(expected_hostname, str) or actual_hostname != expected_hostname.lower():
        fail()
    action = request.get("action")
    if action == "inspect" and set(request) == {
        "schema_version", "action", "role", "expected_hostname", "files", "units"
    }:
        result = inspect(role, request["files"], request["units"])
    elif action == "stage" and set(request) == {
        "schema_version", "action", "role", "expected_hostname", "files", "units", "backup_id", "bundle_manifest_sha256"
    }:
        result = run_locked(
            stage,
            role,
            request["files"],
            request["units"],
            request["backup_id"],
            request["bundle_manifest_sha256"],
        )
    elif action == "rollback" and set(request) == {
        "schema_version", "action", "role", "expected_hostname", "units", "backup_id", "bundle_manifest_sha256"
    }:
        result = run_locked(
            rollback,
            role,
            request["backup_id"],
            request["units"],
            request["bundle_manifest_sha256"],
        )
    else:
        fail()
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if result.get("ok") else 1


try:
    raise SystemExit(main())
except SystemExit:
    raise
except Exception:
    print('{"code":"request_rejected","ok":false}')
    raise SystemExit(2)
'''


def _remote_helper_command() -> str:
    compressed = zlib.compress(_REMOTE_HELPER_SOURCE.encode("ascii"), level=9)
    encoded = base64.b64encode(compressed).decode("ascii")
    return (
        "import base64,zlib;"
        f"exec(zlib.decompress(base64.b64decode('{encoded}')))"
    )


class SSHStageRunner:
    """Pinned, public-key-only SSH transport for the fixed remote helper."""

    def __init__(
        self,
        *,
        ssh_binary: str = "ssh",
        keyscan_binary: str = "ssh-keyscan",
        identity_file: Path | None = None,
    ):
        self._ssh_binary = ssh_binary
        self._keyscan_binary = keyscan_binary
        self._identity_file = self._validate_identity_file(identity_file)
        self._temporary_directory = tempfile.TemporaryDirectory(
            prefix="vnet-shared-stage-known-hosts-"
        )
        self._known_hosts: dict[str, Path] = {}

    @staticmethod
    def _validate_identity_file(identity_file: Path | None) -> Path | None:
        if identity_file is None:
            return None
        path = Path(identity_file).absolute()
        try:
            status = path.lstat()
        except OSError as error:
            raise RunnerError("SSH identity file is not readable") from error
        if path.is_symlink() or not stat.S_ISREG(status.st_mode) or status.st_nlink != 1:
            raise RunnerError("SSH identity file must be a single-link regular file")
        if os.name != "nt" and (
            status.st_uid != os.geteuid() or stat.S_IMODE(status.st_mode) & 0o077
        ):
            raise RunnerError("SSH identity file must be owner-only")
        return path

    def close(self) -> None:
        self._temporary_directory.cleanup()

    def __enter__(self) -> "SSHStageRunner":
        return self

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        self.close()

    def verify_host_key(
        self, role: str, node: Mapping[str, Any], timeout: float
    ) -> str:
        if role not in ROLES:
            raise RunnerError("SSH role is not allowlisted")
        address = node["address"]
        scan_timeout = max(1, min(60, int(math.ceil(timeout))))
        try:
            result = subprocess.run(
                [
                    self._keyscan_binary,
                    "-T",
                    str(scan_timeout),
                    "-t",
                    "ed25519",
                    address,
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise RunnerError("host key scan failed") from error
        if result.returncode != 0:
            raise RunnerError("host key scan failed")
        candidates: list[tuple[str, str]] = []
        for raw in result.stdout.splitlines():
            fields = raw.strip().split()
            if (
                len(fields) != 3
                or fields[0] not in (address, f"[{address}]:22")
                or fields[1] != "ssh-ed25519"
            ):
                continue
            try:
                key = base64.b64decode(fields[2], validate=True)
            except (binascii.Error, ValueError):
                continue
            digest = base64.b64encode(hashlib.sha256(key).digest()).decode("ascii")
            candidates.append((raw.strip(), "SHA256:" + digest.rstrip("=")))
        fingerprints = {fingerprint for _line, fingerprint in candidates}
        if len(fingerprints) != 1:
            raise RunnerError("host key scan did not return one ed25519 key")
        fingerprint = next(iter(fingerprints))
        if fingerprint != node["host_key_fingerprint"]:
            return fingerprint
        known_hosts = Path(self._temporary_directory.name) / f"{role}.known_hosts"
        line = next(line for line, observed in candidates if observed == fingerprint)
        known_hosts.write_text(line + "\n", encoding="ascii")
        try:
            known_hosts.chmod(0o600)
        except OSError:
            pass
        self._known_hosts[role] = known_hosts
        return fingerprint

    def _invoke(
        self,
        role: str,
        node: Mapping[str, Any],
        request: Mapping[str, Any],
        timeout: float,
    ) -> dict[str, Any]:
        known_hosts = self._known_hosts.get(role)
        if known_hosts is None:
            raise RunnerError("host key was not verified")
        connect_timeout = max(1, min(60, int(math.ceil(timeout))))
        command = [
            self._ssh_binary,
            "-F",
            os.devnull,
            "-o",
            "BatchMode=yes",
            "-o",
            "PasswordAuthentication=no",
            "-o",
            "KbdInteractiveAuthentication=no",
            "-o",
            "PubkeyAuthentication=yes",
            "-o",
            "PreferredAuthentications=publickey",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "ClearAllForwardings=yes",
            "-o",
            "PermitLocalCommand=no",
            "-o",
            "ForwardAgent=no",
            "-o",
            "ForwardX11=no",
            "-o",
            "RequestTTY=no",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "CheckHostIP=yes",
            "-o",
            f"UserKnownHostsFile={known_hosts.as_posix()}",
            "-o",
            f"GlobalKnownHostsFile={os.devnull}",
            "-o",
            "HostKeyAlgorithms=ssh-ed25519",
            "-o",
            "UpdateHostKeys=no",
            "-o",
            "LogLevel=ERROR",
            "-o",
            f"ConnectTimeout={connect_timeout}",
        ]
        if self._identity_file is not None:
            command.extend(("-i", str(self._identity_file)))
        destination = f"{node['ssh_user']}@{node['address']}"
        remote = shlex.join(
            (
                "sudo",
                "-n",
                "--",
                "/usr/bin/python3",
                "-I",
                "-B",
                "-c",
                _remote_helper_command(),
            )
        )
        command.extend((destination, remote))
        try:
            result = subprocess.run(
                command,
                input=json.dumps(request, sort_keys=True, separators=(",", ":")),
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise RunnerError("stage SSH operation failed") from error
        try:
            response = json.loads(result.stdout)
        except (TypeError, json.JSONDecodeError) as error:
            raise RunnerError("stage SSH operation returned invalid evidence") from error
        if result.returncode != 0 or not isinstance(response, dict) or response.get("ok") is not True:
            raise RunnerError("stage SSH operation failed")
        return response

    @staticmethod
    def _request_base(
        action: str, role: str, node: Mapping[str, Any]
    ) -> dict[str, Any]:
        return {
            "schema_version": SCHEMA_VERSION,
            "action": action,
            "role": role,
            "expected_hostname": node["expected_hostname"],
        }

    def inspect_node(self, role, node, files, units, timeout):
        request = self._request_base("inspect", role, node)
        request.update(
            {
                "files": [{"target": item["target"]} for item in files],
                "units": list(units),
            }
        )
        return self._invoke(role, node, request, timeout)

    def stage_node(
        self,
        role,
        node,
        files,
        units,
        backup_id,
        bundle_manifest_sha256,
        timeout,
    ):
        request = self._request_base("stage", role, node)
        request.update(
            {
                "files": [
                    {
                        "target": item["target"],
                        "mode": item["mode"],
                        "sha256": item["sha256"],
                        "payload_b64": base64.b64encode(item["payload"]).decode("ascii"),
                    }
                    for item in files
                ],
                "units": list(units),
                "backup_id": backup_id,
                "bundle_manifest_sha256": bundle_manifest_sha256,
            }
        )
        return self._invoke(role, node, request, timeout)

    def rollback_node(
        self, role, node, backup_id, bundle_manifest_sha256, timeout
    ):
        request = self._request_base("rollback", role, node)
        request.update(
            {
                "units": list(ROLE_UNITS[role]),
                "backup_id": backup_id,
                "bundle_manifest_sha256": bundle_manifest_sha256,
            }
        )
        return self._invoke(role, node, request, timeout)


def _preflight_module():
    path = Path(__file__).with_name("openstack_shared_cluster_preflight.py")
    name = "_vnet_shared_preflight_for_stage"
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise DeploymentError("shared-cluster preflight validator is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    module_directory = str(path.parent)
    inserted_path = module_directory not in sys.path
    if inserted_path:
        sys.path.insert(0, module_directory)
    try:
        spec.loader.exec_module(module)
    finally:
        sys.modules.pop(name, None)
        if inserted_path:
            sys.path.remove(module_directory)
    return module


def _renderer_module():
    path = Path(__file__).with_name("render_openstack_shared_bundle.py")
    name = "_vnet_shared_renderer_for_stage"
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise DeploymentError("shared-cluster bundle renderer is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    module_directory = str(path.parent)
    inserted_path = module_directory not in sys.path
    if inserted_path:
        sys.path.insert(0, module_directory)
    try:
        spec.loader.exec_module(module)
    finally:
        sys.modules.pop(name, None)
        if inserted_path:
            sys.path.remove(module_directory)
    return module


def _bundle_snapshot(root: Path, label: str) -> dict[str, str]:
    if root.is_symlink() or not root.is_dir():
        raise DeploymentError(f"{label} must be a non-symlink directory")
    result: dict[str, str] = {}
    for path in root.rglob("*"):
        if path.is_symlink():
            raise DeploymentError(f"{label} contains a symlink")
        if path.is_dir():
            continue
        if not path.is_file():
            raise DeploymentError(f"{label} contains an unsafe entry")
        relative = path.relative_to(root).as_posix()
        try:
            payload = path.read_bytes()
        except OSError as error:
            raise DeploymentError(f"{label} cannot be read") from error
        result[relative] = _sha256_bytes(payload)
    return result


def verify_reproducible_bundle(
    topology_path: Path,
    artifact_root: Path,
    bundle_root: Path,
) -> str:
    """Re-render from trusted inputs and require a byte-identical bundle."""

    renderer = _renderer_module()
    with tempfile.TemporaryDirectory(prefix="vnet-shared-trusted-render-") as tmp:
        expected = Path(tmp) / "bundle"
        try:
            renderer.render_bundle(topology_path, expected, artifact_root)
        except Exception as error:
            raise DeploymentError("trusted bundle reproduction failed") from error
        expected_snapshot = _bundle_snapshot(expected, "trusted rendered bundle")
        observed_snapshot = _bundle_snapshot(bundle_root, "deployment bundle")
        if observed_snapshot != expected_snapshot:
            raise DeploymentError(
                "deployment bundle differs from the trusted reproducible render"
            )
        manifest_path = expected / "bundle-manifest.json"
        return _sha256_bytes(manifest_path.read_bytes())


def _canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _mapping(value: Any, path: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise DeploymentError(f"{path} must be an object")
    return value


def _string(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value:
        raise DeploymentError(f"{path} must be a non-empty string")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise DeploymentError(f"{path} contains a control character")
    return value


def _sha256(value: Any, path: str) -> str:
    digest = _string(value, path)
    if not _SHA256_RE.fullmatch(digest):
        raise DeploymentError(f"{path} must be a lowercase SHA256 digest")
    return digest


def _parse_utc(value: Any, path: str) -> datetime:
    text = _string(value, path)
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as error:
        raise DeploymentError(f"{path} must be an ISO-8601 timestamp") from error
    if parsed.tzinfo is None:
        raise DeploymentError(f"{path} must include a timezone")
    return parsed.astimezone(timezone.utc)


def _utc_now_datetime() -> datetime:
    return datetime.now(timezone.utc)


def _validate_preflight(
    value: Any,
    inventory: Mapping[str, Any],
    *,
    now: datetime,
    max_age_seconds: float,
) -> str:
    report = _mapping(value, "preflight")
    if report.get("schema_version") != SCHEMA_VERSION:
        raise DeploymentError(f"preflight.schema_version must be {SCHEMA_VERSION}")
    if report.get("status") != "allowed" or report.get("deploy_allowed") is not True:
        raise DeploymentError("preflight does not allow deployment")
    if not isinstance(max_age_seconds, (int, float)) or isinstance(
        max_age_seconds, bool
    ) or max_age_seconds <= 0:
        raise DeploymentError("max_age_seconds must be positive")
    generated_at = _parse_utc(report.get("generated_at"), "preflight.generated_at")
    current = now.astimezone(timezone.utc)
    generated_age = (current - generated_at).total_seconds()
    if generated_age < -30 or generated_age > max_age_seconds:
        raise DeploymentError("preflight evidence is stale or from the future")

    snapshot = _mapping(report.get("snapshot"), "preflight.snapshot")
    if snapshot.get("confirmed") is not True:
        raise DeploymentError("preflight snapshot is not confirmed")
    collection_started_at = _parse_utc(
        snapshot.get("collection_started_at"),
        "preflight.snapshot.collection_started_at",
    )
    confirmation_started_at = _parse_utc(
        snapshot.get("confirmation_started_at"),
        "preflight.snapshot.confirmation_started_at",
    )
    confirmation_completed_at = _parse_utc(
        snapshot.get("confirmation_completed_at"),
        "preflight.snapshot.confirmation_completed_at",
    )
    if not (
        collection_started_at <= confirmation_started_at <= confirmation_completed_at
        <= generated_at
    ):
        raise DeploymentError("preflight snapshot timestamps are inconsistent")
    confirmation_seconds = (
        confirmation_completed_at - confirmation_started_at
    ).total_seconds()
    reported_duration_ms = snapshot.get("duration_ms")
    if (
        not isinstance(reported_duration_ms, (int, float))
        or isinstance(reported_duration_ms, bool)
        or not math.isfinite(reported_duration_ms)
        or reported_duration_ms < 0
        or abs(reported_duration_ms / 1000.0 - confirmation_seconds) > 0.1
        or confirmation_seconds > PREFLIGHT_MAX_SNAPSHOT_SECONDS
        or snapshot.get("max_duration_seconds") != PREFLIGHT_MAX_SNAPSHOT_SECONDS
    ):
        raise DeploymentError("preflight snapshot duration is invalid")
    if (
        snapshot.get("command_count") != PREFLIGHT_SNAPSHOT_COMMAND_COUNT
        or snapshot.get("required_command_count")
        != PREFLIGHT_SNAPSHOT_COMMAND_COUNT
    ):
        raise DeploymentError("preflight snapshot command set is incomplete")
    if (generated_at - confirmation_completed_at).total_seconds() > 30:
        raise DeploymentError("preflight snapshot was not published promptly")
    snapshot_age = (current - confirmation_completed_at).total_seconds()
    if snapshot_age < -30 or snapshot_age > max_age_seconds:
        raise DeploymentError("preflight snapshot is stale or from the future")

    inventory_sha256 = _sha256_bytes(_canonical_bytes(inventory))
    evidence_inventory = _mapping(report.get("inventory"), "preflight.inventory")
    if evidence_inventory.get("sha256") != inventory_sha256:
        raise DeploymentError("preflight inventory SHA256 does not match inventory")
    evidence_roles = _mapping(
        evidence_inventory.get("roles"), "preflight.inventory.roles"
    )
    if set(evidence_roles) != set(ROLES):
        raise DeploymentError("preflight inventory roles must be exact")
    for role in ROLES:
        observed = _mapping(evidence_roles[role], f"preflight.inventory.roles.{role}")
        expected = inventory["roles"][role]
        for field in ("address", "expected_hostname", "host_key_fingerprint"):
            if observed.get(field) != expected[field]:
                raise DeploymentError(
                    f"preflight inventory role {role} does not match {field}"
                )

    gates = report.get("gates")
    if not isinstance(gates, list) or not gates:
        raise DeploymentError("preflight gates must be a non-empty array")
    if any(
        not isinstance(gate, dict)
        or not isinstance(gate.get("name"), str)
        or gate.get("passed") is not True
        for gate in gates
    ):
        raise DeploymentError("every preflight gate must pass")
    gate_names = [gate["name"] for gate in gates]
    if len(gate_names) != len(set(gate_names)) or set(gate_names) != set(
        REQUIRED_PREFLIGHT_GATES
    ):
        raise DeploymentError("preflight gate set is incomplete or unexpected")

    identities = report.get("host_identity")
    if not isinstance(identities, list):
        raise DeploymentError("preflight host_identity must be an array")
    by_role = {
        item.get("role"): item
        for item in identities
        if isinstance(item, dict) and isinstance(item.get("role"), str)
    }
    if set(by_role) != set(ROLES) or len(identities) != len(ROLES):
        raise DeploymentError("preflight host identities must be exact")
    for role in ROLES:
        item = by_role[role]
        node = inventory["roles"][role]
        if item.get("host_key_verified") is not True:
            raise DeploymentError(f"preflight host key is not verified for {role}")
        for field, expected in (
            ("address", node["address"]),
            ("expected_hostname", node["expected_hostname"]),
            ("expected_host_key_fingerprint", node["host_key_fingerprint"]),
            ("observed_host_key_fingerprint", node["host_key_fingerprint"]),
        ):
            if item.get(field) != expected:
                raise DeploymentError(f"preflight host identity mismatch for {role}")
    return inventory_sha256


def _safe_source(bundle_root: Path, source: Any, path: str) -> tuple[str, Path]:
    relative = _string(source, path)
    pure = PurePosixPath(relative)
    if pure.is_absolute() or not pure.parts or any(
        part in ("", ".", "..") for part in pure.parts
    ):
        raise DeploymentError(f"{path} must be a normalized relative path")
    candidate = bundle_root.joinpath(*pure.parts)
    current = bundle_root
    for part in pure.parts:
        current = current / part
        if current.is_symlink():
            raise DeploymentError(f"{path} traverses a symlink")
    if not candidate.is_file() or candidate.is_symlink():
        raise DeploymentError(f"{path} must reference a regular file")
    return relative, candidate


def _safe_target(value: Any, path: str) -> str:
    target = _string(value, path)
    pure = PurePosixPath(target)
    if not pure.is_absolute() or any(part in ("", ".", "..") for part in pure.parts):
        raise DeploymentError(f"{path} must be a normalized absolute path")
    if target in UNIT_TARGETS.values():
        return target
    if target == PENDING_SUDOERS_TARGET:
        return target
    if target.startswith("/opt/vnet-dataplane-shared/"):
        return target
    if target.startswith("/etc/vnet-dataplane-shared/"):
        return target
    raise DeploymentError(f"{path} is outside the isolated deployment roots")


def _trusted_unit_bytes(unit: str) -> bytes:
    path = Path(__file__).resolve().parents[1] / "deploy" / "systemd" / unit
    if path.is_symlink() or not path.is_file():
        raise DeploymentError(f"trusted unit is unavailable: {unit}")
    return path.read_bytes()


def _trusted_sudoers_bytes() -> bytes:
    path = (
        Path(__file__).resolve().parents[1]
        / "deploy"
        / "sudoers"
        / "vnet-dataplane-shared"
    )
    if path.is_symlink() or not path.is_file():
        raise DeploymentError("trusted shared sudoers fragment is unavailable")
    return path.read_bytes()


def _validate_file_entries(
    bundle_root: Path,
    entries: Any,
    *,
    host_files: bool,
) -> list[dict[str, Any]]:
    if not isinstance(entries, list):
        raise DeploymentError("bundle files must be an array")
    result: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for index, raw in enumerate(entries):
        item = _mapping(raw, f"files[{index}]")
        role = _string(item.get("role"), f"files[{index}].role")
        if host_files and role not in ROLES:
            raise DeploymentError(f"files[{index}].role is not deployable")
        source, source_path = _safe_source(
            bundle_root, item.get("source"), f"files[{index}].source"
        )
        digest = _sha256(item.get("sha256"), f"files[{index}].sha256")
        payload = source_path.read_bytes()
        if _sha256_bytes(payload) != digest:
            raise DeploymentError(f"files[{index}] SHA256 mismatch")
        mode = _string(item.get("mode"), f"files[{index}].mode")
        if mode not in ALLOWED_MODES:
            raise DeploymentError(f"files[{index}].mode is not allowed")
        normalized: dict[str, Any] = {
            "role": role,
            "source": source,
            "mode": mode,
            "sha256": digest,
            "payload": payload,
        }
        if host_files:
            target = _safe_target(item.get("target"), f"files[{index}].target")
            key = (role, target)
            if key in seen:
                raise DeploymentError(f"duplicate deployment target for {role}: {target}")
            seen.add(key)
            normalized["target"] = target
            unit = PurePosixPath(target).name if target in UNIT_TARGETS.values() else None
            if unit is not None:
                if unit not in ROLE_UNITS[role]:
                    raise DeploymentError(f"unit {unit} is not allowed on role {role}")
                if mode != "0644" or payload != _trusted_unit_bytes(unit):
                    raise DeploymentError(f"unit payload is not trusted: {unit}")
            if target == PENDING_SUDOERS_TARGET:
                if (
                    role not in ("source", "target")
                    or mode != "0600"
                    or payload != _trusted_sudoers_bytes()
                ):
                    raise DeploymentError(
                        "pending shared sudoers payload is not least-privilege"
                    )
        result.append(normalized)
    return result


def _load_bundle(
    bundle_value: os.PathLike[str] | str,
    inventory: Mapping[str, Any],
    inventory_sha256: str,
):
    bundle_root = Path(bundle_value)
    if bundle_root.is_symlink() or not bundle_root.is_dir():
        raise DeploymentError("bundle root must be a non-symlink directory")
    manifest_path = bundle_root / "bundle-manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise DeploymentError("bundle manifest must be a regular non-symlink file")
    try:
        manifest_bytes = manifest_path.read_bytes()
        manifest = json.loads(manifest_bytes)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise DeploymentError("bundle manifest is not valid JSON") from error
    manifest = _mapping(manifest, "bundle manifest")
    if manifest.get("schema_version") != SCHEMA_VERSION:
        raise DeploymentError(f"bundle schema_version must be {SCHEMA_VERSION}")
    _string(manifest.get("deployment_id"), "bundle.deployment_id")
    if manifest.get("inventory_sha256") != inventory_sha256:
        raise DeploymentError("bundle inventory SHA256 does not match inventory")
    _sha256(manifest.get("topology_sha256"), "bundle.topology_sha256")

    files = _validate_file_entries(bundle_root, manifest.get("files"), host_files=True)
    guest_files = manifest.get("guest_files", [])
    _validate_file_entries(bundle_root, guest_files, host_files=False)
    by_role = {role: [item for item in files if item["role"] == role] for role in ROLES}
    if {role for role, values in by_role.items() if values} != set(ROLES):
        raise DeploymentError("bundle files must cover exactly all host roles")
    for role, values in by_role.items():
        targets = {item["target"] for item in values}
        if not any(target.startswith("/opt/vnet-dataplane-shared/") for target in targets):
            raise DeploymentError(f"bundle is missing verified /opt artifacts for {role}")
        if not any(target.startswith("/etc/vnet-dataplane-shared/") for target in targets):
            raise DeploymentError(f"bundle is missing isolated configuration for {role}")
        for unit in ROLE_UNITS[role]:
            if UNIT_TARGETS[unit] not in targets:
                raise DeploymentError(f"bundle is missing unit {unit} for {role}")

    units = manifest.get("units")
    if not isinstance(units, list):
        raise DeploymentError("bundle units must be an array")
    observed_units: dict[str, list[str]] = {role: [] for role in ROLES}
    for index, raw in enumerate(units):
        item = _mapping(raw, f"units[{index}]")
        role = _string(item.get("role"), f"units[{index}].role")
        name = _string(item.get("name"), f"units[{index}].name")
        if role not in ROLES or name not in ROLE_UNITS[role]:
            raise DeploymentError(f"units[{index}] is not allowlisted")
        if item.get("enabled") is not False or item.get("started") is not False:
            raise DeploymentError(f"units[{index}] must declare inactive and disabled")
        observed_units[role].append(name)
    for role in ROLES:
        if sorted(observed_units[role]) != sorted(ROLE_UNITS[role]):
            raise DeploymentError(f"bundle units are incomplete for {role}")

    hosts = manifest.get("hosts")
    if not isinstance(hosts, list):
        raise DeploymentError("bundle hosts must be an array")
    host_roles = [item.get("role") for item in hosts if isinstance(item, dict)]
    if sorted(host_roles) != sorted(ROLES) or len(hosts) != len(ROLES):
        raise DeploymentError("bundle hosts must contain exact deployment roles")
    for raw in hosts:
        item = _mapping(raw, "bundle.hosts[]")
        role = item["role"]
        expected_keys = {"role", "ssh_destination"}
        if role != "controller":
            expected_keys.add("nova_host")
        if set(item) != expected_keys:
            raise DeploymentError(f"bundle host fields are not exact for {role}")
        node = inventory["roles"][role]
        if item.get("ssh_destination") != f"ubuntu@{node['address']}":
            raise DeploymentError(f"bundle SSH destination mismatch for {role}")
        if role != "controller" and item.get("nova_host") != node["expected_hostname"]:
            raise DeploymentError(f"bundle Nova host mismatch for {role}")

    return manifest, manifest_bytes, by_role


def _validate_inspection(role: str, result: Any, files, units) -> None:
    value = _mapping(result, f"inspection.{role}")
    if value.get("activation_marker_absent") is not True:
        raise DeploymentError(f"activation marker is present or unverified on {role}")
    targets = value.get("targets")
    if not isinstance(targets, list):
        raise DeploymentError(f"inspection targets missing for {role}")
    expected_targets = {item["target"] for item in files}
    observed_targets: set[str] = set()
    for item in targets:
        entry = _mapping(item, f"inspection.{role}.target")
        target = entry.get("target")
        if target not in expected_targets or target in observed_targets:
            raise DeploymentError(f"inspection targets do not match for {role}")
        observed_targets.add(target)
        if entry.get("symlink") is not False:
            raise DeploymentError(f"deployment target is a symlink on {role}")
        if entry.get("exists") is not False:
            raise DeploymentError(
                f"deployment target already exists on {role}: {target}"
            )
    if observed_targets != expected_targets:
        raise DeploymentError(f"inspection targets are incomplete for {role}")
    states = _mapping(value.get("units"), f"inspection.{role}.units")
    if set(states) != set(units):
        raise DeploymentError(f"inspection unit set does not match for {role}")
    for unit in units:
        state = _mapping(states[unit], f"inspection.{role}.units.{unit}")
        if state.get("active") not in ("inactive", "unknown"):
            raise DeploymentError(f"unit is not inactive on {role}: {unit}")
        if state.get("enabled") not in ("disabled", "not-found"):
            raise DeploymentError(f"unit is not disabled on {role}: {unit}")


def _validate_stage_result(
    role: str,
    result: Any,
    files: Sequence[Mapping[str, Any]],
    units: Sequence[str],
    backup_id: str,
) -> dict[str, str]:
    value = _mapping(result, f"stage.{role}")
    backup_root = f"/var/backups/vnet-dataplane-shared/{backup_id}"
    rollback_manifest = f"{backup_root}/rollback-manifest.json"
    if (
        value.get("status") != "staged"
        or value.get("backup_root") != backup_root
        or value.get("rollback_manifest") != rollback_manifest
        or value.get("manager_reloaded") is not False
    ):
        raise DeploymentError(f"stage result is incomplete for {role}")

    targets = value.get("targets")
    if not isinstance(targets, list) or len(targets) != len(files):
        raise DeploymentError(f"stage target verification is incomplete for {role}")
    expected = {item["target"]: item for item in files}
    observed: set[str] = set()
    for raw in targets:
        item = _mapping(raw, f"stage.{role}.target")
        target = item.get("target")
        if target not in expected or target in observed:
            raise DeploymentError(f"stage target verification does not match for {role}")
        observed.add(target)
        wanted = expected[target]
        if (
            item.get("sha256") != wanted["sha256"]
            or item.get("mode") != wanted["mode"]
            or item.get("owner") != "root:root"
            or item.get("symlink") is not False
        ):
            raise DeploymentError(f"stage target verification failed for {role}")
    states = _mapping(value.get("units"), f"stage.{role}.units")
    if set(states) != set(units):
        raise DeploymentError(f"stage unit set does not match for {role}")
    for unit in units:
        state = _mapping(states[unit], f"stage.{role}.units.{unit}")
        if state.get("active") not in ("inactive", "unknown") or state.get(
            "enabled"
        ) not in ("disabled", "not-found"):
            raise DeploymentError(f"staged unit is active or enabled: {unit}")
    return {"backup_root": backup_root, "rollback_manifest": rollback_manifest}


def stage_deployment(
    inventory_value: Any,
    preflight_value: Any,
    bundle_root: os.PathLike[str] | str,
    runner: Any,
    *,
    expected_bundle_manifest_sha256: str,
    recovery_path: os.PathLike[str] | str | None = None,
    dry_run: bool = False,
    now: datetime | None = None,
    max_preflight_age_seconds: float = 120,
    timeout: float = 30,
) -> dict[str, Any]:
    """Validate and then sequentially stage the bundle on the three hosts."""

    if not isinstance(dry_run, bool):
        raise DeploymentError("dry_run must be boolean")
    if not isinstance(timeout, (int, float)) or isinstance(timeout, bool) or timeout <= 0:
        raise DeploymentError("timeout must be positive")
    if not dry_run and recovery_path is None:
        raise DeploymentError("stage requires a recovery output")
    current = now or _utc_now_datetime()
    if current.tzinfo is None:
        raise DeploymentError("now must include a timezone")
    generated_at = current.astimezone(timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )

    try:
        inventory = _preflight_module().validate_inventory(inventory_value)
    except Exception as error:
        raise DeploymentError("inventory validation failed") from error
    inventory_sha256 = _validate_preflight(
        preflight_value,
        inventory,
        now=current,
        max_age_seconds=max_preflight_age_seconds,
    )
    manifest, manifest_bytes, files_by_role = _load_bundle(
        bundle_root, inventory, inventory_sha256
    )
    manifest_sha256 = _sha256_bytes(manifest_bytes)
    expected_digest = _sha256(
        expected_bundle_manifest_sha256,
        "expected_bundle_manifest_sha256",
    )
    if manifest_sha256 != expected_digest:
        raise DeploymentError(
            "bundle manifest changed after trusted reproduction"
        )
    backup_id = (
        "codex-backup-"
        + current.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
        + manifest_sha256[:12]
        + "-"
        + secrets.token_hex(16)
    )

    nodes: list[dict[str, Any]] = []
    node_evidence: dict[str, dict[str, Any]] = {}
    for role in STAGE_ORDER:
        node = inventory["roles"][role]
        files = files_by_role[role]
        units = ROLE_UNITS[role]
        evidence = {
            "role": role,
            "address": node["address"],
            "expected_hostname": node["expected_hostname"],
            "host_key_verified": False,
            "status": "pending",
            "inspection_state": "pending",
            "stage_state": "not_requested",
            "rollback_state": "not_requested",
            "file_count": len(files),
            "unit_count": len(units),
        }
        nodes.append(evidence)
        node_evidence[role] = evidence

    recovery: dict[str, Any] | None = None
    recovery_file = Path(recovery_path) if recovery_path is not None else None

    def persist_recovery(status_value: str, *, exclusive: bool = False) -> None:
        if recovery is None or recovery_file is None:
            return
        recovery["status"] = status_value
        recovery["updated_at"] = generated_at
        atomic_write_json(
            recovery_file,
            recovery,
            exclusive=exclusive,
            require_existing_parent=True,
        )

    if not dry_run:
        recovery = {
            "schema_version": SCHEMA_VERSION,
            "operation": "stage_recovery_intent",
            "generated_at": generated_at,
            "updated_at": generated_at,
            "status": "armed",
            "staged": False,
            "activation_ready": False,
            "pending_gates": list(ACTIVATION_PENDING_GATES),
            "deployment_id": manifest["deployment_id"],
            "inventory_sha256": inventory_sha256,
            "bundle_manifest_sha256": manifest_sha256,
            "backup_id": backup_id,
            "stage_order": list(STAGE_ORDER),
            "rollback_order": list(reversed(STAGE_ORDER)),
            "nodes": nodes,
            "rollback": {
                "available": True,
                "required": False,
                "remote_manifest": (
                    "/var/backups/vnet-dataplane-shared/"
                    f"{backup_id}/rollback-manifest.json"
                ),
            },
        }
        # Arm recovery before the first SSH inspection so host identity and
        # transaction intent are durable before any remote phase begins.
        persist_recovery("armed", exclusive=True)

    for role in STAGE_ORDER:
        node = inventory["roles"][role]
        try:
            observed_fingerprint = runner.verify_host_key(role, node, timeout)
            if observed_fingerprint != node["host_key_fingerprint"]:
                raise DeploymentError(f"host key mismatch for {role}")
            files = files_by_role[role]
            units = ROLE_UNITS[role]
            inspection = runner.inspect_node(role, node, files, units, timeout)
            _validate_inspection(role, inspection, files, units)
        except Exception as error:
            node_evidence[role].update(
                {"status": "verification_failed", "inspection_state": "failed"}
            )
            try:
                persist_recovery("verification_failed")
            except Exception:
                pass
            raise DeploymentError(
                f"pre-stage verification failed on {role}"
            ) from error
        node_evidence[role].update(
            {
                "host_key_verified": True,
                "status": "verified",
                "inspection_state": "passed",
            }
        )
        persist_recovery("verified")

    # Remote inspection may consume most of the evidence lifetime. Production
    # staging therefore rechecks the real clock immediately before any file is
    # published; the explicit ``now`` override remains deterministic for tests.
    post_inspection_now = current if now is not None else _utc_now_datetime()
    try:
        confirmed_inventory_sha256 = _validate_preflight(
            preflight_value,
            inventory,
            now=post_inspection_now,
            max_age_seconds=max_preflight_age_seconds,
        )
    except DeploymentError as error:
        try:
            persist_recovery("preflight_expired")
        except Exception:
            pass
        raise DeploymentError(
            "preflight evidence expired during pre-stage inspection"
        ) from error
    if confirmed_inventory_sha256 != inventory_sha256:
        raise DeploymentError("preflight inventory changed during inspection")

    completed: list[tuple[str, Mapping[str, Any]]] = []
    if not dry_run:
        for role in STAGE_ORDER:
            node = inventory["roles"][role]
            files = files_by_role[role]
            units = ROLE_UNITS[role]
            stage_attempted = False
            try:
                node_evidence[role].update(
                    {"status": "stage_requested", "stage_state": "requested"}
                )
                assert recovery is not None
                recovery["rollback"]["required"] = True
                persist_recovery("staging")
                stage_now = current if now is not None else _utc_now_datetime()
                stage_inventory_sha256 = _validate_preflight(
                    preflight_value,
                    inventory,
                    now=stage_now,
                    max_age_seconds=max_preflight_age_seconds,
                )
                if stage_inventory_sha256 != inventory_sha256:
                    raise DeploymentError(
                        "preflight inventory changed before remote stage"
                    )
                stage_attempted = True
                stage_result = runner.stage_node(
                    role,
                    node,
                    files,
                    units,
                    backup_id,
                    manifest_sha256,
                    timeout,
                )
                completed.append((role, node))
                backup = _validate_stage_result(
                    role, stage_result, files, units, backup_id
                )
                node_evidence[role].update(
                    {
                        "status": "staged",
                        "stage_state": "confirmed",
                        "backup_root": backup["backup_root"],
                        "rollback_manifest": backup["rollback_manifest"],
                    }
                )
                persist_recovery("staging")
            except Exception as error:
                rollback_failed = False
                rollback_nodes = list(reversed(completed))
                if stage_attempted and not any(
                    completed_role == role for completed_role, _node in completed
                ):
                    rollback_nodes.insert(0, (role, node))
                for completed_role, completed_node in rollback_nodes:
                    node_evidence[completed_role]["rollback_state"] = "requested"
                    try:
                        persist_recovery("rolling_back")
                    except Exception:
                        pass
                    try:
                        transaction_may_be_absent = completed_role == role and not any(
                            item_role == role for item_role, _item_node in completed
                        )
                        rollback = runner.rollback_node(
                            completed_role,
                            completed_node,
                            backup_id,
                            manifest_sha256,
                            timeout,
                        )
                        if (
                            not isinstance(rollback, dict)
                            or rollback.get("manager_reloaded") is not False
                            or (
                                rollback.get("status") != "rolled_back"
                                and not (
                                    transaction_may_be_absent
                                    and rollback.get("status") == "no_transaction"
                                )
                            )
                        ):
                            rollback_failed = True
                            node_evidence[completed_role]["rollback_state"] = "failed"
                        else:
                            node_evidence[completed_role]["rollback_state"] = (
                                "not_present"
                                if rollback.get("status") == "no_transaction"
                                else "confirmed"
                            )
                    except Exception:
                        rollback_failed = True
                        node_evidence[completed_role]["rollback_state"] = "failed"
                    try:
                        persist_recovery("rolling_back")
                    except Exception:
                        pass
                assert recovery is not None
                recovery["rollback"]["required"] = rollback_failed
                try:
                    persist_recovery(
                        "rollback_incomplete" if rollback_failed else "rolled_back"
                    )
                except Exception:
                    pass
                detail = " and rollback is incomplete" if rollback_failed else ""
                raise StageDeploymentError(
                    f"stage failed on {role}{detail}",
                    backup_id=backup_id,
                    failed_role=role,
                    rollback_incomplete=rollback_failed,
                ) from error

    report = {
        "schema_version": SCHEMA_VERSION,
        "operation": "stage_only",
        "generated_at": generated_at,
        "status": "dry_run" if dry_run else "staged",
        "staged": not dry_run,
        "activation_ready": False,
        "pending_gates": list(ACTIVATION_PENDING_GATES),
        "deployment_id": manifest["deployment_id"],
        "inventory_sha256": inventory_sha256,
        "bundle_manifest_sha256": manifest_sha256,
        "backup_id": backup_id,
        "stage_order": list(STAGE_ORDER),
        "rollback_order": list(reversed(STAGE_ORDER)),
        "nodes": nodes,
        "safety": {
            "services_started": False,
            "services_enabled": False,
            "systemd_manager_reloaded": False,
            "network_changed": False,
            "time_changed": False,
            "openstack_resources_changed": False,
        },
        "rollback": {
            "available": not dry_run,
            "required": False,
            "remote_manifest": (
                "/var/backups/vnet-dataplane-shared/"
                f"{backup_id}/rollback-manifest.json"
            ),
            "node_order": list(reversed(STAGE_ORDER)),
            "instructions": [
                "Keep every vnet-dataplane-shared unit inactive and disabled.",
                "Restore exact targets from each root-owned rollback manifest in reverse node order.",
                "Defer systemd manager reload to a separately authorized workflow.",
                "Recheck file ownership, hashes, and inactive/disabled unit state before activation.",
            ],
        },
    }
    if not dry_run:
        assert recovery_file is not None
        try:
            atomic_write_json(
                recovery_file,
                report,
                require_existing_parent=True,
            )
        except Exception as error:
            raise StageDeploymentError(
                "final recovery receipt could not be published",
                backup_id=backup_id,
                failed_role="local_receipt",
                rollback_incomplete=True,
            ) from error
    return report


def rollback_deployment(
    inventory_value: Any,
    receipt_value: Any,
    runner: Any,
    *,
    now: datetime | None = None,
    timeout: float = 30,
) -> dict[str, Any]:
    """Rollback one successful stage receipt in reverse node order."""

    if not isinstance(timeout, (int, float)) or isinstance(timeout, bool) or timeout <= 0:
        raise DeploymentError("timeout must be positive")
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        raise DeploymentError("now must include a timezone")
    try:
        inventory = _preflight_module().validate_inventory(inventory_value)
    except Exception as error:
        raise DeploymentError("inventory validation failed") from error
    inventory_sha256 = _sha256_bytes(_canonical_bytes(inventory))
    receipt = _mapping(receipt_value, "stage receipt")
    manifest_sha256 = _sha256(
        receipt.get("bundle_manifest_sha256"),
        "stage receipt bundle_manifest_sha256",
    )
    operation = receipt.get("operation")
    if receipt.get("schema_version") != SCHEMA_VERSION:
        raise DeploymentError("stage receipt does not match the trusted deployment")
    if receipt.get("inventory_sha256") != inventory_sha256:
        raise DeploymentError("stage receipt does not match the trusted deployment")
    final_receipt = (
        operation == "stage_only"
        and receipt.get("status") == "staged"
        and receipt.get("staged") is True
    )
    recovery_intent = operation == "stage_recovery_intent"
    if not final_receipt and not recovery_intent:
        raise DeploymentError("stage receipt does not match the trusted deployment")
    backup_id = _string(receipt.get("backup_id"), "stage receipt backup_id")
    if (
        _BACKUP_ID_RE.fullmatch(backup_id) is None
        or ("-" + manifest_sha256[:12] + "-") not in backup_id
    ):
        raise DeploymentError("stage receipt backup_id is invalid")
    raw_nodes = receipt.get("nodes")
    if not isinstance(raw_nodes, list) or len(raw_nodes) != len(ROLES):
        raise DeploymentError("stage receipt node evidence is incomplete")
    receipt_nodes: dict[str, Mapping[str, Any]] = {}
    for raw in raw_nodes:
        item = _mapping(raw, "stage receipt node")
        role = item.get("role")
        if not isinstance(role, str) or role in receipt_nodes or role not in ROLES:
            raise DeploymentError("stage receipt node roles are invalid")
        node = inventory["roles"][role]
        if (
            item.get("address") != node["address"]
            or item.get("expected_hostname") != node["expected_hostname"]
        ):
            raise DeploymentError(f"stage receipt node mismatch for {role}")
        if final_receipt and (
            item.get("status") != "staged"
            or item.get("host_key_verified") is not True
        ):
            raise DeploymentError(f"stage receipt node mismatch for {role}")
        if recovery_intent:
            stage_state = item.get("stage_state")
            rollback_state = item.get("rollback_state")
            if stage_state not in ("not_requested", "requested", "confirmed"):
                raise DeploymentError(f"stage recovery state is invalid for {role}")
            if rollback_state not in (
                "not_requested",
                "requested",
                "confirmed",
                "failed",
                "not_present",
            ):
                raise DeploymentError(f"rollback recovery state is invalid for {role}")
            if stage_state in ("requested", "confirmed") and (
                item.get("host_key_verified") is not True
                or item.get("inspection_state") != "passed"
            ):
                raise DeploymentError(f"stage recovery evidence is invalid for {role}")
            if stage_state == "not_requested" and rollback_state != "not_requested":
                raise DeploymentError(f"rollback recovery evidence is invalid for {role}")
            if stage_state == "confirmed" and rollback_state == "not_present":
                raise DeploymentError(f"rollback recovery evidence is invalid for {role}")
        receipt_nodes[role] = item
    if set(receipt_nodes) != set(ROLES):
        raise DeploymentError("stage receipt node roles are incomplete")

    if recovery_intent:
        if receipt.get("stage_order") != list(STAGE_ORDER) or receipt.get(
            "rollback_order"
        ) != list(reversed(STAGE_ORDER)):
            raise DeploymentError("stage recovery node order is invalid")
        rollback_roles = [
            role
            for role in reversed(STAGE_ORDER)
            if receipt_nodes[role].get("stage_state") in ("requested", "confirmed")
            and receipt_nodes[role].get("rollback_state") != "confirmed"
        ]
    else:
        rollback_roles = list(reversed(STAGE_ORDER))

    results: list[dict[str, Any]] = []
    failed = False
    for role in rollback_roles:
        node = inventory["roles"][role]
        result = {
            "role": role,
            "address": node["address"],
            "expected_hostname": node["expected_hostname"],
        }
        try:
            observed_fingerprint = runner.verify_host_key(role, node, timeout)
            if observed_fingerprint != node["host_key_fingerprint"]:
                raise DeploymentError(f"host key mismatch for {role}")
            remote = runner.rollback_node(
                role,
                node,
                backup_id,
                manifest_sha256,
                timeout,
            )
            remote_status = remote.get("status") if isinstance(remote, dict) else None
            unknown_transaction = (
                recovery_intent
                and receipt_nodes[role].get("stage_state") == "requested"
            )
            if (
                not isinstance(remote, dict)
                or remote.get("manager_reloaded") is not False
                or (
                    remote_status != "rolled_back"
                    and not (
                        unknown_transaction and remote_status == "no_transaction"
                    )
                )
            ):
                raise DeploymentError(f"rollback evidence is invalid for {role}")
        except Exception:
            result["status"] = "failed"
            failed = True
        else:
            result.update(
                {
                    "status": remote_status,
                    "host_key_verified": True,
                }
            )
        results.append(result)
    if failed:
        raise RollbackDeploymentError(backup_id, results)
    return {
        "schema_version": SCHEMA_VERSION,
        "operation": "rollback",
        "generated_at": current.astimezone(timezone.utc).isoformat().replace(
            "+00:00", "Z"
        ),
        "status": "rolled_back",
        "staged": False,
        "activation_ready": False,
        "pending_gates": list(ACTIVATION_PENDING_GATES),
        "deployment_id": receipt.get("deployment_id"),
        "inventory_sha256": inventory_sha256,
        "bundle_manifest_sha256": manifest_sha256,
        "backup_id": backup_id,
        "nodes": results,
        "safety": {
            "services_started": False,
            "services_enabled": False,
            "systemd_manager_reloaded": False,
            "network_changed": False,
            "time_changed": False,
            "openstack_resources_changed": False,
        },
    }


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DeploymentError(f"duplicate JSON field: {key}")
        result[key] = value
    return result


def _read_json_file(path_value: os.PathLike[str] | str, label: str) -> Any:
    path = Path(path_value)
    try:
        status = path.lstat()
    except OSError as error:
        raise DeploymentError(f"{label} is not readable") from error
    if path.is_symlink() or not stat.S_ISREG(status.st_mode):
        raise DeploymentError(f"{label} must be a regular non-symlink file")
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_pairs,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise DeploymentError(f"{label} is not valid JSON") from error


def _fsync_parent_directory(path: Path) -> None:
    if os.name == "nt":
        return
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    try:
        descriptor = os.open(path.parent, flags)
    except OSError as error:
        raise DeploymentError("evidence directory cannot be synchronized") from error
    try:
        os.fsync(descriptor)
    except OSError as error:
        raise DeploymentError("evidence directory cannot be synchronized") from error
    finally:
        os.close(descriptor)


def _synchronize_existing_directory_chain(path: Path) -> None:
    absolute = Path(os.path.abspath(path))
    current = Path(absolute.anchor)
    directories = [current]
    for part in absolute.parts[1:]:
        current = current / part
        directories.append(current)
    for directory in directories:
        try:
            info = os.lstat(directory)
        except OSError as error:
            raise DeploymentError(
                "recovery output parent must already exist"
            ) from error
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise DeploymentError(
                "recovery output directory chain must contain only real directories"
            )
    if os.name == "nt":
        return
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    for directory in directories:
        try:
            descriptor = os.open(directory, flags)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        except OSError as error:
            raise DeploymentError(
                "recovery output directory chain cannot be synchronized"
            ) from error


def _paths_alias(left: Path, right: Path) -> bool:
    if os.path.normcase(os.path.abspath(left)) == os.path.normcase(
        os.path.abspath(right)
    ):
        return True
    try:
        return os.path.samefile(left, right)
    except (FileNotFoundError, OSError):
        return False


def _publish_temporary(temporary: Path, path: Path, *, exclusive: bool) -> None:
    if os.name == "nt":
        import ctypes

        move_file = ctypes.WinDLL("kernel32", use_last_error=True).MoveFileExW
        move_file.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint32]
        move_file.restype = ctypes.c_int
        flags = 0x8 | (0 if exclusive else 0x1)
        if not move_file(
            str(temporary.absolute()),
            str(path.absolute()),
            flags,
        ):
            error_code = ctypes.get_last_error()
            if exclusive and os.path.lexists(path):
                raise DeploymentError(
                    "recovery output already exists; resolve it before staging"
                )
            raise OSError(error_code, "durable evidence publication failed", str(path))
        return
    if exclusive:
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise DeploymentError(
                "recovery output already exists; resolve it before staging"
            ) from error
        temporary.unlink()
    else:
        os.replace(temporary, path)


def atomic_write_json(
    path_value: os.PathLike[str] | str,
    value: Any,
    *,
    exclusive: bool = False,
    require_existing_parent: bool = False,
) -> None:
    path = Path(path_value)
    if path.is_symlink():
        raise DeploymentError("evidence output must not be a symlink")
    if require_existing_parent:
        _synchronize_existing_directory_chain(path.parent)
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent)
    )
    temporary = Path(temporary_name)
    try:
        payload = json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True) + "\n"
        with os.fdopen(descriptor, "w", encoding="ascii", newline="\n") as stream:
            descriptor = -1
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        _publish_temporary(temporary, path, exclusive=exclusive)
        _fsync_parent_directory(path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def main(argv: Sequence[str] | None = None, *, runner: Any | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Safely stage, but never activate, the shared OpenStack bundle"
    )
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--preflight", type=Path)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--topology", type=Path)
    parser.add_argument("--artifact-root", type=Path)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--recovery-output", type=Path)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--dry-run", action="store_true")
    action.add_argument("--stage", action="store_true")
    action.add_argument("--rollback", action="store_true")
    parser.add_argument("--identity-file", type=Path)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--max-preflight-age", type=float, default=120)
    args = parser.parse_args(argv)

    owns_runner = runner is None
    active_runner = runner
    try:
        inventory = _read_json_file(args.inventory, "inventory")
        if os.path.lexists(args.output):
            raise UnsafeEvidencePathError(
                "evidence output already exists; refusing to overwrite it"
            )
        if args.rollback:
            if (
                args.receipt is None
                or args.preflight is not None
                or args.topology is not None
                or args.artifact_root is not None
                or args.bundle is not None
                or args.recovery_output is not None
            ):
                raise DeploymentError(
                    "rollback requires only --inventory, --receipt, and --output"
                )
            assert args.receipt is not None
            if _paths_alias(args.receipt, args.output):
                raise UnsafeEvidencePathError(
                    "rollback output must differ from the stage receipt"
                )
            trusted_manifest_sha256 = None
            recovery_output = None
        else:
            if (
                args.preflight is None
                or args.receipt is not None
                or args.topology is None
                or args.artifact_root is None
                or args.bundle is None
            ):
                raise DeploymentError(
                    "dry-run and stage require --preflight, --topology, "
                    "--artifact-root, and --bundle"
                )
            if args.dry_run and args.recovery_output is not None:
                raise DeploymentError("dry-run does not accept --recovery-output")
            trusted_manifest_sha256 = verify_reproducible_bundle(
                args.topology,
                args.artifact_root,
                args.bundle,
            )
            recovery_output = (
                args.recovery_output
                if args.recovery_output is not None
                else Path(str(args.output) + ".recovery.json")
            )
            if args.stage and os.path.normcase(os.path.abspath(recovery_output)) == os.path.normcase(
                os.path.abspath(args.output)
            ):
                raise UnsafeEvidencePathError(
                    "recovery output must differ from final output"
                )
        if active_runner is None:
            if args.identity_file is None:
                raise DeploymentError(
                    "an explicit SSH identity file is required for shared operation"
                )
            active_runner = SSHStageRunner(identity_file=args.identity_file)
        if args.rollback:
            if args.receipt is None or args.preflight is not None:
                raise DeploymentError(
                    "rollback requires --receipt and does not accept --preflight"
                )
            receipt = _read_json_file(args.receipt, "stage receipt")
            report = rollback_deployment(
                inventory,
                receipt,
                active_runner,
                timeout=args.timeout,
            )
        else:
            assert args.preflight is not None
            assert args.bundle is not None
            assert trusted_manifest_sha256 is not None
            preflight = _read_json_file(args.preflight, "preflight evidence")
            report = stage_deployment(
                inventory,
                preflight,
                args.bundle,
                active_runner,
                dry_run=args.dry_run,
                max_preflight_age_seconds=args.max_preflight_age,
                timeout=args.timeout,
                expected_bundle_manifest_sha256=trusted_manifest_sha256,
                recovery_path=recovery_output if args.stage else None,
            )
        atomic_write_json(args.output, report, exclusive=True)
        print(
            json.dumps(
                {
                    "status": report["status"],
                    "staged": report["staged"],
                    "output": str(args.output),
                },
                sort_keys=True,
            )
        )
        return 0
    except Exception as error:
        failure = {
            "schema_version": SCHEMA_VERSION,
            "operation": "rollback" if args.rollback else "stage_only",
            "status": "blocked",
            "staged": False,
            "reason_code": "safety_gate_failed",
            "rollback_required": isinstance(error, StageDeploymentError)
            and error.rollback_incomplete,
        }
        if isinstance(error, StageDeploymentError):
            failure.update(
                {
                    "backup_id": error.backup_id,
                    "failed_role": error.failed_role,
                }
            )
        if isinstance(error, RollbackDeploymentError):
            failure.update(
                {
                    "backup_id": error.backup_id,
                    "nodes": error.nodes,
                    "rollback_required": True,
                }
            )
        if isinstance(error, UnsafeEvidencePathError):
            print("shared operation: unsafe evidence output", file=sys.stderr)
            return 2
        try:
            atomic_write_json(args.output, failure, exclusive=True)
        except Exception:
            print("shared stage: evidence write failed", file=sys.stderr)
            return 3
        print("shared operation: blocked by a safety gate", file=sys.stderr)
        return 2
    finally:
        if owns_runner and active_runner is not None:
            active_runner.close()


if __name__ == "__main__":
    raise SystemExit(main())
