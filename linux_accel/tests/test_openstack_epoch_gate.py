import unittest

from agent.openstack_epoch_gate import (
    GateAction,
    GateError,
    RequiredEndpoint,
    evaluate_gate,
    parse_agent_snapshot,
    parse_guest_endpoint_snapshot,
)


SERVER_ID = "server-1"
PORT_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
BACKEND_SERVER_ID = "server-2"
BACKEND_PORT_ID = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
NOW_MS = 1_000_000


def snapshot(
    source,
    host,
    state,
    updated_ms=NOW_MS,
    ifindex=14,
    *,
    binding_host=None,
    observation_host=None,
    revision_number=7,
    status="ACTIVE",
    vif_type="ovs",
    accel_role="client",
    grpc_observe_port=50052,
    guest_grpc_listen_port=50053,
    trusted_dns=None,
    port_ids=None,
    legacy_grpc_port=None,
):
    inventory_host = host if binding_host is None else binding_host
    observed_host = host if observation_host is None else observation_host
    if trusted_dns is None:
        trusted_dns = ["10.0.0.12"] if accel_role == "client" else []
    if port_ids is None:
        port_ids = [PORT_ID]
    dns_capability = (
        "xdp_client_cache"
        if accel_role == "client"
        else "tc_observability"
    )
    port_health = []
    if state is not None:
        port_health.append(
            {
                "port_id": PORT_ID,
                "state": state,
                "reason": "test_state",
                "accel_role": accel_role,
                "grpc_observe_port": grpc_observe_port,
                "guest_grpc_listen_port": guest_grpc_listen_port,
                "dns_capability": dns_capability,
                "grpc_capability": "tc_observability",
                "binding": {
                    "server_id": SERVER_ID,
                    "port_id": PORT_ID,
                    "host": observed_host,
                    "interface": "tap-test",
                    "ifindex": ifindex,
                    "accel_role": accel_role,
                    "grpc_observe_port": grpc_observe_port,
                    "guest_grpc_listen_port": guest_grpc_listen_port,
                    "dns_capability": dns_capability,
                    "grpc_capability": "tc_observability",
                },
            }
        )
    endpoint_item = {
        "server_id": SERVER_ID,
        "port_ids": port_ids,
        "accel_role": accel_role,
        "grpc_observe_port": grpc_observe_port,
        "guest_grpc_listen_port": guest_grpc_listen_port,
        **(
            {"trusted_dns": trusted_dns}
            if accel_role == "client"
            else {}
        ),
    }
    if legacy_grpc_port is not None:
        endpoint_item["grpc_port"] = legacy_grpc_port
    return parse_agent_snapshot(
        {
            "schema_version": 3,
            "local_host": host,
            "updated_ms": updated_ms,
            "endpoint_config": [endpoint_item],
            "grpc_capability": "tc_observability",
            "port_inventory": [
                {
                    "server_id": SERVER_ID,
                    "port_id": PORT_ID,
                    "status": status,
                    "binding_host": inventory_host,
                    "vif_type": vif_type,
                    "revision_number": revision_number,
                }
            ],
            "port_health": port_health,
        },
        source,
    )


def guest_snapshot(
    source="client-guest",
    role="client",
    updated_ms=NOW_MS,
    state="healthy",
    listen_port=None,
    listen_host="0.0.0.0",
    server_id=SERVER_ID,
    port_id=PORT_ID,
    interface_ip=None,
    backend_host=None,
    backend_port=None,
    backend_ready=True,
    pins_present=None,
    map_paths=None,
):
    if listen_port is None:
        listen_port = 50053 if role == "client" else 50052
    if interface_ip is None:
        interface_ip = "10.0.0.43" if role == "client" else "10.0.0.55"
    if backend_host is None:
        backend_host = "10.0.0.55"
    if backend_port is None:
        backend_port = 50052 if role == "client" else 50051
    expected_maps = 2 if role == "server" else 1
    program_id = 91 if role == "server" else None
    port_root = f"/sys/fs/bpf/vnet-dataplane-guest/{port_id}"
    if map_paths is None:
        map_paths = {
            "grpc_runtime_control": f"{port_root}/grpc/cache_runtime_control",
            "dns_runtime_control": (
                f"{port_root}/dns/cache_runtime_control"
                if role == "server"
                else None
            ),
            "dns_cache_stats": (
                f"{port_root}/dns/dns_cache_stats"
                if role == "server"
                else None
            ),
            "dns_cache_entries": (
                f"{port_root}/dns/dns_cache_entries"
                if role == "server"
                else None
            ),
        }
    if pins_present is None:
        pins_present = {
            path: True for path in map_paths.values() if path is not None
        }
    processes = {
        "grpc_fast_cache": {"pid": 1201, "alive": True},
        "dns_monitor": {
            "pid": 1202 if role == "server" else None,
            "alive": role == "server",
        },
    }
    return parse_guest_endpoint_snapshot(
        {
            "schema_version": 1,
            "source_kind": "guest_endpoint",
            "server_id": server_id,
            "port_id": port_id,
            "accel_role": role,
            "interface": "ens3",
            "interface_ipv4": [interface_ip],
            "updated_ms": updated_ms,
            "state": state,
            "reason": "ready" if state == "healthy" else "test_failure",
            "grpc_capability": "userspace_fast_cache",
            "grpc": {
                "listen": f"{listen_host}:{listen_port}",
                "backend": f"{backend_host}:{backend_port}",
                "method": "/grpc.health.v1.Health/Check",
                "cache_file": "/etc/vnet/grpc-policy.txt",
                "listener_owned": True,
                "backend_ready": backend_ready,
            },
            "processes": processes,
            "dns_xdp_prog_id": program_id,
            "current_dns_xdp_prog_id": program_id,
            "map_paths": map_paths,
            "pins_present": pins_present,
            "runtime_readback": {
                "schema_version": 1,
                "present": True,
                "maps": expected_maps,
                "epoch": 7,
                "mode": 3 if role == "client" else 2,
                "flags": 1,
            },
            "quiesced": False,
        },
        source,
    )


def two_endpoint_compute_snapshot(source="master-state", host="master"):
    endpoints = (
        {
            "server_id": SERVER_ID,
            "port_id": PORT_ID,
            "accel_role": "client",
            "grpc_observe_port": 50052,
            "guest_grpc_listen_port": 50053,
            "dns_capability": "xdp_client_cache",
            "trusted_dns": ["10.0.0.55"],
            "ifindex": 14,
        },
        {
            "server_id": BACKEND_SERVER_ID,
            "port_id": BACKEND_PORT_ID,
            "accel_role": "observer",
            "grpc_observe_port": 50052,
            "guest_grpc_listen_port": 50052,
            "dns_capability": "tc_observability",
            "trusted_dns": [],
            "ifindex": 15,
        },
    )
    return parse_agent_snapshot(
        {
            "schema_version": 3,
            "local_host": host,
            "updated_ms": NOW_MS,
            "endpoint_config": [
                {
                    "server_id": item["server_id"],
                    "port_ids": [item["port_id"]],
                    "accel_role": item["accel_role"],
                    "grpc_observe_port": item["grpc_observe_port"],
                    "guest_grpc_listen_port": item[
                        "guest_grpc_listen_port"
                    ],
                    **(
                        {"trusted_dns": item["trusted_dns"]}
                        if item["accel_role"] == "client"
                        else {}
                    ),
                }
                for item in endpoints
            ],
            "grpc_capability": "tc_observability",
            "port_inventory": [
                {
                    "server_id": item["server_id"],
                    "port_id": item["port_id"],
                    "status": "ACTIVE",
                    "binding_host": host,
                    "vif_type": "ovs",
                    "revision_number": 7,
                }
                for item in endpoints
            ],
            "port_health": [
                {
                    "port_id": item["port_id"],
                    "state": "healthy",
                    "reason": "test_state",
                    "accel_role": item["accel_role"],
                    "grpc_observe_port": item["grpc_observe_port"],
                    "guest_grpc_listen_port": item[
                        "guest_grpc_listen_port"
                    ],
                    "dns_capability": item["dns_capability"],
                    "grpc_capability": "tc_observability",
                    "binding": {
                        "server_id": item["server_id"],
                        "port_id": item["port_id"],
                        "host": host,
                        "interface": f"tap-{item['ifindex']}",
                        "ifindex": item["ifindex"],
                        "accel_role": item["accel_role"],
                        "grpc_observe_port": item["grpc_observe_port"],
                        "guest_grpc_listen_port": item[
                            "guest_grpc_listen_port"
                        ],
                        "dns_capability": item["dns_capability"],
                        "grpc_capability": "tc_observability",
                    },
                }
                for item in endpoints
            ],
        },
        source,
    )


class EpochGateTest(unittest.TestCase):
    def setUp(self):
        self.required = [RequiredEndpoint(SERVER_ID, PORT_ID)]

    def test_single_healthy_binding_allows_publication(self):
        decision = evaluate_gate(
            [
                snapshot(
                    "master-state",
                    "master",
                    "absent",
                    binding_host="compute2",
                ),
                snapshot("compute2-state", "compute2", "healthy", ifindex=21),
            ],
            self.required,
            NOW_MS,
            max_age_ms=10_000,
        )
        self.assertEqual(decision.action, GateAction.PUBLISH)
        self.assertFalse(decision.force_bypass)
        self.assertEqual(decision.healthy_observations[0].source, "compute2-state")

    def test_observer_endpoint_can_gate_backend_migration_without_cache_role(self):
        required = [
            RequiredEndpoint(
                SERVER_ID,
                PORT_ID,
                compute_role="observer",
                guest_cache_role=None,
            )
        ]
        decision = evaluate_gate(
            [
                snapshot(
                    "master-state",
                    "master",
                    "absent",
                    binding_host="compute2",
                    accel_role="observer",
                    guest_grpc_listen_port=50052,
                ),
                snapshot(
                    "compute2-state",
                    "compute2",
                    "healthy",
                    ifindex=21,
                    accel_role="observer",
                    guest_grpc_listen_port=50052,
                ),
            ],
            required,
            NOW_MS,
            max_age_ms=10_000,
        )
        self.assertEqual(decision.action, GateAction.PUBLISH)
        self.assertEqual(
            decision.healthy_observations[0].dns_capability,
            "tc_observability",
        )

    def test_guest_cache_health_is_joined_with_compute_binding(self):
        required = [
            RequiredEndpoint(
                SERVER_ID,
                PORT_ID,
                compute_role="client",
                guest_cache_role="client",
            )
        ]
        compute = [
            snapshot(
                "master-state",
                "master",
                "absent",
                binding_host="compute2",
            ),
            snapshot("compute2-state", "compute2", "healthy", ifindex=21),
        ]
        published = evaluate_gate(
            compute,
            required,
            NOW_MS,
            max_age_ms=10_000,
            guest_snapshots=[guest_snapshot()],
        )
        missing = evaluate_gate(
            compute,
            required,
            NOW_MS,
            max_age_ms=10_000,
        )
        stale = evaluate_gate(
            compute,
            required,
            NOW_MS,
            max_age_ms=10_000,
            guest_snapshots=[
                guest_snapshot(updated_ms=NOW_MS - 10_001)
            ],
        )
        wrong_port = evaluate_gate(
            compute,
            required,
            NOW_MS,
            max_age_ms=10_000,
            guest_snapshots=[guest_snapshot(listen_port=50052)],
        )

        self.assertEqual(published.action, GateAction.PUBLISH)
        self.assertEqual(
            published.healthy_guest_observations[0].accel_role,
            "client",
        )
        self.assertEqual(missing.action, GateAction.BYPASS)
        self.assertIn("guest_endpoint_presence_invalid", missing.reason)
        self.assertEqual(stale.action, GateAction.BYPASS)
        self.assertIn("stale_guest_snapshot", stale.reason)
        self.assertEqual(wrong_port.action, GateAction.BYPASS)
        self.assertIn("guest_grpc_listen_port_mismatch", wrong_port.reason)
        with self.assertRaisesRegex(GateError, "ready owned"):
            guest_snapshot(backend_ready=False)
        with self.assertRaisesRegex(GateError, "non-local grpc.listen"):
            guest_snapshot(listen_host="10.0.0.99")
        with self.assertRaisesRegex(GateError, "invalid grpc.backend"):
            guest_snapshot(backend_host="0.0.0.0")

    def test_guest_client_rejects_same_count_substituted_pin(self):
        fake_pin = (
            f"/sys/fs/bpf/vnet-dataplane-guest/{PORT_ID}"
            "/grpc/substituted_runtime_control"
        )

        with self.assertRaisesRegex(GateError, "pins"):
            guest_snapshot(pins_present={fake_pin: True})

    def test_guest_server_rejects_same_count_substituted_pin(self):
        port_root = (
            f"/sys/fs/bpf/vnet-dataplane-guest/{BACKEND_PORT_ID}"
        )
        pins = {
            f"{port_root}/grpc/cache_runtime_control": True,
            f"{port_root}/dns/cache_runtime_control": True,
            f"{port_root}/dns/dns_cache_entries": True,
            f"{port_root}/dns/substituted_cache_stats": True,
        }

        with self.assertRaisesRegex(GateError, "pins"):
            guest_snapshot(
                source="backend-guest",
                role="server",
                server_id=BACKEND_SERVER_ID,
                port_id=BACKEND_PORT_ID,
                pins_present=pins,
            )

    def test_guest_rejects_map_paths_and_pins_at_untrusted_root(self):
        port_root = f"/tmp/forged-bpffs/{PORT_ID}"
        map_paths = {
            "grpc_runtime_control": f"{port_root}/grpc/cache_runtime_control",
            "dns_runtime_control": None,
            "dns_cache_stats": None,
            "dns_cache_entries": None,
        }
        pins = {map_paths["grpc_runtime_control"]: True}

        with self.assertRaisesRegex(GateError, "map_paths"):
            guest_snapshot(map_paths=map_paths, pins_present=pins)

    def test_guest_grpc_backend_topology_must_match_server_endpoint(self):
        required = [
            RequiredEndpoint(
                SERVER_ID,
                PORT_ID,
                compute_role="client",
                guest_cache_role="client",
                grpc_backend_server_id=BACKEND_SERVER_ID,
            ),
            RequiredEndpoint(
                BACKEND_SERVER_ID,
                BACKEND_PORT_ID,
                compute_role="observer",
                guest_cache_role="server",
            ),
        ]
        compute = [two_endpoint_compute_snapshot()]
        backend_guest = guest_snapshot(
            source="backend-guest",
            role="server",
            server_id=BACKEND_SERVER_ID,
            port_id=BACKEND_PORT_ID,
        )
        client_guest = guest_snapshot()

        published = evaluate_gate(
            compute,
            required,
            NOW_MS,
            max_age_ms=10_000,
            guest_snapshots=[client_guest, backend_guest],
        )
        wrong_host = evaluate_gate(
            compute,
            required,
            NOW_MS,
            max_age_ms=10_000,
            guest_snapshots=[
                guest_snapshot(backend_host="10.0.0.99"),
                backend_guest,
            ],
        )
        wrong_port = evaluate_gate(
            compute,
            required,
            NOW_MS,
            max_age_ms=10_000,
            guest_snapshots=[
                guest_snapshot(backend_port=50054),
                backend_guest,
            ],
        )

        self.assertEqual(published.action, GateAction.PUBLISH)
        self.assertEqual(wrong_host.action, GateAction.BYPASS)
        self.assertIn("guest_grpc_backend_mismatch", wrong_host.reason)
        self.assertEqual(wrong_port.action, GateAction.BYPASS)
        self.assertIn("guest_grpc_backend_mismatch", wrong_port.reason)

    def test_endpoint_role_or_grpc_endpoint_port_drift_forces_bypass(self):
        role_mismatch = evaluate_gate(
            [
                snapshot(
                    "master-state",
                    "master",
                    "healthy",
                    accel_role="observer",
                    guest_grpc_listen_port=50052,
                )
            ],
            self.required,
            NOW_MS,
            max_age_ms=10_000,
        )
        self.assertEqual(role_mismatch.action, GateAction.BYPASS)
        self.assertIn("endpoint_role_mismatch", role_mismatch.reason)

        port_drift = evaluate_gate(
            [
                snapshot(
                    "master-state",
                    "master",
                    "absent",
                    binding_host="compute2",
                ),
                snapshot(
                    "compute2-state",
                    "compute2",
                    "healthy",
                    ifindex=21,
                    grpc_observe_port=50054,
                ),
            ],
            self.required,
            NOW_MS,
            max_age_ms=10_000,
        )
        self.assertEqual(port_drift.action, GateAction.BYPASS)
        self.assertIn("endpoint_config_mismatch", port_drift.reason)

        guest_listen_port_drift = evaluate_gate(
            [
                snapshot(
                    "master-state",
                    "master",
                    "absent",
                    binding_host="compute2",
                ),
                snapshot(
                    "compute2-state",
                    "compute2",
                    "healthy",
                    ifindex=21,
                    guest_grpc_listen_port=50054,
                ),
            ],
            self.required,
            NOW_MS,
            max_age_ms=10_000,
        )
        self.assertEqual(guest_listen_port_drift.action, GateAction.BYPASS)
        self.assertIn(
            "endpoint_config_mismatch", guest_listen_port_drift.reason
        )

    def test_required_port_must_be_in_every_compute_allowlist(self):
        missing = evaluate_gate(
            [
                snapshot("master-state", "master", "healthy"),
                snapshot(
                    "compute2-state",
                    "compute2",
                    "absent",
                    binding_host="master",
                    port_ids=[BACKEND_PORT_ID],
                ),
            ],
            self.required,
            NOW_MS,
            max_age_ms=10_000,
        )
        drift = evaluate_gate(
            [
                snapshot("master-state", "master", "healthy"),
                snapshot(
                    "compute2-state",
                    "compute2",
                    "absent",
                    binding_host="master",
                    port_ids=[PORT_ID, BACKEND_PORT_ID],
                ),
            ],
            self.required,
            NOW_MS,
            max_age_ms=10_000,
        )

        self.assertEqual(missing.action, GateAction.BYPASS)
        self.assertIn("endpoint_port_not_allowed", missing.reason)
        self.assertEqual(drift.action, GateAction.BYPASS)
        self.assertIn("endpoint_config_mismatch", drift.reason)

    def test_legacy_grpc_port_field_is_rejected(self):
        with self.assertRaisesRegex(GateError, "legacy grpc_port"):
            snapshot(
                "master-state",
                "master",
                "healthy",
                legacy_grpc_port=50053,
            )

    def test_transition_freezes_even_if_target_is_already_healthy(self):
        decision = evaluate_gate(
            [
                snapshot(
                    "master-state",
                    "master",
                    "transition",
                    binding_host="compute2",
                ),
                snapshot(
                    "compute2-state",
                    "compute2",
                    "healthy",
                    ifindex=21,
                    revision_number=8,
                ),
            ],
            self.required,
            NOW_MS,
            max_age_ms=10_000,
        )
        self.assertEqual(decision.action, GateAction.FREEZE)
        self.assertEqual(
            decision.reason,
            f"migration_transition:{SERVER_ID}:{PORT_ID}:master-state",
        )
        self.assertTrue(decision.force_bypass)

    def test_degraded_or_stale_snapshot_forces_bypass(self):
        degraded = evaluate_gate(
            [
                snapshot("master-state", "master", "degraded"),
                snapshot(
                    "compute2-state",
                    "compute2",
                    "transition",
                    binding_host="master",
                    revision_number=8,
                ),
            ],
            self.required,
            NOW_MS,
            max_age_ms=10_000,
        )
        self.assertEqual(degraded.action, GateAction.BYPASS)
        self.assertIn("endpoint_unhealthy", degraded.reason)

        stale = evaluate_gate(
            [
                snapshot(
                    "master-state",
                    "master",
                    "healthy",
                    updated_ms=NOW_MS - 10_001,
                )
            ],
            self.required,
            NOW_MS,
            max_age_ms=10_000,
        )
        self.assertEqual(stale.action, GateAction.BYPASS)
        self.assertEqual(stale.reason, "stale_snapshot:master-state")

    def test_two_healthy_hosts_are_rejected_as_ambiguous(self):
        decision = evaluate_gate(
            [
                snapshot("master-state", "master", "healthy"),
                snapshot(
                    "compute2-state",
                    "compute2",
                    "healthy",
                    ifindex=21,
                    binding_host="master",
                ),
            ],
            self.required,
            NOW_MS,
            max_age_ms=10_000,
        )
        self.assertEqual(decision.action, GateAction.BYPASS)
        self.assertIn("ambiguous_healthy_binding", decision.reason)

    def test_missing_required_port_forces_bypass(self):
        decision = evaluate_gate(
            [snapshot("master-state", "master", None)],
            self.required,
            NOW_MS,
            max_age_ms=10_000,
        )
        self.assertEqual(decision.action, GateAction.BYPASS)
        self.assertIn("no_healthy_binding", decision.reason)

    def test_required_inventory_must_agree_across_every_source(self):
        mismatches = {
            "revision_number": {"revision_number": 8},
            "binding_host": {"binding_host": "master"},
            "status": {"status": "DOWN"},
            "vif_type": {"vif_type": "unbound"},
        }
        for field, override in mismatches.items():
            with self.subTest(field=field):
                decision = evaluate_gate(
                    [
                        snapshot(
                            "master-state",
                            "master",
                            "absent",
                            binding_host="compute2",
                        ),
                        snapshot(
                            "compute2-state",
                            "compute2",
                            "healthy",
                            ifindex=21,
                            **override,
                        ),
                    ],
                    self.required,
                    NOW_MS,
                    max_age_ms=10_000,
                )
                self.assertEqual(decision.action, GateAction.BYPASS)
                self.assertIn(
                    f"inventory_mismatch:{SERVER_ID}:{PORT_ID}:{field}",
                    decision.reason,
                )

    def test_old_healthy_source_and_new_revision_mismatch_cannot_publish(self):
        decision = evaluate_gate(
            [
                snapshot(
                    "old-source",
                    "master",
                    "healthy",
                    revision_number=19,
                ),
                snapshot(
                    "new-target",
                    "compute2",
                    "absent",
                    binding_host="master",
                    revision_number=20,
                ),
            ],
            self.required,
            NOW_MS,
            max_age_ms=10_000,
        )
        self.assertEqual(decision.action, GateAction.BYPASS)
        self.assertIn("inventory_mismatch", decision.reason)

    def test_healthy_observation_must_be_on_inventory_binding_host(self):
        decision = evaluate_gate(
            [
                snapshot(
                    "master-state",
                    "master",
                    "healthy",
                    binding_host="compute2",
                    observation_host="compute2",
                )
            ],
            self.required,
            NOW_MS,
            max_age_ms=10_000,
        )
        self.assertEqual(decision.action, GateAction.BYPASS)
        self.assertIn("healthy_local_host_mismatch", decision.reason)

    def test_inter_source_skew_is_bounded_and_configurable(self):
        snapshots = [
            snapshot(
                "master-state",
                "master",
                "absent",
                updated_ms=NOW_MS - 101,
                binding_host="compute2",
            ),
            snapshot(
                "compute2-state",
                "compute2",
                "healthy",
                updated_ms=NOW_MS,
                ifindex=21,
            ),
        ]
        rejected = evaluate_gate(
            snapshots,
            self.required,
            NOW_MS,
            max_age_ms=10_000,
            max_skew_ms=100,
        )
        accepted = evaluate_gate(
            snapshots,
            self.required,
            NOW_MS,
            max_age_ms=10_000,
            max_skew_ms=101,
        )
        self.assertEqual(rejected.action, GateAction.BYPASS)
        self.assertEqual(rejected.reason, "snapshot_skew_exceeded:101")
        self.assertEqual(accepted.action, GateAction.PUBLISH)

    def test_future_snapshot_is_rejected(self):
        snapshots = [
            snapshot(
                "master-state",
                "master",
                "absent",
                updated_ms=NOW_MS,
                binding_host="compute2",
            ),
            snapshot(
                "compute2-state",
                "compute2",
                "healthy",
                updated_ms=NOW_MS + 5_001,
                ifindex=21,
            ),
        ]
        decision = evaluate_gate(
            snapshots,
            self.required,
            NOW_MS,
            max_age_ms=10_000,
            max_skew_ms=5_000,
        )
        self.assertEqual(decision.action, GateAction.BYPASS)
        self.assertEqual(decision.reason, "future_snapshot:compute2-state")

    def test_missing_global_inventory_is_rejected(self):
        with self.assertRaisesRegex(GateError, "no port_inventory list"):
            parse_agent_snapshot(
                {
                    "schema_version": 3,
                    "local_host": "master",
                    "updated_ms": NOW_MS,
                    "endpoint_config": [
                        {
                            "server_id": SERVER_ID,
                            "port_ids": [PORT_ID],
                            "accel_role": "client",
                            "grpc_observe_port": 50052,
                            "guest_grpc_listen_port": 50053,
                            "trusted_dns": ["10.0.0.12"],
                        }
                    ],
                    "grpc_capability": "tc_observability",
                    "port_health": [],
                },
                "master-state",
            )


if __name__ == "__main__":
    unittest.main()
