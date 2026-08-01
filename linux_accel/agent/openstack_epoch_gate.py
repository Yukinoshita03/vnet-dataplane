#!/usr/bin/env python3
"""Validate agent snapshots before an OpenStack cache-policy epoch is published."""

from __future__ import annotations

import ipaddress
import uuid

from dataclasses import asdict, dataclass
from enum import Enum
from pathlib import PurePosixPath
from typing import Any, Iterable, Sequence


class GateError(RuntimeError):
    pass


class GateAction(str, Enum):
    PUBLISH = "publish"
    FREEZE = "freeze"
    BYPASS = "bypass"


_PORT_STATES = {"healthy", "transition", "degraded", "absent", "stopped"}
_COMPUTE_ROLES = {"client", "observer"}
_GRPC_CAPABILITY = "tc_observability"
_GUEST_PIN_ROOT = PurePosixPath("/sys/fs/bpf/vnet-dataplane-guest")
_DNS_CAPABILITIES = {
    "client": "xdp_client_cache",
    "observer": "tc_observability",
}
DEFAULT_MAX_SNAPSHOT_SKEW_MS = 5_000


@dataclass(frozen=True)
class RequiredEndpoint:
    server_id: str
    port_id: str
    compute_role: str = "client"
    guest_cache_role: str | None = None
    grpc_backend_server_id: str | None = None


@dataclass(frozen=True)
class EndpointConfigObservation:
    source: str
    server_id: str
    port_ids: tuple[str, ...]
    accel_role: str
    grpc_observe_port: int
    guest_grpc_listen_port: int
    trusted_dns: tuple[str, ...]


@dataclass(frozen=True)
class PortObservation:
    source: str
    local_host: str
    server_id: str
    port_id: str
    state: str
    reason: str
    host: str
    interface: str
    ifindex: int
    accel_role: str
    grpc_observe_port: int
    guest_grpc_listen_port: int
    dns_capability: str
    grpc_capability: str


@dataclass(frozen=True)
class InventoryObservation:
    source: str
    server_id: str
    port_id: str
    status: str
    binding_host: str
    vif_type: str
    revision_number: int


@dataclass(frozen=True)
class AgentSnapshot:
    source: str
    local_host: str
    updated_ms: int
    observations: tuple[PortObservation, ...]
    port_inventory: tuple[InventoryObservation, ...]
    endpoint_configs: tuple[EndpointConfigObservation, ...]


@dataclass(frozen=True)
class GuestEndpointSnapshot:
    source: str
    server_id: str
    port_id: str
    accel_role: str
    updated_ms: int
    state: str
    reason: str
    epoch: int
    mode: int
    flags: int
    maps: int
    interface_ipv4: tuple[str, ...]
    grpc_listen_host: str
    grpc_listen_port: int
    grpc_backend_host: str
    grpc_backend_port: int


@dataclass(frozen=True)
class GateDecision:
    action: GateAction
    reason: str
    required_endpoints: tuple[RequiredEndpoint, ...]
    healthy_observations: tuple[PortObservation, ...] = ()
    healthy_guest_observations: tuple[GuestEndpointSnapshot, ...] = ()

    @property
    def force_bypass(self) -> bool:
        return self.action is not GateAction.PUBLISH

    def asdict(self) -> dict[str, Any]:
        return {
            "action": self.action.value,
            "force_bypass": self.force_bypass,
            "reason": self.reason,
            "required_endpoints": [asdict(item) for item in self.required_endpoints],
            "healthy_observations": [
                asdict(item) for item in self.healthy_observations
            ],
            "healthy_guest_observations": [
                asdict(item) for item in self.healthy_guest_observations
            ],
        }


def parse_agent_snapshot(value: Any, source: str) -> AgentSnapshot:
    if not isinstance(value, dict):
        raise GateError(f"agent state from {source} must be a JSON object")
    _reject_legacy_grpc_port_fields(value, source)
    if value.get("schema_version") != 3:
        raise GateError(f"agent state from {source} has unsupported schema version")
    local_host = _required_string(value.get("local_host"), "local_host", source)
    updated_ms = value.get("updated_ms")
    if (
        isinstance(updated_ms, bool)
        or not isinstance(updated_ms, int)
        or updated_ms < 0
    ):
        raise GateError(f"agent state from {source} has invalid updated_ms")
    port_health = value.get("port_health")
    if not isinstance(port_health, list):
        raise GateError(f"agent state from {source} has no port_health list")
    port_inventory = value.get("port_inventory")
    if not isinstance(port_inventory, list):
        raise GateError(f"agent state from {source} has no port_inventory list")
    if value.get("grpc_capability") != _GRPC_CAPABILITY:
        raise GateError(
            f"agent state from {source} has invalid grpc_capability"
        )
    endpoint_config = value.get("endpoint_config")
    if not isinstance(endpoint_config, list) or not endpoint_config:
        raise GateError(f"agent state from {source} has no endpoint_config list")

    endpoint_configs: list[EndpointConfigObservation] = []
    seen_endpoint_servers: set[str] = set()
    for item in endpoint_config:
        if not isinstance(item, dict):
            raise GateError(
                f"agent state from {source} has invalid endpoint config item"
            )
        server_id = _required_string(
            item.get("server_id"), "endpoint_config.server_id", source
        )
        if server_id in seen_endpoint_servers:
            raise GateError(
                f"agent state from {source} repeats endpoint server {server_id}"
            )
        seen_endpoint_servers.add(server_id)
        port_ids_value = item.get("port_ids")
        if not isinstance(port_ids_value, list) or not port_ids_value:
            raise GateError(
                f"agent state from {source} has invalid port_ids for "
                f"{server_id}"
            )
        port_ids: list[str] = []
        seen_port_ids: set[str] = set()
        for raw_port_id in port_ids_value:
            if not isinstance(raw_port_id, str) or raw_port_id != raw_port_id.strip():
                raise GateError(
                    f"agent state from {source} has invalid port_ids for "
                    f"{server_id}"
                )
            try:
                parsed_port_id = uuid.UUID(raw_port_id)
            except (ValueError, AttributeError) as error:
                raise GateError(
                    f"agent state from {source} has invalid port_ids for "
                    f"{server_id}"
                ) from error
            if str(parsed_port_id) != raw_port_id or raw_port_id in seen_port_ids:
                raise GateError(
                    f"agent state from {source} has invalid port_ids for "
                    f"{server_id}"
                )
            seen_port_ids.add(raw_port_id)
            port_ids.append(raw_port_id)
        accel_role = item.get("accel_role")
        if accel_role not in _COMPUTE_ROLES:
            raise GateError(
                f"agent state from {source} has invalid accel_role for "
                f"{server_id}"
            )
        grpc_ports: dict[str, int] = {}
        for field in ("grpc_observe_port", "guest_grpc_listen_port"):
            port = item.get(field)
            if (
                isinstance(port, bool)
                or not isinstance(port, int)
                or not 1 <= port <= 65535
            ):
                raise GateError(
                    f"agent state from {source} has invalid {field} for "
                    f"{server_id}"
                )
            grpc_ports[field] = port
        trusted_value = item.get("trusted_dns", [])
        if (
            not isinstance(trusted_value, list)
            or not all(
                isinstance(address, str) and address.strip()
                for address in trusted_value
            )
            or len(trusted_value) != len(set(trusted_value))
            or (accel_role == "client" and not trusted_value)
            or (accel_role == "observer" and trusted_value)
        ):
            raise GateError(
                f"agent state from {source} has invalid trusted_dns for "
                f"{server_id}"
            )
        endpoint_configs.append(
            EndpointConfigObservation(
                source,
                server_id,
                tuple(port_ids),
                accel_role,
                grpc_ports["grpc_observe_port"],
                grpc_ports["guest_grpc_listen_port"],
                tuple(trusted_value),
            )
        )

    inventory: list[InventoryObservation] = []
    seen_inventory_ports: set[str] = set()
    for item in port_inventory:
        if not isinstance(item, dict):
            raise GateError(
                f"agent state from {source} has invalid port inventory item"
            )
        port_id = _required_string(
            item.get("port_id"), "port_inventory.port_id", source
        )
        if port_id in seen_inventory_ports:
            raise GateError(
                f"agent state from {source} repeats inventory port {port_id}"
            )
        seen_inventory_ports.add(port_id)
        binding_host = item.get("binding_host")
        if not isinstance(binding_host, str):
            raise GateError(
                f"agent state from {source} has invalid binding_host for {port_id}"
            )
        revision_number = item.get("revision_number")
        if (
            isinstance(revision_number, bool)
            or not isinstance(revision_number, int)
            or revision_number < 0
        ):
            raise GateError(
                f"agent state from {source} has invalid revision_number for {port_id}"
            )
        inventory.append(
            InventoryObservation(
                source=source,
                server_id=_required_string(
                    item.get("server_id"), "port_inventory.server_id", source
                ),
                port_id=port_id,
                status=_required_string(
                    item.get("status"), "port_inventory.status", source
                ).upper(),
                binding_host=binding_host.strip(),
                vif_type=_required_string(
                    item.get("vif_type"), "port_inventory.vif_type", source
                ).lower(),
                revision_number=revision_number,
            )
        )

    observations: list[PortObservation] = []
    seen_ports: set[str] = set()
    for item in port_health:
        if not isinstance(item, dict):
            raise GateError(f"agent state from {source} has invalid port health item")
        state = item.get("state")
        if state not in _PORT_STATES:
            raise GateError(f"agent state from {source} has invalid port state")
        port_id = _required_string(item.get("port_id"), "port_id", source)
        if port_id in seen_ports:
            raise GateError(f"agent state from {source} repeats port {port_id}")
        seen_ports.add(port_id)
        reason = _required_string(item.get("reason"), "reason", source)
        binding = item.get("binding")
        if not isinstance(binding, dict):
            raise GateError(f"agent state from {source} has no binding for {port_id}")
        binding_port = _required_string(
            binding.get("port_id"), "binding.port_id", source
        )
        if binding_port != port_id:
            raise GateError(f"agent state from {source} has mismatched binding port")
        ifindex = binding.get("ifindex")
        if (
            isinstance(ifindex, bool)
            or not isinstance(ifindex, int)
            or ifindex <= 0
        ):
            raise GateError(
                f"agent state from {source} has invalid ifindex for {port_id}"
            )
        server_id = _required_string(
            binding.get("server_id"),
            "binding.server_id",
            source,
        )
        endpoint = next(
            (
                candidate
                for candidate in endpoint_configs
                if candidate.server_id == server_id
            ),
            None,
        )
        if endpoint is None:
            raise GateError(
                f"agent state from {source} binding uses unconfigured "
                f"server {server_id}"
            )
        expected_dns_capability = _DNS_CAPABILITIES[endpoint.accel_role]
        if (
            item.get("accel_role") != endpoint.accel_role
            or binding.get("accel_role") != endpoint.accel_role
            or item.get("grpc_observe_port") != endpoint.grpc_observe_port
            or binding.get("grpc_observe_port") != endpoint.grpc_observe_port
            or item.get("guest_grpc_listen_port")
            != endpoint.guest_grpc_listen_port
            or binding.get("guest_grpc_listen_port")
            != endpoint.guest_grpc_listen_port
            or item.get("dns_capability") != expected_dns_capability
            or binding.get("dns_capability") != expected_dns_capability
            or item.get("grpc_capability") != _GRPC_CAPABILITY
            or binding.get("grpc_capability") != _GRPC_CAPABILITY
        ):
            raise GateError(
                f"agent state from {source} has inconsistent endpoint "
                f"capabilities for {port_id}"
            )
        observations.append(
            PortObservation(
                source=source,
                local_host=local_host,
                server_id=server_id,
                port_id=port_id,
                state=state,
                reason=reason,
                host=_required_string(binding.get("host"), "binding.host", source),
                interface=_required_string(
                    binding.get("interface"), "binding.interface", source
                ),
                ifindex=ifindex,
                accel_role=endpoint.accel_role,
                grpc_observe_port=endpoint.grpc_observe_port,
                guest_grpc_listen_port=endpoint.guest_grpc_listen_port,
                dns_capability=expected_dns_capability,
                grpc_capability=_GRPC_CAPABILITY,
            )
        )
    return AgentSnapshot(
        source=source,
        local_host=local_host,
        updated_ms=updated_ms,
        observations=tuple(observations),
        port_inventory=tuple(inventory),
        endpoint_configs=tuple(endpoint_configs),
    )


def parse_guest_endpoint_snapshot(
    value: Any, source: str
) -> GuestEndpointSnapshot:
    if not isinstance(value, dict):
        raise GateError(f"guest state from {source} must be a JSON object")
    if (
        value.get("schema_version") != 1
        or value.get("source_kind") != "guest_endpoint"
    ):
        raise GateError(f"guest state from {source} has unsupported schema")
    server_id = _required_string(value.get("server_id"), "server_id", source)
    port_id = _required_string(value.get("port_id"), "port_id", source)
    accel_role = value.get("accel_role")
    if accel_role not in {"client", "server"}:
        raise GateError(f"guest state from {source} has invalid accel_role")
    updated_ms = value.get("updated_ms")
    if (
        isinstance(updated_ms, bool)
        or not isinstance(updated_ms, int)
        or updated_ms < 0
    ):
        raise GateError(f"guest state from {source} has invalid updated_ms")
    state = _required_string(value.get("state"), "state", source)
    reason = _required_string(value.get("reason"), "reason", source)
    if value.get("grpc_capability") != "userspace_fast_cache":
        raise GateError(
            f"guest state from {source} has invalid grpc_capability"
        )
    if value.get("quiesced") is not False:
        raise GateError(f"guest state from {source} is quiesced")
    interface_ipv4 = _parse_guest_ipv4_addresses(
        value.get("interface_ipv4"), source
    )

    grpc = value.get("grpc")
    if (
        not isinstance(grpc, dict)
        or grpc.get("listener_owned") is not True
        or grpc.get("backend_ready") is not True
    ):
        raise GateError(
            f"guest state from {source} has no ready owned gRPC endpoint"
        )
    grpc_listen_host, grpc_listen_port = _parse_ipv4_endpoint(
        grpc.get("listen"), "grpc.listen", source
    )
    grpc_backend_host, grpc_backend_port = _parse_ipv4_endpoint(
        grpc.get("backend"), "grpc.backend", source
    )
    listen_address = ipaddress.IPv4Address(grpc_listen_host)
    if (
        not listen_address.is_unspecified
        and not listen_address.is_loopback
        and grpc_listen_host not in interface_ipv4
    ):
        raise GateError(
            f"guest state from {source} has non-local grpc.listen"
        )
    if ipaddress.IPv4Address(grpc_backend_host).is_unspecified:
        raise GateError(
            f"guest state from {source} has invalid grpc.backend"
        )
    processes = value.get("processes")
    required_processes = ["grpc_fast_cache"]
    if accel_role == "server":
        required_processes.append("dns_monitor")
    if not isinstance(processes, dict):
        raise GateError(f"guest state from {source} has invalid processes")
    for process_name in required_processes:
        process = processes.get(process_name)
        if (
            not isinstance(process, dict)
            or isinstance(process.get("pid"), bool)
            or not isinstance(process.get("pid"), int)
            or process["pid"] <= 0
            or process.get("alive") is not True
        ):
            raise GateError(
                f"guest state from {source} has unhealthy {process_name}"
            )

    expected_maps = 2 if accel_role == "server" else 1
    runtime = value.get("runtime_readback")
    if not isinstance(runtime, dict):
        raise GateError(f"guest state from {source} has no runtime readback")
    epoch = runtime.get("epoch")
    mode = runtime.get("mode")
    flags = runtime.get("flags")
    maps = runtime.get("maps")
    if (
        runtime.get("schema_version") != 1
        or runtime.get("present") is not True
        or isinstance(maps, bool)
        or maps != expected_maps
        or isinstance(epoch, bool)
        or not isinstance(epoch, int)
        or epoch <= 0
        or isinstance(mode, bool)
        or not isinstance(mode, int)
        or mode not in {1, 2, 3, 4}
        or flags != 1
    ):
        raise GateError(
            f"guest state from {source} has invalid runtime readback"
        )
    expected_pins = _expected_guest_pin_paths(
        value.get("map_paths"), accel_role, port_id, source
    )
    pins = value.get("pins_present")
    if not isinstance(pins, dict) or set(pins) != expected_pins:
        raise GateError(f"guest state from {source} has invalid pins")
    if not all(item is True for item in pins.values()):
        raise GateError(f"guest state from {source} has missing pins")
    if accel_role == "server":
        recorded_program = value.get("dns_xdp_prog_id")
        current_program = value.get("current_dns_xdp_prog_id")
        if (
            isinstance(recorded_program, bool)
            or not isinstance(recorded_program, int)
            or recorded_program <= 0
            or current_program != recorded_program
        ):
            raise GateError(
                f"guest state from {source} has invalid DNS XDP ownership"
            )
    if state != "healthy":
        raise GateError(
            f"guest state from {source} is not healthy: {state}:{reason}"
        )
    return GuestEndpointSnapshot(
        source,
        server_id,
        port_id,
        accel_role,
        updated_ms,
        state,
        reason,
        epoch,
        mode,
        flags,
        maps,
        interface_ipv4,
        grpc_listen_host,
        grpc_listen_port,
        grpc_backend_host,
        grpc_backend_port,
    )


def evaluate_gate(
    snapshots: Sequence[AgentSnapshot],
    required_endpoints: Sequence[RequiredEndpoint],
    now_ms: int,
    max_age_ms: int,
    max_skew_ms: int = DEFAULT_MAX_SNAPSHOT_SKEW_MS,
    guest_snapshots: Sequence[GuestEndpointSnapshot] = (),
) -> GateDecision:
    required = _normalize_required(required_endpoints)
    if not snapshots:
        return GateDecision(GateAction.BYPASS, "no_agent_snapshots", required)
    if max_age_ms <= 0:
        raise GateError("max age must be positive")
    if max_skew_ms <= 0:
        raise GateError("max snapshot skew must be positive")

    source_names: set[str] = set()
    local_hosts: set[str] = set()
    for snapshot in snapshots:
        if snapshot.source in source_names:
            return GateDecision(
                GateAction.BYPASS,
                f"duplicate_snapshot_source:{snapshot.source}",
                required,
            )
        source_names.add(snapshot.source)
        normalized_host = _normalize_host(snapshot.local_host)
        if normalized_host in local_hosts:
            return GateDecision(
                GateAction.BYPASS,
                f"duplicate_snapshot_host:{snapshot.local_host}",
                required,
            )
        local_hosts.add(normalized_host)
        if max(0, now_ms - snapshot.updated_ms) > max_age_ms:
            return GateDecision(
                GateAction.BYPASS,
                f"stale_snapshot:{snapshot.source}",
                required,
            )
        if snapshot.updated_ms - now_ms > max_skew_ms:
            return GateDecision(
                GateAction.BYPASS,
                f"future_snapshot:{snapshot.source}",
                required,
            )

    guest_sources: set[str] = set()
    guest_keys: set[tuple[str, str]] = set()
    for snapshot in guest_snapshots:
        if snapshot.source in guest_sources or snapshot.source in source_names:
            return GateDecision(
                GateAction.BYPASS,
                f"duplicate_snapshot_source:{snapshot.source}",
                required,
            )
        guest_sources.add(snapshot.source)
        key = (snapshot.server_id, snapshot.port_id)
        if key in guest_keys:
            return GateDecision(
                GateAction.BYPASS,
                f"duplicate_guest_endpoint:{snapshot.server_id}:"
                f"{snapshot.port_id}",
                required,
            )
        guest_keys.add(key)
        if max(0, now_ms - snapshot.updated_ms) > max_age_ms:
            return GateDecision(
                GateAction.BYPASS,
                f"stale_guest_snapshot:{snapshot.source}",
                required,
            )
        if snapshot.updated_ms - now_ms > max_skew_ms:
            return GateDecision(
                GateAction.BYPASS,
                f"future_guest_snapshot:{snapshot.source}",
                required,
            )

    observed_times = [
        item.updated_ms for item in (*snapshots, *guest_snapshots)
    ]
    snapshot_skew_ms = max(observed_times) - min(observed_times)
    if snapshot_skew_ms > max_skew_ms:
        return GateDecision(
            GateAction.BYPASS,
            f"snapshot_skew_exceeded:{snapshot_skew_ms}",
            required,
        )

    healthy: list[PortObservation] = []
    healthy_guests: list[GuestEndpointSnapshot] = []
    for endpoint in required:
        matching_guests = [
            item
            for item in guest_snapshots
            if item.server_id == endpoint.server_id
            and item.port_id == endpoint.port_id
        ]
        if endpoint.guest_cache_role is not None:
            if len(matching_guests) != 1:
                return GateDecision(
                    GateAction.BYPASS,
                    f"guest_endpoint_presence_invalid:{endpoint.server_id}:"
                    f"{endpoint.port_id}:{len(matching_guests)}",
                    required,
                )
            guest = matching_guests[0]
            if guest.accel_role != endpoint.guest_cache_role:
                return GateDecision(
                    GateAction.BYPASS,
                    f"guest_role_mismatch:{endpoint.server_id}:"
                    f"{endpoint.port_id}:{guest.accel_role}:"
                    f"{endpoint.guest_cache_role}",
                    required,
                )
            healthy_guests.append(guest)
        elif matching_guests:
            return GateDecision(
                GateAction.BYPASS,
                f"unexpected_guest_endpoint:{endpoint.server_id}:"
                f"{endpoint.port_id}",
                required,
            )

        endpoint_configs: list[EndpointConfigObservation] = []
        for snapshot in snapshots:
            matches = [
                item
                for item in snapshot.endpoint_configs
                if item.server_id == endpoint.server_id
            ]
            if not matches:
                return GateDecision(
                    GateAction.BYPASS,
                    f"missing_endpoint_config:{endpoint.server_id}:"
                    f"{snapshot.source}",
                    required,
                )
            endpoint_configs.append(matches[0])
        config_reference = endpoint_configs[0]
        missing_port_config = next(
            (
                item
                for item in endpoint_configs
                if endpoint.port_id not in item.port_ids
            ),
            None,
        )
        if missing_port_config is not None:
            return GateDecision(
                GateAction.BYPASS,
                f"endpoint_port_not_allowed:{endpoint.server_id}:"
                f"{endpoint.port_id}:{missing_port_config.source}",
                required,
            )
        if config_reference.accel_role != endpoint.compute_role:
            return GateDecision(
                GateAction.BYPASS,
                f"endpoint_role_mismatch:{endpoint.server_id}:"
                f"{config_reference.accel_role}:{endpoint.compute_role}",
                required,
            )
        if (
            matching_guests
            and matching_guests[0].grpc_listen_port
            != config_reference.guest_grpc_listen_port
        ):
            return GateDecision(
                GateAction.BYPASS,
                f"guest_grpc_listen_port_mismatch:{endpoint.server_id}:"
                f"{endpoint.port_id}:"
                f"{matching_guests[0].grpc_listen_port}:"
                f"{config_reference.guest_grpc_listen_port}",
                required,
            )
        for candidate in endpoint_configs[1:]:
            if (
                candidate.port_ids,
                candidate.accel_role,
                candidate.grpc_observe_port,
                candidate.guest_grpc_listen_port,
                candidate.trusted_dns,
            ) != (
                config_reference.port_ids,
                config_reference.accel_role,
                config_reference.grpc_observe_port,
                config_reference.guest_grpc_listen_port,
                config_reference.trusted_dns,
            ):
                return GateDecision(
                    GateAction.BYPASS,
                    f"endpoint_config_mismatch:{endpoint.server_id}:"
                    f"{config_reference.source}:{candidate.source}",
                    required,
                )

        endpoint_inventory: list[InventoryObservation] = []
        for snapshot in snapshots:
            matches = [
                item
                for item in snapshot.port_inventory
                if item.server_id == endpoint.server_id
                and item.port_id == endpoint.port_id
            ]
            if not matches:
                return GateDecision(
                    GateAction.BYPASS,
                    f"missing_endpoint_inventory:{endpoint.server_id}:"
                    f"{endpoint.port_id}:{snapshot.source}",
                    required,
                )
            endpoint_inventory.append(matches[0])
        reference = endpoint_inventory[0]

        observations = [
            item
            for snapshot in snapshots
            for item in snapshot.observations
            if item.server_id == endpoint.server_id and item.port_id == endpoint.port_id
        ]
        degraded = next(
            (item for item in observations if item.state in {"degraded", "stopped"}),
            None,
        )
        if degraded is not None:
            return GateDecision(
                GateAction.BYPASS,
                f"endpoint_unhealthy:{endpoint.server_id}:{endpoint.port_id}:"
                f"{degraded.source}:{degraded.state}",
                required,
            )
        transition = next(
            (item for item in observations if item.state == "transition"),
            None,
        )
        if transition is not None:
            return GateDecision(
                GateAction.FREEZE,
                f"migration_transition:{endpoint.server_id}:{endpoint.port_id}:"
                f"{transition.source}",
                required,
            )

        for candidate in endpoint_inventory[1:]:
            mismatch = _inventory_mismatch(reference, candidate)
            if mismatch is not None:
                return GateDecision(
                    GateAction.BYPASS,
                    f"inventory_mismatch:{endpoint.server_id}:{endpoint.port_id}:"
                    f"{mismatch}:{reference.source}:{candidate.source}",
                    required,
                )
        if reference.status != "ACTIVE":
            return GateDecision(
                GateAction.BYPASS,
                f"endpoint_inventory_not_active:{endpoint.server_id}:"
                f"{endpoint.port_id}:{reference.status}",
                required,
            )
        if reference.vif_type != "ovs":
            return GateDecision(
                GateAction.BYPASS,
                f"endpoint_inventory_not_ovs:{endpoint.server_id}:"
                f"{endpoint.port_id}:{reference.vif_type}",
                required,
            )
        endpoint_healthy = [
            item for item in observations if item.state == "healthy"
        ]
        if not endpoint_healthy:
            return GateDecision(
                GateAction.BYPASS,
                f"no_healthy_binding:{endpoint.server_id}:{endpoint.port_id}",
                required,
            )
        if len(endpoint_healthy) != 1:
            return GateDecision(
                GateAction.BYPASS,
                f"ambiguous_healthy_binding:{endpoint.server_id}:{endpoint.port_id}",
                required,
            )
        healthy_observation = endpoint_healthy[0]
        if healthy_observation.accel_role != endpoint.compute_role:
            return GateDecision(
                GateAction.BYPASS,
                f"healthy_role_mismatch:{endpoint.server_id}:"
                f"{endpoint.port_id}:{healthy_observation.accel_role}",
                required,
            )
        if not _hosts_equal(
            healthy_observation.local_host, reference.binding_host
        ):
            return GateDecision(
                GateAction.BYPASS,
                f"healthy_local_host_mismatch:{endpoint.server_id}:"
                f"{endpoint.port_id}:{healthy_observation.source}",
                required,
            )
        if not _hosts_equal(healthy_observation.host, reference.binding_host):
            return GateDecision(
                GateAction.BYPASS,
                f"healthy_binding_mismatch:{endpoint.server_id}:"
                f"{endpoint.port_id}:{healthy_observation.source}",
                required,
            )
        healthy.append(healthy_observation)
    guest_by_server = {
        item.server_id: item for item in healthy_guests
    }
    for endpoint in required:
        if endpoint.grpc_backend_server_id is None:
            continue
        client = guest_by_server.get(endpoint.server_id)
        backend = guest_by_server.get(endpoint.grpc_backend_server_id)
        if client is None or backend is None or backend.accel_role != "server":
            return GateDecision(
                GateAction.BYPASS,
                f"guest_grpc_backend_missing:{endpoint.server_id}:"
                f"{endpoint.grpc_backend_server_id}",
                required,
            )
        if (
            client.grpc_backend_host not in backend.interface_ipv4
            or client.grpc_backend_port != backend.grpc_listen_port
        ):
            return GateDecision(
                GateAction.BYPASS,
                f"guest_grpc_backend_mismatch:{endpoint.server_id}:"
                f"{client.grpc_backend_host}:{client.grpc_backend_port}:"
                f"{endpoint.grpc_backend_server_id}:"
                f"{','.join(backend.interface_ipv4)}:"
                f"{backend.grpc_listen_port}",
                required,
            )

    return GateDecision(
        GateAction.PUBLISH,
        "all_required_endpoints_healthy",
        required,
        tuple(healthy),
        tuple(healthy_guests),
    )


def bypass_decision(
    required_endpoints: Sequence[RequiredEndpoint], reason: str
) -> GateDecision:
    return GateDecision(
        GateAction.BYPASS,
        reason,
        _normalize_required(required_endpoints),
    )


def _inventory_mismatch(
    reference: InventoryObservation,
    candidate: InventoryObservation,
) -> str | None:
    fields = (
        ("revision_number", reference.revision_number, candidate.revision_number),
        (
            "binding_host",
            _normalize_host(reference.binding_host),
            _normalize_host(candidate.binding_host),
        ),
        ("status", reference.status, candidate.status),
        ("vif_type", reference.vif_type, candidate.vif_type),
    )
    return next(
        (name for name, expected, actual in fields if expected != actual),
        None,
    )


def _normalize_host(value: str) -> str:
    return value.strip().lower().split(".", 1)[0]


def _hosts_equal(first: str, second: str) -> bool:
    return bool(_normalize_host(first)) and _normalize_host(first) == _normalize_host(
        second
    )


def _normalize_required(
    endpoints: Iterable[RequiredEndpoint],
) -> tuple[RequiredEndpoint, ...]:
    result: list[RequiredEndpoint] = []
    seen: set[tuple[str, str]] = set()
    for endpoint in endpoints:
        server_id = endpoint.server_id.strip()
        port_id = endpoint.port_id.strip()
        if not server_id or not port_id:
            raise GateError("required endpoint server_id and port_id must not be empty")
        if endpoint.compute_role not in _COMPUTE_ROLES:
            raise GateError(
                f"required endpoint has invalid compute_role: "
                f"{endpoint.compute_role}"
            )
        if endpoint.guest_cache_role not in {None, "client", "server"}:
            raise GateError(
                f"required endpoint has invalid guest_cache_role: "
                f"{endpoint.guest_cache_role}"
            )
        backend_server_id = endpoint.grpc_backend_server_id
        if backend_server_id is not None:
            if not isinstance(backend_server_id, str) or not backend_server_id.strip():
                raise GateError(
                    "required endpoint grpc_backend_server_id must be non-empty"
                )
            backend_server_id = backend_server_id.strip()
            if endpoint.guest_cache_role != "client":
                raise GateError(
                    "only a client guest endpoint can declare "
                    "grpc_backend_server_id"
                )
        key = (server_id, port_id)
        if key in seen:
            raise GateError(f"duplicate required endpoint: {server_id}:{port_id}")
        seen.add(key)
        result.append(
            RequiredEndpoint(
                server_id,
                port_id,
                endpoint.compute_role,
                endpoint.guest_cache_role,
                backend_server_id,
            )
        )
    if not result:
        raise GateError("at least one required endpoint is needed")
    server_ids = {item.server_id for item in result}
    for endpoint in result:
        backend_server_id = endpoint.grpc_backend_server_id
        if backend_server_id is None:
            continue
        if backend_server_id == endpoint.server_id:
            raise GateError(
                "grpc_backend_server_id must reference another endpoint"
            )
        if backend_server_id not in server_ids:
            raise GateError(
                f"grpc_backend_server_id is not required: {backend_server_id}"
            )
    return tuple(result)


def _required_string(value: Any, field: str, source: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise GateError(f"agent state from {source} has invalid {field}")
    return value.strip()


def _reject_legacy_grpc_port_fields(value: Any, source: str) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            if key in {"grpc_port", "grpc_ports"}:
                raise GateError(
                    f"agent state from {source} contains legacy {key}"
                )
            _reject_legacy_grpc_port_fields(item, source)
    elif isinstance(value, list):
        for item in value:
            _reject_legacy_grpc_port_fields(item, source)


def _parse_ipv4_endpoint(
    value: Any, field: str, source: str
) -> tuple[str, int]:
    endpoint = _required_string(value, field, source)
    if endpoint.count(":") != 1:
        raise GateError(
            f"guest state from {source} has invalid {field}"
        )
    host, port_text = endpoint.rsplit(":", 1)
    try:
        ipaddress.IPv4Address(host)
        port = int(port_text)
    except (ipaddress.AddressValueError, ValueError) as error:
        raise GateError(
            f"guest state from {source} has invalid {field}"
        ) from error
    if not 1 <= port <= 65535:
        raise GateError(
            f"guest state from {source} has invalid {field}"
        )
    return str(ipaddress.IPv4Address(host)), port


def _parse_guest_ipv4_addresses(
    value: Any, source: str
) -> tuple[str, ...]:
    if not isinstance(value, list) or not value:
        raise GateError(
            f"guest state from {source} has invalid interface_ipv4"
        )
    addresses: set[str] = set()
    for item in value:
        if not isinstance(item, str):
            raise GateError(
                f"guest state from {source} has invalid interface_ipv4"
            )
        try:
            address = ipaddress.IPv4Address(item)
        except ipaddress.AddressValueError as error:
            raise GateError(
                f"guest state from {source} has invalid interface_ipv4"
            ) from error
        if (
            address.is_loopback
            or address.is_link_local
            or address.is_multicast
            or address.is_unspecified
            or str(address) != item
        ):
            raise GateError(
                f"guest state from {source} has invalid interface_ipv4"
            )
        addresses.add(item)
    if len(addresses) != len(value):
        raise GateError(
            f"guest state from {source} has duplicate interface_ipv4"
        )
    return tuple(sorted(addresses))


def _expected_guest_pin_paths(
    value: Any, accel_role: str, port_id: str, source: str
) -> frozenset[str]:
    layout = {
        "grpc_runtime_control": ("grpc", "cache_runtime_control"),
        "dns_runtime_control": ("dns", "cache_runtime_control"),
        "dns_cache_stats": ("dns", "dns_cache_stats"),
        "dns_cache_entries": ("dns", "dns_cache_entries"),
    }
    if not isinstance(value, dict) or set(value) != set(layout):
        raise GateError(f"guest state from {source} has invalid map_paths")

    active_keys = {"grpc_runtime_control"}
    if accel_role == "server":
        active_keys.update(
            {
                "dns_runtime_control",
                "dns_cache_stats",
                "dns_cache_entries",
            }
        )

    expected: set[str] = set()
    port_roots: set[PurePosixPath] = set()
    for key, (directory_name, file_name) in layout.items():
        path_value = value.get(key)
        if key not in active_keys:
            if path_value is not None:
                raise GateError(
                    f"guest state from {source} has invalid map_paths"
                )
            continue
        if (
            not isinstance(path_value, str)
            or not path_value
            or "\x00" in path_value
        ):
            raise GateError(f"guest state from {source} has invalid map_paths")
        path = PurePosixPath(path_value)
        if (
            path.root != "/"
            or str(path) != path_value
            or ".." in path.parts
            or path.name != file_name
            or path.parent.name != directory_name
            or path.parent.parent.name != port_id
        ):
            raise GateError(f"guest state from {source} has invalid map_paths")
        expected.add(path_value)
        port_roots.add(path.parent.parent)

    if (
        len(expected) != len(active_keys)
        or port_roots != {_GUEST_PIN_ROOT / port_id}
    ):
        raise GateError(f"guest state from {source} has invalid map_paths")
    return frozenset(expected)
