#!/usr/bin/env python3
"""Collect fail-closed, read-only preflight evidence for the shared cluster."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import ipaddress
import json
import math
import os
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from types import MappingProxyType
from typing import Any, Mapping, NamedTuple, Sequence


SCHEMA_VERSION = 1
ROLES = ("controller", "source", "target")
COMPUTE_ROLES = ("source", "target")
SHARED_CLUSTER_IDENTITIES = MappingProxyType(
    {
        "controller": ("172.25.6.11", "controller"),
        "compute2": ("172.25.6.13", "compute2"),
        "compute3": ("172.25.6.14", "compute3"),
    }
)
_FINGERPRINT_RE = re.compile(r"SHA256:[A-Za-z0-9+/]{43}")
_UUID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
)
_MAC_RE = re.compile(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}")


class InventoryError(ValueError):
    """The inventory cannot safely identify the shared cluster."""


class RunnerError(RuntimeError):
    """A command runner could not safely collect evidence."""


class CommandResult(NamedTuple):
    returncode: int
    stdout: str
    stderr: str


_COMMON_COMMANDS = {
    "hostname": ("hostname",),
    "clock_tracking": ("chronyc", "-n", "tracking"),
    "active_sessions": ("who",),
}

_CONTROLLER_COMMANDS = {
    **_COMMON_COMMANDS,
    "nova_services": (
        "openstack",
        "compute",
        "service",
        "list",
        "-f",
        "json",
    ),
    "neutron_agents": (
        "openstack",
        "network",
        "agent",
        "list",
        "-f",
        "json",
    ),
    "migrations": (
        "openstack",
        "server",
        "migration",
        "list",
        "-f",
        "json",
    ),
    "servers": (
        "openstack",
        "server",
        "list",
        "--all-projects",
        "--long",
        "-f",
        "json",
    ),
    "ports": (
        "openstack",
        "port",
        "list",
        "--long",
        "-f",
        "json",
    ),
    "hypervisors": (
        "openstack",
        "hypervisor",
        "list",
        "--long",
        "-f",
        "json",
    ),
}

_COMPUTE_COMMANDS = {
    **_COMMON_COMMANDS,
    "libvirt_domains": (
        "virsh",
        "--connect",
        "qemu:///system",
        "--readonly",
        "list",
        "--name",
    ),
    "ovs_bridges": (
        "ovs-vsctl",
        "--format=json",
        "--columns=name",
        "list",
        "Bridge",
    ),
    "ovs_interfaces": (
        "ovs-vsctl",
        "--format=json",
        "--columns=name,external_ids",
        "list",
        "Interface",
    ),
    "br_int_ports": ("ovs-vsctl", "list-ports", "br-int"),
    "links": ("ip", "-json", "link", "show"),
}

READ_ONLY_COMMANDS = MappingProxyType(
    {
        "controller": MappingProxyType(_CONTROLLER_COMMANDS),
        "source": MappingProxyType(_COMPUTE_COMMANDS),
        "target": MappingProxyType(_COMPUTE_COMMANDS),
    }
)

SNAPSHOT_CONFIRMATION_COMMANDS = MappingProxyType(
    {
        "controller": (
            "active_sessions",
            "nova_services",
            "neutron_agents",
            "migrations",
            "servers",
            "ports",
            "hypervisors",
        ),
        "source": (
            "active_sessions",
            "libvirt_domains",
            "ovs_bridges",
            "ovs_interfaces",
            "br_int_ports",
            "links",
        ),
        "target": (
            "active_sessions",
            "libvirt_domains",
            "ovs_bridges",
            "ovs_interfaces",
            "br_int_ports",
            "links",
        ),
    }
)
SNAPSHOT_CONFIRMATION_COMMAND_COUNT = sum(
    len(command_ids) for command_ids in SNAPSHOT_CONFIRMATION_COMMANDS.values()
)
MAX_SNAPSHOT_CONFIRMATION_SECONDS = 60.0


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _normalized_key(value: str) -> str:
    return "".join(character.lower() for character in value if character.isalnum())


def _field(record: Mapping[str, Any], *names: str) -> Any:
    normalized = {_normalized_key(str(key)): value for key, value in record.items()}
    for name in names:
        key = _normalized_key(name)
        if key in normalized:
            return normalized[key]
    return None


def _short_host(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    return value.strip().rstrip(".").split(".", 1)[0].lower()


def _check_keys(value: Mapping[str, Any], allowed: set[str], path: str) -> None:
    unknown = sorted(set(value) - allowed, key=str)
    if unknown:
        raise InventoryError(
            f"{path} has unknown field(s): {', '.join(str(item) for item in unknown)}"
        )


def _require_mapping(value: Any, path: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise InventoryError(f"{path} must be an object")
    return value


def _require_string(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise InventoryError(f"{path} must be a non-empty string")
    result = value.strip()
    if any(ord(character) < 32 or ord(character) == 127 for character in result):
        raise InventoryError(f"{path} contains a control character")
    return result


def _string_list(
    value: Any,
    path: str,
    *,
    require_nonempty: bool = False,
) -> list[str]:
    if not isinstance(value, list):
        raise InventoryError(f"{path} must be an array")
    result = [_require_string(item, f"{path}[{index}]") for index, item in enumerate(value)]
    if require_nonempty and not result:
        raise InventoryError(f"{path} must not be empty")
    if len(set(result)) != len(result):
        raise InventoryError(f"{path} must contain unique values")
    return result


def _positive_int(value: Any, path: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise InventoryError(f"{path} must be a positive integer")
    return value


def _validate_fingerprint(value: Any, path: str) -> str:
    fingerprint = _require_string(value, path)
    if not _FINGERPRINT_RE.fullmatch(fingerprint):
        raise InventoryError(f"{path} must be an OpenSSH SHA256 fingerprint")
    try:
        decoded = base64.b64decode(fingerprint[7:] + "=", validate=True)
    except (binascii.Error, ValueError) as error:
        raise InventoryError(f"{path} is not valid base64") from error
    if len(decoded) != 32:
        raise InventoryError(f"{path} must identify a SHA256 digest")
    return fingerprint


def _canonical_uuid(value: Any, path: str) -> str:
    candidate = _require_string(value, path)
    if _UUID_RE.fullmatch(candidate) is None:
        raise InventoryError(f"{path} must be a canonical lowercase UUID")
    return candidate


def _rfc1918_ipv4(value: Any, path: str) -> str:
    candidate = _require_string(value, path)
    try:
        address = ipaddress.IPv4Address(candidate)
    except ipaddress.AddressValueError as error:
        raise InventoryError(f"{path} must be a canonical RFC1918 IPv4 address") from error
    private_networks = (
        ipaddress.IPv4Network("10.0.0.0/8"),
        ipaddress.IPv4Network("172.16.0.0/12"),
        ipaddress.IPv4Network("192.168.0.0/16"),
    )
    if str(address) != candidate or not any(
        address in network for network in private_networks
    ):
        raise InventoryError(f"{path} must be a canonical RFC1918 IPv4 address")
    return candidate


def _canonical_mac(value: Any, path: str) -> str:
    candidate = _require_string(value, path)
    if _MAC_RE.fullmatch(candidate) is None:
        raise InventoryError(f"{path} must be a canonical lowercase MAC address")
    first_octet = int(candidate.split(":", 1)[0], 16)
    if first_octet & 1 or candidate == "00:00:00:00:00:00":
        raise InventoryError(f"{path} must be a unicast MAC address")
    return candidate


def _port_value_map(
    value: Any,
    path: str,
    allowed_port_ids: Sequence[str],
    validator: Any,
) -> dict[str, str]:
    raw = _require_mapping(value, path)
    if set(raw) != set(allowed_port_ids):
        raise InventoryError(f"{path} must cover allowed_port_ids exactly")
    return {
        port_id: validator(raw[port_id], f"{path}.{port_id}")
        for port_id in allowed_port_ids
    }


def validate_inventory(value: Any) -> dict[str, Any]:
    """Validate and normalize a credential-free shared-cluster inventory."""

    root = _require_mapping(value, "inventory")
    _check_keys(
        root,
        {
            "schema_version",
            "clock_tolerance_ms",
            "allowed_server_ids",
            "allowed_port_ids",
            "owner_project_id",
            "ownership_tag",
            "port_server_bindings",
            "port_fixed_ipv4s",
            "port_mac_addresses",
            "minimum_target_capacity",
            "roles",
        },
        "inventory",
    )
    if (
        isinstance(root.get("schema_version"), bool)
        or not isinstance(root.get("schema_version"), int)
        or root.get("schema_version") != SCHEMA_VERSION
    ):
        raise InventoryError(f"schema_version must be {SCHEMA_VERSION}")
    tolerance = root.get("clock_tolerance_ms")
    if (
        isinstance(tolerance, bool)
        or not isinstance(tolerance, (int, float))
        or not math.isfinite(tolerance)
        or tolerance <= 0
        or tolerance > 10
    ):
        raise InventoryError("clock_tolerance_ms must be greater than 0 and at most 10")

    allowed_server_ids = _string_list(
        root.get("allowed_server_ids"), "allowed_server_ids", require_nonempty=True
    )
    allowed_port_ids = _string_list(
        root.get("allowed_port_ids"), "allowed_port_ids", require_nonempty=True
    )
    if len(allowed_server_ids) != 2 or len(allowed_port_ids) != 2:
        raise InventoryError(
            "allowed_server_ids and allowed_port_ids must each contain exactly two UUIDs"
        )
    for field, identifiers in (
        ("allowed_server_ids", allowed_server_ids),
        ("allowed_port_ids", allowed_port_ids),
    ):
        for index, identifier in enumerate(identifiers):
            if _UUID_RE.fullmatch(identifier) is None:
                raise InventoryError(
                    f"{field}[{index}] must be a canonical lowercase UUID"
                )
    owner_project_id = _canonical_uuid(
        root.get("owner_project_id"), "owner_project_id"
    )
    ownership_tag = _require_string(root.get("ownership_tag"), "ownership_tag")
    if (
        re.fullmatch(
            r"vnet-dataplane-owner-[a-z0-9][a-z0-9-]{2,48}", ownership_tag
        )
        is None
    ):
        raise InventoryError(
            "ownership_tag must be a dedicated vnet-dataplane ownership claim"
        )
    raw_port_server_bindings = _require_mapping(
        root.get("port_server_bindings"), "port_server_bindings"
    )
    port_server_bindings: dict[str, str] = {}
    for port_id, server_id in raw_port_server_bindings.items():
        if not isinstance(port_id, str) or port_id not in allowed_port_ids:
            raise InventoryError("port_server_bindings has an unowned port")
        if not isinstance(server_id, str) or server_id not in allowed_server_ids:
            raise InventoryError("port_server_bindings has an unowned server")
        port_server_bindings[port_id] = server_id
    if set(port_server_bindings) != set(allowed_port_ids):
        raise InventoryError("port_server_bindings must cover allowed_port_ids")
    if set(port_server_bindings.values()) != set(allowed_server_ids):
        raise InventoryError(
            "port_server_bindings must bind exactly one port to each allowed server"
        )
    port_fixed_ipv4s = _port_value_map(
        root.get("port_fixed_ipv4s"),
        "port_fixed_ipv4s",
        allowed_port_ids,
        _rfc1918_ipv4,
    )
    if len(set(port_fixed_ipv4s.values())) != len(port_fixed_ipv4s):
        raise InventoryError("port_fixed_ipv4s values must be unique")
    port_mac_addresses = _port_value_map(
        root.get("port_mac_addresses"),
        "port_mac_addresses",
        allowed_port_ids,
        _canonical_mac,
    )
    if len(set(port_mac_addresses.values())) != len(port_mac_addresses):
        raise InventoryError("port_mac_addresses values must be unique")
    capacity = _require_mapping(
        root.get("minimum_target_capacity"), "minimum_target_capacity"
    )
    _check_keys(capacity, {"vcpus", "memory_mb", "disk_gb"}, "minimum_target_capacity")
    normalized_capacity = {
        name: _positive_int(capacity.get(name), f"minimum_target_capacity.{name}")
        for name in ("vcpus", "memory_mb", "disk_gb")
    }

    roles = _require_mapping(root.get("roles"), "roles")
    if set(roles) != set(ROLES):
        raise InventoryError("roles must contain exactly controller, source, and target")

    base_node_fields = {
        "address",
        "ssh_user",
        "expected_hostname",
        "host_key_fingerprint",
        "expected_clock_reference",
    }
    controller_node_fields = base_node_fields | {"openstack_cloud"}
    compute_node_fields = base_node_fields | {
        "allowed_libvirt_domains",
        "required_ovs_bridges",
        "required_tap_interfaces",
        "required_port_bindings",
    }
    normalized_roles: dict[str, dict[str, Any]] = {}
    fingerprints: list[str] = []
    for role in ROLES:
        node = _require_mapping(roles.get(role), f"roles.{role}")
        allowed_fields = (
            compute_node_fields if role in COMPUTE_ROLES else controller_node_fields
        )
        _check_keys(node, allowed_fields, f"roles.{role}")
        address = _require_string(node.get("address"), f"roles.{role}.address")
        ssh_user = _require_string(node.get("ssh_user"), f"roles.{role}.ssh_user")
        hostname = _require_string(
            node.get("expected_hostname"), f"roles.{role}.expected_hostname"
        )
        fingerprint = _validate_fingerprint(
            node.get("host_key_fingerprint"),
            f"roles.{role}.host_key_fingerprint",
        )
        expected_clock_reference = _require_string(
            node.get("expected_clock_reference"),
            f"roles.{role}.expected_clock_reference",
        )
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:()-]{0,127}", expected_clock_reference):
            raise InventoryError(
                f"roles.{role}.expected_clock_reference has unsafe characters"
            )
        if ssh_user != "ubuntu":
            raise InventoryError(f"roles.{role}.ssh_user must be ubuntu")
        normalized = {
            "address": address,
            "ssh_user": ssh_user,
            "expected_hostname": hostname,
            "host_key_fingerprint": fingerprint,
            "expected_clock_reference": expected_clock_reference,
        }
        if role == "controller":
            cloud = _require_string(
                node.get("openstack_cloud"), "roles.controller.openstack_cloud"
            )
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", cloud):
                raise InventoryError(
                    "roles.controller.openstack_cloud has unsafe characters"
                )
            normalized["openstack_cloud"] = cloud
        if role in COMPUTE_ROLES:
            normalized.update(
                {
                    "allowed_libvirt_domains": _string_list(
                        node.get("allowed_libvirt_domains"),
                        f"roles.{role}.allowed_libvirt_domains",
                    ),
                    "required_ovs_bridges": _string_list(
                        node.get("required_ovs_bridges"),
                        f"roles.{role}.required_ovs_bridges",
                        require_nonempty=True,
                    ),
                    "required_tap_interfaces": _string_list(
                        node.get("required_tap_interfaces"),
                        f"roles.{role}.required_tap_interfaces",
                        require_nonempty=role == "source",
                    ),
                }
            )
            raw_bindings = _require_mapping(
                node.get("required_port_bindings"),
                f"roles.{role}.required_port_bindings",
            )
            bindings: dict[str, str] = {}
            for port_id, interface in raw_bindings.items():
                if not isinstance(port_id, str) or port_id not in allowed_port_ids:
                    raise InventoryError(
                        f"roles.{role}.required_port_bindings has an unowned port"
                    )
                name = _require_string(
                    interface,
                    f"roles.{role}.required_port_bindings.{port_id}",
                )
                if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,14}", name):
                    raise InventoryError(
                        f"roles.{role}.required_port_bindings.{port_id} "
                        "is not a safe Linux interface name"
                    )
                bindings[port_id] = name
            if len(set(bindings.values())) != len(bindings):
                raise InventoryError(
                    f"roles.{role}.required_port_bindings interfaces must be unique"
                )
            if set(bindings.values()) != set(normalized["required_tap_interfaces"]):
                raise InventoryError(
                    f"roles.{role}.required_port_bindings must match "
                    "required_tap_interfaces"
                )
            if role == "source" and set(bindings) != set(allowed_port_ids):
                raise InventoryError(
                    "roles.source.required_port_bindings must cover allowed_port_ids"
                )
            if role == "target" and bindings:
                raise InventoryError(
                    "roles.target.required_port_bindings must be empty before migration"
                )
            normalized["required_port_bindings"] = bindings
            if "br-int" not in normalized["required_ovs_bridges"]:
                raise InventoryError(
                    f"roles.{role}.required_ovs_bridges must include br-int"
                )
        normalized_roles[role] = normalized
        fingerprints.append(fingerprint)

    controller = normalized_roles["controller"]
    controller_identity = (controller["address"], controller["expected_hostname"])
    if controller_identity != SHARED_CLUSTER_IDENTITIES["controller"]:
        raise InventoryError("controller identity does not match the shared cluster")

    source_identity = (
        normalized_roles["source"]["address"],
        normalized_roles["source"]["expected_hostname"],
    )
    target_identity = (
        normalized_roles["target"]["address"],
        normalized_roles["target"]["expected_hostname"],
    )
    if (
        source_identity != SHARED_CLUSTER_IDENTITIES["compute2"]
        or target_identity != SHARED_CLUSTER_IDENTITIES["compute3"]
    ):
        raise InventoryError(
            "source identity must be compute2 and target identity must be compute3"
        )
    if len(normalized_roles["source"]["allowed_libvirt_domains"]) != 2:
        raise InventoryError(
            "roles.source.allowed_libvirt_domains must contain exactly two domains"
        )
    if normalized_roles["target"]["allowed_libvirt_domains"]:
        raise InventoryError(
            "roles.target.allowed_libvirt_domains must be empty before migration"
        )
    if len(set(fingerprints)) != len(fingerprints):
        raise InventoryError("host key fingerprints must be unique per node")

    return {
        "schema_version": SCHEMA_VERSION,
        "clock_tolerance_ms": float(tolerance),
        "allowed_server_ids": allowed_server_ids,
        "allowed_port_ids": allowed_port_ids,
        "owner_project_id": owner_project_id,
        "ownership_tag": ownership_tag,
        "port_server_bindings": port_server_bindings,
        "port_fixed_ipv4s": port_fixed_ipv4s,
        "port_mac_addresses": port_mac_addresses,
        "minimum_target_capacity": normalized_capacity,
        "roles": normalized_roles,
    }


def is_command_allowed(role: str, command_id: str, argv: Sequence[str]) -> bool:
    commands = READ_ONLY_COMMANDS.get(role)
    if commands is None:
        return False
    expected = commands.get(command_id)
    return expected is not None and tuple(argv) == expected


class SSHReadOnlyRunner:
    """SSH runner that accepts no password and pins an ed25519 host key."""

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
            prefix="vnet-preflight-known-hosts-"
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
        if os.name != "nt":
            if status.st_uid != os.geteuid() or stat.S_IMODE(status.st_mode) & 0o077:
                raise RunnerError("SSH identity file must be owner-only")
        return path

    def close(self) -> None:
        self._temporary_directory.cleanup()

    def __enter__(self) -> "SSHReadOnlyRunner":
        return self

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        self.close()

    def verify_host_key(
        self,
        role: str,
        node: Mapping[str, Any],
        timeout: float,
    ) -> str:
        previous = self._known_hosts.pop(role, None)
        if previous is not None:
            try:
                previous.unlink()
            except FileNotFoundError:
                pass
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
        for line in result.stdout.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            fields = stripped.split()
            if len(fields) != 3 or fields[1] != "ssh-ed25519":
                continue
            try:
                key = base64.b64decode(fields[2], validate=True)
            except (binascii.Error, ValueError):
                continue
            digest = base64.b64encode(hashlib.sha256(key).digest()).decode("ascii")
            candidates.append((stripped, "SHA256:" + digest.rstrip("=")))
        unique_fingerprints = {fingerprint for _line, fingerprint in candidates}
        if len(unique_fingerprints) != 1:
            raise RunnerError("host key scan did not return one ed25519 key")
        fingerprint = next(iter(unique_fingerprints))
        if fingerprint != node["host_key_fingerprint"]:
            return fingerprint
        key_line = next(line for line, observed in candidates if observed == fingerprint)
        known_hosts = Path(self._temporary_directory.name) / f"{role}.known_hosts"
        known_hosts.write_text(key_line + "\n", encoding="ascii")
        self._known_hosts[role] = known_hosts
        return fingerprint

    def run(
        self,
        role: str,
        node: Mapping[str, Any],
        command_id: str,
        argv: Sequence[str],
        timeout: float,
    ) -> CommandResult:
        if not is_command_allowed(role, command_id, argv):
            raise RunnerError("remote command is not in the read-only allowlist")
        known_hosts = self._known_hosts.get(role)
        if known_hosts is None:
            raise RunnerError("host key was not verified")
        connect_timeout = max(1, min(60, int(math.ceil(timeout))))
        destination = f"{node['ssh_user']}@{node['address']}"
        remote_argv = list(argv)
        if role == "controller" and command_id in {
            "nova_services",
            "neutron_agents",
            "migrations",
            "servers",
            "ports",
            "hypervisors",
        }:
            remote_argv = [
                "env",
                f"OS_CLOUD={node['openstack_cloud']}",
                *remote_argv,
            ]
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
        command.extend((destination, shlex.join(tuple(remote_argv))))
        try:
            result = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise RunnerError("read-only SSH command failed") from error
        return CommandResult(result.returncode, result.stdout, result.stderr)


def _coerce_result(value: Any) -> CommandResult:
    try:
        returncode = value.returncode
        stdout = value.stdout
        stderr = value.stderr
    except AttributeError as error:
        raise RunnerError("runner returned an invalid result") from error
    if isinstance(returncode, bool) or not isinstance(returncode, int):
        raise RunnerError("runner returned an invalid return code")
    if isinstance(stdout, bytes):
        stdout = stdout.decode("utf-8", errors="replace")
    if isinstance(stderr, bytes):
        stderr = stderr.decode("utf-8", errors="replace")
    if not isinstance(stdout, str) or not isinstance(stderr, str):
        raise RunnerError("runner output must be text")
    return CommandResult(returncode, stdout, stderr)


def _command_record(
    role: str,
    command_id: str,
    argv: Sequence[str],
    *,
    started: float,
    result: CommandResult | None,
    error_type: str | None = None,
) -> dict[str, Any]:
    record: dict[str, Any] = {
        "role": role,
        "command_id": command_id,
        "argv": list(argv),
        "duration_ms": round((time.monotonic() - started) * 1000, 3),
    }
    if result is None:
        record.update({"status": "runner_error", "returncode": None})
        if error_type:
            record["error_type"] = error_type
        return record
    encoded = result.stdout.encode("utf-8", errors="replace")
    record.update(
        {
            "status": "ok" if result.returncode == 0 else "command_failed",
            "returncode": result.returncode,
            "stdout_bytes": len(encoded),
            "stdout_sha256": hashlib.sha256(encoded).hexdigest(),
        }
    )
    return record


def _safe_error_type(error: Exception) -> str:
    if isinstance(error, subprocess.TimeoutExpired):
        return "timeout"
    if isinstance(error, OSError):
        return "os_error"
    return "runner_error"


def _run_command(
    runner: Any,
    role: str,
    node: Mapping[str, Any],
    command_id: str,
    timeout: float,
    records: list[dict[str, Any]],
    *,
    phase: str = "initial",
) -> str | None:
    argv = READ_ONLY_COMMANDS[role][command_id]
    if not is_command_allowed(role, command_id, argv):
        raise RunnerError("internal command is not in the read-only allowlist")
    started = time.monotonic()
    try:
        result = _coerce_result(
            runner.run(role, node, command_id, tuple(argv), timeout)
        )
    except Exception as error:
        record = _command_record(
            role,
            command_id,
            argv,
            started=started,
            result=None,
            error_type=_safe_error_type(error),
        )
        record["phase"] = phase
        records.append(record)
        return None
    record = _command_record(
        role,
        command_id,
        argv,
        started=started,
        result=result,
    )
    record["phase"] = phase
    records.append(record)
    return result.stdout if result.returncode == 0 else None


def _parse_json_records(value: str | None) -> list[dict[str, Any]] | None:
    if value is None:
        return None
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, list) or not all(isinstance(item, dict) for item in parsed):
        return None
    return parsed


_SYSTEM_TIME_RE = re.compile(
    r"^System time\s*:\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s+seconds\s+"
    r"(fast|slow)\s+of\s+NTP\s+time\s*$",
    re.IGNORECASE | re.MULTILINE,
)
_STRATUM_RE = re.compile(r"^Stratum\s*:\s*(\d+)\s*$", re.MULTILINE)
_LEAP_RE = re.compile(r"^Leap status\s*:\s*(\S.*?)\s*$", re.MULTILINE)
_REFERENCE_ID_RE = re.compile(r"^Reference ID\s*:\s*(\S.*?)\s*$", re.MULTILINE)
_ROOT_DELAY_RE = re.compile(
    r"^Root delay\s*:\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)"
    r"\s+seconds\s*$",
    re.MULTILINE,
)
_ROOT_DISPERSION_RE = re.compile(
    r"^Root dispersion\s*:\s*"
    r"([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s+seconds\s*$",
    re.MULTILINE,
)


def _parse_clock(value: str | None) -> dict[str, Any]:
    if value is None:
        return {"valid": False}
    offset_match = _SYSTEM_TIME_RE.search(value)
    stratum_match = _STRATUM_RE.search(value)
    leap_match = _LEAP_RE.search(value)
    reference_match = _REFERENCE_ID_RE.search(value)
    root_delay_match = _ROOT_DELAY_RE.search(value)
    root_dispersion_match = _ROOT_DISPERSION_RE.search(value)
    if not all(
        (
            offset_match,
            stratum_match,
            leap_match,
            reference_match,
            root_delay_match,
            root_dispersion_match,
        )
    ):
        return {"valid": False}
    seconds = abs(float(offset_match.group(1)))
    if offset_match.group(2).lower() == "slow":
        seconds = -seconds
    root_delay_ms = float(root_delay_match.group(1)) * 1000
    root_dispersion_ms = float(root_dispersion_match.group(1)) * 1000
    if root_delay_ms < 0 or root_dispersion_ms < 0:
        return {"valid": False}
    return {
        "valid": True,
        "offset_ms": round(seconds * 1000, 6),
        "stratum": int(stratum_match.group(1)),
        "leap_status": leap_match.group(1).strip(),
        "reference_id": reference_match.group(1).strip(),
        "root_delay_ms": round(root_delay_ms, 6),
        "root_dispersion_ms": round(root_dispersion_ms, 6),
        "root_distance_ms": round(root_delay_ms / 2 + root_dispersion_ms, 6),
    }


def _parse_ovs_names(value: str | None) -> set[str] | None:
    if value is None:
        return None
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, dict):
        return None
    headings = parsed.get("headings")
    data = parsed.get("data")
    if not isinstance(headings, list) or not isinstance(data, list) or "name" not in headings:
        return None
    index = headings.index("name")
    names: set[str] = set()
    for row in data:
        if not isinstance(row, list) or index >= len(row) or not isinstance(row[index], str):
            return None
        names.add(row[index])
    return names


def _parse_ovs_map(value: Any) -> dict[str, str] | None:
    if not isinstance(value, list) or len(value) != 2 or value[0] != "map":
        return None
    pairs = value[1]
    if not isinstance(pairs, list):
        return None
    result: dict[str, str] = {}
    for pair in pairs:
        if (
            not isinstance(pair, list)
            or len(pair) != 2
            or not isinstance(pair[0], str)
            or not isinstance(pair[1], str)
            or pair[0] in result
        ):
            return None
        result[pair[0]] = pair[1]
    return result


def _parse_ovs_interface_bindings(value: str | None) -> dict[str, str | None] | None:
    if value is None:
        return None
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, dict):
        return None
    headings = parsed.get("headings")
    data = parsed.get("data")
    if (
        not isinstance(headings, list)
        or not isinstance(data, list)
        or "name" not in headings
        or "external_ids" not in headings
    ):
        return None
    name_index = headings.index("name")
    external_ids_index = headings.index("external_ids")
    result: dict[str, str | None] = {}
    for row in data:
        if (
            not isinstance(row, list)
            or max(name_index, external_ids_index) >= len(row)
            or not isinstance(row[name_index], str)
        ):
            return None
        name = row[name_index]
        external_ids = _parse_ovs_map(row[external_ids_index])
        if external_ids is None or name in result:
            return None
        iface_id = external_ids.get("iface-id")
        result[name] = iface_id if isinstance(iface_id, str) and iface_id else None
    return result


def _parse_link_names(value: str | None) -> set[str] | None:
    records = _parse_json_records(value)
    if records is None:
        return None
    names = {_field(record, "ifname") for record in records}
    if not all(isinstance(name, str) and name for name in names):
        return None
    return set(names)


def _parse_interface_lines(value: str | None) -> set[str] | None:
    if value is None:
        return None
    names = [line.strip() for line in value.splitlines() if line.strip()]
    if len(names) != len(set(names)) or any(
        re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,14}", name) is None
        for name in names
    ):
        return None
    return set(names)


def _healthy_state(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    return str(value or "").strip().lower() in {
        "up",
        "enabled",
        "alive",
        "true",
        "yes",
        ":-)",
    }


def _project_service_records(
    records: list[dict[str, Any]] | None,
    expected_hosts: set[str],
    *,
    neutron: bool,
) -> tuple[list[dict[str, Any]], bool]:
    if records is None:
        return [], False
    projected: list[dict[str, Any]] = []
    seen_hosts: set[str] = set()
    all_healthy = True
    for record in records:
        host = _short_host(_field(record, "host", "hypervisor hostname"))
        if host not in expected_hosts:
            continue
        seen_hosts.add(host)
        status = _field(record, "status")
        state = _field(record, "state")
        if neutron:
            admin = _field(record, "admin state up", "admin_state_up")
            if admin is None:
                admin = state
            alive = _field(record, "alive")
            healthy = (
                _healthy_state(admin)
                and alive is not None
                and _healthy_state(alive)
            )
            service = str(_field(record, "agent type", "binary") or "")
        else:
            healthy = _healthy_state(status) and _healthy_state(state)
            service = str(_field(record, "binary", "service") or "")
        all_healthy = all_healthy and healthy
        projected.append(
            {
                "host": host,
                "service": service,
                "healthy": healthy,
            }
        )
    return projected, all_healthy and seen_hosts == expected_hosts


def _record_id(record: Mapping[str, Any]) -> str:
    value = _field(record, "id", "uuid")
    return str(value) if value is not None else "<missing>"


def _record_tags(record: Mapping[str, Any]) -> set[str] | None:
    value = _field(record, "tags")
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return {item.strip() for item in value if item.strip()}
    if isinstance(value, str):
        text = value.strip()
        if not text or text == "[]":
            return set()
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            parsed = None
        if isinstance(parsed, list) and all(
            isinstance(item, str) for item in parsed
        ):
            return {item.strip() for item in parsed if item.strip()}
        return {item.strip() for item in text.strip("[]").split(",") if item.strip()}
    return None


def _record_fixed_ipv4s(record: Mapping[str, Any]) -> set[str] | None:
    value = _field(record, "fixed ip addresses", "fixed_ips", "fixed ips")
    if value is None:
        return None
    candidates: list[Any] = []
    if isinstance(value, list):
        for item in value:
            if isinstance(item, Mapping):
                candidates.append(_field(item, "ip_address", "ip address"))
            else:
                candidates.append(item)
    elif isinstance(value, Mapping):
        candidates.append(_field(value, "ip_address", "ip address"))
    elif isinstance(value, str):
        candidates.extend(
            match.group(0)
            for match in re.finditer(r"(?:[0-9]{1,3}\.){3}[0-9]{1,3}", value)
        )
    else:
        return None
    addresses: set[str] = set()
    for candidate in candidates:
        if not isinstance(candidate, str):
            return None
        try:
            address = ipaddress.ip_address(candidate.strip())
        except ValueError:
            return None
        if isinstance(address, ipaddress.IPv4Address):
            addresses.add(str(address))
    return addresses


def _active_migrations(records: list[dict[str, Any]] | None) -> list[str] | None:
    if records is None:
        return None
    terminal = {
        "completed",
        "confirmed",
        "done",
        "error",
        "failed",
        "cancel",
        "canceled",
        "cancelled",
        "reverted",
    }
    return sorted(
        _record_id(record)
        for record in records
        if str(_field(record, "status") or "").strip().lower() not in terminal
    )


def _unrelated_servers(
    records: list[dict[str, Any]] | None,
    compute_hosts: set[str],
    allowed_ids: set[str],
) -> list[str] | None:
    if records is None:
        return None
    unrelated: set[str] = set()
    for record in records:
        host = _short_host(
            _field(
                record,
                "host",
                "OS-EXT-SRV-ATTR:host",
                "hypervisor hostname",
            )
        )
        server_id = _record_id(record)
        if host in compute_hosts and server_id not in allowed_ids:
            unrelated.add(server_id)
    return sorted(unrelated)


def _owned_servers(
    records: list[dict[str, Any]] | None,
    allowed_ids: set[str],
    source_host: str,
    allowed_domains: set[str],
    owner_project_id: str,
    ownership_tag: str,
) -> tuple[list[dict[str, Any]], bool]:
    evidence: list[dict[str, Any]] = []
    if records is None:
        return evidence, False
    records_by_id: dict[str, list[dict[str, Any]]] = {}
    for record in records:
        records_by_id.setdefault(_record_id(record), []).append(record)
    observed_domains: set[str] = set()
    all_healthy = True
    for server_id in sorted(allowed_ids):
        matches = records_by_id.get(server_id, [])
        item: dict[str, Any] = {
            "server_id": server_id,
            "record_count": len(matches),
        }
        healthy = len(matches) == 1
        if healthy:
            record = matches[0]
            host = _short_host(
                _field(record, "host", "OS-EXT-SRV-ATTR:host")
            )
            status = str(_field(record, "status") or "").strip().lower()
            instance_name = str(
                _field(
                    record,
                    "instance name",
                    "OS-EXT-SRV-ATTR:instance_name",
                )
                or ""
            ).strip()
            project_id = str(
                _field(record, "project id", "project_id", "project") or ""
            ).strip()
            tags = _record_tags(record)
            item.update(
                {
                    "host": host,
                    "status": status,
                    "instance_name": instance_name,
                    "project_id": project_id,
                    "ownership_tag_present": (
                        tags is not None and ownership_tag in tags
                    ),
                }
            )
            healthy = (
                host == source_host
                and status == "active"
                and instance_name in allowed_domains
                and project_id == owner_project_id
                and tags is not None
                and ownership_tag in tags
            )
            if instance_name:
                observed_domains.add(instance_name)
        item["healthy"] = healthy
        all_healthy = all_healthy and healthy
        evidence.append(item)
    return evidence, all_healthy and observed_domains == allowed_domains


def _owned_ports(
    records: list[dict[str, Any]] | None,
    port_server_bindings: Mapping[str, str],
    port_fixed_ipv4s: Mapping[str, str],
    port_mac_addresses: Mapping[str, str],
    source_host: str,
    owner_project_id: str,
    ownership_tag: str,
) -> tuple[list[dict[str, Any]], bool]:
    evidence: list[dict[str, Any]] = []
    if records is None:
        return evidence, False
    records_by_id: dict[str, list[dict[str, Any]]] = {}
    for record in records:
        records_by_id.setdefault(_record_id(record), []).append(record)
    allowed_servers = set(port_server_bindings.values())
    unexpected = []
    for record in records:
        server_id = str(_field(record, "device id", "device_id") or "").strip()
        port_id = _record_id(record)
        if server_id in allowed_servers and port_id not in port_server_bindings:
            unexpected.append(
                {
                    "port_id": port_id,
                    "server_id": server_id,
                    "unexpected": True,
                    "healthy": False,
                }
            )
    all_healthy = not unexpected
    for port_id, expected_server_id in sorted(port_server_bindings.items()):
        matches = records_by_id.get(port_id, [])
        item: dict[str, Any] = {
            "port_id": port_id,
            "expected_server_id": expected_server_id,
            "record_count": len(matches),
        }
        healthy = len(matches) == 1
        if healthy:
            record = matches[0]
            server_id = str(_field(record, "device id", "device_id") or "").strip()
            binding_host = _short_host(
                _field(record, "binding host id", "binding_host_id", "host")
            )
            status = str(_field(record, "status") or "").strip().lower()
            device_owner = str(
                _field(record, "device owner", "device_owner") or ""
            ).strip().lower()
            project_id = str(
                _field(record, "project id", "project_id", "project") or ""
            ).strip()
            tags = _record_tags(record)
            fixed_ipv4s = _record_fixed_ipv4s(record)
            mac_address = str(
                _field(record, "mac address", "mac_address") or ""
            ).strip().lower()
            item.update(
                {
                    "server_id": server_id,
                    "binding_host": binding_host,
                    "status": status,
                    "device_owner": device_owner,
                    "project_id": project_id,
                    "ownership_tag_present": (
                        tags is not None and ownership_tag in tags
                    ),
                    "fixed_ipv4s": sorted(fixed_ipv4s or []),
                    "mac_address": mac_address,
                }
            )
            healthy = (
                server_id == expected_server_id
                and binding_host == source_host
                and status == "active"
                and device_owner.startswith("compute:")
                and project_id == owner_project_id
                and tags is not None
                and ownership_tag in tags
                and fixed_ipv4s == {port_fixed_ipv4s[port_id]}
                and mac_address == port_mac_addresses[port_id]
            )
        item["healthy"] = healthy
        all_healthy = all_healthy and healthy
        evidence.append(item)
    evidence.extend(sorted(unexpected, key=lambda item: item["port_id"]))
    return evidence, all_healthy


def _number(record: Mapping[str, Any], *names: str) -> float | None:
    value = _field(record, *names)
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(value):
        return float(value)
    if isinstance(value, str):
        try:
            parsed = float(value.strip())
        except ValueError:
            return None
        return parsed if math.isfinite(parsed) else None
    return None


def _target_capacity(
    records: list[dict[str, Any]] | None,
    target_host: str,
    minimum: Mapping[str, int],
) -> tuple[dict[str, Any], bool]:
    evidence: dict[str, Any] = {"target_host": target_host, "available": False}
    if records is None:
        return evidence, False
    matches = [
        record
        for record in records
        if _short_host(_field(record, "hypervisor hostname", "host")) == target_host
    ]
    if len(matches) != 1:
        return evidence, False
    record = matches[0]
    totals = {
        "vcpus": _number(record, "vcpus"),
        "memory_mb": _number(record, "memory mb", "memory_mb"),
        "disk_gb": _number(record, "local gb", "local_gb"),
    }
    used = {
        "vcpus": _number(record, "vcpus used", "vcpus_used"),
        "memory_mb": _number(record, "memory mb used", "memory_mb_used"),
        "disk_gb": _number(record, "local gb used", "local_gb_used"),
    }
    if any(value is None for value in (*totals.values(), *used.values())):
        return evidence, False
    if any(value < 0 for value in (*totals.values(), *used.values())):
        return evidence, False
    free = {name: round(totals[name] - used[name], 3) for name in totals}
    healthy = _healthy_state(_field(record, "status")) and _healthy_state(
        _field(record, "state")
    )
    enough = all(free[name] >= minimum[name] for name in minimum)
    evidence.update(
        {
            "available": True,
            "healthy": healthy,
            "total": totals,
            "used": used,
            "free": free,
            "minimum": dict(minimum),
        }
    )
    return evidence, healthy and enough


def _add_gate(gates: list[dict[str, Any]], name: str, passed: bool) -> None:
    gates.append({"name": name, "passed": bool(passed)})


def _inventory_evidence(inventory: Mapping[str, Any]) -> dict[str, Any]:
    roles: dict[str, dict[str, Any]] = {}
    for role in ROLES:
        node = inventory["roles"][role]
        roles[role] = {
            "address": node["address"],
            "expected_hostname": node["expected_hostname"],
            "host_key_fingerprint": node["host_key_fingerprint"],
        }
    canonical = json.dumps(
        inventory, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    return {
        "schema_version": inventory["schema_version"],
        "sha256": hashlib.sha256(canonical).hexdigest(),
        "clock_tolerance_ms": inventory["clock_tolerance_ms"],
        "allowed_server_ids": list(inventory["allowed_server_ids"]),
        "allowed_port_ids": list(inventory["allowed_port_ids"]),
        "owner_project_id": inventory["owner_project_id"],
        "ownership_tag": inventory["ownership_tag"],
        "port_server_bindings": dict(inventory["port_server_bindings"]),
        "port_fixed_ipv4s": dict(inventory["port_fixed_ipv4s"]),
        "port_mac_addresses": dict(inventory["port_mac_addresses"]),
        "minimum_target_capacity": dict(inventory["minimum_target_capacity"]),
        "roles": roles,
    }


def run_preflight(
    inventory_value: Any,
    runner: Any,
    *,
    timeout: float = 15.0,
) -> dict[str, Any]:
    """Run every preflight check and return credential-free JSON evidence."""

    inventory = validate_inventory(inventory_value)
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)):
        raise ValueError("timeout must be a number")
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("timeout must be positive")

    collection_started_at = _utc_now()
    gates: list[dict[str, Any]] = []
    commands: list[dict[str, Any]] = []
    outputs: dict[tuple[str, str], str | None] = {}
    identity: list[dict[str, Any]] = []
    _add_gate(gates, "inventory.valid", True)

    verified_roles: set[str] = set()
    for role in ROLES:
        node = inventory["roles"][role]
        expected_fingerprint = node["host_key_fingerprint"]
        item: dict[str, Any] = {
            "role": role,
            "address": node["address"],
            "expected_hostname": node["expected_hostname"],
            "expected_host_key_fingerprint": expected_fingerprint,
        }
        try:
            observed_fingerprint = runner.verify_host_key(role, node, timeout)
        except Exception as error:
            item.update(
                {
                    "host_key_verified": False,
                    "verification_error_type": _safe_error_type(error),
                }
            )
        else:
            valid_observation = (
                isinstance(observed_fingerprint, str)
                and _FINGERPRINT_RE.fullmatch(observed_fingerprint) is not None
            )
            if valid_observation:
                item["observed_host_key_fingerprint"] = observed_fingerprint
            item["host_key_verified"] = (
                valid_observation and observed_fingerprint == expected_fingerprint
            )
            if item["host_key_verified"]:
                verified_roles.add(role)
        identity.append(item)
        _add_gate(gates, f"host_key.{role}", item["host_key_verified"])

    for role in ROLES:
        if role not in verified_roles:
            continue
        node = inventory["roles"][role]
        for command_id in READ_ONLY_COMMANDS[role]:
            outputs[(role, command_id)] = _run_command(
                runner,
                role,
                node,
                command_id,
                float(timeout),
                commands,
            )

    confirmation_started_at = _utc_now()
    confirmation_started_monotonic = time.monotonic()
    confirmation_record_start = len(commands)
    for role in ROLES:
        if role not in verified_roles:
            continue
        node = inventory["roles"][role]
        for command_id in SNAPSHOT_CONFIRMATION_COMMANDS[role]:
            outputs[(role, command_id)] = _run_command(
                runner,
                role,
                node,
                command_id,
                float(timeout),
                commands,
                phase="confirmation",
            )
    confirmation_duration_seconds = max(
        0.0, time.monotonic() - confirmation_started_monotonic
    )
    confirmation_completed_at = _utc_now()
    confirmation_records = commands[confirmation_record_start:]
    confirmation_succeeded = (
        len(confirmation_records) == SNAPSHOT_CONFIRMATION_COMMAND_COUNT
        and all(record["status"] == "ok" for record in confirmation_records)
        and confirmation_duration_seconds <= MAX_SNAPSHOT_CONFIRMATION_SECONDS
    )
    snapshot_evidence = {
        "collection_started_at": collection_started_at,
        "confirmation_started_at": confirmation_started_at,
        "confirmation_completed_at": confirmation_completed_at,
        "duration_ms": round(confirmation_duration_seconds * 1000.0, 3),
        "command_count": len(confirmation_records),
        "required_command_count": SNAPSHOT_CONFIRMATION_COMMAND_COUNT,
        "max_duration_seconds": MAX_SNAPSHOT_CONFIRMATION_SECONDS,
        "confirmed": confirmation_succeeded,
    }
    _add_gate(gates, "snapshot.confirmed", confirmation_succeeded)

    commands_succeeded = (
        len(commands)
        == sum(len(READ_ONLY_COMMANDS[role]) for role in ROLES)
        + SNAPSHOT_CONFIRMATION_COMMAND_COUNT
        and all(record["status"] == "ok" for record in commands)
    )
    _add_gate(gates, "commands.success", commands_succeeded)

    for item in identity:
        role = item["role"]
        output = outputs.get((role, "hostname"))
        observed = output.strip() if output is not None else None
        item["observed_hostname"] = observed
        hostname_matches = observed == item["expected_hostname"]
        item["hostname_verified"] = hostname_matches
        _add_gate(gates, f"hostname.{role}", hostname_matches)

    clocks = {
        role: _parse_clock(outputs.get((role, "clock_tracking"))) for role in ROLES
    }
    valid_offsets = [
        item["offset_ms"] for item in clocks.values() if item.get("valid")
    ]
    reference_ids = {
        item["reference_id"] for item in clocks.values() if item.get("valid")
    }
    reference_consistent = len(reference_ids) == 1 and len(valid_offsets) == len(ROLES)
    reference_matches = {
        role: clocks[role].get("valid") is True
        and clocks[role].get("reference_id")
        == inventory["roles"][role]["expected_clock_reference"]
        for role in ROLES
    }
    reference_topology_verified = all(reference_matches.values())
    error_bounds = sorted(
        (
            abs(item["offset_ms"]) + item["root_distance_ms"]
            for item in clocks.values()
            if item.get("valid")
        ),
        reverse=True,
    )
    max_pairwise_error_bound = (
        sum(error_bounds[:2]) if len(error_bounds) == len(ROLES) else None
    )
    tolerance = inventory["clock_tolerance_ms"]
    max_absolute_offset = (
        max((abs(value) for value in valid_offsets), default=0.0)
        if len(valid_offsets) == len(ROLES)
        else None
    )
    max_pairwise_offset = (
        max(valid_offsets) - min(valid_offsets)
        if len(valid_offsets) == len(ROLES)
        else None
    )
    clocks_healthy = all(
        item.get("valid")
        and item.get("stratum", 0) > 0
        and str(item.get("leap_status", "")).lower() == "normal"
        and bool(item.get("reference_id"))
        for item in clocks.values()
    ) and (
        reference_topology_verified
        and max_pairwise_error_bound is not None
        and max_pairwise_error_bound <= tolerance
    )
    clock_evidence = {
        "tolerance_ms": tolerance,
        "reference_consistent": reference_consistent,
        "reference_topology_verified": reference_topology_verified,
        "reference_matches": reference_matches,
        "max_absolute_offset_ms": max_absolute_offset,
        "max_pairwise_offset_ms": max_pairwise_offset,
        "max_pairwise_error_bound_ms": max_pairwise_error_bound,
        "roles": clocks,
    }
    _add_gate(gates, "clock.synchronized", clocks_healthy)

    session_evidence: dict[str, dict[str, Any]] = {}
    sessions_clear = True
    for role in ROLES:
        value = outputs.get((role, "active_sessions"))
        if value is None:
            session_evidence[role] = {"available": False, "count": None}
            sessions_clear = False
            continue
        lines = [line for line in value.splitlines() if line.strip()]
        encoded = value.encode("utf-8", errors="replace")
        session_evidence[role] = {
            "available": True,
            "count": len(lines),
            "evidence_sha256": hashlib.sha256(encoded).hexdigest(),
        }
        sessions_clear = sessions_clear and not lines
    _add_gate(gates, "sessions.clear", sessions_clear)

    expected_hosts = {
        _short_host(inventory["roles"][role]["expected_hostname"]) for role in ROLES
    }
    compute_hosts = {
        _short_host(inventory["roles"][role]["expected_hostname"])
        for role in COMPUTE_ROLES
    }
    nova_records = _parse_json_records(outputs.get(("controller", "nova_services")))
    neutron_records = _parse_json_records(
        outputs.get(("controller", "neutron_agents"))
    )
    nova_evidence, nova_healthy = _project_service_records(
        nova_records, expected_hosts, neutron=False
    )
    neutron_evidence, neutron_healthy = _project_service_records(
        neutron_records, expected_hosts, neutron=True
    )
    nova_services_by_host: dict[str, set[str]] = {}
    for item in nova_evidence:
        if item["healthy"]:
            nova_services_by_host.setdefault(item["host"], set()).add(
                item["service"].strip().lower()
            )
    nova_requirements = {
        "controller": {"nova-scheduler", "nova-conductor"},
        "compute2": {"nova-compute"},
        "compute3": {"nova-compute"},
    }
    nova_healthy = nova_healthy and all(
        required <= nova_services_by_host.get(host, set())
        for host, required in nova_requirements.items()
    )
    neutron_services_by_host: dict[str, list[str]] = {}
    for item in neutron_evidence:
        if item["healthy"]:
            neutron_services_by_host.setdefault(item["host"], []).append(
                item["service"].strip().lower()
            )
    neutron_healthy = neutron_healthy and all(
        any(
            "ovn controller" in service or "open vswitch" in service
            for service in neutron_services_by_host.get(host, [])
        )
        for host in compute_hosts
    )
    _add_gate(gates, "nova.services", nova_healthy)
    _add_gate(gates, "neutron.agents", neutron_healthy)

    migration_records = _parse_json_records(outputs.get(("controller", "migrations")))
    active_migration_ids = _active_migrations(migration_records)
    migrations_idle = active_migration_ids == []
    migration_evidence = {
        "available": active_migration_ids is not None,
        "active_ids": active_migration_ids or [],
    }
    _add_gate(gates, "migrations.idle", migrations_idle)

    server_records = _parse_json_records(outputs.get(("controller", "servers")))
    port_records = _parse_json_records(outputs.get(("controller", "ports")))
    source_host = _short_host(
        inventory["roles"]["source"]["expected_hostname"]
    )
    unrelated_servers = _unrelated_servers(
        server_records,
        compute_hosts,
        set(inventory["allowed_server_ids"]),
    )
    owned_servers, owned_servers_ok = _owned_servers(
        server_records,
        set(inventory["allowed_server_ids"]),
        source_host,
        set(inventory["roles"]["source"]["allowed_libvirt_domains"]),
        inventory["owner_project_id"],
        inventory["ownership_tag"],
    )
    owned_ports, owned_ports_ok = _owned_ports(
        port_records,
        inventory["port_server_bindings"],
        inventory["port_fixed_ipv4s"],
        inventory["port_mac_addresses"],
        source_host,
        inventory["owner_project_id"],
        inventory["ownership_tag"],
    )
    libvirt: dict[str, dict[str, Any]] = {}
    unrelated_domains: dict[str, list[str]] = {}
    libvirt_available = True
    for role in COMPUTE_ROLES:
        value = outputs.get((role, "libvirt_domains"))
        if value is None:
            libvirt[role] = {"available": False, "active_count": None}
            unrelated_domains[role] = []
            libvirt_available = False
            continue
        domains = sorted({line.strip() for line in value.splitlines() if line.strip()})
        allowed_domains = set(inventory["roles"][role]["allowed_libvirt_domains"])
        unrelated_domains[role] = sorted(set(domains) - allowed_domains)
        libvirt[role] = {
            "available": True,
            "active_count": len(domains),
            "unrelated_domains": unrelated_domains[role],
        }
    workloads_clear = (
        unrelated_servers == []
        and libvirt_available
        and not any(unrelated_domains.values())
    )
    workload_evidence = {
        "server_inventory_available": unrelated_servers is not None,
        "unrelated_server_ids": unrelated_servers or [],
        "libvirt": libvirt,
    }
    _add_gate(gates, "workloads.clear", workloads_clear)
    _add_gate(gates, "resources.servers", owned_servers_ok)
    _add_gate(gates, "resources.ports", owned_ports_ok)

    hypervisor_records = _parse_json_records(
        outputs.get(("controller", "hypervisors"))
    )
    target_host = _short_host(inventory["roles"]["target"]["expected_hostname"])
    capacity_evidence, capacity_ok = _target_capacity(
        hypervisor_records,
        target_host,
        inventory["minimum_target_capacity"],
    )
    _add_gate(gates, "capacity.target", capacity_ok)

    ovs_evidence: dict[str, dict[str, Any]] = {}
    owned_tap_names = set(
        inventory["roles"]["source"]["required_tap_interfaces"]
    )
    allowed_port_ids = set(inventory["allowed_port_ids"])
    for role in COMPUTE_ROLES:
        node = inventory["roles"][role]
        bridges = _parse_ovs_names(outputs.get((role, "ovs_bridges")))
        interfaces = _parse_ovs_interface_bindings(
            outputs.get((role, "ovs_interfaces"))
        )
        br_int_ports = _parse_interface_lines(
            outputs.get((role, "br_int_ports"))
        )
        links = _parse_link_names(outputs.get((role, "links")))
        required_bridges = set(node["required_ovs_bridges"])
        required_taps = set(node["required_tap_interfaces"])
        required_bindings = node["required_port_bindings"]
        interface_names = set(interfaces) if interfaces is not None else None
        missing_bridges = (
            sorted(required_bridges - bridges) if bridges is not None else sorted(required_bridges)
        )
        missing_ovs_taps = (
            sorted(required_taps - interface_names)
            if interface_names is not None
            else sorted(required_taps)
        )
        missing_link_taps = (
            sorted(required_taps - links) if links is not None else sorted(required_taps)
        )
        missing_br_int_taps = (
            sorted(required_taps - br_int_ports)
            if br_int_ports is not None
            else sorted(required_taps)
        )
        mismatched_port_bindings = []
        unexpected_owned_bindings = []
        if interfaces is None:
            mismatched_port_bindings = [
                {
                    "port_id": port_id,
                    "expected_interface": interface,
                    "observed_iface_id": None,
                }
                for port_id, interface in sorted(required_bindings.items())
            ]
        else:
            for port_id in sorted(allowed_port_ids):
                expected_interface = required_bindings.get(port_id)
                observed_interfaces = sorted(
                    name
                    for name, iface_id in interfaces.items()
                    if iface_id == port_id
                )
                expected_interfaces = (
                    [expected_interface] if expected_interface is not None else []
                )
                if observed_interfaces != expected_interfaces:
                    mismatched_port_bindings.append(
                        {
                            "port_id": port_id,
                            "expected_interface": expected_interface,
                            "observed_interfaces": observed_interfaces,
                        }
                    )
            unexpected_owned_bindings = sorted(
                name
                for name, iface_id in interfaces.items()
                if iface_id in allowed_port_ids and name not in required_taps
            )
        unexpected_owned_taps = []
        if role == "target":
            observed_names = set()
            for collection in (interface_names, links, br_int_ports):
                if collection is not None:
                    observed_names.update(owned_tap_names & collection)
            unexpected_owned_taps = sorted(observed_names)
        ovs_ok = bridges is not None and not missing_bridges
        taps_ok = (
            interfaces is not None
            and links is not None
            and br_int_ports is not None
            and not missing_ovs_taps
            and not missing_link_taps
            and not missing_br_int_taps
            and not mismatched_port_bindings
            and not unexpected_owned_bindings
            and not unexpected_owned_taps
        )
        ovs_evidence[role] = {
            "available": (
                bridges is not None
                and interfaces is not None
                and links is not None
                and br_int_ports is not None
            ),
            "missing_bridges": missing_bridges,
            "missing_ovs_tap_interfaces": missing_ovs_taps,
            "missing_link_tap_interfaces": missing_link_taps,
            "missing_br_int_tap_interfaces": missing_br_int_taps,
            "mismatched_port_bindings": mismatched_port_bindings,
            "unexpected_owned_bindings": unexpected_owned_bindings,
            "unexpected_owned_tap_interfaces": unexpected_owned_taps,
        }
        _add_gate(gates, f"ovs.{role}", ovs_ok)
        _add_gate(gates, f"tap.{role}", taps_ok)

    deploy_allowed = bool(gates) and all(item["passed"] for item in gates)
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": _utc_now(),
        "status": "allowed" if deploy_allowed else "blocked",
        "deploy_allowed": deploy_allowed,
        "inventory": _inventory_evidence(inventory),
        "snapshot": snapshot_evidence,
        "host_identity": identity,
        "clock": clock_evidence,
        "sessions": session_evidence,
        "services": {"nova": nova_evidence, "neutron": neutron_evidence},
        "migrations": migration_evidence,
        "workloads": workload_evidence,
        "resources": {"servers": owned_servers, "ports": owned_ports},
        "capacity": capacity_evidence,
        "ovs_tap": ovs_evidence,
        "commands": commands,
        "gates": gates,
    }


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise InventoryError(f"duplicate JSON field: {key}")
        result[key] = value
    return result


def load_inventory(path: Path) -> dict[str, Any]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise InventoryError("inventory could not be read") from error
    try:
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(
                InventoryError("inventory contains a non-finite number")
            ),
        )
    except json.JSONDecodeError as error:
        raise InventoryError("inventory is not valid JSON") from error
    return validate_inventory(value)


def _fsync_parent_directory(path: Path) -> None:
    if os.name == "nt":
        return
    descriptor = os.open(
        path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    )
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_write_json(
    path: Path, value: Mapping[str, Any], *, exclusive: bool = False
) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent)
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, sort_keys=True, indent=2, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if exclusive:
            if os.name == "nt":
                os.rename(temporary, path)
            else:
                os.link(temporary, path)
                temporary.unlink()
        else:
            os.replace(temporary, path)
        _fsync_parent_directory(path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _invalid_inventory_report() -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": _utc_now(),
        "status": "invalid_inventory",
        "deploy_allowed": False,
        "commands": [],
        "gates": [{"name": "inventory.valid", "passed": False}],
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--identity-file", type=Path)
    return parser


def main(argv: Sequence[str] | None = None, *, runner: Any = None) -> int:
    args = build_parser().parse_args(argv)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        build_parser().error("--timeout must be positive")
    if os.path.lexists(args.output):
        print(
            "openstack_shared_cluster_preflight: output already exists",
            file=sys.stderr,
        )
        return 2
    try:
        inventory = load_inventory(args.inventory)
    except InventoryError:
        report = _invalid_inventory_report()
        try:
            atomic_write_json(args.output, report, exclusive=True)
        except OSError:
            print("openstack_shared_cluster_preflight: output write failed", file=sys.stderr)
            return 1
        print("openstack_shared_cluster_preflight: invalid inventory", file=sys.stderr)
        return 2

    owns_runner = runner is None
    if owns_runner and args.identity_file is None:
        print(
            "openstack_shared_cluster_preflight: --identity-file is required",
            file=sys.stderr,
        )
        return 2
    try:
        active_runner = (
            runner
            if runner is not None
            else SSHReadOnlyRunner(identity_file=args.identity_file)
        )
    except RunnerError:
        print(
            "openstack_shared_cluster_preflight: SSH identity is unsafe",
            file=sys.stderr,
        )
        return 2
    try:
        report = run_preflight(inventory, active_runner, timeout=args.timeout)
    finally:
        if owns_runner:
            active_runner.close()
    try:
        atomic_write_json(args.output, report, exclusive=True)
    except OSError:
        print("openstack_shared_cluster_preflight: output write failed", file=sys.stderr)
        return 1
    failed_gates = [item["name"] for item in report["gates"] if not item["passed"]]
    print(
        json.dumps(
            {
                "deploy_allowed": report["deploy_allowed"],
                "failed_gates": failed_gates,
                "output": str(args.output),
                "status": report["status"],
            },
            sort_keys=True,
        )
    )
    return 0 if report["deploy_allowed"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
