#!/usr/bin/env python3
"""Render a credential-free deployment bundle for the shared Yoga cluster."""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Sequence

try:
    from bench.openstack_shared_cluster_preflight import (
        InventoryError,
        validate_inventory,
    )
except ImportError:  # Direct execution from linux_accel/bench.
    from openstack_shared_cluster_preflight import (  # type: ignore
        InventoryError,
        validate_inventory,
    )


SCHEMA_VERSION = 1
CONFIG_ROOT = PurePosixPath("/etc/vnet-dataplane-shared")
INSTALL_ROOT = PurePosixPath("/opt/vnet-dataplane-shared")
AGENT_RUNTIME_ROOT = PurePosixPath("/run/vnet-dataplane-shared-agent")
METRICS_RUNTIME_ROOT = PurePosixPath("/run/vnet-dataplane-shared-metrics")
AGENT_PIN_ROOT = PurePosixPath("/sys/fs/bpf/vnet-dataplane-shared")
GUEST_RUNTIME_ROOT = PurePosixPath("/run/vnet-dataplane-guest")
GUEST_LOG_ROOT = PurePosixPath("/var/log/vnet-dataplane-guest")
GUEST_PIN_ROOT = PurePosixPath("/sys/fs/bpf/vnet-dataplane-guest")
POLICY_LOCK_ROOT = PurePosixPath("/run/vnet-dataplane-policy")
KNOWN_HOSTS_ROOT = PurePosixPath("/etc/vnet-dataplane-agent")

_DEPLOYMENT_RE = re.compile(r"[a-z][a-z0-9-]{2,31}")
_SAFE_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}")
_INTERFACE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,14}")
_MAC_RE = re.compile(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}")
_RFC1918_NETWORKS = tuple(
    ipaddress.IPv4Network(value)
    for value in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
)

_ARTIFACTS = {
    "controller": (
        ("linux_accel/agent/openstack_epoch_coordinator.py", "0755"),
        ("linux_accel/agent/openstack_epoch_gate.py", "0644"),
        ("linux_accel/agent/openstack_metrics_bridge.py", "0755"),
        ("linux_accel/build/dynamic_cache_controller", "0755"),
    ),
    "compute": (
        ("linux_accel/agent/openstack_dataplane_agent.py", "0755"),
        ("linux_accel/agent/openstack_metrics_bridge.py", "0755"),
        ("linux_accel/build/dns_monitor", "0755"),
        ("linux_accel/build/dns_client_cache.bpf.o", "0644"),
        ("linux_accel/build/dns_monitor.bpf.o", "0644"),
        ("linux_accel/build/grpc_monitor", "0755"),
        ("linux_accel/build/grpc_monitor.bpf.o", "0644"),
        ("linux_accel/build/cache_policy_txn", "0755"),
    ),
}

_UNIT_ARTIFACTS = {
    "controller": (
        "vnet-dataplane-shared-metrics-controller.service",
        "vnet-dataplane-shared-epoch-coordinator.service",
    ),
    "compute": ("vnet-dataplane-shared-agent.service",),
}


class BundleError(ValueError):
    """The requested deployment bundle is unsafe or internally inconsistent."""


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise BundleError(f"duplicate topology field: {key}")
        result[key] = value
    return result


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode("utf-8")


def required_artifact_paths() -> tuple[str, ...]:
    values = {
        relative
        for records in _ARTIFACTS.values()
        for relative, _mode in records
    }
    values.update(
        f"linux_accel/deploy/systemd/{name}"
        for records in _UNIT_ARTIFACTS.values()
        for name in records
    )
    return tuple(sorted(values))


def _read_artifact(root: Path, relative: str) -> bytes:
    path = root / Path(relative)
    try:
        if root.is_symlink() or not root.is_dir():
            raise BundleError("artifact_root must be a real directory")
        current = root
        for part in Path(relative).parts:
            current = current / part
            if current.is_symlink():
                raise BundleError(f"required artifact is a symlink: {relative}")
        if not path.is_file():
            raise BundleError(f"required artifact is missing or unsafe: {relative}")
        size = path.stat().st_size
        if size <= 0 or size > 128 * 1024 * 1024:
            raise BundleError(f"required artifact has an unsafe size: {relative}")
        return path.read_bytes()
    except OSError as error:
        raise BundleError(f"cannot read required artifact: {relative}") from error


def _pretty_json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("ascii")


def _mapping(value: Any, field: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise BundleError(f"{field} must be an object")
    return value


def _reject_unknown(value: Mapping[str, Any], allowed: set[str], field: str) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise BundleError(f"{field} has unknown field(s): {', '.join(unknown)}")


def _text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise BundleError(f"{field} must be a non-empty string")
    result = value.strip()
    if any(ord(character) < 32 or ord(character) == 127 for character in result):
        raise BundleError(f"{field} contains a control character")
    return result


def _canonical_uuid(value: Any, field: str) -> str:
    candidate = _text(value, field)
    try:
        normalized = str(uuid.UUID(candidate))
    except (ValueError, AttributeError) as error:
        raise BundleError(f"{field} must be a canonical UUID") from error
    if candidate != normalized:
        raise BundleError(f"{field} must be a canonical UUID")
    return normalized


def _private_ipv4(value: Any, field: str) -> str:
    candidate = _text(value, field)
    try:
        address = ipaddress.IPv4Address(candidate)
    except ipaddress.AddressValueError as error:
        raise BundleError(f"{field} must be a canonical private IPv4 address") from error
    if (
        str(address) != candidate
        or not any(address in network for network in _RFC1918_NETWORKS)
        or address.is_loopback
        or address.is_link_local
        or address.is_multicast
        or address.is_unspecified
        or address.is_reserved
    ):
        raise BundleError(f"{field} must be a canonical private IPv4 address")
    return candidate


def _canonical_mac(value: Any, field: str) -> str:
    candidate = _text(value, field)
    if not _MAC_RE.fullmatch(candidate):
        raise BundleError(f"{field} must be a canonical lowercase MAC address")
    first_octet = int(candidate[:2], 16)
    if candidate == "00:00:00:00:00:00" or first_octet & 1:
        raise BundleError(f"{field} must be a unicast MAC address")
    return candidate


def _safe_name(value: Any, field: str, *, label: str) -> str:
    candidate = _text(value, field)
    if not _SAFE_NAME_RE.fullmatch(candidate):
        raise BundleError(f"{field} must be a safe {label}")
    return candidate


def _interface(value: Any, field: str) -> str:
    candidate = _text(value, field)
    if not _INTERFACE_RE.fullmatch(candidate) or candidate in {".", ".."}:
        raise BundleError(f"{field} must be a safe Linux interface name")
    return candidate


def _ssh_destination(
    value: Any,
    field: str,
    *,
    expected_user: str,
    expected_address: str,
) -> str:
    destination = _text(value, field)
    if destination.count("@") != 1:
        raise BundleError(f"{field} must be an explicit user@private-IPv4 destination")
    user, address_value = destination.split("@", 1)
    address = _private_ipv4(address_value, f"{field} address")
    if user != expected_user or address != expected_address:
        raise BundleError(f"{field} does not match its validated inventory identity")
    return destination


def _validate_hosts(
    value: Any,
    inventory: Mapping[str, Any],
) -> dict[str, dict[str, str]]:
    hosts = _mapping(value, "hosts")
    if set(hosts) != {"controller", "source", "target"}:
        raise BundleError("hosts must contain exactly controller, source, and target")
    result: dict[str, dict[str, str]] = {}
    for role in ("controller", "source", "target"):
        item = _mapping(hosts[role], f"hosts.{role}")
        allowed = {"ssh_destination"} if role == "controller" else {
            "nova_host",
            "ssh_destination",
        }
        _reject_unknown(item, allowed, f"hosts.{role}")
        node = inventory["roles"][role]
        normalized: dict[str, str] = {
            "ssh_destination": _ssh_destination(
                item.get("ssh_destination"),
                f"hosts.{role}.ssh_destination",
                expected_user=node["ssh_user"],
                expected_address=node["address"],
            )
        }
        if role != "controller":
            nova_host = _safe_name(
                item.get("nova_host"),
                f"hosts.{role}.nova_host",
                label="Nova host name",
            )
            if nova_host != node["expected_hostname"]:
                raise BundleError(
                    f"hosts.{role}.Nova host does not match expected_hostname"
                )
            normalized["nova_host"] = nova_host
        result[role] = normalized
    return result


def _validate_interfaces(value: Any) -> dict[str, dict[str, str]]:
    interfaces = _mapping(value, "interfaces")
    if set(interfaces) != {"source", "target"}:
        raise BundleError("interfaces must contain exactly source and target")
    result: dict[str, dict[str, str]] = {}
    for role in ("source", "target"):
        item = _mapping(interfaces[role], f"interfaces.{role}")
        if set(item) != {"client", "backend"}:
            raise BundleError(
                f"interfaces.{role} must contain exactly client and backend"
            )
        normalized = {
            endpoint: _interface(
                item[endpoint], f"interfaces.{role}.{endpoint} interface"
            )
            for endpoint in ("client", "backend")
        }
        if len(set(normalized.values())) != 2:
            raise BundleError(f"interfaces.{role} interface names must be unique")
        result[role] = normalized
    return result


def _validate_guests(
    value: Any,
    inventory: Mapping[str, Any],
) -> dict[str, dict[str, str]]:
    guests = _mapping(value, "guests")
    if set(guests) != {"client", "backend"}:
        raise BundleError("guests must contain exactly client and backend")
    result: dict[str, dict[str, str]] = {}
    for role in ("client", "backend"):
        item = _mapping(guests[role], f"guests.{role}")
        _reject_unknown(
            item,
            {
                "server_id",
                "port_id",
                "private_ipv4",
                "mac_address",
                "ssh_destination",
                "interface",
            },
            f"guests.{role}",
        )
        private_address = _private_ipv4(
            item.get("private_ipv4"), f"guests.{role}.private_ipv4"
        )
        result[role] = {
            "server_id": _canonical_uuid(
                item.get("server_id"), f"guests.{role}.server_id"
            ),
            "port_id": _canonical_uuid(
                item.get("port_id"), f"guests.{role}.port_id"
            ),
            "private_ipv4": private_address,
            "mac_address": _canonical_mac(
                item.get("mac_address"), f"guests.{role}.mac_address"
            ),
            "ssh_destination": _ssh_destination(
                item.get("ssh_destination"),
                f"guests.{role}.ssh_destination",
                expected_user="ubuntu",
                expected_address=private_address,
            ),
            "interface": _interface(
                item.get("interface"), f"guests.{role}.interface"
            ),
        }
    if result["client"]["server_id"] == result["backend"]["server_id"]:
        raise BundleError("guest server UUIDs must be unique")
    if result["client"]["port_id"] == result["backend"]["port_id"]:
        raise BundleError("guest port UUIDs must be unique")
    if result["client"]["private_ipv4"] == result["backend"]["private_ipv4"]:
        raise BundleError("guest private IPv4 addresses must be unique")
    if result["client"]["mac_address"] == result["backend"]["mac_address"]:
        raise BundleError("guest MAC addresses must be unique")
    expected_servers = {
        result["client"]["server_id"],
        result["backend"]["server_id"],
    }
    if set(inventory["allowed_server_ids"]) != expected_servers:
        raise BundleError(
            "inventory.allowed_server_ids must exactly match the two guest server UUIDs"
        )
    return result


def validate_topology(value: Any) -> dict[str, Any]:
    root = _mapping(value, "topology")
    _reject_unknown(
        root,
        {
            "schema_version",
            "deployment_id",
            "known_hosts_file",
            "inventory",
            "hosts",
            "interfaces",
            "guests",
        },
        "topology",
    )
    if (
        isinstance(root.get("schema_version"), bool)
        or root.get("schema_version") != SCHEMA_VERSION
    ):
        raise BundleError(f"topology schema_version must be {SCHEMA_VERSION}")
    deployment_id = _text(root.get("deployment_id"), "deployment_id")
    if not _DEPLOYMENT_RE.fullmatch(deployment_id):
        raise BundleError("deployment_id must be a safe lowercase deployment name")
    try:
        inventory = validate_inventory(root.get("inventory"))
    except InventoryError as error:
        raise BundleError(f"inventory is invalid: {error}") from error
    known_hosts_value = _text(root.get("known_hosts_file"), "known_hosts_file")
    known_hosts = PurePosixPath(known_hosts_value)
    expected_known_hosts = KNOWN_HOSTS_ROOT / f"known_hosts.{deployment_id}"
    if known_hosts != expected_known_hosts or str(known_hosts) != known_hosts_value:
        raise BundleError(
            f"known_hosts_file must be exactly {expected_known_hosts}"
        )
    hosts = _validate_hosts(root.get("hosts"), inventory)
    interfaces = _validate_interfaces(root.get("interfaces"))
    if interfaces["target"] != interfaces["source"]:
        raise BundleError(
            "target interfaces must match the source port-stable tap names"
        )
    guests = _validate_guests(root.get("guests"), inventory)
    if set(inventory["allowed_port_ids"]) != {
        guests["client"]["port_id"],
        guests["backend"]["port_id"],
    }:
        raise BundleError(
            "inventory.allowed_port_ids must exactly match the two guest port UUIDs"
        )
    if inventory["port_server_bindings"] != {
        guests["client"]["port_id"]: guests["client"]["server_id"],
        guests["backend"]["port_id"]: guests["backend"]["server_id"],
    }:
        raise BundleError(
            "inventory.port_server_bindings must match the guest port owners"
        )
    if inventory["port_fixed_ipv4s"] != {
        guests["client"]["port_id"]: guests["client"]["private_ipv4"],
        guests["backend"]["port_id"]: guests["backend"]["private_ipv4"],
    }:
        raise BundleError(
            "inventory.port_fixed_ipv4s must match the guest fixed IPv4 addresses"
        )
    if inventory["port_mac_addresses"] != {
        guests["client"]["port_id"]: guests["client"]["mac_address"],
        guests["backend"]["port_id"]: guests["backend"]["mac_address"],
    }:
        raise BundleError(
            "inventory.port_mac_addresses must match the guest MAC addresses"
        )
    source_required = set(
        inventory["roles"]["source"]["required_tap_interfaces"]
    )
    if not set(interfaces["source"].values()).issubset(source_required):
        raise BundleError(
            "source interfaces must be present in inventory required_tap_interfaces"
        )
    expected_source_bindings = {
        guests["client"]["port_id"]: interfaces["source"]["client"],
        guests["backend"]["port_id"]: interfaces["source"]["backend"],
    }
    if (
        inventory["roles"]["source"]["required_port_bindings"]
        != expected_source_bindings
    ):
        raise BundleError(
            "source required_port_bindings must match guest ports and interfaces"
        )
    return {
        "schema_version": SCHEMA_VERSION,
        "deployment_id": deployment_id,
        "known_hosts_file": known_hosts_value,
        "inventory": inventory,
        "hosts": hosts,
        "interfaces": interfaces,
        "guests": guests,
    }


def _ssh_prefix(destination: str, known_hosts: str, *, timeout: bool) -> list[str]:
    result = [
        "/usr/bin/ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        f"UserKnownHostsFile={known_hosts}",
        "-o",
        "HostKeyAlgorithms=ssh-ed25519",
    ]
    if timeout:
        result.extend(["-o", "ConnectTimeout=5"])
    result.append(destination)
    return result


def _remote_command(
    destination: str,
    known_hosts: str,
    command: Sequence[str],
) -> list[str]:
    return _ssh_prefix(destination, known_hosts, timeout=True) + list(command)


def _transaction_arguments(
    port_id: str,
    services: Sequence[str],
    *,
    guest: bool,
) -> list[str]:
    root = GUEST_PIN_ROOT if guest else AGENT_PIN_ROOT
    result = [
        "--allow-all-missing",
        "--lock-file",
        str(POLICY_LOCK_ROOT / f"vnet-dataplane-{port_id}.lock"),
        "--quiesce-file",
        str(POLICY_LOCK_ROOT / f"vnet-dataplane-{port_id}.quiesce"),
    ]
    for service in services:
        result.extend(
            [
                "--control-map",
                str(root / port_id / service / "cache_runtime_control"),
            ]
        )
    return result


def _publisher(
    *,
    name: str,
    host: str,
    destination: str,
    known_hosts: str,
    server_id: str,
    port_id: str,
    actor_id: str,
    target_kind: str,
    cache_role: str,
    services: Sequence[str],
    guest: bool,
) -> dict[str, Any]:
    transaction = str(INSTALL_ROOT / "bin/cache_policy_txn")
    command = _ssh_prefix(destination, known_hosts, timeout=False) + [
        "/usr/bin/sudo",
        "-n",
        transaction,
        *_transaction_arguments(port_id, services, guest=guest),
    ]
    return {
        "name": name,
        "host": host,
        "ssh_destination": destination,
        "server_id": server_id,
        "port_id": port_id,
        "actor_id": actor_id,
        "target_kind": target_kind,
        "cache_role": cache_role,
        "services": list(services),
        "protocol": "cache-policy-txn-v1",
        "command": command,
    }


def _coordinator_config(topology: Mapping[str, Any]) -> dict[str, Any]:
    hosts = topology["hosts"]
    guests = topology["guests"]
    known_hosts = topology["known_hosts_file"]
    client = guests["client"]
    backend = guests["backend"]
    state_sources: list[dict[str, Any]] = []
    for role in ("source", "target"):
        state_sources.append(
            {
                "name": hosts[role]["nova_host"],
                "kind": "compute_agent",
                "command": _remote_command(
                    hosts[role]["ssh_destination"],
                    known_hosts,
                    [
                        "/usr/bin/sudo",
                        "-n",
                        "/usr/bin/cat",
                        str(AGENT_RUNTIME_ROOT / "state.json"),
                    ],
                ),
            }
        )
    for role in ("client", "backend"):
        state_sources.append(
            {
                "name": f"{role}-guest",
                "kind": "guest_endpoint",
                "command": _remote_command(
                    guests[role]["ssh_destination"],
                    known_hosts,
                    [
                        "/usr/bin/sudo",
                        "-n",
                        "/usr/bin/cat",
                        str(GUEST_RUNTIME_ROOT / "state.json"),
                    ],
                ),
            }
        )

    publishers: list[dict[str, Any]] = []
    for role in ("source", "target"):
        nova_host = hosts[role]["nova_host"]
        destination = hosts[role]["ssh_destination"]
        publishers.append(
            _publisher(
                name=f"{nova_host}-client-caches",
                host=nova_host,
                destination=destination,
                known_hosts=known_hosts,
                server_id=client["server_id"],
                port_id=client["port_id"],
                actor_id="client-host-caches",
                target_kind="compute_port",
                cache_role="client",
                services=("dns", "grpc"),
                guest=False,
            )
        )
        publishers.append(
            _publisher(
                name=f"{nova_host}-backend-caches",
                host=nova_host,
                destination=destination,
                known_hosts=known_hosts,
                server_id=backend["server_id"],
                port_id=backend["port_id"],
                actor_id="backend-host-caches",
                target_kind="compute_port",
                cache_role="server",
                services=("grpc",),
                guest=False,
            )
        )
    publishers.extend(
        [
            _publisher(
                name="client-guest-grpc",
                host="client-guest",
                destination=client["ssh_destination"],
                known_hosts=known_hosts,
                server_id=client["server_id"],
                port_id=client["port_id"],
                actor_id="grpc-client-guest-cache",
                target_kind="guest_endpoint",
                cache_role="client",
                services=("grpc",),
                guest=True,
            ),
            _publisher(
                name="backend-guest-caches",
                host="backend-guest",
                destination=backend["ssh_destination"],
                known_hosts=known_hosts,
                server_id=backend["server_id"],
                port_id=backend["port_id"],
                actor_id="backend-guest-caches",
                target_kind="guest_endpoint",
                cache_role="server",
                services=("dns", "grpc"),
                guest=True,
            ),
        ]
    )
    return {
        "schema_version": 2,
        "max_state_age_seconds": 60,
        "max_snapshot_skew_seconds": 10,
        "max_desired_mode_age_seconds": 60,
        "command_timeout_seconds": 12,
        "policy_lock_root": str(POLICY_LOCK_ROOT),
        "required_endpoints": [
            {
                "server_id": client["server_id"],
                "port_id": client["port_id"],
                "compute_role": "client",
                "guest_cache_role": "client",
                "grpc_backend_server_id": backend["server_id"],
            },
            {
                "server_id": backend["server_id"],
                "port_id": backend["port_id"],
                "compute_role": "observer",
                "guest_cache_role": "server",
            },
        ],
        "state_sources": state_sources,
        "publishers": publishers,
    }


def _snapshot_command(
    destination: str,
    known_hosts: str,
    log_path: str,
) -> list[str]:
    return _remote_command(
        destination,
        known_hosts,
        [
            "/usr/bin/sudo",
            "-n",
            str(INSTALL_ROOT / "bin/snapshot_log"),
            "--path",
            log_path,
            "--max-bytes",
            "262144",
        ],
    )


def _metrics_source(
    *,
    name: str,
    kind: str,
    role: str,
    destination: str,
    known_hosts: str,
    log_path: PurePosixPath,
    authoritative: bool,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "name": name,
        "kind": kind,
        "role": role,
        "command": _snapshot_command(destination, known_hosts, str(log_path)),
    }
    if not authoritative:
        result["error_authoritative"] = False
    return result


def _metrics_config(topology: Mapping[str, Any]) -> dict[str, Any]:
    hosts = topology["hosts"]
    guests = topology["guests"]
    interfaces = topology["interfaces"]
    known_hosts = topology["known_hosts_file"]
    client = guests["client"]
    backend = guests["backend"]
    agent_log_root = (
        PurePosixPath("/var/log/vnet-dataplane-agent")
        / f"shared-{topology['deployment_id']}"
    )
    sources: list[dict[str, Any]] = []
    for compute_role in ("source", "target"):
        destination = hosts[compute_role]["ssh_destination"]
        nova_host = hosts[compute_role]["nova_host"]
        source_interfaces = interfaces[compute_role]
        sources.extend(
            [
                _metrics_source(
                    name=f"{nova_host}-dns-client-monitor",
                    kind="dns_metrics",
                    role="client",
                    destination=destination,
                    known_hosts=known_hosts,
                    log_path=(
                        agent_log_root
                        / client["port_id"]
                        / f"dns-{source_interfaces['client']}.log"
                    ),
                    authoritative=False,
                ),
                _metrics_source(
                    name=f"{nova_host}-grpc-client-monitor",
                    kind="grpc_metrics",
                    role="client",
                    destination=destination,
                    known_hosts=known_hosts,
                    log_path=(
                        agent_log_root
                        / client["port_id"]
                        / f"grpc-{source_interfaces['client']}.log"
                    ),
                    authoritative=False,
                ),
                _metrics_source(
                    name=f"{nova_host}-grpc-backend-monitor",
                    kind="grpc_metrics",
                    role="server",
                    destination=destination,
                    known_hosts=known_hosts,
                    log_path=(
                        agent_log_root
                        / backend["port_id"]
                        / f"grpc-{source_interfaces['backend']}.log"
                    ),
                    authoritative=False,
                ),
            ]
        )
    sources.extend(
        [
            _metrics_source(
                name="backend-guest-dns-monitor",
                kind="dns_metrics",
                role="server",
                destination=backend["ssh_destination"],
                known_hosts=known_hosts,
                log_path=GUEST_LOG_ROOT / backend["port_id"] / "dns-monitor.log",
                authoritative=False,
            ),
            _metrics_source(
                name="client-guest-grpc-cache",
                kind="grpc_fast_cache",
                role="client",
                destination=client["ssh_destination"],
                known_hosts=known_hosts,
                log_path=GUEST_LOG_ROOT / client["port_id"] / "grpc-fast-cache.log",
                authoritative=True,
            ),
            _metrics_source(
                name="backend-guest-grpc-cache",
                kind="grpc_fast_cache",
                role="server",
                destination=backend["ssh_destination"],
                known_hosts=known_hosts,
                log_path=GUEST_LOG_ROOT / backend["port_id"] / "grpc-fast-cache.log",
                authoritative=True,
            ),
        ]
    )
    desired_mode = METRICS_RUNTIME_ROOT / "desired-mode.json"
    controller_mode = METRICS_RUNTIME_ROOT / "controller-mode.json"
    return {
        "schema_version": 1,
        "desired_mode_file": str(desired_mode),
        "controller_mode_file": str(controller_mode),
        "controller_command": [
            str(INSTALL_ROOT / "linux_accel/build/dynamic_cache_controller"),
            "--desired-mode-file",
            str(controller_mode),
            "--initial-mode",
            "bypass",
            "--window-size",
            "5",
            "--required-windows",
            "2",
            "--cooldown-ms",
            "10000",
            "--min-window-requests",
            "1",
        ],
        "poll_interval_seconds": 1.0,
        "source_timeout_seconds": 5.0,
        "decision_timeout_seconds": 5.0,
        "stop_timeout_seconds": 5.0,
        "max_snapshot_age_seconds": 20.0,
        "max_future_skew_seconds": 5.0,
        "max_snapshot_bytes": 262144,
        "sources": sources,
    }


def _compute_endpoints(topology: Mapping[str, Any]) -> dict[str, Any]:
    client = topology["guests"]["client"]
    backend = topology["guests"]["backend"]
    return {
        "schema_version": 2,
        "endpoints": [
            {
                "server_id": client["server_id"],
                "port_ids": [client["port_id"]],
                "accel_role": "client",
                "grpc_observe_port": 50052,
                "guest_grpc_listen_port": 50053,
                "trusted_dns": [backend["private_ipv4"]],
            },
            {
                "server_id": backend["server_id"],
                "port_ids": [backend["port_id"]],
                "accel_role": "observer",
                "grpc_observe_port": 50052,
                "guest_grpc_listen_port": 50052,
            },
        ],
    }


def _guest_endpoint(topology: Mapping[str, Any], role: str) -> dict[str, Any]:
    guest = topology["guests"][role]
    backend = topology["guests"]["backend"]
    value: dict[str, Any] = {
        "schema_version": 1,
        "server_id": guest["server_id"],
        "port_id": guest["port_id"],
        "accel_role": role if role == "client" else "server",
        "interface": guest["interface"],
        "verbose_events": False,
        "grpc": {
            "listen": "0.0.0.0:50053" if role == "client" else "0.0.0.0:50052",
            "backend": (
                f"{backend['private_ipv4']}:50052"
                if role == "client"
                else f"{backend['private_ipv4']}:50051"
            ),
            "method": "/grpc.health.v1.Health/Check",
            "cache_file": "/etc/vnet-dataplane-guest/grpc-cache.policy",
        },
    }
    if role == "backend":
        value["dns_cache_file"] = "/etc/vnet-dataplane-guest/dns-cache.policy"
    return value


def _agent_env(nova_host: str, cloud: str, deployment_id: str) -> bytes:
    values = {
        "VNET_AGENT_SCRIPT": str(
            INSTALL_ROOT / "linux_accel/agent/openstack_dataplane_agent.py"
        ),
        "VNET_ENDPOINT_CONFIG": str(CONFIG_ROOT / "endpoints.json"),
        "VNET_LOCAL_HOST": nova_host,
        "VNET_DNS_MONITOR": str(INSTALL_ROOT / "linux_accel/build/dns_monitor"),
        "VNET_DNS_CLIENT_BPF": str(
            INSTALL_ROOT / "linux_accel/build/dns_client_cache.bpf.o"
        ),
        "VNET_DNS_TC_BPF": str(
            INSTALL_ROOT / "linux_accel/build/dns_monitor.bpf.o"
        ),
        "VNET_GRPC_MONITOR": str(INSTALL_ROOT / "linux_accel/build/grpc_monitor"),
        "VNET_GRPC_BPF": str(
            INSTALL_ROOT / "linux_accel/build/grpc_monitor.bpf.o"
        ),
        "VNET_CACHE_POLICY_TXN": str(
            INSTALL_ROOT / "linux_accel/build/cache_policy_txn"
        ),
        "VNET_AGENT_INTERVAL": "2",
        "VNET_MISSING_GRACE_CYCLES": "2",
        "VNET_DEPLOYMENT_ID": deployment_id,
        "OS_CLOUD": cloud,
    }
    return "".join(f"{key}={value}\n" for key, value in values.items()).encode("ascii")


def _guest_env() -> bytes:
    values = {
        "VNET_GUEST_AGENT": str(
            INSTALL_ROOT / "linux_accel/agent/openstack_guest_endpoint_agent.py"
        ),
        "VNET_GUEST_CONFIG": "/etc/vnet-dataplane-guest/endpoint.json",
        "VNET_GUEST_DNS_MONITOR": str(
            INSTALL_ROOT / "linux_accel/build/dns_monitor"
        ),
        "VNET_GUEST_DNS_SERVER_BPF": str(
            INSTALL_ROOT / "linux_accel/build/dns_server_cache.bpf.o"
        ),
        "VNET_GUEST_GRPC_FAST_CACHE": str(
            INSTALL_ROOT / "linux_accel/build/grpc_fast_cache"
        ),
        "VNET_GUEST_CACHE_POLICY_TXN": str(
            INSTALL_ROOT / "linux_accel/build/cache_policy_txn"
        ),
        "VNET_GUEST_BPFTOOL": "/usr/sbin/bpftool",
        "VNET_GUEST_IP": "/usr/sbin/ip",
        "VNET_GUEST_INTERVAL": "2",
    }
    return "".join(f"{key}={value}\n" for key, value in values.items()).encode("ascii")


def _cache_policy_wrapper(topology: Mapping[str, Any]) -> bytes:
    client_port = topology["guests"]["client"]["port_id"]
    backend_port = topology["guests"]["backend"]["port_id"]
    prefixes = [
        _transaction_arguments(client_port, ("dns", "grpc"), guest=False),
        _transaction_arguments(backend_port, ("grpc",), guest=False),
    ]
    prefixes_json = json.dumps(prefixes, separators=(",", ":"), ensure_ascii=True)
    real_binary = str(INSTALL_ROOT / "linux_accel/build/cache_policy_txn")
    script = f'''#!/usr/bin/python3 -I
import json
import os
import re
import sys

ALLOWED_PREFIXES = json.loads({prefixes_json!r})
REAL_BINARY = {real_binary!r}
OPERATIONS = {{"stage", "verify-staged", "commit", "verify-committed", "force-bypass", "read-current"}}
MODES = {{"bypass", "server", "client", "dual"}}

args = sys.argv[1:]
if len(args) < 6 or args[-6] != "--operation" or args[-4] != "--mode" or args[-2] != "--epoch":
    raise SystemExit("cache policy wrapper: rejected argument shape")
prefix = args[:-6]
operation, mode, epoch_text = args[-5], args[-3], args[-1]
if prefix not in ALLOWED_PREFIXES:
    raise SystemExit("cache policy wrapper: rejected endpoint paths")
if operation not in OPERATIONS or mode not in MODES:
    raise SystemExit("cache policy wrapper: rejected operation or mode")
if operation == "force-bypass" and mode != "bypass":
    raise SystemExit("cache policy wrapper: force-bypass requires bypass mode")
if not re.fullmatch(r"0|[1-9][0-9]{{0,19}}", epoch_text) or int(epoch_text) > 18446744073709551615:
    raise SystemExit("cache policy wrapper: rejected epoch")
environment = {{"LANG": "C", "LC_ALL": "C", "PATH": "/usr/sbin:/usr/bin"}}
os.execve(REAL_BINARY, [REAL_BINARY, *args], environment)
'''
    return script.encode("ascii")


def _snapshot_wrapper(topology: Mapping[str, Any], compute_role: str) -> bytes:
    deployment_id = topology["deployment_id"]
    interfaces = topology["interfaces"][compute_role]
    client_port = topology["guests"]["client"]["port_id"]
    backend_port = topology["guests"]["backend"]["port_id"]
    log_root = (
        PurePosixPath("/var/log/vnet-dataplane-agent")
        / f"shared-{deployment_id}"
    )
    paths = sorted(
        {
            str(log_root / client_port / f"dns-{interfaces['client']}.log"),
            str(log_root / client_port / f"grpc-{interfaces['client']}.log"),
            str(log_root / backend_port / f"grpc-{interfaces['backend']}.log"),
        }
    )
    paths_json = json.dumps(paths, separators=(",", ":"), ensure_ascii=True)
    bridge = str(INSTALL_ROOT / "linux_accel/agent/openstack_metrics_bridge.py")
    script = f'''#!/usr/bin/python3 -I
import json
import os
import sys

ALLOWED_PATHS = set(json.loads({paths_json!r}))
PYTHON = "/usr/bin/python3"
BRIDGE = {bridge!r}

args = sys.argv[1:]
if len(args) != 4 or args[0] != "--path" or args[2:] != ["--max-bytes", "262144"]:
    raise SystemExit("snapshot wrapper: rejected argument shape")
if args[1] not in ALLOWED_PATHS:
    raise SystemExit("snapshot wrapper: rejected log path")
environment = {{"LANG": "C", "LC_ALL": "C", "PATH": "/usr/sbin:/usr/bin"}}
os.execve(PYTHON, [PYTHON, "-I", BRIDGE, "snapshot-log", *args], environment)
'''
    return script.encode("ascii")


def _sudoers_fragment() -> bytes:
    path = (
        Path(__file__).resolve().parents[1]
        / "deploy"
        / "sudoers"
        / "vnet-dataplane-shared"
    )
    if path.is_symlink() or not path.is_file():
        raise BundleError("trusted shared sudoers fragment is unavailable")
    try:
        payload = path.read_bytes()
        payload.decode("ascii")
    except (OSError, UnicodeError) as error:
        raise BundleError("trusted shared sudoers fragment cannot be read") from error
    return payload


def _validate_sudoers_if_available(payload: bytes) -> None:
    visudo = shutil.which("visudo")
    if visudo is None:
        return
    with tempfile.TemporaryDirectory(prefix="vnet-shared-sudoers-") as temporary:
        candidate = Path(temporary) / "fragment"
        candidate.write_bytes(payload)
        candidate.chmod(0o440)
        result = subprocess.run(
            [visudo, "-cf", str(candidate)],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            raise BundleError("generated sudoers fragment failed visudo validation")


def _payloads(
    topology: Mapping[str, Any],
    artifact_root: Path,
) -> tuple[dict[str, bytes], dict[str, str]]:
    cloud = topology["inventory"]["roles"]["controller"]["openstack_cloud"]
    endpoints = _pretty_json_bytes(_compute_endpoints(topology))
    payloads: dict[str, bytes] = {
        "controller/coordinator.json": _pretty_json_bytes(
            _coordinator_config(topology)
        ),
        "controller/coordinator.env": (
            "VNET_COORDINATOR_SCRIPT="
            f"{INSTALL_ROOT}/linux_accel/agent/openstack_epoch_coordinator.py\n"
            f"VNET_COORDINATOR_CONFIG={CONFIG_ROOT}/coordinator.json\n"
            f"VNET_DESIRED_MODE_FILE={METRICS_RUNTIME_ROOT}/desired-mode.json\n"
            "VNET_COORDINATOR_INTERVAL=2\n"
        ).encode("ascii"),
        "controller/metrics-bridge.json": _pretty_json_bytes(
            _metrics_config(topology)
        ),
        "controller/metrics-bridge.env": (
            "VNET_METRICS_BRIDGE_SCRIPT="
            f"{INSTALL_ROOT}/linux_accel/agent/openstack_metrics_bridge.py\n"
            f"VNET_METRICS_BRIDGE_CONFIG={CONFIG_ROOT}/metrics-bridge.json\n"
            f"OS_CLOUD={cloud}\n"
        ).encode("ascii"),
        "source/endpoints.json": endpoints,
        "source/agent.env": _agent_env(
            topology["hosts"]["source"]["nova_host"],
            cloud,
            topology["deployment_id"],
        ),
        "target/endpoints.json": endpoints,
        "target/agent.env": _agent_env(
            topology["hosts"]["target"]["nova_host"],
            cloud,
            topology["deployment_id"],
        ),
        "guest-files/client/endpoint.json": _pretty_json_bytes(
            _guest_endpoint(topology, "client")
        ),
        "guest-files/client/guest-endpoint.env": _guest_env(),
        "guest-files/backend/endpoint.json": _pretty_json_bytes(
            _guest_endpoint(topology, "backend")
        ),
        "guest-files/backend/guest-endpoint.env": _guest_env(),
    }
    modes = {name: "0600" for name in payloads}
    for relative, _mode in {
        item
        for records in _ARTIFACTS.values()
        for item in records
    }:
        source = f"artifacts/{relative}"
        payloads[source] = _read_artifact(artifact_root, relative)
        mode = next(
            artifact_mode
            for records in _ARTIFACTS.values()
            for artifact_relative, artifact_mode in records
            if artifact_relative == relative
        )
        modes[source] = mode
    for unit_name in {
        name for records in _UNIT_ARTIFACTS.values() for name in records
    }:
        relative = f"linux_accel/deploy/systemd/{unit_name}"
        source = f"systemd/{unit_name}"
        payloads[source] = _read_artifact(artifact_root, relative)
        modes[source] = "0644"
    sudoers = _sudoers_fragment()
    _validate_sudoers_if_available(sudoers)
    cache_wrapper = _cache_policy_wrapper(topology)
    for role in ("source", "target"):
        payloads[f"{role}/tools/cache_policy_txn"] = cache_wrapper
        modes[f"{role}/tools/cache_policy_txn"] = "0755"
        payloads[f"{role}/tools/snapshot_log"] = _snapshot_wrapper(topology, role)
        modes[f"{role}/tools/snapshot_log"] = "0755"
        payloads[f"{role}/shared.sudoers"] = sudoers
        modes[f"{role}/shared.sudoers"] = "0600"
    return payloads, modes


def _file_record(
    role: str,
    source: str,
    target: str,
    payload: bytes,
    mode: str = "0600",
) -> dict[str, str]:
    return {
        "role": role,
        "source": source,
        "target": target,
        "mode": mode,
        "sha256": hashlib.sha256(payload).hexdigest(),
    }


def _manifest(
    topology: Mapping[str, Any],
    payloads: Mapping[str, bytes],
    modes: Mapping[str, str],
    topology_sha256: str,
) -> dict[str, Any]:
    files = [
        _file_record(
            "controller",
            "controller/coordinator.json",
            str(CONFIG_ROOT / "coordinator.json"),
            payloads["controller/coordinator.json"],
            modes["controller/coordinator.json"],
        ),
        _file_record(
            "controller",
            "controller/coordinator.env",
            str(CONFIG_ROOT / "coordinator.env"),
            payloads["controller/coordinator.env"],
            modes["controller/coordinator.env"],
        ),
        _file_record(
            "controller",
            "controller/metrics-bridge.json",
            str(CONFIG_ROOT / "metrics-bridge.json"),
            payloads["controller/metrics-bridge.json"],
            modes["controller/metrics-bridge.json"],
        ),
        _file_record(
            "controller",
            "controller/metrics-bridge.env",
            str(CONFIG_ROOT / "metrics-bridge.env"),
            payloads["controller/metrics-bridge.env"],
            modes["controller/metrics-bridge.env"],
        ),
    ]
    for role in ("source", "target"):
        for filename in ("endpoints.json", "agent.env"):
            source = f"{role}/{filename}"
            files.append(
                _file_record(
                    role,
                    source,
                    str(CONFIG_ROOT / filename),
                    payloads[source],
                    modes[source],
                )
            )
    for role, artifact_group in (
        ("controller", "controller"),
        ("source", "compute"),
        ("target", "compute"),
    ):
        for relative, mode in _ARTIFACTS[artifact_group]:
            source = f"artifacts/{relative}"
            files.append(
                _file_record(
                    role,
                    source,
                    str(INSTALL_ROOT / relative),
                    payloads[source],
                    mode,
                )
            )
        for unit_name in _UNIT_ARTIFACTS[artifact_group]:
            source = f"systemd/{unit_name}"
            files.append(
                _file_record(
                    role,
                    source,
                    f"/etc/systemd/system/{unit_name}",
                    payloads[source],
                    modes[source],
                )
            )
    for role in ("source", "target"):
        for filename, target in (
            (
                "tools/cache_policy_txn",
                str(INSTALL_ROOT / "bin/cache_policy_txn"),
            ),
            ("tools/snapshot_log", str(INSTALL_ROOT / "bin/snapshot_log")),
            (
                "shared.sudoers",
                "/etc/vnet-dataplane-shared/vnet-dataplane-shared.sudoers.pending",
            ),
        ):
            source = f"{role}/{filename}"
            files.append(
                _file_record(
                    role,
                    source,
                    target,
                    payloads[source],
                    modes[source],
                )
            )
    guest_files = []
    for role in ("client", "backend"):
        for filename, target in (
            ("endpoint.json", "/etc/vnet-dataplane-guest/endpoint.json"),
            (
                "guest-endpoint.env",
                "/etc/vnet-dataplane-guest/guest-endpoint.env",
            ),
        ):
            source = f"guest-files/{role}/{filename}"
            guest_files.append(
                _file_record(
                    role,
                    source,
                    target,
                    payloads[source],
                    modes[source],
                )
            )
    hosts = []
    for role in ("controller", "source", "target"):
        item = {
            "role": role,
            "ssh_destination": topology["hosts"][role]["ssh_destination"],
        }
        if role != "controller":
            item["nova_host"] = topology["hosts"][role]["nova_host"]
        hosts.append(item)
    units = [
        {
            "role": "controller",
            "name": "vnet-dataplane-shared-metrics-controller.service",
            "enabled": False,
            "started": False,
        },
        {
            "role": "controller",
            "name": "vnet-dataplane-shared-epoch-coordinator.service",
            "enabled": False,
            "started": False,
        },
        {
            "role": "source",
            "name": "vnet-dataplane-shared-agent.service",
            "enabled": False,
            "started": False,
        },
        {
            "role": "target",
            "name": "vnet-dataplane-shared-agent.service",
            "enabled": False,
            "started": False,
        },
    ]
    inventory_hash = hashlib.sha256(
        canonical_json_bytes(topology["inventory"])
    ).hexdigest()
    return {
        "schema_version": 1,
        "deployment_id": topology["deployment_id"],
        "inventory_sha256": inventory_hash,
        "topology_sha256": topology_sha256,
        "known_hosts_file": topology["known_hosts_file"],
        "hosts": hosts,
        "files": files,
        "guest_files": guest_files,
        "units": units,
    }


def _write_bundle(
    output: Path,
    payloads: Mapping[str, bytes],
    modes: Mapping[str, str],
    manifest: Any,
) -> None:
    if os.path.lexists(output):
        raise BundleError(f"output directory already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(
        tempfile.mkdtemp(prefix=f".{output.name}.", dir=str(output.parent))
    )
    try:
        for relative, payload in payloads.items():
            destination = temporary / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(payload)
            try:
                destination.chmod(int(modes[relative], 8))
            except OSError:
                pass
        manifest_path = temporary / "bundle-manifest.json"
        manifest_path.write_bytes(_pretty_json_bytes(manifest))
        try:
            manifest_path.chmod(0o600)
        except OSError:
            pass
        _publish_directory_exclusive(temporary, output)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def _publish_directory_exclusive(source: Path, destination: Path) -> None:
    """Atomically publish a directory without replacing any existing path."""

    if os.name == "nt":
        try:
            os.rename(source, destination)
        except FileExistsError as error:
            raise BundleError(
                f"output directory already exists: {destination}"
            ) from error
        return
    if os.name != "posix":
        raise BundleError("exclusive directory publication is unsupported")

    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        raise BundleError("exclusive directory publication is unavailable")
    renameat2.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameat2.restype = ctypes.c_int
    result = renameat2(
        -100,
        os.fsencode(source),
        -100,
        os.fsencode(destination),
        1,
    )
    if result == 0:
        return
    error_number = ctypes.get_errno()
    if error_number in (errno.EEXIST, errno.ENOTEMPTY):
        raise BundleError(f"output directory already exists: {destination}")
    raise BundleError(
        "cannot exclusively publish output directory: "
        + os.strerror(error_number)
    )


def render_bundle(
    topology_path: Path,
    output: Path,
    artifact_root: Path,
) -> dict[str, Any]:
    if os.path.lexists(output):
        raise BundleError(f"output directory already exists: {output}")
    try:
        raw = topology_path.read_bytes()
        value = json.loads(
            raw.decode("utf-8"), object_pairs_hook=_reject_duplicate_pairs
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BundleError(f"cannot read topology: {type(error).__name__}") from error
    topology = validate_topology(value)
    payloads, modes = _payloads(topology, artifact_root)
    manifest = _manifest(
        topology,
        payloads,
        modes,
        hashlib.sha256(raw).hexdigest(),
    )
    _write_bundle(output, payloads, modes, manifest)
    return manifest


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Render the credential-free shared OpenStack deployment bundle"
    )
    parser.add_argument("--topology", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--artifact-root", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        manifest = render_bundle(args.topology, args.output, args.artifact_root)
    except BundleError as error:
        print(f"render failed: {error}", file=sys.stderr)
        return 2
    print(
        json.dumps(
            {
                "output": str(args.output),
                "deployment_id": manifest["deployment_id"],
                "inventory_sha256": manifest["inventory_sha256"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
