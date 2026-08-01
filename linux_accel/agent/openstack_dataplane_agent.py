#!/usr/bin/env python3
"""Discover OpenStack VM interfaces and keep eBPF attachments reconciled."""

from __future__ import annotations

import argparse
import errno
import ipaddress
import json
import math
import os
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Mapping, Protocol, Sequence

try:
    import fcntl
except ImportError:
    fcntl = None  # type: ignore[assignment]


AGENT_STATE_SCHEMA_VERSION = 3
ENDPOINT_CONFIG_SCHEMA_VERSION = 2
GRPC_CAPABILITY = "tc_observability"
DNS_CLIENT_CAPABILITY = "xdp_client_cache"
DNS_OBSERVER_CAPABILITY = "tc_observability"
DEFAULT_COMMAND_TIMEOUT_SECONDS = 10.0
DEFAULT_ATTACH_READY_TIMEOUT_SECONDS = 10.0
DEFAULT_SHUTDOWN_TIMEOUT_SECONDS = 240.0
ATTACH_READY_POLL_SECONDS = 0.05
TC_PRIORITY = 1
DNS_TC_HANDLE = 1
GRPC_TC_HANDLE = 2
POLICY_LOCK_ROOT = Path("/run/vnet-dataplane-policy")


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
class PortInventory:
    server_id: str
    port_id: str
    status: str
    binding_host: str
    vif_type: str
    revision_number: int


@dataclass(frozen=True)
class DiscoveryResult:
    bindings: tuple[Binding, ...]
    port_inventory: tuple[PortInventory, ...]
    policy_errors: tuple[str, ...] = ()


@dataclass(frozen=True)
class DiscoverySample:
    result: DiscoveryResult
    completed_ms: int


@dataclass(frozen=True)
class EndpointConfig:
    server_id: str
    accel_role: str
    grpc_observe_port: int
    guest_grpc_listen_port: int
    port_ids: tuple[str, ...]
    trusted_dns: tuple[str, ...] = ()
    dns_cache_file: str | None = None


@dataclass(frozen=True)
class AttachmentConfig:
    dns_monitor: Path
    dns_client_bpf: Path
    dns_tc_bpf: Path
    grpc_monitor: Path
    grpc_bpf: Path
    cache_policy_txn: Path
    endpoint_configs: tuple[EndpointConfig, ...]
    pin_root: Path
    log_root: Path
    policy_lock_root: Path = POLICY_LOCK_ROOT
    ip_command: str = "ip"
    tc_command: str = "tc"
    attach_ready_timeout_seconds: float = DEFAULT_ATTACH_READY_TIMEOUT_SECONDS
    command_timeout_seconds: float = DEFAULT_COMMAND_TIMEOUT_SECONDS
    verbose_events: bool = False


def _endpoint_config_state(config: EndpointConfig) -> dict[str, Any]:
    record: dict[str, Any] = {
        "server_id": config.server_id,
        "port_ids": list(config.port_ids),
        "accel_role": config.accel_role,
        "grpc_observe_port": config.grpc_observe_port,
        "guest_grpc_listen_port": config.guest_grpc_listen_port,
    }
    if config.accel_role == "client":
        record["trusted_dns"] = list(config.trusted_dns)
    elif config.accel_role == "server" and config.dns_cache_file is not None:
        record["dns_cache_file"] = str(config.dns_cache_file)
    return record


def _endpoint_port(record: dict[str, Any], field: str, label: str) -> int:
    value = record.get(field)
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or not 1 <= value <= 65535
    ):
        raise AgentError(
            f"{label} {field} must be an integer in 1..65535"
        )
    return value


def _canonical_port_id(value: Any, label: str) -> str:
    if not isinstance(value, str):
        raise AgentError(f"{label} must be a canonical UUID")
    try:
        parsed = uuid.UUID(value)
    except (AttributeError, ValueError) as error:
        raise AgentError(f"{label} must be a canonical UUID") from error
    canonical = str(parsed)
    if value != canonical:
        raise AgentError(f"{label} must be a canonical UUID")
    return canonical


def _canonical_port_ids(value: Any, label: str) -> tuple[str, ...]:
    if not isinstance(value, (list, tuple)) or not value:
        raise AgentError(f"{label} must be a non-empty UUID array")
    port_ids: list[str] = []
    seen: set[str] = set()
    for index, item in enumerate(value):
        port_id = _canonical_port_id(item, f"{label}[{index}]")
        if port_id in seen:
            raise AgentError(f"{label} has duplicate port ID: {port_id}")
        seen.add(port_id)
        port_ids.append(port_id)
    return tuple(port_ids)


def _reject_legacy_grpc_port_fields(value: Any, source: str) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            if key in {"grpc_port", "grpc_ports"}:
                raise AgentError(f"{source} contains legacy field {key}")
            _reject_legacy_grpc_port_fields(item, f"{source}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            _reject_legacy_grpc_port_fields(
                item,
                f"{source}[{index}]",
            )


def _parse_endpoint_records(value: Any, source: str) -> tuple[EndpointConfig, ...]:
    if not isinstance(value, list) or not value:
        raise AgentError(f"{source} endpoints must be a non-empty JSON array")

    configs: list[EndpointConfig] = []
    seen_servers: set[str] = set()
    seen_ports: dict[str, str] = {}
    allowed_keys = {
        "server_id",
        "port_ids",
        "accel_role",
        "grpc_observe_port",
        "guest_grpc_listen_port",
        "trusted_dns",
        "dns_cache_file",
    }
    for index, record in enumerate(value):
        label = f"{source} endpoint[{index}]"
        if not isinstance(record, dict):
            raise AgentError(f"{label} must be a JSON object")
        unknown = sorted(set(record) - allowed_keys)
        if unknown:
            raise AgentError(f"{label} has unknown fields: {', '.join(unknown)}")

        server_id = record.get("server_id")
        if not isinstance(server_id, str) or not server_id.strip():
            raise AgentError(f"{label} has invalid server_id")
        server_id = server_id.strip()
        if server_id in seen_servers:
            raise AgentError(f"{source} has duplicate server_id: {server_id}")
        seen_servers.add(server_id)

        port_ids = _canonical_port_ids(
            record.get("port_ids"),
            f"{label} port_ids",
        )
        for port_id in port_ids:
            previous_server = seen_ports.get(port_id)
            if previous_server is not None:
                raise AgentError(
                    f"{source} has duplicate port ID {port_id} for servers "
                    f"{previous_server} and {server_id}"
                )
            seen_ports[port_id] = server_id

        accel_role = record.get("accel_role")
        if accel_role not in {"client", "observer", "server"}:
            raise AgentError(
                f"{label} accel_role must be exactly client, observer, or server"
            )

        grpc_observe_port = _endpoint_port(
            record,
            "grpc_observe_port",
            label,
        )
        guest_grpc_listen_port = _endpoint_port(
            record,
            "guest_grpc_listen_port",
            label,
        )

        if accel_role == "client":
            if "dns_cache_file" in record:
                raise AgentError(f"{label} client role forbids dns_cache_file")
            trusted_value = record.get("trusted_dns")
            if not isinstance(trusted_value, list) or not trusted_value:
                raise AgentError(
                    f"{label} client role requires non-empty trusted_dns"
                )
            trusted_dns: list[str] = []
            seen_dns: set[str] = set()
            for dns_index, address in enumerate(trusted_value):
                if not isinstance(address, str) or not address.strip():
                    raise AgentError(
                        f"{label} trusted_dns[{dns_index}] must be an IPv4 address"
                    )
                try:
                    parsed_address = ipaddress.IPv4Address(address.strip())
                except ipaddress.AddressValueError as error:
                    raise AgentError(
                        f"{label} trusted_dns[{dns_index}] must be an IPv4 address"
                    ) from error
                normalized = str(parsed_address)
                if normalized in seen_dns:
                    raise AgentError(
                        f"{label} has duplicate trusted DNS address: {normalized}"
                    )
                seen_dns.add(normalized)
                trusted_dns.append(normalized)
            configs.append(
                EndpointConfig(
                    server_id=server_id,
                    accel_role=accel_role,
                    grpc_observe_port=grpc_observe_port,
                    guest_grpc_listen_port=guest_grpc_listen_port,
                    port_ids=port_ids,
                    trusted_dns=tuple(trusted_dns),
                )
            )
            continue

        if accel_role == "observer":
            if "trusted_dns" in record:
                raise AgentError(f"{label} observer role forbids trusted_dns")
            if "dns_cache_file" in record:
                raise AgentError(f"{label} observer role forbids dns_cache_file")
            configs.append(
                EndpointConfig(
                    server_id=server_id,
                    accel_role=accel_role,
                    grpc_observe_port=grpc_observe_port,
                    guest_grpc_listen_port=guest_grpc_listen_port,
                    port_ids=port_ids,
                )
            )
            continue

        if "trusted_dns" in record:
            raise AgentError(f"{label} server role forbids trusted_dns")
        cache_value = record.get("dns_cache_file")
        if not isinstance(cache_value, str) or not cache_value.strip():
            raise AgentError(f"{label} server role requires dns_cache_file")
        cache_value = cache_value.strip()
        cache_file = Path(cache_value)
        if not cache_file.is_absolute() and not cache_value.startswith("/"):
            raise AgentError(f"{label} dns_cache_file must be absolute")
        configs.append(
            EndpointConfig(
                server_id=server_id,
                accel_role=accel_role,
                grpc_observe_port=grpc_observe_port,
                guest_grpc_listen_port=guest_grpc_listen_port,
                port_ids=port_ids,
                dns_cache_file=cache_value,
            )
        )
    return tuple(configs)


def _parse_endpoint_config(value: Any, source: str) -> tuple[EndpointConfig, ...]:
    if not isinstance(value, dict):
        raise AgentError(f"{source} must be a JSON object")
    unknown = sorted(set(value) - {"schema_version", "endpoints"})
    if unknown:
        raise AgentError(f"{source} has unknown fields: {', '.join(unknown)}")
    schema_version = value.get("schema_version")
    if (
        not isinstance(schema_version, int)
        or isinstance(schema_version, bool)
        or schema_version != ENDPOINT_CONFIG_SCHEMA_VERSION
    ):
        raise AgentError(
            f"{source} schema_version must be "
            f"{ENDPOINT_CONFIG_SCHEMA_VERSION}"
        )
    return _require_host_endpoint_roles(
        _parse_endpoint_records(value.get("endpoints"), source), source
    )


def _load_endpoint_configs(path: Path) -> tuple[EndpointConfig, ...]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise AgentError(f"endpoint config does not exist: {path}") from error
    return _parse_endpoint_config(value, f"endpoint config {path}")


def _validated_endpoint_map(
    configs: Sequence[EndpointConfig], source: str
) -> dict[str, EndpointConfig]:
    records: list[dict[str, Any]] = []
    for config in configs:
        if not isinstance(config, EndpointConfig):
            raise AgentError(f"{source} contains a non-EndpointConfig value")
        record = _endpoint_config_state(config)
        if config.accel_role != "server" and config.dns_cache_file is not None:
            record["dns_cache_file"] = str(config.dns_cache_file)
        if config.accel_role != "client" and config.trusted_dns:
            record["trusted_dns"] = list(config.trusted_dns)
        records.append(record)
    validated = _parse_endpoint_records(records, source)
    return {config.server_id: config for config in validated}


def _require_host_endpoint_roles(
    configs: Sequence[EndpointConfig], source: str
) -> tuple[EndpointConfig, ...]:
    server_ids = sorted(
        config.server_id
        for config in configs
        if config.accel_role == "server"
    )
    if server_ids:
        raise AgentError(
            f"{source} requests server DNS acceleration on host VM-facing "
            "interfaces; use a guest-side agent for: "
            + ", ".join(server_ids)
        )
    return tuple(configs)


def _dns_capability(config: EndpointConfig) -> str:
    if config.accel_role == "client":
        return DNS_CLIENT_CAPABILITY
    if config.accel_role == "observer":
        return DNS_OBSERVER_CAPABILITY
    raise AgentError(
        f"server DNS role for {config.server_id} must be managed "
        "by a guest-side agent"
    )


def _external_command(value: str, label: str) -> str:
    if not isinstance(value, str) or not value.strip() or "\0" in value:
        raise AgentError(f"{label} command must be a non-empty string")
    return value.strip()


class CommandRunner:
    def __init__(
        self,
        timeout_seconds: float = DEFAULT_COMMAND_TIMEOUT_SECONDS,
    ):
        if (
            isinstance(timeout_seconds, bool)
            or not isinstance(timeout_seconds, (int, float))
            or not math.isfinite(timeout_seconds)
            or timeout_seconds <= 0
        ):
            raise AgentError("command timeout seconds must be positive")
        self._timeout_seconds = float(timeout_seconds)
        self._deadline: float | None = None

    def set_deadline(self, deadline: float) -> None:
        self._deadline = deadline

    def _timeout(self) -> float:
        if self._deadline is None:
            return self._timeout_seconds
        remaining = self._deadline - time.monotonic()
        if remaining <= 0:
            raise AgentError("shutdown deadline expired before external command")
        return min(self._timeout_seconds, remaining)

    def run(self, args: Sequence[str]) -> str:
        command = list(args)
        if not command:
            raise AgentError("external command must not be empty")
        timeout_seconds = self._timeout()
        try:
            result = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout_seconds,
            )
        except subprocess.TimeoutExpired as error:
            raise AgentError(
                "command timed out after "
                f"{timeout_seconds:g}s: {' '.join(command)}"
            ) from error
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip()
            raise AgentError(
                f"command failed ({result.returncode}): {' '.join(command)}: "
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


def _revision_number(port: dict[str, Any], port_id: str) -> int:
    value = _field(port, "revision_number")
    if isinstance(value, bool):
        raise AgentError(f"port {port_id} has invalid revision number")
    try:
        revision_number = int(value)
    except (TypeError, ValueError) as error:
        raise AgentError(f"port {port_id} has invalid revision number") from error
    if revision_number < 0:
        raise AgentError(f"port {port_id} has invalid revision number")
    return revision_number


def _short_host(value: str) -> str:
    return value.strip().lower().split(".", 1)[0]


class OpenStackOvsResolver:
    def __init__(
        self,
        runner: CommandRunner,
        local_host: str,
        *,
        openstack_command: str = "openstack",
        ovs_vsctl_command: str = "ovs-vsctl",
        ip_command: str = "ip",
    ):
        self._runner = runner
        self._local_host = _short_host(local_host)
        self._openstack_command = _external_command(
            openstack_command, "OpenStack"
        )
        self._ovs_vsctl_command = _external_command(
            ovs_vsctl_command, "OVS"
        )
        self._ip_command = _external_command(ip_command, "IP")

    def discover(
        self,
        server_id: str,
        allowed_port_ids: Sequence[str] | None = None,
    ) -> list[Binding]:
        return list(
            self.discover_with_inventory(server_id, allowed_port_ids).bindings
        )

    def discover_with_inventory(
        self,
        server_id: str,
        allowed_port_ids: Sequence[str] | None = None,
    ) -> DiscoveryResult:
        allowed = (
            None
            if allowed_port_ids is None
            else frozenset(
                _canonical_port_ids(
                    allowed_port_ids,
                    f"server {server_id} allowed port IDs",
                )
            )
        )
        port_rows = self._json(
            [
                self._openstack_command,
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
        inventory: list[PortInventory] = []
        seen_ports: set[str] = set()
        for row in port_rows:
            port_id = str(_field(row, "id") or "")
            if not port_id:
                raise AgentError("OpenStack port list returned a row without ID")
            if port_id in seen_ports:
                raise AgentError(
                    f"OpenStack port list returned duplicate port {port_id}"
                )
            seen_ports.add(port_id)
            port = self._json_object(
                [
                    self._openstack_command,
                    "port",
                    "show",
                    port_id,
                    "-f",
                    "json",
                ]
            )
            shown_port_id = str(_field(port, "id") or "")
            if shown_port_id != port_id:
                raise AgentError(
                    f"OpenStack port show returned mismatched ID for {port_id}"
                )
            device_id = str(_field(port, "device_id") or "")
            if device_id != server_id:
                raise AgentError(
                    f"port {port_id} no longer belongs to server {server_id}"
                )
            status = str(_field(port, "status") or "").strip().upper()
            if not status:
                raise AgentError(f"port {port_id} has no status")
            binding_host = str(
                _field(port, "binding_host_id", "binding:host_id") or ""
            ).strip()
            vif_type = str(
                _field(port, "binding_vif_type", "binding:vif_type") or ""
            ).strip().lower()
            if not vif_type:
                raise AgentError(f"port {port_id} has no VIF type")
            revision_number = _revision_number(port, port_id)
            inventory.append(
                PortInventory(
                    server_id=server_id,
                    port_id=port_id,
                    status=status,
                    binding_host=binding_host,
                    vif_type=vif_type,
                    revision_number=revision_number,
                )
            )

        policy_errors: list[str] = []
        inventory_by_port = {item.port_id: item for item in inventory}
        if allowed is not None:
            for port_id in sorted(allowed - inventory_by_port.keys()):
                policy_errors.append(
                    f"server {server_id} declared port is missing from "
                    f"Neutron inventory: {port_id}"
                )
            for port_id in sorted(allowed & inventory_by_port.keys()):
                item = inventory_by_port[port_id]
                binding_host = _short_host(item.binding_host)
                if binding_host != self._local_host:
                    continue
                if item.status != "ACTIVE":
                    policy_errors.append(
                        f"server {server_id} declared port is not ACTIVE: "
                        f"{port_id} status={item.status}"
                    )
                elif item.vif_type != "ovs":
                    policy_errors.append(
                        f"server {server_id} declared port VIF type is not ovs: "
                        f"{port_id} vif_type={item.vif_type}"
                    )
            extra_local_ports = sorted(
                item.port_id
                for item in inventory
                if item.port_id not in allowed
                and item.status == "ACTIVE"
                and _short_host(item.binding_host) == self._local_host
                and item.vif_type == "ovs"
            )
            for port_id in extra_local_ports:
                policy_errors.append(
                    f"server {server_id} has undeclared ACTIVE local OVS port: "
                    f"{port_id}"
                )

        bindings: list[Binding] = []
        if not policy_errors:
            for item in inventory:
                if item.status != "ACTIVE":
                    continue
                if _short_host(item.binding_host) != self._local_host:
                    continue
                if item.vif_type != "ovs":
                    raise AgentError(
                        f"port {item.port_id} is local but VIF type is not ovs"
                    )
                if allowed is not None and item.port_id not in allowed:
                    continue
                interface = self._ovs_interface(item.port_id)
                ifindex = self._ifindex(interface)
                bindings.append(
                    Binding(
                        server_id=server_id,
                        port_id=item.port_id,
                        host=item.binding_host,
                        interface=interface,
                        ifindex=ifindex,
                    )
                )
        return DiscoveryResult(
            bindings=tuple(sorted(bindings, key=lambda item: item.port_id)),
            port_inventory=tuple(
                sorted(inventory, key=lambda item: (item.server_id, item.port_id))
            ),
            policy_errors=tuple(policy_errors),
        )

    def discover_many(
        self,
        server_ids: Sequence[str],
        allowed_port_ids_by_server: Mapping[str, Sequence[str]] | None = None,
    ) -> list[Binding]:
        bindings: list[Binding] = []
        seen_servers: set[str] = set()
        seen_ports: set[str] = set()
        for server_id in server_ids:
            normalized = server_id.strip()
            if not normalized:
                raise AgentError("server ID must not be empty")
            if normalized in seen_servers:
                continue
            seen_servers.add(normalized)
            allowed_port_ids = (
                None
                if allowed_port_ids_by_server is None
                else allowed_port_ids_by_server.get(normalized)
            )
            if (
                allowed_port_ids_by_server is not None
                and allowed_port_ids is None
            ):
                raise AgentError(
                    f"no allowed port IDs declared for server {normalized}"
                )
            discovered = (
                self.discover(normalized)
                if allowed_port_ids is None
                else self.discover(normalized, allowed_port_ids)
            )
            for binding in discovered:
                if binding.port_id in seen_ports:
                    raise AgentError(
                        f"port {binding.port_id} belongs to multiple requested servers"
                    )
                seen_ports.add(binding.port_id)
                bindings.append(binding)
        return sorted(bindings, key=lambda item: (item.server_id, item.port_id))

    def discover_many_with_inventory(
        self,
        server_ids: Sequence[str],
        allowed_port_ids_by_server: Mapping[str, Sequence[str]] | None = None,
    ) -> DiscoveryResult:
        bindings: list[Binding] = []
        inventory: list[PortInventory] = []
        policy_errors: list[str] = []
        seen_servers: set[str] = set()
        seen_ports: set[str] = set()
        for server_id in server_ids:
            normalized = server_id.strip()
            if not normalized:
                raise AgentError("server ID must not be empty")
            if normalized in seen_servers:
                continue
            seen_servers.add(normalized)
            allowed_port_ids = (
                None
                if allowed_port_ids_by_server is None
                else allowed_port_ids_by_server.get(normalized)
            )
            if (
                allowed_port_ids_by_server is not None
                and allowed_port_ids is None
            ):
                raise AgentError(
                    f"no allowed port IDs declared for server {normalized}"
                )
            result = (
                self.discover_with_inventory(normalized)
                if allowed_port_ids is None
                else self.discover_with_inventory(normalized, allowed_port_ids)
            )
            for item in result.port_inventory:
                if item.port_id in seen_ports:
                    raise AgentError(
                        f"port {item.port_id} belongs to multiple requested servers"
                    )
                seen_ports.add(item.port_id)
                inventory.append(item)
            bindings.extend(result.bindings)
            policy_errors.extend(result.policy_errors)
        return DiscoveryResult(
            bindings=tuple(
                sorted(bindings, key=lambda item: (item.server_id, item.port_id))
            ),
            port_inventory=tuple(
                sorted(inventory, key=lambda item: (item.server_id, item.port_id))
            ),
            policy_errors=tuple(policy_errors),
        )

    def _ovs_interface(self, port_id: str) -> str:
        payload = self._json_object(
            [
                self._ovs_vsctl_command,
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
        rows = self._json(
            [self._ip_command, "-j", "link", "show", "dev", interface]
        )
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


def _sample_discovery(
    resolver: OpenStackOvsResolver,
    server_ids: Sequence[str],
    allowed_port_ids_by_server: Mapping[str, Sequence[str]] | None = None,
) -> DiscoverySample:
    result = (
        resolver.discover_many_with_inventory(server_ids)
        if allowed_port_ids_by_server is None
        else resolver.discover_many_with_inventory(
            server_ids,
            allowed_port_ids_by_server,
        )
    )
    return DiscoverySample(
        result=result,
        completed_ms=int(time.time() * 1000),
    )


def _assert_discovery_consistent(
    sampled: DiscoveryResult,
    revalidated: DiscoveryResult,
) -> None:
    if sampled.policy_errors != revalidated.policy_errors:
        raise AgentError("port policy errors changed before publication")
    sampled_inventory = {
        (item.server_id, item.port_id): item
        for item in sampled.port_inventory
    }
    revalidated_inventory = {
        (item.server_id, item.port_id): item
        for item in revalidated.port_inventory
    }
    if len(sampled_inventory) != len(sampled.port_inventory):
        raise AgentError("sampled discovery contains duplicate ports")
    if len(revalidated_inventory) != len(revalidated.port_inventory):
        raise AgentError("revalidated discovery contains duplicate ports")
    if sampled_inventory.keys() != revalidated_inventory.keys():
        raise AgentError("Neutron port inventory changed before publication")

    for key in sorted(sampled_inventory):
        before = sampled_inventory[key]
        after = revalidated_inventory[key]
        if before.revision_number != after.revision_number:
            raise AgentError(
                f"Neutron revision changed for port {before.port_id}: "
                f"{before.revision_number} -> {after.revision_number}"
            )
        if before.binding_host != after.binding_host:
            raise AgentError(
                f"Neutron binding host changed for port {before.port_id}: "
                f"{before.binding_host!r} -> {after.binding_host!r}"
            )
        if before.status != after.status:
            raise AgentError(
                f"Neutron status changed for port {before.port_id}: "
                f"{before.status} -> {after.status}"
            )
        if before.vif_type != after.vif_type:
            raise AgentError(
                f"Neutron VIF type changed for port {before.port_id}: "
                f"{before.vif_type} -> {after.vif_type}"
            )

    sampled_bindings = {
        (item.server_id, item.port_id): item for item in sampled.bindings
    }
    revalidated_bindings = {
        (item.server_id, item.port_id): item for item in revalidated.bindings
    }
    if len(sampled_bindings) != len(sampled.bindings):
        raise AgentError("sampled discovery contains duplicate local bindings")
    if len(revalidated_bindings) != len(revalidated.bindings):
        raise AgentError(
            "revalidated discovery contains duplicate local bindings"
        )
    if sampled_bindings.keys() != revalidated_bindings.keys():
        raise AgentError("local binding set changed before publication")

    for key in sorted(sampled_bindings):
        before = sampled_bindings[key]
        after = revalidated_bindings[key]
        if before.ifindex != after.ifindex:
            raise AgentError(
                f"local ifindex changed for port {before.port_id}: "
                f"{before.ifindex} -> {after.ifindex}"
            )
        if before.interface != after.interface:
            raise AgentError(
                f"local interface changed for port {before.port_id}: "
                f"{before.interface} -> {after.interface}"
            )
        if before.host != after.host:
            raise AgentError(
                f"local binding host changed for port {before.port_id}: "
                f"{before.host!r} -> {after.host!r}"
            )


def _plain_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _numeric_value(value: Any) -> int | None:
    if _plain_int(value):
        return value
    if not isinstance(value, str) or not value:
        return None
    try:
        return int(value, 0)
    except ValueError:
        return None


def _extract_xdp_program_id(link: Any) -> int:
    if not isinstance(link, dict):
        raise AgentError("ip link XDP record is not an object")
    xdp = link.get("xdp")
    if xdp is None:
        return 0
    if not isinstance(xdp, dict):
        raise AgentError("ip link XDP metadata is invalid")
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
        "attached",
    ):
        nested = xdp.get(key)
        if isinstance(nested, list):
            for item in nested:
                collect(item)
        else:
            collect(nested)
    if len(candidates) > 1:
        raise AgentError("interface has ambiguous XDP program IDs")
    return next(iter(candidates), 0)


def _extract_tc_program_ids(
    value: Any,
    *,
    priority: int,
    handles: Sequence[int],
) -> dict[int, int]:
    if not isinstance(value, list) or not all(
        isinstance(item, dict) for item in value
    ):
        raise AgentError("tc filter JSON must be an array of objects")
    target_handles = set(handles)
    programs: dict[int, int] = {}
    for item in value:
        options = item.get("options", {})
        if not isinstance(options, dict):
            raise AgentError("tc filter options must be an object")
        item_priority = _numeric_value(
            item.get("pref", item.get("priority"))
        )
        handle = _numeric_value(
            options.get("handle", item.get("handle"))
        )
        if item_priority != priority or handle not in target_handles:
            continue
        chain = _numeric_value(item.get("chain", 0))
        if chain is None:
            raise AgentError(
                f"tc slot pref {priority} handle {handle} has invalid chain"
            )
        if chain != 0 or item.get("protocol") != "all":
            continue
        if item.get("kind") != "bpf":
            raise AgentError(
                f"tc slot pref {priority} handle {handle} is not BPF"
            )
        candidates: set[int] = set()
        for container in (
            item,
            options,
            options.get("bpf"),
            options.get("prog"),
        ):
            if not isinstance(container, dict):
                continue
            for key in ("id", "prog_id"):
                candidate = container.get(key)
                if _plain_int(candidate) and candidate > 0:
                    candidates.add(candidate)
        if len(candidates) != 1:
            raise AgentError(
                f"tc slot pref {priority} handle {handle} "
                "has no unique program ID"
            )
        program_id = next(iter(candidates))
        if handle in programs:
            raise AgentError(
                f"tc slot pref {priority} handle {handle} is ambiguous"
            )
        programs[handle] = program_id
    return {handle: programs.get(handle, 0) for handle in handles}


class AttachmentDriver(Protocol):
    def attach(self, binding: Binding) -> None:
        ...

    def detach(self, binding: Binding) -> None:
        ...

    def healthy(self, binding: Binding) -> bool:
        ...

    def snapshot(self) -> dict[str, Any]:
        ...


@dataclass(frozen=True)
class HookProgramIds:
    dns_xdp: int | None
    dns_tc_ingress: int
    dns_tc_egress: int
    grpc_tc_ingress: int
    grpc_tc_egress: int


@dataclass
class _ManagedAttachment:
    binding: Binding
    dns_process: subprocess.Popen[bytes]
    grpc_process: subprocess.Popen[bytes]
    programs: HookProgramIds


@dataclass
class _ResidualAttachment:
    binding: Binding
    dns_process: subprocess.Popen[bytes] | None
    grpc_process: subprocess.Popen[bytes] | None
    cleanup_blocked: bool
    reason: str


class ProcessAttachmentDriver:
    def __init__(
        self,
        config: AttachmentConfig,
        runner: CommandRunner | None = None,
    ):
        self._config = config
        self._runner = runner or CommandRunner(
            config.command_timeout_seconds
        )
        self._ip_command = _external_command(config.ip_command, "IP")
        self._tc_command = _external_command(config.tc_command, "TC")
        self._endpoint_by_server = _validated_endpoint_map(
            config.endpoint_configs, "attachment endpoint config"
        )
        self._managed: dict[str, _ManagedAttachment] = {}
        self._residual: dict[str, _ResidualAttachment] = {}
        self._quiesce_fds: dict[str, int] = {}
        self._quiesce_identities: dict[str, tuple[int, int]] = {}
        self._shutdown_deadline: float | None = None
        self._validate_config()

    def begin_shutdown(self, deadline: float) -> None:
        self._shutdown_deadline = deadline
        set_deadline = getattr(self._runner, "set_deadline", None)
        if callable(set_deadline):
            set_deadline(deadline)

    def _remaining_timeout(self, maximum: float) -> float:
        if self._shutdown_deadline is None:
            return maximum
        remaining = self._shutdown_deadline - time.monotonic()
        if remaining <= 0:
            raise AgentError("shutdown deadline expired during attachment cleanup")
        return min(maximum, remaining)

    def attach(self, binding: Binding) -> None:
        if (
            binding.port_id in self._managed
            or binding.port_id in self._residual
        ):
            raise AgentError(f"port {binding.port_id} is already attached")
        dns_command, grpc_command = self.commands(binding)
        port_pin = self._port_path(self._config.pin_root, binding.port_id)
        port_log = self._port_path(self._config.log_root, binding.port_id)
        self._enter_quiesce(binding.port_id)
        if port_pin.exists():
            self._residual[binding.port_id] = _ResidualAttachment(
                binding,
                None,
                None,
                True,
                "preexisting pin ownership is unknown",
            )
            raise AgentError(
                f"port {binding.port_id} has an unowned preexisting pin tree"
            )
        self._ensure_hook_slots_available(binding)
        if self._endpoint(binding).accel_role == "client":
            (port_pin / "dns").mkdir(parents=True, exist_ok=True)
        (port_pin / "grpc").mkdir(parents=True, exist_ok=True)
        port_log.mkdir(parents=True, exist_ok=True)

        dns_process: subprocess.Popen[bytes] | None = None
        grpc_process: subprocess.Popen[bytes] | None = None
        programs: HookProgramIds | None = None
        try:
            dns_process = self._start(
                dns_command, port_log / f"dns-{binding.interface}.log"
            )
            grpc_process = self._start(
                grpc_command, port_log / f"grpc-{binding.interface}.log"
            )
            programs = self._wait_attachment_ready(
                binding,
                dns_process,
                grpc_process,
            )
            self._initialize_committed_bypass(binding)
            if not self._programs_intact(
                binding,
                dns_process,
                grpc_process,
                programs,
            ):
                raise AgentError(
                    "attachment hook ownership changed before readiness "
                    f"completed for {binding.interface}"
                )
        except Exception:
            grpc_stopped = (
                grpc_process is None or self._stop(grpc_process)
            )
            dns_stopped = dns_process is None or self._stop(dns_process)
            if grpc_stopped and dns_stopped:
                self._remove_pin_tree(port_pin)
                self._remove_empty_pin_root()
            else:
                self._residual[binding.port_id] = _ResidualAttachment(
                    binding,
                    dns_process,
                    grpc_process,
                    True,
                    "monitor cleanup could not be confirmed",
                )
            raise

        if programs is None:
            raise AgentError(
                f"attachment readiness was not proven for {binding.interface}"
            )
        # Register before releasing the fence so a release failure remains
        # reachable through the reconciler's cleanup-debt path.
        self._managed[binding.port_id] = _ManagedAttachment(
            binding=binding,
            dns_process=dns_process,
            grpc_process=grpc_process,
            programs=programs,
        )
        self._leave_quiesce(binding.port_id)

    def detach(self, binding: Binding) -> None:
        managed = self._managed.get(binding.port_id)
        residual = self._residual.get(binding.port_id)
        self._enter_quiesce(binding.port_id)
        if residual is not None and residual.cleanup_blocked:
            raise AgentError(
                f"residual cleanup is blocked for {binding.port_id}: "
                f"{residual.reason}"
            )
        self._force_and_verify_bypass(binding, allow_all_missing=True)
        if managed is not None:
            grpc_stopped = self._stop(managed.grpc_process)
            dns_stopped = self._stop(managed.dns_process)
            if not grpc_stopped or not dns_stopped:
                raise AgentError(
                    f"monitor cleanup could not be confirmed for {binding.port_id}"
                )
            if (
                managed.grpc_process.poll() is not None
                and managed.dns_process.poll() is not None
            ):
                self._detach_owned_hooks(binding, managed.programs)
            self._managed.pop(binding.port_id, None)
        self._residual.pop(binding.port_id, None)
        self._remove_pin_tree(
            self._port_path(self._config.pin_root, binding.port_id)
        )
        self._remove_empty_pin_root()
        self._leave_quiesce(binding.port_id)

    def healthy(self, binding: Binding) -> bool:
        managed = self._managed.get(binding.port_id)
        if (
            managed is None
            or managed.binding != binding
            or managed.dns_process.poll() is not None
            or managed.grpc_process.poll() is not None
            or self._missing_pins(binding)
            or self._policy_quiesce_path(binding.port_id).exists()
        ):
            return False
        return self._programs_intact(
            binding,
            managed.dns_process,
            managed.grpc_process,
            managed.programs,
        )

    def snapshot(self) -> dict[str, Any]:
        managed: dict[str, Any] = {}
        for port_id, value in sorted(self._managed.items()):
            endpoint = self._endpoint(value.binding)
            missing_pins = self._missing_pins(value.binding)
            ownership_verified, current_programs, ownership_error = (
                self._program_ownership_status(
                    value.binding,
                    value.dns_process,
                    value.grpc_process,
                    value.programs,
                )
            )
            process_healthy = bool(
                value.dns_process.poll() is None
                and value.grpc_process.poll() is None
            )
            quiesced = self._policy_quiesce_path(port_id).exists()
            managed[port_id] = {
                "binding": asdict(value.binding),
                "accel_role": endpoint.accel_role,
                "dns_capability": _dns_capability(endpoint),
                "grpc_observe_port": endpoint.grpc_observe_port,
                "guest_grpc_listen_port": endpoint.guest_grpc_listen_port,
                "grpc_capability": GRPC_CAPABILITY,
                "dns_pid": value.dns_process.pid,
                "grpc_pid": value.grpc_process.pid,
                "program_ids": asdict(value.programs),
                "current_program_ids": (
                    asdict(current_programs)
                    if current_programs is not None
                    else None
                ),
                "hook_ownership_verified": ownership_verified,
                "hook_ownership_error": ownership_error,
                "healthy": bool(
                    process_healthy
                    and not missing_pins
                    and not quiesced
                    and ownership_verified
                ),
                "missing_pins": missing_pins,
            }
        for port_id, value in sorted(self._residual.items()):
            record = {
                "binding": asdict(value.binding),
                "accel_role": self._endpoint(value.binding).accel_role,
                "dns_capability": _dns_capability(
                    self._endpoint(value.binding)
                ),
                "grpc_observe_port": self._endpoint(
                    value.binding
                ).grpc_observe_port,
                "guest_grpc_listen_port": self._endpoint(
                    value.binding
                ).guest_grpc_listen_port,
                "grpc_capability": GRPC_CAPABILITY,
                "dns_pid": (
                    value.dns_process.pid
                    if value.dns_process is not None
                    else None
                ),
                "grpc_pid": (
                    value.grpc_process.pid
                    if value.grpc_process is not None
                    else None
                ),
                "healthy": False,
                "program_ids": None,
                "current_program_ids": None,
                "hook_ownership_verified": False,
                "hook_ownership_error": value.reason,
                "residual_cleanup_blocked": value.cleanup_blocked,
                "residual_reason": value.reason,
                "missing_pins": self._missing_pins(value.binding),
            }
            managed[port_id] = record
        return managed

    def _missing_pins(self, binding: Binding) -> list[str]:
        port_pin = self._port_path(self._config.pin_root, binding.port_id)
        required = [
            port_pin / "grpc" / "cache_runtime_control",
            port_pin / "grpc" / "grpc_policy_map",
            port_pin / "grpc" / "grpc_response_cache",
        ]
        if self._endpoint(binding).accel_role == "client":
            required[0:0] = [
                port_pin / "dns" / "cache_runtime_control",
                port_pin / "dns" / "dns_cache_stats",
                port_pin / "dns" / "dns_cache_entries",
            ]
        return [str(path) for path in required if not path.exists()]

    def _ensure_hook_slots_available(self, binding: Binding) -> None:
        current = self._current_programs(binding)
        occupied = [
            name
            for name, program_id in asdict(current).items()
            if program_id not in (None, 0)
        ]
        if occupied:
            raise AgentError(
                f"refusing to replace preexisting hooks on "
                f"{binding.interface}: {', '.join(occupied)}"
            )

    def _wait_attachment_ready(
        self,
        binding: Binding,
        dns_process: subprocess.Popen[bytes],
        grpc_process: subprocess.Popen[bytes],
    ) -> HookProgramIds:
        deadline = (
            time.monotonic()
            + self._config.attach_ready_timeout_seconds
        )
        last_reason = "attachment has not exposed pins and hook IDs"
        while True:
            if (
                dns_process.poll() is not None
                or grpc_process.poll() is not None
            ):
                raise AgentError(
                    f"monitor exited while attaching {binding.interface}"
                )
            missing_pins = self._missing_pins(binding)
            if missing_pins:
                last_reason = "missing maps: " + ", ".join(missing_pins)
            else:
                try:
                    current = self._current_programs(binding)
                    if not self._programs_ready(binding, current):
                        last_reason = "hook program IDs are not ready"
                    elif not self._programs_owned_by_processes(
                        current,
                        dns_process,
                        grpc_process,
                    ):
                        last_reason = (
                            "hook program IDs are not owned by monitor "
                            "processes"
                        )
                    else:
                        return current
                except (AgentError, OSError, UnicodeError) as error:
                    last_reason = str(error)
            now = time.monotonic()
            if now >= deadline:
                break
            time.sleep(min(ATTACH_READY_POLL_SECONDS, deadline - now))
        raise AgentError(
            f"attachment readiness timed out for {binding.interface}: "
            f"{last_reason}"
        )

    def _current_programs(self, binding: Binding) -> HookProgramIds:
        ingress = self._current_tc_program_ids(
            binding.interface,
            "ingress",
        )
        egress = self._current_tc_program_ids(
            binding.interface,
            "egress",
        )
        dns_xdp = (
            self._current_xdp_program_id(binding.interface)
            if self._endpoint(binding).accel_role == "client"
            else None
        )
        return HookProgramIds(
            dns_xdp=dns_xdp,
            dns_tc_ingress=ingress[DNS_TC_HANDLE],
            dns_tc_egress=egress[DNS_TC_HANDLE],
            grpc_tc_ingress=ingress[GRPC_TC_HANDLE],
            grpc_tc_egress=egress[GRPC_TC_HANDLE],
        )

    def _current_xdp_program_id(self, interface: str) -> int:
        try:
            value = json.loads(
                self._runner.run(
                    [
                        self._ip_command,
                        "-j",
                        "-details",
                        "link",
                        "show",
                        "dev",
                        interface,
                    ]
                )
            )
        except json.JSONDecodeError as error:
            raise AgentError("ip link returned invalid XDP JSON") from error
        if not isinstance(value, list) or len(value) != 1:
            raise AgentError(f"interface {interface} is not unique")
        return _extract_xdp_program_id(value[0])

    def _current_tc_program_ids(
        self,
        interface: str,
        direction: str,
    ) -> dict[int, int]:
        if direction not in {"ingress", "egress"}:
            raise AgentError(f"invalid tc direction: {direction}")
        try:
            value = json.loads(
                self._runner.run(
                    [
                        self._tc_command,
                        "-j",
                        "filter",
                        "show",
                        "dev",
                        interface,
                        direction,
                    ]
                )
            )
        except json.JSONDecodeError as error:
            raise AgentError("tc filter returned invalid JSON") from error
        return _extract_tc_program_ids(
            value,
            priority=TC_PRIORITY,
            handles=(DNS_TC_HANDLE, GRPC_TC_HANDLE),
        )

    def _programs_ready(
        self,
        binding: Binding,
        programs: HookProgramIds,
    ) -> bool:
        tc_programs = (
            programs.dns_tc_ingress,
            programs.dns_tc_egress,
            programs.grpc_tc_ingress,
            programs.grpc_tc_egress,
        )
        if not all(_plain_int(value) and value > 0 for value in tc_programs):
            return False
        if self._endpoint(binding).accel_role == "client":
            return bool(
                _plain_int(programs.dns_xdp)
                and programs.dns_xdp > 0
            )
        return programs.dns_xdp is None

    @staticmethod
    def _process_program_ids(
        process: subprocess.Popen[bytes],
    ) -> set[int]:
        fdinfo_root = Path("/proc") / str(process.pid) / "fdinfo"
        try:
            entries = list(fdinfo_root.iterdir())
        except OSError as error:
            raise AgentError(
                f"cannot inspect BPF program ownership for pid {process.pid}"
            ) from error
        program_ids: set[int] = set()
        for entry in entries:
            try:
                lines = entry.read_text(encoding="utf-8").splitlines()
            except FileNotFoundError:
                continue
            except OSError as error:
                raise AgentError(
                    f"cannot inspect BPF fd ownership for pid {process.pid}"
                ) from error
            for line in lines:
                key, separator, raw_value = line.partition(":")
                if separator and key.strip() == "prog_id":
                    program_id = _numeric_value(raw_value.strip())
                    if program_id is None or program_id <= 0:
                        raise AgentError(
                            f"pid {process.pid} has invalid BPF program ID"
                        )
                    program_ids.add(program_id)
        return program_ids

    def _programs_owned_by_processes(
        self,
        programs: HookProgramIds,
        dns_process: subprocess.Popen[bytes],
        grpc_process: subprocess.Popen[bytes],
    ) -> bool:
        if (
            dns_process.poll() is not None
            or grpc_process.poll() is not None
        ):
            return False
        dns_expected = {
            programs.dns_tc_ingress,
            programs.dns_tc_egress,
        }
        if programs.dns_xdp is not None:
            dns_expected.add(programs.dns_xdp)
        grpc_expected = {
            programs.grpc_tc_ingress,
            programs.grpc_tc_egress,
        }
        owned = bool(
            dns_expected.issubset(self._process_program_ids(dns_process))
            and grpc_expected.issubset(
                self._process_program_ids(grpc_process)
            )
        )
        return bool(
            owned
            and dns_process.poll() is None
            and grpc_process.poll() is None
        )

    def _program_ownership_status(
        self,
        binding: Binding,
        dns_process: subprocess.Popen[bytes],
        grpc_process: subprocess.Popen[bytes],
        expected: HookProgramIds,
    ) -> tuple[bool, HookProgramIds | None, str | None]:
        try:
            current = self._current_programs(binding)
            if current != expected:
                return False, current, "hook program IDs changed"
            if not self._programs_owned_by_processes(
                current,
                dns_process,
                grpc_process,
            ):
                return (
                    False,
                    current,
                    "hook program IDs are not owned by monitor processes",
                )
        except (AgentError, OSError, UnicodeError) as error:
            return False, None, str(error)
        return True, current, None

    def _programs_intact(
        self,
        binding: Binding,
        dns_process: subprocess.Popen[bytes],
        grpc_process: subprocess.Popen[bytes],
        expected: HookProgramIds,
    ) -> bool:
        verified, _current, _error = self._program_ownership_status(
            binding,
            dns_process,
            grpc_process,
            expected,
        )
        return verified

    def _hooks_absent(
        self,
        binding: Binding,
        programs: HookProgramIds,
    ) -> bool:
        tc_absent = all(
            value == 0
            for value in (
                programs.dns_tc_ingress,
                programs.dns_tc_egress,
                programs.grpc_tc_ingress,
                programs.grpc_tc_egress,
            )
        )
        if self._endpoint(binding).accel_role != "client":
            return tc_absent
        return tc_absent and programs.dns_xdp in {None, 0}

    def _detach_owned_hooks(
        self,
        binding: Binding,
        expected: HookProgramIds,
    ) -> None:
        """Remove hooks left behind after a monitor exits unexpectedly.

        The monitors normally detach through libbpf while they still own their
        program FDs.  If a supervisor terminates a monitor after it has lost
        that opportunity, the Agent must not remove pins and pretend cleanup
        succeeded.  Re-read every hook, require the attach-time program IDs to
        still match, remove only the two handles owned by this Agent, and then
        verify that all of those hooks are gone.  Foreign handles (including
        NetMig's 0x65/0x66) are never targeted.
        """
        try:
            current = self._current_programs(binding)
        except AgentError as error:
            # Neutron/OVS may delete the tap before the source Agent gets its
            # final reconcile.  Once the device is gone, its hooks cannot
            # survive; treating this as an idempotent cleanup avoids leaving
            # the source port in a permanent transition state.  Other query
            # failures remain fail-closed so ownership is never guessed.
            detail = str(error)
            if "Cannot find device" in detail or "No such device" in detail:
                return
            raise
        if self._hooks_absent(binding, current):
            return
        if current != expected:
            raise AgentError(
                "refusing fallback hook cleanup because ownership changed "
                f"for {binding.interface}"
            )

        if self._endpoint(binding).accel_role == "client":
            if expected.dns_xdp is None or expected.dns_xdp <= 0:
                raise AgentError(
                    f"client XDP ownership is invalid for {binding.interface}"
                )
            self._runner.run(
                [
                    self._ip_command,
                    "link",
                    "set",
                    "dev",
                    binding.interface,
                    "xdpgeneric",
                    "off",
                ]
            )

        for direction, handle in (
            ("ingress", DNS_TC_HANDLE),
            ("egress", DNS_TC_HANDLE),
            ("ingress", GRPC_TC_HANDLE),
            ("egress", GRPC_TC_HANDLE),
        ):
            self._runner.run(
                [
                    self._tc_command,
                    "filter",
                    "del",
                    "dev",
                    binding.interface,
                    direction,
                    "protocol",
                    "all",
                    "pref",
                    str(TC_PRIORITY),
                    "handle",
                    hex(handle),
                    "bpf",
                ]
            )

        remaining = self._current_programs(binding)
        if not self._hooks_absent(binding, remaining):
            raise AgentError(
                f"owned hook cleanup could not be verified for {binding.interface}"
            )

    def _initialize_committed_bypass(self, binding: Binding) -> None:
        self._force_and_verify_bypass(binding)

    def _force_and_verify_bypass(
        self,
        binding: Binding,
        allow_all_missing: bool = False,
    ) -> None:
        control_maps = self._runtime_control_maps(binding)
        common = [
            str(self._config.cache_policy_txn),
            "--lock-file",
            str(self._policy_lock_path(binding.port_id)),
            "--quiesce-file",
            str(self._policy_quiesce_path(binding.port_id)),
        ]
        for control_map in control_maps:
            common.extend(["--control-map", str(control_map)])
        if allow_all_missing:
            common.append("--allow-all-missing")
        try:
            force_timeout = self._remaining_timeout(
                self._config.command_timeout_seconds
            )
            force = subprocess.run(
                [
                    *common,
                    "--operation",
                    "force-bypass",
                    "--mode",
                    "bypass",
                    "--epoch",
                    "1",
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=force_timeout,
            )
            observed_timeout = self._remaining_timeout(
                self._config.command_timeout_seconds
            )
            observed = subprocess.run(
                [
                    *common,
                    "--operation",
                    "read-current",
                    "--mode",
                    "bypass",
                    "--epoch",
                    "1",
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=observed_timeout,
            )
        except subprocess.TimeoutExpired as error:
            raise AgentError(
                "cache policy transaction timed out after "
                f"{self._config.command_timeout_seconds:g}s for "
                f"{binding.port_id}"
            ) from error
        try:
            value = json.loads(observed.stdout)
        except (json.JSONDecodeError, TypeError):
            value = None
        maps_present = bool(
            observed.returncode == 0
            and isinstance(value, dict)
            and value.get("schema_version") == 1
            and value.get("present") is True
            and value.get("maps") == len(control_maps)
            and isinstance(value.get("epoch"), int)
            and not isinstance(value.get("epoch"), bool)
            and value["epoch"] >= 1
            and value.get("mode") == 1
            and value.get("flags") == 1
        )
        maps_absent = bool(
            allow_all_missing
            and observed.returncode == 0
            and isinstance(value, dict)
            and value.get("schema_version") == 1
            and value.get("present") is False
            and value.get("maps") == 0
            and value.get("epoch") == 0
            and value.get("mode") == 0
            and value.get("flags") == 0
        )
        confirmed = maps_present or maps_absent
        if not confirmed:
            detail = (
                observed.stderr.strip()
                or observed.stdout.strip()
                or force.stderr.strip()
                or force.stdout.strip()
            )
            raise AgentError(
                f"failed to confirm committed BYPASS for {binding.port_id}: "
                f"{detail[:400]}"
            )

    def commands(self, binding: Binding) -> tuple[list[str], list[str]]:
        endpoint = self._endpoint(binding)
        port_pin = self._port_path(self._config.pin_root, binding.port_id)
        if endpoint.accel_role == "client":
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
                str(self._config.dns_client_bpf),
            ]
            for address in endpoint.trusted_dns:
                dns.extend(["--trusted-dns", address])
            dns.extend(
                [
                    "--initial-runtime-bypass",
                    "--pin-dir",
                    str(port_pin / "dns"),
                ]
            )
        else:
            dns = [
                str(self._config.dns_monitor),
                "--dev",
                binding.interface,
                "--hook",
                "tc",
                "--bpf-object",
                str(self._config.dns_tc_bpf),
            ]
        grpc = [
            str(self._config.grpc_monitor),
            "--dev",
            binding.interface,
            "--bpf-object",
            str(self._config.grpc_bpf),
            "--port",
            str(endpoint.grpc_observe_port),
            "--initial-runtime-bypass",
            "--pin-dir",
            str(port_pin / "grpc"),
        ]
        if self._config.verbose_events:
            dns.append("--verbose-events")
            grpc.append("--verbose-events")
        return dns, grpc

    def _validate_config(self) -> None:
        if (
            isinstance(self._config.attach_ready_timeout_seconds, bool)
            or not isinstance(
                self._config.attach_ready_timeout_seconds,
                (int, float),
            )
            or not math.isfinite(
                self._config.attach_ready_timeout_seconds
            )
            or self._config.attach_ready_timeout_seconds <= 0
        ):
            raise AgentError(
                "attach ready timeout seconds must be positive"
            )
        if (
            isinstance(self._config.command_timeout_seconds, bool)
            or not isinstance(
                self._config.command_timeout_seconds, (int, float)
            )
            or not math.isfinite(self._config.command_timeout_seconds)
            or self._config.command_timeout_seconds <= 0
        ):
            raise AgentError("command timeout seconds must be positive")
        if not isinstance(self._config.verbose_events, bool):
            raise AgentError("verbose_events must be a boolean")
        for path in (
            self._config.dns_monitor,
            self._config.dns_client_bpf,
            self._config.dns_tc_bpf,
            self._config.grpc_monitor,
            self._config.grpc_bpf,
            self._config.cache_policy_txn,
        ):
            if not path.is_file():
                raise AgentError(f"missing attachment input: {path}")
        if not self._config.cache_policy_txn.is_absolute():
            raise AgentError("cache policy transaction path must be absolute")
        if not self._config.pin_root.is_absolute():
            raise AgentError("pin root must be absolute")
        if self._config.pin_root == Path("/sys/fs/bpf"):
            raise AgentError("pin root must be below /sys/fs/bpf")
        if not self._config.policy_lock_root.is_absolute():
            raise AgentError("policy lock root must be absolute")
        if self._config.policy_lock_root == Path("/"):
            raise AgentError("policy lock root must not be /")
        server_endpoints = [
            endpoint.server_id
            for endpoint in self._endpoint_by_server.values()
            if endpoint.accel_role == "server"
        ]
        if server_endpoints:
            raise AgentError(
                "server DNS role cannot run on host VM-facing interfaces; "
                "manage these server IDs with a guest-side agent: "
                + ", ".join(sorted(server_endpoints))
            )

    def _endpoint(self, binding: Binding) -> EndpointConfig:
        endpoint = self._endpoint_by_server.get(binding.server_id)
        if endpoint is None:
            raise AgentError(
                f"no endpoint config for server {binding.server_id}"
            )
        if endpoint.accel_role == "server":
            raise AgentError(
                f"server DNS role for {binding.server_id} must be managed "
                "by a guest-side agent"
            )
        if binding.port_id not in endpoint.port_ids:
            raise AgentError(
                f"port {binding.port_id} is not declared for server "
                f"{binding.server_id}"
            )
        return endpoint

    def _runtime_control_maps(self, binding: Binding) -> list[Path]:
        endpoint = self._endpoint(binding)
        port_pin = self._port_path(self._config.pin_root, binding.port_id)
        maps = [port_pin / "grpc" / "cache_runtime_control"]
        if endpoint.accel_role == "client":
            maps.insert(0, port_pin / "dns" / "cache_runtime_control")
        return maps

    def _policy_lock_path(self, port_id: str) -> Path:
        if not port_id or any(char not in "0123456789abcdef-" for char in port_id):
            raise AgentError(f"unsafe port ID: {port_id}")
        root = self._config.policy_lock_root
        candidate = root / f"vnet-dataplane-{port_id}.lock"
        if candidate.parent != root:
            raise AgentError(f"unsafe policy lock path: {candidate}")
        return candidate

    def _policy_quiesce_path(self, port_id: str) -> Path:
        if not port_id or any(char not in "0123456789abcdef-" for char in port_id):
            raise AgentError(f"unsafe port ID: {port_id}")
        root = self._config.policy_lock_root
        candidate = root / f"vnet-dataplane-{port_id}.quiesce"
        if candidate.parent != root:
            raise AgentError(f"unsafe policy quiesce path: {candidate}")
        return candidate

    def _open_policy_lock(self, port_id: str) -> int:
        root = self._config.policy_lock_root
        lock_path = self._policy_lock_path(port_id)
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        named_root = os.lstat(root)
        self._validate_policy_root_status(named_root)

        root_descriptor: int | None = None
        lock_descriptor = -1
        try:
            if os.name != "nt":
                root_descriptor = os.open(
                    root,
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_NOFOLLOW", 0),
                )
                opened_root = os.fstat(root_descriptor)
                self._validate_policy_root_status(opened_root)
                if self._file_identity(opened_root) != self._file_identity(named_root):
                    raise AgentError("policy lock root changed during open")

            lock_name: str | Path = (
                lock_path.name if root_descriptor is not None else lock_path
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
                named_lock = os.lstat(lock_path)
                opened_root = os.lstat(root)
            else:
                named_lock = os.stat(
                    lock_path.name,
                    dir_fd=root_descriptor,
                    follow_symlinks=False,
                )
                opened_root = os.fstat(root_descriptor)
            named_current_root = os.lstat(root)
            self._validate_policy_lock_status(named_lock)
            self._validate_policy_root_status(opened_root)
            self._validate_policy_root_status(named_current_root)
            if self._file_identity(named_lock) != self._file_identity(opened_lock):
                raise AgentError("policy lock changed during acquisition")
            if (
                self._file_identity(opened_root) != self._file_identity(named_root)
                or self._file_identity(named_current_root)
                != self._file_identity(opened_root)
            ):
                raise AgentError("policy lock root changed during acquisition")
            return lock_descriptor
        except OSError as error:
            if lock_descriptor >= 0:
                os.close(lock_descriptor)
            raise AgentError(f"policy lock acquisition failed: {error}") from error
        except Exception:
            if lock_descriptor >= 0:
                os.close(lock_descriptor)
            raise
        finally:
            if root_descriptor is not None:
                os.close(root_descriptor)

    @staticmethod
    def _file_identity(status: os.stat_result) -> tuple[int, int]:
        return status.st_dev, status.st_ino

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
                time.sleep(ATTACH_READY_POLL_SECONDS)
                continue
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AgentError(
                    "shutdown deadline expired waiting for policy lock"
                )
            time.sleep(min(ATTACH_READY_POLL_SECONDS, remaining))

    @staticmethod
    def _validate_policy_root_status(status: os.stat_result) -> None:
        if not stat.S_ISDIR(status.st_mode):
            raise AgentError("policy lock root is not a real directory")
        if os.name != "nt":
            current_uid = os.geteuid()
            if status.st_uid not in {0, current_uid}:
                raise AgentError("policy lock root has an unsafe owner")
            if stat.S_IMODE(status.st_mode) & 0o022:
                raise AgentError("policy lock root is writable by other users")

    @staticmethod
    def _validate_policy_lock_status(status: os.stat_result) -> None:
        if not stat.S_ISREG(status.st_mode):
            raise AgentError("policy lock is not a regular file")
        if status.st_nlink != 1:
            raise AgentError("policy lock has an unsafe link count")
        if os.name != "nt":
            if status.st_uid != os.geteuid():
                raise AgentError("policy lock has an unsafe owner")
            if stat.S_IMODE(status.st_mode) != 0o600:
                raise AgentError("policy lock has unsafe permissions")

    @staticmethod
    def _validate_quiesce_status(status: os.stat_result) -> None:
        if not stat.S_ISREG(status.st_mode):
            raise AgentError("quiesce file is not a regular file")
        if status.st_nlink != 1:
            raise AgentError("quiesce file has an unsafe link count")
        if os.name != "nt":
            if status.st_uid != os.geteuid():
                raise AgentError("quiesce file has an unsafe owner")
            if stat.S_IMODE(status.st_mode) != 0o600:
                raise AgentError("quiesce file has unsafe permissions")

    def _enter_quiesce(self, port_id: str) -> None:
        path = self._policy_quiesce_path(port_id)
        policy_descriptor = self._open_policy_lock(port_id)
        try:
            try:
                current = os.lstat(path)
            except FileNotFoundError:
                current = None
            if current is not None:
                self._validate_quiesce_status(current)

            expected = self._quiesce_identities.get(port_id)
            if expected is not None:
                if current is None or self._file_identity(current) != expected:
                    raise AgentError("quiesce file was replaced")
                descriptor = self._quiesce_fds.get(port_id)
                if (
                    descriptor is not None
                    and self._file_identity(os.fstat(descriptor)) != expected
                ):
                    raise AgentError("quiesce file descriptor was replaced")
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
                        path,
                        flags | os.O_CREAT | os.O_EXCL,
                        0o600,
                    )
                    if os.name != "nt":
                        os.fchmod(descriptor, 0o600)
                except FileExistsError:
                    descriptor = os.open(path, flags)
                opened = os.fstat(descriptor)
                self._validate_quiesce_status(opened)
                if fcntl is not None:
                    try:
                        fcntl.flock(
                            descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB
                        )
                    except OSError as error:
                        if error.errno in {errno.EACCES, errno.EAGAIN}:
                            raise AgentError(
                                "quiesce file is owned by another agent"
                            ) from error
                        raise
                named = os.lstat(path)
                self._validate_quiesce_status(named)
                if self._file_identity(named) != self._file_identity(opened):
                    raise AgentError("quiesce file was replaced")
                if os.name == "nt":
                    os.close(descriptor)
                    descriptor = -1
                else:
                    self._quiesce_fds[port_id] = descriptor
                self._quiesce_identities[port_id] = self._file_identity(opened)
            except Exception:
                if descriptor >= 0:
                    os.close(descriptor)
                raise
        finally:
            os.close(policy_descriptor)

    def _leave_quiesce(self, port_id: str) -> None:
        path = self._policy_quiesce_path(port_id)
        policy_descriptor = self._open_policy_lock(port_id)
        try:
            expected = self._quiesce_identities.get(port_id)
            descriptor = self._quiesce_fds.get(port_id)
            if expected is None:
                if os.path.lexists(path):
                    raise AgentError("quiesce file ownership is unknown")
                return
            if (
                descriptor is not None
                and self._file_identity(os.fstat(descriptor)) != expected
            ):
                raise AgentError("quiesce file descriptor was replaced")
            try:
                named = os.lstat(path)
            except FileNotFoundError:
                raise AgentError("quiesce file disappeared") from None
            self._validate_quiesce_status(named)
            if self._file_identity(named) != expected:
                raise AgentError("quiesce file was replaced")

            release_path = path.with_name(
                f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.release"
            )
            try:
                os.replace(path, release_path)
                released = os.lstat(release_path)
                if self._file_identity(released) != expected:
                    raise AgentError("quiesce file was replaced")
                release_path.unlink()
            except Exception as error:
                try:
                    if os.path.lexists(release_path) and not os.path.lexists(path):
                        os.replace(release_path, path)
                except Exception as restore_error:
                    raise AgentError(
                        "quiesce release failed and fence restoration failed: "
                        f"{restore_error}"
                    ) from error
                raise

            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError as error:
                    print(
                        "openstack_dataplane_agent: warning: close quiesce "
                        f"descriptor failed after release: {error}",
                        file=sys.stderr,
                    )
            self._quiesce_fds.pop(port_id, None)
            self._quiesce_identities.pop(port_id, None)
            if os.path.lexists(path):
                raise AgentError("quiesce file was replaced")
        finally:
            os.close(policy_descriptor)

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

    def _stop(self, process: subprocess.Popen[bytes]) -> bool:
        if process.poll() is not None:
            return True
        for sig, timeout, cleanup_confirmed in (
            (signal.SIGINT, 3.0, True),
            (signal.SIGTERM, 2.0, True),
            (getattr(signal, "SIGKILL", signal.SIGTERM), 1.0, False),
        ):
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                return cleanup_confirmed and process.poll() is not None
            try:
                process.wait(timeout=self._remaining_timeout(timeout))
                return cleanup_confirmed
            except (AgentError, subprocess.TimeoutExpired):
                if (
                    self._shutdown_deadline is not None
                    and time.monotonic() >= self._shutdown_deadline
                ):
                    return False
                continue
        return False

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

@dataclass
class ReconcileEvent:
    action: str
    port_id: str
    reason: str
    binding: Binding | None = None


@dataclass(frozen=True)
class PortHealth:
    port_id: str
    state: str
    reason: str
    binding: Binding | None = None


class Reconciler:
    def __init__(
        self,
        driver: AttachmentDriver,
        missing_grace_cycles: int = 2,
        *,
        allowed_port_ids_by_server: Mapping[str, Sequence[str]] | None = None,
    ):
        if missing_grace_cycles < 1:
            raise AgentError("missing grace cycles must be positive")
        self._driver = driver
        self._missing_grace_cycles = missing_grace_cycles
        self._allowed_port_ids_by_server = (
            None
            if allowed_port_ids_by_server is None
            else {
                server_id: frozenset(
                    _canonical_port_ids(
                        port_ids,
                        f"server {server_id} allowed port IDs",
                    )
                )
                for server_id, port_ids in allowed_port_ids_by_server.items()
            }
        )
        self._current: dict[str, Binding] = {}
        self._cleanup_debt: dict[str, Binding] = {}
        self._missing: dict[str, int] = {}
        self._port_health: dict[str, PortHealth] = {}

    def reconcile(self, desired: Sequence[Binding]) -> list[ReconcileEvent]:
        if self._allowed_port_ids_by_server is not None:
            for binding in desired:
                allowed_port_ids = self._allowed_port_ids_by_server.get(
                    binding.server_id
                )
                if (
                    allowed_port_ids is None
                    or binding.port_id not in allowed_port_ids
                ):
                    raise AgentError(
                        f"port {binding.port_id} is not declared for server "
                        f"{binding.server_id}"
                    )
        desired_by_port = {binding.port_id: binding for binding in desired}
        if len(desired_by_port) != len(desired):
            raise AgentError("desired bindings contain duplicate port IDs")
        events: list[ReconcileEvent] = []

        cleanup_blocked: set[str] = set()
        for port_id, binding in list(self._cleanup_debt.items()):
            try:
                self._driver.detach(binding)
            except Exception as error:
                cleanup_blocked.add(port_id)
                self._set_port_health(
                    binding,
                    "degraded",
                    f"cleanup_failed:{error}",
                )
                events.append(
                    ReconcileEvent(
                        "error",
                        port_id,
                        f"cleanup_failed:{error}",
                        binding,
                    )
                )
                continue
            del self._cleanup_debt[port_id]
            if port_id in desired_by_port:
                self._set_port_health(
                    binding,
                    "transition",
                    "cleanup_completed",
                )
                events.append(
                    ReconcileEvent(
                        "cleanup",
                        port_id,
                        "cleanup_completed",
                        binding,
                    )
                )
            else:
                self._set_port_health(
                    binding,
                    "absent",
                    "binding_left_host",
                )
                events.append(
                    ReconcileEvent(
                        "cleanup",
                        port_id,
                        "binding_left_host",
                        binding,
                    )
                )

        for port_id, current in list(self._current.items()):
            wanted = desired_by_port.get(port_id)
            if wanted is None:
                missing = self._missing.get(port_id, 0) + 1
                self._missing[port_id] = missing
                if missing < self._missing_grace_cycles:
                    self._set_port_health(
                        current,
                        "transition",
                        f"missing_grace_{missing}",
                    )
                    events.append(
                        ReconcileEvent(
                            "wait",
                            port_id,
                            f"missing_grace_{missing}",
                            current,
                        )
                    )
                    continue
                try:
                    self._driver.detach(current)
                except Exception as error:
                    self._set_port_health(
                        current,
                        "degraded",
                        f"detach_failed:{error}",
                    )
                    events.append(
                        ReconcileEvent(
                            "error",
                            port_id,
                            f"detach_failed:{error}",
                            current,
                        )
                    )
                    continue
                del self._current[port_id]
                self._missing.pop(port_id, None)
                self._set_port_health(current, "absent", "binding_left_host")
                events.append(
                    ReconcileEvent("detach", port_id, "binding_left_host", current)
                )
                continue

            self._missing.pop(port_id, None)
            if wanted != current:
                try:
                    self._driver.detach(current)
                except Exception as error:
                    self._set_port_health(
                        current,
                        "degraded",
                        f"detach_failed:{error}",
                    )
                    events.append(
                        ReconcileEvent(
                            "error",
                            port_id,
                            f"detach_failed:{error}",
                            current,
                        )
                    )
                    continue
                del self._current[port_id]
                self._set_port_health(current, "transition", "binding_changed")
                events.append(
                    ReconcileEvent("detach", port_id, "binding_changed", current)
                )
            elif not self._driver.healthy(current):
                try:
                    self._driver.detach(current)
                except Exception as error:
                    self._set_port_health(
                        current,
                        "degraded",
                        f"detach_failed:{error}",
                    )
                    events.append(
                        ReconcileEvent(
                            "error",
                            port_id,
                            f"detach_failed:{error}",
                            current,
                        )
                    )
                    continue
                del self._current[port_id]
                self._set_port_health(current, "degraded", "monitor_unhealthy")
                events.append(
                    ReconcileEvent("detach", port_id, "monitor_unhealthy", current)
                )

        for port_id, wanted in desired_by_port.items():
            if (
                port_id in self._current
                or port_id in cleanup_blocked
                or port_id in self._cleanup_debt
            ):
                continue
            try:
                self._driver.attach(wanted)
            except Exception as error:
                self._cleanup_debt[port_id] = wanted
                self._set_port_health(wanted, "degraded", f"attach_failed:{error}")
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
            if not self._driver.healthy(wanted):
                try:
                    self._driver.detach(wanted)
                except Exception as error:
                    self._set_port_health(
                        wanted,
                        "degraded",
                        f"attach_cleanup_failed:{error}",
                    )
                    events.append(
                        ReconcileEvent(
                            "error",
                            port_id,
                            f"attach_cleanup_failed:{error}",
                            wanted,
                        )
                    )
                    continue
                del self._current[port_id]
                self._set_port_health(
                    wanted,
                    "degraded",
                    "attach_unhealthy",
                )
                events.append(
                    ReconcileEvent("error", port_id, "attach_unhealthy", wanted)
                )
                continue
            self._set_port_health(wanted, "healthy", "binding_local")
            events.append(ReconcileEvent("attach", port_id, "binding_local", wanted))
        return events

    def close(self) -> list[ReconcileEvent]:
        events: list[ReconcileEvent] = []
        for port_id, binding in list(self._current.items()):
            try:
                self._driver.detach(binding)
            except Exception as error:
                self._set_port_health(
                    binding,
                    "degraded",
                    f"stop_failed:{error}",
                )
                events.append(
                    ReconcileEvent(
                        "error",
                        port_id,
                        f"stop_failed:{error}",
                        binding,
                    )
                )
                continue
            del self._current[port_id]
            self._set_port_health(binding, "stopped", "agent_stopped")
            events.append(ReconcileEvent("detach", port_id, "agent_stopped", binding))
        for port_id, binding in list(self._cleanup_debt.items()):
            try:
                self._driver.detach(binding)
            except Exception as error:
                self._set_port_health(
                    binding,
                    "degraded",
                    f"stop_cleanup_failed:{error}",
                )
                events.append(
                    ReconcileEvent(
                        "error",
                        port_id,
                        f"stop_cleanup_failed:{error}",
                        binding,
                    )
                )
                continue
            del self._cleanup_debt[port_id]
            self._set_port_health(binding, "stopped", "agent_stopped")
            events.append(
                ReconcileEvent("cleanup", port_id, "agent_stopped", binding)
            )
        self._missing.clear()
        return events

    def bindings(self) -> list[Binding]:
        return [self._current[key] for key in sorted(self._current)]

    def port_health(self) -> list[PortHealth]:
        return [self._port_health[key] for key in sorted(self._port_health)]

    def _set_port_health(
        self,
        binding: Binding,
        state: str,
        reason: str,
    ) -> None:
        self._port_health[binding.port_id] = PortHealth(
            port_id=binding.port_id,
            state=state,
            reason=reason,
            binding=binding,
        )


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


def _binding_state(
    binding: Binding, endpoint_by_server: dict[str, EndpointConfig]
) -> dict[str, Any]:
    endpoint = endpoint_by_server.get(binding.server_id)
    if endpoint is None:
        raise AgentError(
            f"binding references unconfigured server {binding.server_id}"
        )
    if binding.port_id not in endpoint.port_ids:
        raise AgentError(
            f"binding port {binding.port_id} is not declared for server "
            f"{binding.server_id}"
        )
    return {
        **asdict(binding),
        "accel_role": endpoint.accel_role,
        "dns_capability": _dns_capability(endpoint),
        "grpc_observe_port": endpoint.grpc_observe_port,
        "guest_grpc_listen_port": endpoint.guest_grpc_listen_port,
        "grpc_capability": GRPC_CAPABILITY,
    }


def _port_health_state(
    item: PortHealth, endpoint_by_server: dict[str, EndpointConfig]
) -> dict[str, Any]:
    record: dict[str, Any] = {
        "port_id": item.port_id,
        "state": item.state,
        "reason": item.reason,
        "binding": None,
    }
    if item.binding is not None:
        endpoint = endpoint_by_server.get(item.binding.server_id)
        if endpoint is None:
            raise AgentError(
                f"port health references unconfigured server "
                f"{item.binding.server_id}"
            )
        if item.binding.port_id not in endpoint.port_ids:
            raise AgentError(
                f"port health references undeclared port "
                f"{item.binding.port_id} for server {item.binding.server_id}"
            )
        record.update(
            {
                "accel_role": endpoint.accel_role,
                "dns_capability": _dns_capability(endpoint),
                "grpc_observe_port": endpoint.grpc_observe_port,
                "guest_grpc_listen_port": endpoint.guest_grpc_listen_port,
                "grpc_capability": GRPC_CAPABILITY,
                "binding": _binding_state(item.binding, endpoint_by_server),
            }
        )
    return record


def _write_state(
    path: Path,
    server_ids: Sequence[str],
    local_host: str,
    reconciler: Reconciler,
    driver: AttachmentDriver,
    endpoint_configs: Sequence[EndpointConfig],
    *,
    sample_completed_ms: int,
    port_inventory: Sequence[PortInventory] = (),
    snapshot_error: str | None = None,
) -> None:
    if (
        not isinstance(sample_completed_ms, int)
        or isinstance(sample_completed_ms, bool)
        or sample_completed_ms < 0
    ):
        raise AgentError("sample completion time must be a non-negative integer")
    if snapshot_error is not None:
        if not isinstance(snapshot_error, str) or not snapshot_error.strip():
            raise AgentError("snapshot error must be a non-empty string")
        snapshot_error = snapshot_error.strip()[:400]
    configured_server_ids = _server_ids(server_ids)
    if len(configured_server_ids) != len(server_ids):
        raise AgentError("state server_ids must be unique")
    endpoint_by_server = _validated_endpoint_map(
        endpoint_configs, "state endpoint config"
    )
    _require_host_endpoint_roles(
        tuple(endpoint_by_server.values()), "state endpoint config"
    )
    missing_configs = sorted(set(configured_server_ids) - set(endpoint_by_server))
    extra_configs = sorted(set(endpoint_by_server) - set(configured_server_ids))
    if missing_configs or extra_configs:
        detail = []
        if missing_configs:
            detail.append(f"missing={','.join(missing_configs)}")
        if extra_configs:
            detail.append(f"extra={','.join(extra_configs)}")
        raise AgentError(
            "state endpoint config does not match server_ids: "
            + " ".join(detail)
        )
    published_configs = [
        endpoint_by_server[server_id] for server_id in configured_server_ids
    ]
    health_records = reconciler.port_health()
    if snapshot_error is None:
        published_bindings = reconciler.bindings()
        published_health_records = health_records
    else:
        published_bindings = []
        published_health_records = tuple(
            PortHealth(
                port_id=item.port_id,
                state="degraded",
                reason=f"snapshot_inconsistent:{snapshot_error}",
            )
            for item in health_records
        )
    health = _health_summary(published_health_records, published_configs)
    health["snapshot_consistency"] = (
        "consistent" if snapshot_error is None else "degraded"
    )
    health["snapshot_error"] = snapshot_error
    if snapshot_error is not None:
        health["status"] = "degraded"
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema_version": AGENT_STATE_SCHEMA_VERSION,
        "server_id": (
            configured_server_ids[0] if len(configured_server_ids) == 1 else None
        ),
        "server_ids": configured_server_ids,
        "local_host": local_host,
        "endpoint_config": [
            _endpoint_config_state(config) for config in published_configs
        ],
        "dns_capabilities": {
            config.server_id: _dns_capability(config)
            for config in published_configs
        },
        "grpc_capability": GRPC_CAPABILITY,
        "port_inventory": [asdict(item) for item in port_inventory],
        "bindings": [
            _binding_state(binding, endpoint_by_server)
            for binding in published_bindings
        ],
        "attachments": driver.snapshot(),
        "port_health": [
            _port_health_state(item, endpoint_by_server)
            for item in published_health_records
        ],
        "health": health,
        "snapshot_consistency": {
            "status": (
                "consistent" if snapshot_error is None else "degraded"
            ),
            "error": snapshot_error,
        },
        "updated_ms": sample_completed_ms,
    }
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def _health_summary(
    port_health: Sequence[PortHealth],
    endpoint_configs: Sequence[EndpointConfig],
) -> dict[str, Any]:
    groups = {
        "healthy": [],
        "transition": [],
        "degraded": [],
        "absent": [],
        "stopped": [],
    }
    for item in port_health:
        groups.setdefault(item.state, []).append(item.port_id)
    if groups["degraded"]:
        status = "degraded"
    elif groups["transition"]:
        status = "transition"
    elif groups["healthy"]:
        status = "healthy"
    elif groups["stopped"]:
        status = "stopped"
    else:
        status = "idle"
    return {
        "status": status,
        "accel_roles": {
            config.server_id: config.accel_role for config in endpoint_configs
        },
        "grpc_observe_ports": {
            config.server_id: config.grpc_observe_port
            for config in endpoint_configs
        },
        "guest_grpc_listen_ports": {
            config.server_id: config.guest_grpc_listen_port
            for config in endpoint_configs
        },
        "dns_capabilities": {
            config.server_id: _dns_capability(config)
            for config in endpoint_configs
        },
        "grpc_capability": GRPC_CAPABILITY,
        "healthy_port_ids": sorted(groups["healthy"]),
        "transition_port_ids": sorted(groups["transition"]),
        "degraded_port_ids": sorted(groups["degraded"]),
        "absent_port_ids": sorted(groups["absent"]),
    }


def _local_host(
    argument: str | None,
    runner: CommandRunner | None = None,
    hostname_command: str = "hostname",
) -> str:
    if argument is not None:
        host = argument.strip()
        if not host:
            raise AgentError("local host must not be empty")
        return host
    if runner is None:
        runner = CommandRunner()
    host = runner.run(
        [_external_command(hostname_command, "hostname"), "-s"]
    ).strip()
    if not host:
        raise AgentError("hostname command returned an empty host")
    return host


def _add_external_command_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--openstack-command", default="openstack")
    parser.add_argument("--ovs-vsctl-command", default="ovs-vsctl")
    parser.add_argument("--ip-command", default="ip")
    parser.add_argument("--tc-command", default="tc")
    parser.add_argument("--hostname-command", default="hostname")
    parser.add_argument(
        "--command-timeout-seconds",
        type=float,
        default=DEFAULT_COMMAND_TIMEOUT_SECONDS,
    )


def _add_discovery_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--server-id", action="append")
    parser.add_argument("--server-id-file", type=Path)
    parser.add_argument("--endpoint-config", type=Path)
    parser.add_argument("--local-host")
    _add_external_command_args(parser)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    discover = subparsers.add_parser("discover", help="resolve local VM bindings")
    _add_discovery_args(discover)

    watch = subparsers.add_parser("watch", help="reconcile attachments continuously")
    watch.add_argument("--endpoint-config", required=True, type=Path)
    watch.add_argument("--local-host")
    _add_external_command_args(watch)
    watch.add_argument("--dns-monitor", required=True, type=Path)
    watch.add_argument("--dns-client-bpf", required=True, type=Path)
    watch.add_argument("--dns-tc-bpf", required=True, type=Path)
    watch.add_argument("--grpc-monitor", required=True, type=Path)
    watch.add_argument("--grpc-bpf", required=True, type=Path)
    watch.add_argument("--cache-policy-txn", required=True, type=Path)
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
        "--policy-lock-root",
        type=Path,
        default=POLICY_LOCK_ROOT,
    )
    watch.add_argument(
        "--state-file",
        type=Path,
        default=Path("/run/vnet-dataplane-agent/state.json"),
    )
    watch.add_argument("--audit-log", type=Path)
    watch.add_argument("--interval", type=float, default=2.0)
    watch.add_argument("--missing-grace-cycles", type=int, default=2)
    watch.add_argument(
        "--attach-ready-timeout-seconds",
        type=float,
        default=DEFAULT_ATTACH_READY_TIMEOUT_SECONDS,
    )
    watch.add_argument(
        "--shutdown-timeout-seconds",
        type=float,
        default=DEFAULT_SHUTDOWN_TIMEOUT_SECONDS,
    )
    watch.add_argument(
        "--verbose-events",
        action="store_true",
        help="emit per-packet monitor events for debugging",
    )
    watch.add_argument("--max-cycles", type=int, default=0)

    health = subparsers.add_parser("health", help="check an agent state file")
    health.add_argument("--state-file", required=True, type=Path)
    health.add_argument("--server-id", action="append")
    health.add_argument("--server-id-file", type=Path)
    health.add_argument("--max-age-seconds", type=float, default=10.0)

    wait_reconcile = subparsers.add_parser(
        "wait-reconcile",
        help="wait for a matching reconcile audit record",
    )
    wait_reconcile.add_argument("--audit-log", required=True, type=Path)
    wait_reconcile.add_argument("--after-offset", required=True, type=int)
    wait_reconcile.add_argument("--audit-device", required=True, type=int)
    wait_reconcile.add_argument("--audit-inode", required=True, type=int)
    wait_reconcile.add_argument("--port-id", required=True)
    wait_reconcile.add_argument("--server-id", required=True)
    wait_reconcile.add_argument(
        "--action", required=True, choices=("detach", "attach")
    )
    wait_reconcile.add_argument(
        "--reason",
        required=True,
        choices=("binding_left_host", "binding_local"),
    )
    wait_reconcile.add_argument("--expected-host", required=True)
    wait_reconcile.add_argument("--timeout", type=float, default=30.0)
    wait_reconcile.add_argument("--interval", type=float, default=0.1)
    return parser


def _discover(args: argparse.Namespace) -> int:
    runner = CommandRunner(
        getattr(
            args,
            "command_timeout_seconds",
            DEFAULT_COMMAND_TIMEOUT_SECONDS,
        )
    )
    host = _local_host(
        args.local_host,
        runner,
        getattr(args, "hostname_command", "hostname"),
    )
    resolver = OpenStackOvsResolver(
        runner,
        host,
        openstack_command=getattr(
            args, "openstack_command", "openstack"
        ),
        ovs_vsctl_command=getattr(
            args, "ovs_vsctl_command", "ovs-vsctl"
        ),
        ip_command=getattr(args, "ip_command", "ip"),
    )
    endpoint_config_path = getattr(args, "endpoint_config", None)
    allowed_port_ids_by_server: dict[str, tuple[str, ...]] | None = None
    if endpoint_config_path is None:
        server_ids = _configured_server_ids(args)
    else:
        endpoint_configs = _load_endpoint_configs(endpoint_config_path)
        allowed_port_ids_by_server = {
            config.server_id: config.port_ids for config in endpoint_configs
        }
        has_server_filter = bool(
            getattr(args, "server_id", None)
            or getattr(args, "server_id_file", None)
        )
        server_ids = (
            _configured_server_ids(args)
            if has_server_filter
            else list(allowed_port_ids_by_server)
        )
        undeclared_servers = sorted(
            set(server_ids) - set(allowed_port_ids_by_server)
        )
        if undeclared_servers:
            raise AgentError(
                "server IDs are absent from endpoint config: "
                + ", ".join(undeclared_servers)
            )
    discovery = (
        resolver.discover_many_with_inventory(server_ids)
        if allowed_port_ids_by_server is None
        else resolver.discover_many_with_inventory(
            server_ids,
            allowed_port_ids_by_server,
        )
    )
    print(
        json.dumps(
            {
                "server_id": server_ids[0] if len(server_ids) == 1 else None,
                "server_ids": server_ids,
                "local_host": host,
                "port_policy_enforced": allowed_port_ids_by_server is not None,
                "policy_errors": list(discovery.policy_errors),
                "port_inventory": [
                    asdict(item) for item in discovery.port_inventory
                ],
                "bindings": [asdict(binding) for binding in discovery.bindings],
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 2 if discovery.policy_errors else 0


def _watch(args: argparse.Namespace) -> int:
    if os.geteuid() != 0:
        raise AgentError("watch must run as root")
    if args.interval <= 0:
        raise AgentError("interval must be positive")
    shutdown_timeout_seconds = getattr(
        args,
        "shutdown_timeout_seconds",
        DEFAULT_SHUTDOWN_TIMEOUT_SECONDS,
    )
    if (
        isinstance(shutdown_timeout_seconds, bool)
        or not isinstance(shutdown_timeout_seconds, (int, float))
        or not math.isfinite(shutdown_timeout_seconds)
        or shutdown_timeout_seconds <= 0
    ):
        raise AgentError("shutdown timeout seconds must be positive")
    if args.policy_lock_root != POLICY_LOCK_ROOT:
        raise AgentError(
            f"watch policy lock root must be exactly {POLICY_LOCK_ROOT}"
        )
    endpoint_configs = _load_endpoint_configs(args.endpoint_config)
    server_ids = [config.server_id for config in endpoint_configs]
    allowed_port_ids_by_server = {
        config.server_id: config.port_ids for config in endpoint_configs
    }
    command_timeout_seconds = getattr(
        args,
        "command_timeout_seconds",
        DEFAULT_COMMAND_TIMEOUT_SECONDS,
    )
    runner = CommandRunner(command_timeout_seconds)
    host = _local_host(
        args.local_host,
        runner,
        getattr(args, "hostname_command", "hostname"),
    )
    resolver = OpenStackOvsResolver(
        runner,
        host,
        openstack_command=getattr(
            args, "openstack_command", "openstack"
        ),
        ovs_vsctl_command=getattr(
            args, "ovs_vsctl_command", "ovs-vsctl"
        ),
        ip_command=getattr(args, "ip_command", "ip"),
    )
    config = AttachmentConfig(
        dns_monitor=args.dns_monitor,
        dns_client_bpf=args.dns_client_bpf,
        dns_tc_bpf=args.dns_tc_bpf,
        grpc_monitor=args.grpc_monitor,
        grpc_bpf=args.grpc_bpf,
        cache_policy_txn=args.cache_policy_txn,
        endpoint_configs=endpoint_configs,
        pin_root=args.pin_root,
        log_root=args.log_root,
        policy_lock_root=args.policy_lock_root,
        ip_command=getattr(args, "ip_command", "ip"),
        tc_command=getattr(args, "tc_command", "tc"),
        attach_ready_timeout_seconds=getattr(
            args,
            "attach_ready_timeout_seconds",
            DEFAULT_ATTACH_READY_TIMEOUT_SECONDS,
        ),
        command_timeout_seconds=command_timeout_seconds,
        verbose_events=args.verbose_events,
    )
    driver = ProcessAttachmentDriver(config, runner)
    reconciler = Reconciler(
        driver,
        args.missing_grace_cycles,
        allowed_port_ids_by_server=allowed_port_ids_by_server,
    )
    audit = JsonAudit(args.audit_log)
    stopping = threading.Event()

    def request_stop(_signum: int, _frame: Any) -> None:
        if not stopping.is_set():
            deadline = time.monotonic() + shutdown_timeout_seconds
            driver.begin_shutdown(deadline)
            stopping.set()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    audit.emit(
        "agent_started",
        server_ids=server_ids,
        endpoint_config=[
            _endpoint_config_state(config) for config in endpoint_configs
        ],
        dns_capabilities={
            config.server_id: _dns_capability(config)
            for config in endpoint_configs
        },
        grpc_capability=GRPC_CAPABILITY,
        local_host=host,
    )
    cycles = 0
    port_inventory: tuple[PortInventory, ...] = ()
    sample_completed_ms = 0
    snapshot_error: str | None = "discovery_not_completed"
    shutdown_cleanup_failed = False
    try:
        while not stopping.is_set():
            try:
                sampled = _sample_discovery(
                    resolver,
                    server_ids,
                    allowed_port_ids_by_server,
                )
            except Exception as error:
                snapshot_error = f"discovery_failed:{error}"
                audit.emit("discovery_failed", error=str(error))
            else:
                port_inventory = sampled.result.port_inventory
                sample_completed_ms = sampled.completed_ms
                policy_snapshot_error = (
                    "port_policy_blocked:" + " | ".join(
                        sampled.result.policy_errors
                    )
                    if sampled.result.policy_errors
                    else None
                )
                if sampled.result.policy_errors:
                    audit.emit(
                        "port_policy_blocked",
                        errors=list(sampled.result.policy_errors),
                    )
                snapshot_error = policy_snapshot_error
                try:
                    events = reconciler.reconcile(sampled.result.bindings)
                except Exception as error:
                    snapshot_error = f"reconcile_failed:{error}"
                    audit.emit("reconcile_failed", error=str(error))
                else:
                    for event in events:
                        audit.emit(
                            "reconcile",
                            action=event.action,
                            port_id=event.port_id,
                            reason=event.reason,
                            binding=(
                                asdict(event.binding)
                                if event.binding
                                else None
                            ),
                        )
                    try:
                        revalidated = _sample_discovery(
                            resolver,
                            server_ids,
                            allowed_port_ids_by_server,
                        )
                    except Exception as error:
                        snapshot_error = (
                            f"snapshot_revalidation_failed:{error}"
                        )
                        audit.emit(
                            "snapshot_revalidation_failed",
                            error=str(error),
                        )
                    else:
                        port_inventory = revalidated.result.port_inventory
                        sample_completed_ms = revalidated.completed_ms
                        try:
                            _assert_discovery_consistent(
                                sampled.result,
                                revalidated.result,
                            )
                        except AgentError as error:
                            snapshot_error = (
                                f"snapshot_revalidation_changed:{error}"
                            )
                            audit.emit(
                                "snapshot_revalidation_changed",
                                error=str(error),
                            )
                        else:
                            snapshot_error = policy_snapshot_error
            _write_state(
                args.state_file,
                server_ids,
                host,
                reconciler,
                driver,
                endpoint_configs,
                sample_completed_ms=sample_completed_ms,
                port_inventory=port_inventory,
                snapshot_error=snapshot_error,
            )
            cycles += 1
            if args.max_cycles and cycles >= args.max_cycles:
                break
            stopping.wait(args.interval)
    finally:
        close_events = reconciler.close()
        shutdown_cleanup_failed = any(
            event.action == "error" for event in close_events
        )
        for event in close_events:
            audit.emit(
                "reconcile",
                action=event.action,
                port_id=event.port_id,
                reason=event.reason,
                binding=asdict(event.binding) if event.binding else None,
            )
        _write_state(
            args.state_file,
            server_ids,
            host,
            reconciler,
            driver,
            endpoint_configs,
            sample_completed_ms=sample_completed_ms,
            port_inventory=port_inventory,
            snapshot_error=snapshot_error,
        )
        audit.emit(
            "agent_stopped",
            server_ids=server_ids,
            endpoint_config=[
                _endpoint_config_state(config) for config in endpoint_configs
            ],
            dns_capabilities={
                config.server_id: _dns_capability(config)
                for config in endpoint_configs
            },
            grpc_capability=GRPC_CAPABILITY,
            local_host=host,
            cleanup_succeeded=not shutdown_cleanup_failed,
        )
    return 1 if shutdown_cleanup_failed else 0


def _server_ids(values: Sequence[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        if not isinstance(value, str):
            raise AgentError("server ID must be a string")
        server_id = value.strip()
        if not server_id:
            raise AgentError("server ID must not be empty")
        if server_id not in seen:
            seen.add(server_id)
            result.append(server_id)
    if not result:
        raise AgentError("at least one server ID is required")
    return result


def _configured_server_ids(args: argparse.Namespace) -> list[str]:
    values = list(getattr(args, "server_id", None) or [])
    path = getattr(args, "server_id_file", None)
    if path is not None:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except FileNotFoundError as error:
            raise AgentError(f"server ID file does not exist: {path}") from error
        values.extend(
            line.strip()
            for line in lines
            if line.strip() and not line.lstrip().startswith("#")
        )
    return _server_ids(values)


@dataclass(frozen=True)
class _ReconcileWaitMatch:
    byte_start: int
    byte_end: int
    binding: dict[str, Any]


def _read_audit_after_offset(
    path: Path,
    after_offset: int,
    audit_device: int,
    audit_inode: int,
) -> list[tuple[dict[str, Any], int, int]]:
    with path.open("rb") as stream:
        identity = os.fstat(stream.fileno())
        if (identity.st_dev, identity.st_ino) != (
            audit_device,
            audit_inode,
        ):
            raise AgentError(
                "audit log identity changed: "
                f"{identity.st_dev}:{identity.st_ino}!="
                f"{audit_device}:{audit_inode}"
            )
        if identity.st_size < after_offset:
            raise AgentError(
                "audit log truncated below after-offset: "
                f"{identity.st_size}:{after_offset}"
            )
        stream.seek(after_offset)
        data = stream.read()

    records: list[tuple[dict[str, Any], int, int]] = []
    cursor = after_offset
    for line in data.splitlines(keepends=True):
        byte_start = cursor
        cursor += len(line)
        if not line.endswith((b"\n", b"\r")):
            break
        payload = line.rstrip(b"\r\n")
        if not payload.strip():
            continue
        try:
            value = json.loads(payload)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise AgentError(
                f"audit log contains invalid JSON after offset {byte_start}"
            ) from error
        if not isinstance(value, dict):
            raise AgentError("audit log record must be an object")
        records.append((value, byte_start, cursor))
    return records


def _reconcile_binding(
    value: Any,
    server_id: str,
    port_id: str,
    expected_host: str,
) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    interface = value.get("interface")
    ifindex = value.get("ifindex")
    host = value.get("host")
    if (
        value.get("server_id") != server_id
        or value.get("port_id") != port_id
        or not isinstance(host, str)
        or not _short_host(host)
        or _short_host(host) != expected_host
        or not isinstance(interface, str)
        or not interface.strip()
        or isinstance(ifindex, bool)
        or not isinstance(ifindex, int)
        or ifindex <= 0
    ):
        return None
    return {
        "server_id": server_id,
        "port_id": port_id,
        "host": host,
        "interface": interface,
        "ifindex": ifindex,
    }


def _find_reconcile_match(
    records: Sequence[tuple[dict[str, Any], int, int]],
    *,
    server_id: str,
    port_id: str,
    action: str,
    reason: str,
    expected_host: str,
) -> _ReconcileWaitMatch | None:
    for record, byte_start, byte_end in records:
        if (
            record.get("event") != "reconcile"
            or record.get("action") != action
            or record.get("port_id") != port_id
            or record.get("reason") != reason
        ):
            continue
        matched_binding = _reconcile_binding(
            record.get("binding"),
            server_id,
            port_id,
            expected_host,
        )
        if matched_binding is not None:
            return _ReconcileWaitMatch(
                byte_start,
                byte_end,
                matched_binding,
            )
    return None


def _wait_reconcile(args: argparse.Namespace) -> int:
    expected_host = _short_host(args.expected_host)
    if not expected_host:
        raise AgentError("expected-host must not be empty")
    deadline = time.monotonic() + args.timeout
    while True:
        records = _read_audit_after_offset(
            args.audit_log,
            args.after_offset,
            args.audit_device,
            args.audit_inode,
        )
        matched = _find_reconcile_match(
            records,
            server_id=args.server_id,
            port_id=args.port_id,
            action=args.action,
            reason=args.reason,
            expected_host=expected_host,
        )
        if matched is not None:
            print(
                json.dumps(
                    {
                        "ready": True,
                        "matched_byte_start": matched.byte_start,
                        "matched_byte_end": matched.byte_end,
                        "binding": matched.binding,
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                ),
                flush=True,
            )
            return 0
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print(
                "openstack_dataplane_agent: wait-reconcile timeout: "
                "audit_has_no_matching_reconcile",
                file=sys.stderr,
            )
            return 1
        time.sleep(min(args.interval, remaining))


def _health(args: argparse.Namespace) -> int:
    if args.max_age_seconds <= 0:
        raise AgentError("max age seconds must be positive")
    try:
        state = json.loads(args.state_file.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise AgentError(f"state file does not exist: {args.state_file}") from error
    if not isinstance(state, dict):
        raise AgentError("agent state must be a JSON object")
    _reject_legacy_grpc_port_fields(state, "agent state")
    if state.get("schema_version") != AGENT_STATE_SCHEMA_VERSION:
        raise AgentError(
            f"agent state schema_version must be "
            f"{AGENT_STATE_SCHEMA_VERSION}"
        )
    endpoint_configs = _parse_endpoint_records(
        state.get("endpoint_config"), "agent state endpoint_config"
    )
    endpoint_configs = _require_host_endpoint_roles(
        endpoint_configs, "agent state endpoint_config"
    )
    endpoint_by_server = {
        config.server_id: config for config in endpoint_configs
    }
    state_server_ids = state.get("server_ids")
    if not isinstance(state_server_ids, list):
        raise AgentError("agent state has no server_ids array")
    configured_server_ids = _server_ids(state_server_ids)
    if len(configured_server_ids) != len(state_server_ids):
        raise AgentError("agent state server_ids must be unique")
    if set(configured_server_ids) != set(endpoint_by_server):
        raise AgentError("agent state endpoint_config does not match server_ids")
    expected_dns_capabilities = {
        config.server_id: _dns_capability(config)
        for config in endpoint_configs
    }
    if state.get("dns_capabilities") != expected_dns_capabilities:
        raise AgentError(
            "agent state dns_capabilities do not match endpoint_config"
        )
    if state.get("grpc_capability") != GRPC_CAPABILITY:
        raise AgentError(
            f"agent state grpc_capability must be {GRPC_CAPABILITY}"
        )
    updated_ms = state.get("updated_ms")
    if not isinstance(updated_ms, int) or isinstance(updated_ms, bool):
        raise AgentError("agent state has no integer updated_ms")
    now_ms = int(time.time() * 1000)
    tolerance_ms = int(args.max_age_seconds * 1000)
    age_ms = max(0, now_ms - updated_ms)
    future_ms = max(0, updated_ms - now_ms)
    health = state.get("health")
    if not isinstance(health, dict):
        raise AgentError("agent state has no health object")
    snapshot_consistency = state.get("snapshot_consistency")
    snapshot_consistent = bool(
        isinstance(snapshot_consistency, dict)
        and snapshot_consistency.get("status") == "consistent"
        and snapshot_consistency.get("error") is None
    )
    expected_roles = {
        config.server_id: config.accel_role for config in endpoint_configs
    }
    expected_observe_ports = {
        config.server_id: config.grpc_observe_port
        for config in endpoint_configs
    }
    expected_guest_listen_ports = {
        config.server_id: config.guest_grpc_listen_port
        for config in endpoint_configs
    }
    if health.get("accel_roles") != expected_roles:
        raise AgentError("agent health accel_roles do not match endpoint_config")
    if health.get("grpc_observe_ports") != expected_observe_ports:
        raise AgentError(
            "agent health grpc_observe_ports do not match endpoint_config"
        )
    if (
        health.get("guest_grpc_listen_ports")
        != expected_guest_listen_ports
    ):
        raise AgentError(
            "agent health guest_grpc_listen_ports do not match endpoint_config"
        )
    if health.get("dns_capabilities") != expected_dns_capabilities:
        raise AgentError(
            "agent health dns_capabilities do not match endpoint_config"
        )
    if health.get("grpc_capability") != GRPC_CAPABILITY:
        raise AgentError(
            f"agent health grpc_capability must be {GRPC_CAPABILITY}"
        )
    has_server_filter = bool(
        getattr(args, "server_id", None) or getattr(args, "server_id_file", None)
    )
    requested_servers = (
        _configured_server_ids(args)
        if has_server_filter
        else configured_server_ids
    )
    port_health = state.get("port_health")
    if not isinstance(port_health, list):
        raise AgentError("agent state has no port_health array")
    healthy_servers: set[str] = set()
    for index, item in enumerate(port_health):
        if not isinstance(item, dict):
            raise AgentError(f"agent port_health[{index}] must be an object")
        binding_value = item.get("binding")
        if binding_value is None:
            continue
        if not isinstance(binding_value, dict):
            raise AgentError(
                f"agent port_health[{index}] binding must be an object"
            )
        server_id = binding_value.get("server_id")
        endpoint = endpoint_by_server.get(server_id)
        if endpoint is None:
            raise AgentError(
                f"agent port_health[{index}] references unconfigured server"
            )
        port_id = binding_value.get("port_id")
        if (
            item.get("port_id") != port_id
            or port_id not in endpoint.port_ids
        ):
            raise AgentError(
                f"agent port_health[{index}] references an undeclared port"
            )
        if (
            item.get("accel_role") != endpoint.accel_role
            or binding_value.get("accel_role") != endpoint.accel_role
        ):
            raise AgentError(
                f"agent port_health[{index}] accel_role does not match "
                "endpoint_config"
            )
        if (
            item.get("grpc_observe_port") != endpoint.grpc_observe_port
            or binding_value.get("grpc_observe_port")
            != endpoint.grpc_observe_port
        ):
            raise AgentError(
                f"agent port_health[{index}] grpc_observe_port does not match "
                "endpoint_config"
            )
        if (
            item.get("guest_grpc_listen_port")
            != endpoint.guest_grpc_listen_port
            or binding_value.get("guest_grpc_listen_port")
            != endpoint.guest_grpc_listen_port
        ):
            raise AgentError(
                f"agent port_health[{index}] guest_grpc_listen_port "
                "does not match "
                "endpoint_config"
            )
        if (
            item.get("grpc_capability") != GRPC_CAPABILITY
            or binding_value.get("grpc_capability") != GRPC_CAPABILITY
        ):
            raise AgentError(
                f"agent port_health[{index}] has invalid grpc_capability"
            )
        expected_dns_capability = _dns_capability(endpoint)
        if (
            item.get("dns_capability") != expected_dns_capability
            or binding_value.get("dns_capability")
            != expected_dns_capability
        ):
            raise AgentError(
                f"agent port_health[{index}] dns_capability does not match "
                "endpoint_config"
            )
        if item.get("state") == "healthy":
            healthy_servers.add(server_id)
    stale = age_ms > tolerance_ms
    future_timestamp = future_ms > tolerance_ms
    missing_servers = [
        server_id for server_id in requested_servers if server_id not in healthy_servers
    ]
    ready = (
        not stale
        and not future_timestamp
        and snapshot_consistent
        and health.get("status") == "healthy"
        and not missing_servers
    )
    print(
        json.dumps(
            {
                "ready": ready,
                "age_ms": age_ms,
                "future_ms": future_ms,
                "stale": stale,
                "future_timestamp": future_timestamp,
                "missing_server_ids": missing_servers,
                "endpoint_config": [
                    _endpoint_config_state(config)
                    for config in endpoint_configs
                ],
                "dns_capabilities": expected_dns_capabilities,
                "grpc_capability": GRPC_CAPABILITY,
                "health": health,
                "snapshot_consistency": snapshot_consistency,
            },
            sort_keys=True,
        )
    )
    return 0 if ready else 2


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.command == "discover":
            return _discover(args)
        if args.command == "health":
            return _health(args)
        if args.command == "wait-reconcile":
            if args.after_offset < 0:
                raise AgentError("after-offset must be non-negative")
            if args.audit_device < 0 or args.audit_inode < 0:
                raise AgentError(
                    "audit-device and audit-inode must be non-negative"
                )
            if args.timeout <= 0:
                raise AgentError("timeout must be positive")
            if args.interval <= 0:
                raise AgentError("interval must be positive")
            expected_reason = {
                "detach": "binding_left_host",
                "attach": "binding_local",
            }[args.action]
            if args.reason != expected_reason:
                raise AgentError(
                    f"{args.action} requires reason {expected_reason}"
                )
            return _wait_reconcile(args)
        return _watch(args)
    except (AgentError, json.JSONDecodeError, OSError) as error:
        print(f"openstack_dataplane_agent: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
