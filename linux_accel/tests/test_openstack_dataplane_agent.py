import argparse
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

try:
    import fcntl
except ImportError:
    fcntl = None

from agent.openstack_dataplane_agent import (
    AttachmentConfig,
    AgentError,
    Binding,
    CommandRunner,
    DiscoveryResult,
    EndpointConfig,
    HookProgramIds,
    PortInventory,
    OpenStackOvsResolver,
    ProcessAttachmentDriver,
    Reconciler,
    _ManagedAttachment,
    _assert_discovery_consistent,
    _configured_server_ids,
    _extract_tc_program_ids,
    _extract_xdp_program_id,
    _health,
    _load_endpoint_configs,
    _sample_discovery,
    _watch,
    _write_state,
)


class FakeRunner:
    def __init__(self, responses):
        self.responses = responses

    def run(self, args):
        key = tuple(args)
        if key not in self.responses:
            raise AssertionError(f"unexpected command: {key}")
        return json.dumps(self.responses[key])


class FakeDriver:
    def __init__(self):
        self.attached = {}
        self.actions = []
        self.unhealthy = set()
        self.persistent_unhealthy = set()
        self.fail_attach = set()
        self.fail_detach = set()

    def attach(self, binding):
        if binding.port_id in self.fail_attach:
            raise AgentError("injected attach failure")
        self.actions.append(("attach", binding.port_id, binding.ifindex))
        self.attached[binding.port_id] = binding
        if binding.port_id not in self.persistent_unhealthy:
            self.unhealthy.discard(binding.port_id)

    def detach(self, binding):
        if binding.port_id in self.fail_detach:
            raise AgentError("injected detach failure")
        self.actions.append(("detach", binding.port_id, binding.ifindex))
        self.attached.pop(binding.port_id, None)

    def healthy(self, binding):
        return (
            self.attached.get(binding.port_id) == binding
            and binding.port_id not in self.unhealthy
        )

    def snapshot(self):
        return {}


class FakeProcess:
    def __init__(self, name):
        self.name = name
        self.pid = 100

    def poll(self):
        return None


def transaction_response(operation, returncode=0, maps=2):
    stdout = ""
    if operation == "read-current" and returncode == 0:
        stdout = json.dumps(
            {
                "schema_version": 1,
                "present": True,
                "maps": maps,
                "epoch": 1,
                "mode": 1,
                "flags": 1,
            }
        )
    return argparse.Namespace(returncode=returncode, stdout=stdout, stderr="")


def binding(ifindex=14, interface="tapport"):
    return Binding(
        server_id="server-1",
        port_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        host="master",
        interface=interface,
        ifindex=ifindex,
    )


def observer_binding(ifindex=15, interface="tapbackend"):
    return Binding(
        server_id="server-2",
        port_id="bbbbbbbb-cccc-dddd-eeee-ffffffffffff",
        host="master",
        interface=interface,
        ifindex=ifindex,
    )


def hook_programs(
    *,
    dns_xdp=101,
    dns_tc_ingress=102,
    dns_tc_egress=102,
    grpc_tc_ingress=201,
    grpc_tc_egress=202,
):
    return HookProgramIds(
        dns_xdp=dns_xdp,
        dns_tc_ingress=dns_tc_ingress,
        dns_tc_egress=dns_tc_egress,
        grpc_tc_ingress=grpc_tc_ingress,
        grpc_tc_egress=grpc_tc_egress,
    )


def discovery_result(
    *,
    revision_number=7,
    binding_host="master",
    ifindex=14,
):
    current = binding(ifindex=ifindex)
    return DiscoveryResult(
        bindings=(current,) if binding_host == "master" else (),
        port_inventory=(
            PortInventory(
                server_id=current.server_id,
                port_id=current.port_id,
                status="ACTIVE",
                binding_host=binding_host,
                vif_type="ovs",
                revision_number=revision_number,
            ),
        ),
    )


def attachment_config(root):
    paths = {
        name: root / name
        for name in (
            "dns",
            "dns-client.bpf",
            "dns-tc.bpf",
            "grpc",
            "grpc.bpf",
            "cache_policy_txn",
        )
    }
    for path in paths.values():
        path.touch()
    return AttachmentConfig(
        dns_monitor=paths["dns"],
        dns_client_bpf=paths["dns-client.bpf"],
        dns_tc_bpf=paths["dns-tc.bpf"],
        grpc_monitor=paths["grpc"],
        grpc_bpf=paths["grpc.bpf"],
        cache_policy_txn=paths["cache_policy_txn"],
        endpoint_configs=(
            EndpointConfig(
                server_id="server-1",
                accel_role="client",
                grpc_observe_port=50052,
                guest_grpc_listen_port=50053,
                port_ids=(binding().port_id,),
                trusted_dns=("10.0.0.53",),
            ),
        ),
        pin_root=root / "bpffs" / "agent",
        log_root=root / "logs",
        policy_lock_root=root / "locks",
        attach_ready_timeout_seconds=0.1,
    )


def client_observer_config(root):
    config = attachment_config(root)
    return replace(
        config,
        endpoint_configs=(
            config.endpoint_configs[0],
            EndpointConfig(
                server_id="server-2",
                accel_role="observer",
                grpc_observe_port=50052,
                guest_grpc_listen_port=50052,
                port_ids=(observer_binding().port_id,),
            ),
        ),
    )


def healthy_state(updated_ms):
    return {
        "schema_version": 3,
        "server_ids": ["server-1"],
        "updated_ms": updated_ms,
        "snapshot_consistency": {
            "status": "consistent",
            "error": None,
        },
        "endpoint_config": [
            {
                "server_id": "server-1",
                "port_ids": [binding().port_id],
                "accel_role": "client",
                "grpc_observe_port": 50052,
                "guest_grpc_listen_port": 50053,
                "trusted_dns": ["10.0.0.53"],
            }
        ],
        "dns_capabilities": {"server-1": "xdp_client_cache"},
        "grpc_capability": "tc_observability",
        "health": {
            "status": "healthy",
            "accel_roles": {"server-1": "client"},
            "grpc_observe_ports": {"server-1": 50052},
            "guest_grpc_listen_ports": {"server-1": 50053},
            "dns_capabilities": {"server-1": "xdp_client_cache"},
            "grpc_capability": "tc_observability",
            "snapshot_consistency": "consistent",
            "snapshot_error": None,
        },
        "port_health": [
            {
                "port_id": binding().port_id,
                "state": "healthy",
                "accel_role": "client",
                "dns_capability": "xdp_client_cache",
                "grpc_observe_port": 50052,
                "guest_grpc_listen_port": 50053,
                "grpc_capability": "tc_observability",
                "binding": {
                    "server_id": "server-1",
                    "port_id": binding().port_id,
                    "accel_role": "client",
                    "dns_capability": "xdp_client_cache",
                    "grpc_observe_port": 50052,
                    "guest_grpc_listen_port": 50053,
                    "grpc_capability": "tc_observability",
                },
            }
        ],
    }


def healthy_client_observer_state(updated_ms):
    state = healthy_state(updated_ms)
    state["server_ids"].append("server-2")
    state["endpoint_config"].append(
        {
            "server_id": "server-2",
            "port_ids": [observer_binding().port_id],
            "accel_role": "observer",
            "grpc_observe_port": 50052,
            "guest_grpc_listen_port": 50052,
        }
    )
    state["dns_capabilities"]["server-2"] = "tc_observability"
    state["health"]["accel_roles"]["server-2"] = "observer"
    state["health"]["grpc_observe_ports"]["server-2"] = 50052
    state["health"]["guest_grpc_listen_ports"]["server-2"] = 50052
    state["health"]["dns_capabilities"]["server-2"] = "tc_observability"
    state["port_health"].append(
        {
            "port_id": observer_binding().port_id,
            "state": "healthy",
            "accel_role": "observer",
            "dns_capability": "tc_observability",
            "grpc_observe_port": 50052,
            "guest_grpc_listen_port": 50052,
            "grpc_capability": "tc_observability",
            "binding": {
                "server_id": "server-2",
                "port_id": observer_binding().port_id,
                "accel_role": "observer",
                "dns_capability": "tc_observability",
                "grpc_observe_port": 50052,
                "guest_grpc_listen_port": 50052,
                "grpc_capability": "tc_observability",
            },
        }
    )
    return state


class CommandRunnerTest(unittest.TestCase):
    def test_slow_external_command_receives_configured_hard_timeout(self):
        completed = argparse.Namespace(
            returncode=0,
            stdout="complete\n",
            stderr="",
        )
        with patch(
            "agent.openstack_dataplane_agent.subprocess.run",
            return_value=completed,
        ) as run:
            output = CommandRunner(0.25).run(["slow-helper", "--json"])

        self.assertEqual(output, "complete\n")
        self.assertEqual(run.call_args.args[0], ["slow-helper", "--json"])
        self.assertEqual(run.call_args.kwargs["timeout"], 0.25)

    def test_external_command_timeout_fails_closed(self):
        with (
            patch(
                "agent.openstack_dataplane_agent.subprocess.run",
                side_effect=subprocess.TimeoutExpired(
                    ["openstack", "port", "list"],
                    0.25,
                ),
            ),
            self.assertRaisesRegex(
                AgentError,
                r"timed out after 0\.25s: openstack port list",
            ),
        ):
            CommandRunner(0.25).run(["openstack", "port", "list"])


class ResolverTest(unittest.TestCase):
    def test_resolves_only_local_active_ovs_port(self):
        local_port = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        remote_port = "11111111-2222-3333-4444-555555555555"
        responses = {
            (
                "openstack",
                "port",
                "list",
                "--server",
                "server-1",
                "-f",
                "json",
                "-c",
                "ID",
            ): [{"ID": local_port}, {"ID": remote_port}],
            (
                "openstack",
                "port",
                "show",
                local_port,
                "-f",
                "json",
            ): {
                "id": local_port,
                "device_id": "server-1",
                "status": "ACTIVE",
                "binding_host_id": "master",
                "binding_vif_type": "ovs",
                "revision_number": 41,
            },
            (
                "openstack",
                "port",
                "show",
                remote_port,
                "-f",
                "json",
            ): {
                "id": remote_port,
                "device_id": "server-1",
                "status": "DOWN",
                "binding_host_id": "compute2",
                "binding_vif_type": "ovs",
                "revision_number": 42,
            },
            (
                "ovs-vsctl",
                "--format=json",
                "--columns=name",
                "find",
                "Interface",
                f"external_ids:iface-id={local_port}",
            ): {"headings": ["name"], "data": [["tapaaaaaaaa-b"]]},
            (
                "ip",
                "-j",
                "link",
                "show",
                "dev",
                "tapaaaaaaaa-b",
            ): [{"ifindex": 14, "ifname": "tapaaaaaaaa-b"}],
        }
        resolver = OpenStackOvsResolver(FakeRunner(responses), "master.local")
        discovery = resolver.discover_with_inventory(
            "server-1",
            (local_port,),
        )
        self.assertEqual(discovery.policy_errors, ())
        self.assertEqual(
            list(discovery.bindings),
            [
                Binding(
                    server_id="server-1",
                    port_id=local_port,
                    host="master",
                    interface="tapaaaaaaaa-b",
                    ifindex=14,
                )
            ],
        )
        self.assertEqual(
            list(discovery.port_inventory),
            [
                PortInventory(
                    server_id="server-1",
                    port_id=remote_port,
                    status="DOWN",
                    binding_host="compute2",
                    vif_type="ovs",
                    revision_number=42,
                ),
                PortInventory(
                    server_id="server-1",
                    port_id=local_port,
                    status="ACTIVE",
                    binding_host="master",
                    vif_type="ovs",
                    revision_number=41,
                ),
            ],
        )

    def test_extra_active_local_ovs_port_blocks_all_bindings_and_attach(self):
        allowed_port = binding().port_id
        extra_port = "11111111-2222-3333-4444-555555555555"
        responses = {
            (
                "openstack",
                "port",
                "list",
                "--server",
                "server-1",
                "-f",
                "json",
                "-c",
                "ID",
            ): [{"ID": allowed_port}, {"ID": extra_port}],
        }
        for port_id in (allowed_port, extra_port):
            responses[
                (
                    "openstack",
                    "port",
                    "show",
                    port_id,
                    "-f",
                    "json",
                )
            ] = {
                "id": port_id,
                "device_id": "server-1",
                "status": "ACTIVE",
                "binding_host_id": "master",
                "binding_vif_type": "ovs",
                "revision_number": 7,
            }
        resolver = OpenStackOvsResolver(FakeRunner(responses), "master")

        discovery = resolver.discover_with_inventory(
            "server-1",
            (allowed_port,),
        )
        driver = FakeDriver()
        reconciler = Reconciler(
            driver,
            allowed_port_ids_by_server={"server-1": (allowed_port,)},
        )
        reconciler.reconcile(discovery.bindings)

        self.assertEqual(discovery.bindings, ())
        self.assertEqual(driver.actions, [])
        self.assertIn("undeclared ACTIVE local OVS port", discovery.policy_errors[0])
        self.assertIn(extra_port, discovery.policy_errors[0])

    def test_declared_port_missing_from_server_inventory_blocks_discovery(self):
        allowed_port = binding().port_id
        responses = {
            (
                "openstack",
                "port",
                "list",
                "--server",
                "server-1",
                "-f",
                "json",
                "-c",
                "ID",
            ): [],
        }
        resolver = OpenStackOvsResolver(FakeRunner(responses), "master")

        discovery = resolver.discover_with_inventory(
            "server-1",
            (allowed_port,),
        )

        self.assertEqual(discovery.bindings, ())
        self.assertIn("declared port is missing", discovery.policy_errors[0])
        self.assertIn(allowed_port, discovery.policy_errors[0])

    def test_declared_port_bound_to_other_host_is_normal_absent(self):
        allowed_port = binding().port_id
        responses = {
            (
                "openstack",
                "port",
                "list",
                "--server",
                "server-1",
                "-f",
                "json",
                "-c",
                "ID",
            ): [{"ID": allowed_port}],
            (
                "openstack",
                "port",
                "show",
                allowed_port,
                "-f",
                "json",
            ): {
                "id": allowed_port,
                "device_id": "server-1",
                "status": "ACTIVE",
                "binding_host_id": "compute2",
                "binding_vif_type": "ovs",
                "revision_number": 8,
            },
        }
        resolver = OpenStackOvsResolver(FakeRunner(responses), "master")

        discovery = resolver.discover_with_inventory(
            "server-1",
            (allowed_port,),
        )

        self.assertEqual(discovery.bindings, ())
        self.assertEqual(discovery.policy_errors, ())
        self.assertEqual(discovery.port_inventory[0].binding_host, "compute2")

    def test_same_allowlist_moves_cleanly_between_two_compute_resolvers(self):
        allowed_port = binding().port_id

        def responses_for(binding_host, interface, ifindex):
            responses = {
                (
                    "openstack",
                    "port",
                    "list",
                    "--server",
                    "server-1",
                    "-f",
                    "json",
                    "-c",
                    "ID",
                ): [{"ID": allowed_port}],
                (
                    "openstack",
                    "port",
                    "show",
                    allowed_port,
                    "-f",
                    "json",
                ): {
                    "id": allowed_port,
                    "device_id": "server-1",
                    "status": "ACTIVE",
                    "binding_host_id": binding_host,
                    "binding_vif_type": "ovs",
                    "revision_number": 9,
                },
                (
                    "ovs-vsctl",
                    "--format=json",
                    "--columns=name",
                    "find",
                    "Interface",
                    f"external_ids:iface-id={allowed_port}",
                ): {"headings": ["name"], "data": [[interface]]},
                (
                    "ip",
                    "-j",
                    "link",
                    "show",
                    "dev",
                    interface,
                ): [{"ifindex": ifindex, "ifname": interface}],
            }
            return responses

        before = responses_for("master", "tap-source", 14)
        after = responses_for("compute2", "tap-target", 21)
        source_before = OpenStackOvsResolver(FakeRunner(before), "master")
        target_before = OpenStackOvsResolver(FakeRunner(before), "compute2")
        source_after = OpenStackOvsResolver(FakeRunner(after), "master")
        target_after = OpenStackOvsResolver(FakeRunner(after), "compute2")

        discoveries = [
            resolver.discover_with_inventory("server-1", (allowed_port,))
            for resolver in (
                source_before,
                target_before,
                source_after,
                target_after,
            )
        ]

        self.assertEqual([item.policy_errors for item in discoveries], [()] * 4)
        self.assertEqual(len(discoveries[0].bindings), 1)
        self.assertEqual(discoveries[1].bindings, ())
        self.assertEqual(discoveries[2].bindings, ())
        self.assertEqual(len(discoveries[3].bindings), 1)

    def test_external_discovery_commands_are_configurable(self):
        port_id = binding().port_id
        responses = {
            (
                "/opt/openstack-client",
                "port",
                "list",
                "--server",
                "server-1",
                "-f",
                "json",
                "-c",
                "ID",
            ): [{"ID": port_id}],
            (
                "/opt/openstack-client",
                "port",
                "show",
                port_id,
                "-f",
                "json",
            ): {
                "id": port_id,
                "device_id": "server-1",
                "status": "ACTIVE",
                "binding_host_id": "master",
                "binding_vif_type": "ovs",
                "revision_number": 7,
            },
            (
                "/opt/ovs-vsctl",
                "--format=json",
                "--columns=name",
                "find",
                "Interface",
                f"external_ids:iface-id={port_id}",
            ): {"headings": ["name"], "data": [["tapport"]]},
            (
                "/opt/ip",
                "-j",
                "link",
                "show",
                "dev",
                "tapport",
            ): [{"ifindex": 14, "ifname": "tapport"}],
        }
        resolver = OpenStackOvsResolver(
            FakeRunner(responses),
            "master",
            openstack_command="/opt/openstack-client",
            ovs_vsctl_command="/opt/ovs-vsctl",
            ip_command="/opt/ip",
        )

        self.assertEqual(
            resolver.discover_with_inventory("server-1"),
            discovery_result(),
        )

    def test_rejects_ambiguous_ovs_mapping(self):
        port_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        responses = {
            (
                "openstack",
                "port",
                "list",
                "--server",
                "server-1",
                "-f",
                "json",
                "-c",
                "ID",
            ): [{"ID": port_id}],
            (
                "openstack",
                "port",
                "show",
                port_id,
                "-f",
                "json",
            ): {
                "id": port_id,
                "device_id": "server-1",
                "status": "ACTIVE",
                "binding_host_id": "master",
                "binding_vif_type": "ovs",
                "revision_number": 7,
            },
            (
                "ovs-vsctl",
                "--format=json",
                "--columns=name",
                "find",
                "Interface",
                f"external_ids:iface-id={port_id}",
            ): {"headings": ["name"], "data": [["tap-a"], ["tap-b"]]},
        }
        resolver = OpenStackOvsResolver(FakeRunner(responses), "master")
        with self.assertRaisesRegex(AgentError, "maps to 2"):
            resolver.discover("server-1")

    def test_discover_many_deduplicates_servers_and_sorts_bindings(self):
        resolver = OpenStackOvsResolver(FakeRunner({}), "master")
        first = binding()
        second = Binding(
            server_id="server-2",
            port_id="bbbbbbbb-cccc-dddd-eeee-ffffffffffff",
            host="master",
            interface="tapsecond",
            ifindex=18,
        )
        with patch.object(
            resolver,
            "discover",
            side_effect=[[second], [first]],
        ) as discover:
            self.assertEqual(
                resolver.discover_many(["server-2", "server-1", "server-2"]),
                [first, second],
            )
        self.assertEqual(discover.call_args_list[0].args, ("server-2",))
        self.assertEqual(discover.call_args_list[1].args, ("server-1",))


class SnapshotConsistencyTest(unittest.TestCase):
    def test_sample_timestamp_is_taken_after_slow_discovery_completes(self):
        clock = {"now": 1.0}

        class SlowResolver:
            @staticmethod
            def discover_many_with_inventory(_server_ids):
                clock["now"] = 9.5
                return discovery_result()

        with patch(
            "agent.openstack_dataplane_agent.time.time",
            side_effect=lambda: clock["now"],
        ):
            sampled = _sample_discovery(SlowResolver(), ["server-1"])

        self.assertEqual(sampled.result, discovery_result())
        self.assertEqual(sampled.completed_ms, 9500)

    def test_revalidation_rejects_neutron_revision_change(self):
        with self.assertRaisesRegex(
            AgentError,
            r"Neutron revision changed.*7 -> 8",
        ):
            _assert_discovery_consistent(
                discovery_result(revision_number=7),
                discovery_result(revision_number=8),
            )

    def test_revalidation_rejects_neutron_binding_host_change(self):
        with self.assertRaisesRegex(
            AgentError,
            "Neutron binding host changed",
        ):
            _assert_discovery_consistent(
                discovery_result(binding_host="master"),
                discovery_result(binding_host="compute2"),
            )

    def test_revalidation_rejects_local_ifindex_change(self):
        with self.assertRaisesRegex(
            AgentError,
            r"local ifindex changed.*14 -> 19",
        ):
            _assert_discovery_consistent(
                discovery_result(ifindex=14),
                discovery_result(ifindex=19),
            )


class ReconcilerTest(unittest.TestCase):
    def test_undeclared_binding_is_rejected_before_attach(self):
        driver = FakeDriver()
        allowed_port = binding().port_id
        undeclared = replace(
            binding(),
            port_id="11111111-2222-3333-4444-555555555555",
        )
        reconciler = Reconciler(
            driver,
            allowed_port_ids_by_server={"server-1": (allowed_port,)},
        )

        with self.assertRaisesRegex(AgentError, "not declared for server"):
            reconciler.reconcile([undeclared])

        self.assertEqual(driver.actions, [])

    def test_attach_is_idempotent_and_interface_recreation_reattaches(self):
        driver = FakeDriver()
        reconciler = Reconciler(driver, missing_grace_cycles=2)
        first = binding()
        rebuilt = binding(ifindex=19)

        reconciler.reconcile([first])
        reconciler.reconcile([first])
        reconciler.reconcile([rebuilt])

        self.assertEqual(
            driver.actions,
            [
                ("attach", first.port_id, 14),
                ("detach", first.port_id, 14),
                ("attach", rebuilt.port_id, 19),
            ],
        )

    def test_migration_detaches_after_grace_and_reattaches_on_return(self):
        driver = FakeDriver()
        reconciler = Reconciler(driver, missing_grace_cycles=2)
        current = binding()

        reconciler.reconcile([current])
        first_missing = reconciler.reconcile([])
        second_missing = reconciler.reconcile([])
        returned = reconciler.reconcile([current])

        self.assertEqual(first_missing[0].action, "wait")
        self.assertEqual(second_missing[0].action, "detach")
        self.assertEqual(returned[0].action, "attach")
        self.assertEqual(
            [action[0] for action in driver.actions],
            ["attach", "detach", "attach"],
        )

    def test_unhealthy_monitor_is_restarted(self):
        driver = FakeDriver()
        reconciler = Reconciler(driver)
        current = binding()

        reconciler.reconcile([current])
        driver.unhealthy.add(current.port_id)
        events = reconciler.reconcile([current])

        self.assertEqual([event.reason for event in events],
                         ["monitor_unhealthy", "binding_local"])

    def test_detach_failure_retains_binding_and_reports_degraded(self):
        driver = FakeDriver()
        reconciler = Reconciler(driver, missing_grace_cycles=2)
        current = binding()
        reconciler.reconcile([current])
        driver.fail_detach.add(current.port_id)

        reconciler.reconcile([])
        failed = reconciler.reconcile([])

        self.assertEqual(failed[0].action, "error")
        self.assertIn("detach_failed", failed[0].reason)
        self.assertEqual(reconciler.bindings(), [current])
        self.assertEqual(reconciler.port_health()[0].state, "degraded")

    def test_port_health_marks_migration_and_attach_failure(self):
        driver = FakeDriver()
        reconciler = Reconciler(driver, missing_grace_cycles=2)
        current = binding()

        reconciler.reconcile([current])
        reconciler.reconcile([])
        self.assertEqual(reconciler.port_health()[0].state, "transition")
        reconciler.reconcile([])
        self.assertEqual(reconciler.port_health()[0].state, "absent")

        driver.persistent_unhealthy.add(current.port_id)
        driver.unhealthy.add(current.port_id)
        reconciler.reconcile([current])
        health = reconciler.port_health()[0]
        self.assertEqual(health.state, "degraded")
        self.assertEqual(health.reason, "attach_unhealthy")

    def test_failed_attach_becomes_absent_when_binding_leaves_host(self):
        driver = FakeDriver()
        current = binding()
        driver.fail_attach.add(current.port_id)
        reconciler = Reconciler(driver)

        reconciler.reconcile([current])
        self.assertEqual(reconciler.port_health()[0].state, "degraded")
        self.assertIn("attach_failed", reconciler.port_health()[0].reason)

        reconciler.reconcile([])
        health = reconciler.port_health()[0]
        self.assertEqual(health.state, "absent")
        self.assertEqual(health.reason, "binding_left_host")

    def test_failed_attach_stays_degraded_until_cleanup_is_confirmed(self):
        driver = FakeDriver()
        current = binding()
        driver.fail_attach.add(current.port_id)
        driver.fail_detach.add(current.port_id)
        reconciler = Reconciler(driver)

        reconciler.reconcile([current])
        cleanup_failed = reconciler.reconcile([])

        self.assertEqual(cleanup_failed[0].action, "error")
        self.assertIn("cleanup_failed", cleanup_failed[0].reason)
        self.assertEqual(reconciler.port_health()[0].state, "degraded")

        driver.fail_detach.clear()
        cleaned = reconciler.reconcile([])
        self.assertEqual(cleaned[0].action, "cleanup")
        self.assertEqual(reconciler.port_health()[0].state, "absent")

    def test_cleanup_debt_is_cleared_before_retrying_attach(self):
        driver = FakeDriver()
        current = binding()
        driver.fail_attach.add(current.port_id)
        reconciler = Reconciler(driver)

        reconciler.reconcile([current])
        driver.fail_attach.clear()
        recovered = reconciler.reconcile([current])

        self.assertEqual(
            [event.action for event in recovered],
            ["cleanup", "attach"],
        )
        self.assertEqual(reconciler.port_health()[0].state, "healthy")
        self.assertEqual(
            [action[0] for action in driver.actions],
            ["detach", "attach"],
        )


class StateSnapshotTest(unittest.TestCase):
    def test_state_includes_global_inventory_with_revision_and_binding(self):
        driver = FakeDriver()
        reconciler = Reconciler(driver)
        reconciler.reconcile([binding(), observer_binding()])
        inventory = [
            PortInventory(
                server_id="server-1",
                port_id=binding().port_id,
                status="ACTIVE",
                binding_host="master",
                vif_type="ovs",
                revision_number=17,
            ),
            PortInventory(
                server_id="server-2",
                port_id=observer_binding().port_id,
                status="ACTIVE",
                binding_host="master",
                vif_type="ovs",
                revision_number=9,
            ),
        ]
        endpoint_configs = (
            EndpointConfig(
                server_id="server-1",
                accel_role="client",
                grpc_observe_port=50052,
                guest_grpc_listen_port=50053,
                port_ids=(binding().port_id,),
                trusted_dns=("10.0.0.53",),
            ),
            EndpointConfig(
                server_id="server-2",
                accel_role="observer",
                grpc_observe_port=50052,
                guest_grpc_listen_port=50052,
                port_ids=(observer_binding().port_id,),
            ),
        )

        with tempfile.TemporaryDirectory() as temp:
            state_file = Path(temp) / "state.json"
            _write_state(
                state_file,
                ["server-1", "server-2"],
                "master",
                reconciler,
                driver,
                endpoint_configs,
                sample_completed_ms=123456,
                port_inventory=inventory,
            )
            state = json.loads(state_file.read_text(encoding="utf-8"))

        self.assertEqual(state["schema_version"], 3)
        self.assertEqual(state["updated_ms"], 123456)
        self.assertEqual(
            state["snapshot_consistency"],
            {"status": "consistent", "error": None},
        )
        self.assertEqual(
            state["endpoint_config"],
            [
                {
                    "server_id": "server-1",
                    "port_ids": [binding().port_id],
                    "accel_role": "client",
                    "grpc_observe_port": 50052,
                    "guest_grpc_listen_port": 50053,
                    "trusted_dns": ["10.0.0.53"],
                },
                {
                    "server_id": "server-2",
                    "port_ids": [observer_binding().port_id],
                    "accel_role": "observer",
                    "grpc_observe_port": 50052,
                    "guest_grpc_listen_port": 50052,
                },
            ],
        )
        self.assertEqual(
            state["dns_capabilities"],
            {
                "server-1": "xdp_client_cache",
                "server-2": "tc_observability",
            },
        )
        self.assertEqual(state["grpc_capability"], "tc_observability")
        self.assertEqual(state["bindings"][0]["accel_role"], "client")
        self.assertEqual(state["bindings"][0]["grpc_observe_port"], 50052)
        self.assertEqual(
            state["bindings"][0]["guest_grpc_listen_port"], 50053
        )
        self.assertEqual(
            state["bindings"][0]["dns_capability"], "xdp_client_cache"
        )
        self.assertEqual(state["bindings"][1]["accel_role"], "observer")
        self.assertEqual(state["bindings"][1]["grpc_observe_port"], 50052)
        self.assertEqual(
            state["bindings"][1]["guest_grpc_listen_port"], 50052
        )
        self.assertEqual(
            state["bindings"][1]["dns_capability"], "tc_observability"
        )
        self.assertEqual(state["port_health"][0]["accel_role"], "client")
        self.assertEqual(
            state["port_health"][0]["grpc_observe_port"], 50052
        )
        self.assertEqual(
            state["port_health"][0]["guest_grpc_listen_port"], 50053
        )
        self.assertEqual(
            state["port_health"][1]["accel_role"], "observer"
        )
        self.assertEqual(
            state["port_health"][1]["grpc_observe_port"], 50052
        )
        self.assertEqual(
            state["port_health"][1]["guest_grpc_listen_port"], 50052
        )
        self.assertEqual(
            state["health"]["accel_roles"],
            {"server-1": "client", "server-2": "observer"},
        )
        self.assertEqual(
            state["health"]["grpc_observe_ports"],
            {"server-1": 50052, "server-2": 50052},
        )
        self.assertEqual(
            state["health"]["guest_grpc_listen_ports"],
            {"server-1": 50053, "server-2": 50052},
        )
        self.assertEqual(
            state["health"]["dns_capabilities"],
            {
                "server-1": "xdp_client_cache",
                "server-2": "tc_observability",
            },
        )
        self.assertEqual(state["port_inventory"], [
            {
                "server_id": item.server_id,
                "port_id": item.port_id,
                "status": item.status,
                "binding_host": item.binding_host,
                "vif_type": item.vif_type,
                "revision_number": item.revision_number,
            }
            for item in inventory
        ])

    def test_inconsistent_snapshot_is_degraded_without_refreshing_or_bindings(self):
        driver = FakeDriver()
        reconciler = Reconciler(driver)
        reconciler.reconcile([binding()])
        endpoint_configs = (
            EndpointConfig(
                server_id="server-1",
                accel_role="client",
                grpc_observe_port=50052,
                guest_grpc_listen_port=50053,
                port_ids=(binding().port_id,),
                trusted_dns=("10.0.0.53",),
            ),
        )

        with tempfile.TemporaryDirectory() as temp:
            state_file = Path(temp) / "state.json"
            with patch(
                "agent.openstack_dataplane_agent.time.time",
                return_value=999999.0,
            ):
                _write_state(
                    state_file,
                    ["server-1"],
                    "master",
                    reconciler,
                    driver,
                    endpoint_configs,
                    sample_completed_ms=123456,
                    port_inventory=discovery_result(
                        revision_number=8
                    ).port_inventory,
                    snapshot_error=(
                        "snapshot_revalidation_changed:"
                        "Neutron revision changed"
                    ),
                )
            state = json.loads(state_file.read_text(encoding="utf-8"))

        self.assertEqual(state["updated_ms"], 123456)
        self.assertEqual(state["bindings"], [])
        self.assertEqual(state["health"]["status"], "degraded")
        self.assertEqual(
            state["snapshot_consistency"]["status"],
            "degraded",
        )
        self.assertIn(
            "Neutron revision changed",
            state["snapshot_consistency"]["error"],
        )
        self.assertEqual(state["port_health"][0]["state"], "degraded")
        self.assertIsNone(state["port_health"][0]["binding"])


class WaitReconcileCommandTest(unittest.TestCase):
    def _run_wait(
        self,
        audit_log,
        *,
        after_offset,
        audit_device,
        audit_inode,
        action="detach",
        reason="binding_left_host",
        expected_host="master",
        timeout="0.08",
    ):
        module = Path(__file__).resolve().parents[1] / "agent" / (
            "openstack_dataplane_agent.py"
        )
        return subprocess.run(
            [
                sys.executable,
                str(module),
                "wait-reconcile",
                "--audit-log",
                str(audit_log),
                "--after-offset",
                str(after_offset),
                "--audit-device",
                str(audit_device),
                "--audit-inode",
                str(audit_inode),
                "--port-id",
                binding().port_id,
                "--server-id",
                binding().server_id,
                "--action",
                action,
                "--reason",
                reason,
                "--expected-host",
                expected_host,
                "--timeout",
                timeout,
                "--interval",
                "0.01",
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_wait_reconcile_matches_source_detach_after_exact_offset(self):
        with tempfile.TemporaryDirectory() as temp:
            audit = Path(temp) / "agent-audit.jsonl"
            audit.write_bytes(b'{"event":"agent_started"}\n')
            identity = audit.stat()
            after_offset = identity.st_size
            expected_binding = {
                "server_id": binding().server_id,
                "port_id": binding().port_id,
                "host": "master",
                "interface": "tapport",
                "ifindex": 14,
            }
            record = {
                "event": "reconcile",
                "action": "detach",
                "port_id": binding().port_id,
                "reason": "binding_left_host",
                "binding": expected_binding,
            }
            with audit.open("ab") as output:
                output.write(
                    json.dumps(record, separators=(",", ":")).encode("utf-8")
                    + b"\n"
                )
            matched_end = audit.stat().st_size

            result = self._run_wait(
                audit,
                after_offset=after_offset,
                audit_device=identity.st_dev,
                audit_inode=identity.st_ino,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            {
                "ready": True,
                "matched_byte_start": after_offset,
                "matched_byte_end": matched_end,
                "binding": expected_binding,
            },
        )

    def test_wait_reconcile_matches_target_attach(self):
        with tempfile.TemporaryDirectory() as temp:
            audit = Path(temp) / "agent-audit.jsonl"
            audit.touch()
            identity = audit.stat()
            expected_binding = {
                "server_id": binding().server_id,
                "port_id": binding().port_id,
                "host": "compute2",
                "interface": "tap-target",
                "ifindex": 27,
            }
            audit.write_text(
                json.dumps(
                    {
                        "event": "reconcile",
                        "action": "attach",
                        "port_id": binding().port_id,
                        "reason": "binding_local",
                        "binding": expected_binding,
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            result = self._run_wait(
                audit,
                after_offset=0,
                audit_device=identity.st_dev,
                audit_inode=identity.st_ino,
                action="attach",
                reason="binding_local",
                expected_host="compute2",
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["binding"], expected_binding)

    def test_wait_reconcile_rejects_audit_identity_change(self):
        with tempfile.TemporaryDirectory() as temp:
            audit = Path(temp) / "agent-audit.jsonl"
            audit.touch()
            identity = audit.stat()

            result = self._run_wait(
                audit,
                after_offset=0,
                audit_device=identity.st_dev,
                audit_inode=identity.st_ino + 1,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("audit log identity changed", result.stderr)

    def test_wait_reconcile_rejects_truncation_below_offset(self):
        with tempfile.TemporaryDirectory() as temp:
            audit = Path(temp) / "agent-audit.jsonl"
            audit.write_bytes(b"{}\n")
            identity = audit.stat()

            result = self._run_wait(
                audit,
                after_offset=identity.st_size + 1,
                audit_device=identity.st_dev,
                audit_inode=identity.st_ino,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("truncated below after-offset", result.stderr)

    def test_wait_reconcile_rejects_complete_malformed_json(self):
        with tempfile.TemporaryDirectory() as temp:
            audit = Path(temp) / "agent-audit.jsonl"
            audit.write_bytes(b"not-json\n")
            identity = audit.stat()

            result = self._run_wait(
                audit,
                after_offset=0,
                audit_device=identity.st_dev,
                audit_inode=identity.st_ino,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid JSON after offset 0", result.stderr)

    def test_wait_reconcile_does_not_accept_an_invalid_binding(self):
        with tempfile.TemporaryDirectory() as temp:
            audit = Path(temp) / "agent-audit.jsonl"
            audit.touch()
            identity = audit.stat()
            audit.write_text(
                json.dumps(
                    {
                        "event": "reconcile",
                        "action": "detach",
                        "port_id": binding().port_id,
                        "reason": "binding_left_host",
                        "binding": {
                            "server_id": binding().server_id,
                            "port_id": binding().port_id,
                            "host": "master",
                            "interface": "tapport",
                            "ifindex": "14",
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            result = self._run_wait(
                audit,
                after_offset=0,
                audit_device=identity.st_dev,
                audit_inode=identity.st_ino,
                timeout="0.03",
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("audit_has_no_matching_reconcile", result.stderr)

    def test_wait_reconcile_rejects_an_action_reason_mismatch(self):
        with tempfile.TemporaryDirectory() as temp:
            audit = Path(temp) / "agent-audit.jsonl"
            audit.touch()
            identity = audit.stat()

            result = self._run_wait(
                audit,
                after_offset=0,
                audit_device=identity.st_dev,
                audit_inode=identity.st_ino,
                action="detach",
                reason="binding_local",
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "detach requires reason binding_left_host",
            result.stderr,
        )


class HealthCommandTest(unittest.TestCase):
    def test_health_requires_fresh_healthy_binding_for_requested_server(self):
        with tempfile.TemporaryDirectory() as temp:
            state_file = Path(temp) / "state.json"
            state_file.write_text(
                json.dumps(healthy_state(int(time.time() * 1000))),
                encoding="utf-8",
            )
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                status = _health(
                    argparse.Namespace(
                        state_file=state_file,
                        server_id=["server-1"],
                        max_age_seconds=10.0,
                    )
                )
            self.assertEqual(status, 0)
            result = json.loads(output.getvalue())
            self.assertTrue(result["ready"])
            self.assertEqual(
                result["endpoint_config"][0]["accel_role"], "client"
            )
            self.assertEqual(
                result["endpoint_config"][0]["grpc_observe_port"], 50052
            )
            self.assertEqual(
                result["endpoint_config"][0]["guest_grpc_listen_port"],
                50053,
            )
            self.assertNotIn("grpc_port", result["endpoint_config"][0])
            self.assertEqual(result["grpc_capability"], "tc_observability")

            with contextlib.redirect_stdout(io.StringIO()):
                status = _health(
                    argparse.Namespace(
                        state_file=state_file,
                        server_id=["server-2"],
                        max_age_seconds=10.0,
                    )
                )
            self.assertEqual(status, 2)

    def test_health_rejects_fresh_but_inconsistent_snapshot(self):
        state = healthy_state(int(time.time() * 1000))
        state["snapshot_consistency"] = {
            "status": "degraded",
            "error": "snapshot_revalidation_changed:revision changed",
        }
        with tempfile.TemporaryDirectory() as temp:
            state_file = Path(temp) / "state.json"
            state_file.write_text(json.dumps(state), encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                status = _health(
                    argparse.Namespace(
                        state_file=state_file,
                        server_id=["server-1"],
                        server_id_file=None,
                        max_age_seconds=10.0,
                    )
                )

        self.assertEqual(status, 2)
        self.assertFalse(json.loads(output.getvalue())["ready"])

    def test_health_accepts_healthy_client_and_observer_endpoints(self):
        with tempfile.TemporaryDirectory() as temp:
            state_file = Path(temp) / "state.json"
            state_file.write_text(
                json.dumps(
                    healthy_client_observer_state(int(time.time() * 1000))
                ),
                encoding="utf-8",
            )
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                status = _health(
                    argparse.Namespace(
                        state_file=state_file,
                        server_id=["server-1", "server-2"],
                        server_id_file=None,
                        max_age_seconds=10.0,
                    )
                )

        result = json.loads(output.getvalue())
        self.assertEqual(status, 0)
        self.assertTrue(result["ready"])
        self.assertEqual(
            result["dns_capabilities"],
            {
                "server-1": "xdp_client_cache",
                "server-2": "tc_observability",
            },
        )
        self.assertEqual(
            [item["accel_role"] for item in result["endpoint_config"]],
            ["client", "observer"],
        )

    def test_default_health_requires_every_configured_endpoint(self):
        state = healthy_client_observer_state(int(time.time() * 1000))
        state["port_health"][1]["state"] = "absent"
        state["port_health"][1]["binding"] = None
        with tempfile.TemporaryDirectory() as temp:
            state_file = Path(temp) / "state.json"
            state_file.write_text(json.dumps(state), encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                status = _health(
                    argparse.Namespace(
                        state_file=state_file,
                        server_id=None,
                        server_id_file=None,
                        max_age_seconds=10.0,
                    )
                )

        result = json.loads(output.getvalue())
        self.assertEqual(status, 2)
        self.assertFalse(result["ready"])
        self.assertEqual(result["missing_server_ids"], ["server-2"])

    def test_health_rejects_state_too_far_in_the_future(self):
        with tempfile.TemporaryDirectory() as temp:
            state_file = Path(temp) / "state.json"
            state_file.write_text(
                json.dumps(healthy_state(1_010_001)),
                encoding="utf-8",
            )
            output = io.StringIO()
            with (
                patch(
                    "agent.openstack_dataplane_agent.time.time",
                    return_value=1_000.0,
                ),
                contextlib.redirect_stdout(output),
            ):
                status = _health(
                    argparse.Namespace(
                        state_file=state_file,
                        server_id=None,
                        server_id_file=None,
                        max_age_seconds=10.0,
                    )
                )

        result = json.loads(output.getvalue())
        self.assertEqual(status, 2)
        self.assertFalse(result["ready"])
        self.assertTrue(result["future_timestamp"])
        self.assertEqual(result["future_ms"], 10_001)

    def test_health_rejects_role_or_port_drift_from_endpoint_config(self):
        cases = {
            "missing role": ("accel_role", None),
            "wrong role": ("accel_role", "server"),
            "wrong observe port": ("grpc_observe_port", 50051),
            "wrong guest listen port": ("guest_grpc_listen_port", 50052),
            "wrong DNS capability": ("dns_capability", "tc_observability"),
        }
        with tempfile.TemporaryDirectory() as temp:
            state_file = Path(temp) / "state.json"
            for name, (field, value) in cases.items():
                state = healthy_state(int(time.time() * 1000))
                if value is None:
                    del state["port_health"][0][field]
                else:
                    state["port_health"][0][field] = value
                state_file.write_text(json.dumps(state), encoding="utf-8")
                with (
                    self.subTest(name=name),
                    self.assertRaises(AgentError),
                    contextlib.redirect_stdout(io.StringIO()),
                ):
                    _health(
                        argparse.Namespace(
                            state_file=state_file,
                            server_id=None,
                            server_id_file=None,
                            max_age_seconds=10.0,
                        )
                    )

    def test_health_rejects_observe_or_guest_listen_port_map_drift(self):
        cases = {
            "observe map": ("grpc_observe_ports", 50051),
            "guest listen map": ("guest_grpc_listen_ports", 50052),
        }
        with tempfile.TemporaryDirectory() as temp:
            state_file = Path(temp) / "state.json"
            for name, (field, value) in cases.items():
                state = healthy_state(int(time.time() * 1000))
                state["health"][field]["server-1"] = value
                state_file.write_text(json.dumps(state), encoding="utf-8")
                with (
                    self.subTest(name=name),
                    self.assertRaisesRegex(AgentError, field),
                    contextlib.redirect_stdout(io.StringIO()),
                ):
                    _health(
                        argparse.Namespace(
                            state_file=state_file,
                            server_id=None,
                            server_id_file=None,
                            max_age_seconds=10.0,
                        )
                    )

    def test_health_strictly_rejects_legacy_grpc_port_fields(self):
        with tempfile.TemporaryDirectory() as temp:
            state_file = Path(temp) / "state.json"
            for field in ("grpc_port", "grpc_ports"):
                state = healthy_state(int(time.time() * 1000))
                state["health"][field] = {"server-1": 50053}
                state_file.write_text(json.dumps(state), encoding="utf-8")
                with (
                    self.subTest(field=field),
                    self.assertRaisesRegex(
                        AgentError,
                        f"legacy field {field}",
                    ),
                    contextlib.redirect_stdout(io.StringIO()),
                ):
                    _health(
                        argparse.Namespace(
                            state_file=state_file,
                            server_id=None,
                            server_id_file=None,
                            max_age_seconds=10.0,
                        )
                    )


class ServerIdConfigTest(unittest.TestCase):
    def test_server_ids_can_be_combined_with_a_commentable_file(self):
        with tempfile.TemporaryDirectory() as temp:
            server_file = Path(temp) / "servers"
            server_file.write_text(
                "# managed instances\nserver-2\nserver-1\n",
                encoding="utf-8",
            )
            self.assertEqual(
                _configured_server_ids(
                    argparse.Namespace(
                        server_id=["server-1"],
                        server_id_file=server_file,
                    )
                ),
                ["server-1", "server-2"],
            )


class EndpointConfigTest(unittest.TestCase):
    def _load(self, root, value):
        path = root / "endpoints.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        return _load_endpoint_configs(path)

    def test_port_ids_are_required_canonical_and_unique(self):
        port_id = binding().port_id
        valid = {
            "server_id": "client-vm",
            "port_ids": [port_id],
            "accel_role": "client",
            "grpc_observe_port": 50052,
            "guest_grpc_listen_port": 50053,
            "trusted_dns": ["10.0.0.53"],
        }
        cases = {
            "missing": (
                {key: value for key, value in valid.items() if key != "port_ids"},
                "port_ids must be a non-empty",
            ),
            "empty": ({**valid, "port_ids": []}, "port_ids must be a non-empty"),
            "duplicate": (
                {**valid, "port_ids": [port_id, port_id]},
                "duplicate port ID",
            ),
            "non-canonical": (
                {**valid, "port_ids": [port_id.upper()]},
                "canonical UUID",
            ),
            "invalid": (
                {**valid, "port_ids": ["not-a-uuid"]},
                "canonical UUID",
            ),
        }
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name, (endpoint, error) in cases.items():
                with (
                    self.subTest(name=name),
                    self.assertRaisesRegex(AgentError, error),
                ):
                    self._load(
                        root,
                        {"schema_version": 2, "endpoints": [endpoint]},
                    )

            duplicate_across_endpoints = [
                valid,
                {
                    "server_id": "observer-vm",
                    "port_ids": [port_id],
                    "accel_role": "observer",
                    "grpc_observe_port": 50052,
                    "guest_grpc_listen_port": 50052,
                },
            ]
            with self.assertRaisesRegex(AgentError, "duplicate port ID"):
                self._load(
                    root,
                    {
                        "schema_version": 2,
                        "endpoints": duplicate_across_endpoints,
                    },
                )

    def test_loads_separate_observe_and_guest_listen_ports(self):
        with tempfile.TemporaryDirectory() as temp:
            configs = self._load(
                Path(temp),
                {
                    "schema_version": 2,
                    "endpoints": [
                        {
                            "server_id": "client-vm",
                            "port_ids": [binding().port_id],
                            "accel_role": "client",
                            "grpc_observe_port": 50052,
                            "guest_grpc_listen_port": 50053,
                            "trusted_dns": ["10.0.0.53", "10.0.0.54"],
                        },
                        {
                            "server_id": "backend-vm",
                            "port_ids": [observer_binding().port_id],
                            "accel_role": "observer",
                            "grpc_observe_port": 50052,
                            "guest_grpc_listen_port": 50052,
                        }
                    ],
                },
            )

        self.assertEqual(
            configs,
            (
                EndpointConfig(
                    server_id="client-vm",
                    accel_role="client",
                    grpc_observe_port=50052,
                    guest_grpc_listen_port=50053,
                    port_ids=(binding().port_id,),
                    trusted_dns=("10.0.0.53", "10.0.0.54"),
                ),
                EndpointConfig(
                    server_id="backend-vm",
                    accel_role="observer",
                    grpc_observe_port=50052,
                    guest_grpc_listen_port=50052,
                    port_ids=(observer_binding().port_id,),
                ),
            ),
        )

    def test_legacy_missing_and_invalid_grpc_port_fields_fail_closed(self):
        valid = {
            "server_id": "client-vm",
            "port_ids": [binding().port_id],
            "accel_role": "client",
            "grpc_observe_port": 50052,
            "guest_grpc_listen_port": 50053,
            "trusted_dns": ["10.0.0.53"],
        }
        cases = {
            "legacy grpc_port": (
                {**valid, "grpc_port": 50053},
                "unknown fields: grpc_port",
            ),
            "missing observe port": (
                {
                    key: value
                    for key, value in valid.items()
                    if key != "grpc_observe_port"
                },
                "grpc_observe_port must be",
            ),
            "missing guest listen port": (
                {
                    key: value
                    for key, value in valid.items()
                    if key != "guest_grpc_listen_port"
                },
                "guest_grpc_listen_port must be",
            ),
            "boolean observe port": (
                {**valid, "grpc_observe_port": True},
                "grpc_observe_port must be",
            ),
            "out-of-range guest listen port": (
                {**valid, "guest_grpc_listen_port": 65536},
                "guest_grpc_listen_port must be",
            ),
        }
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name, (endpoint, pattern) in cases.items():
                with (
                    self.subTest(name=name),
                    self.assertRaisesRegex(AgentError, pattern),
                ):
                    self._load(
                        root,
                        {
                            "schema_version": 2,
                            "endpoints": [endpoint],
                        },
                    )

    def test_missing_invalid_and_duplicate_roles_fail_closed(self):
        cases = {
            "missing role": [
                {
                    "server_id": "server-1",
                    "port_ids": [binding().port_id],
                    "grpc_observe_port": 50052,
                    "guest_grpc_listen_port": 50053,
                    "trusted_dns": ["10.0.0.53"],
                }
            ],
            "invalid role": [
                {
                    "server_id": "server-1",
                    "port_ids": [binding().port_id],
                    "accel_role": "dual",
                    "grpc_observe_port": 50052,
                    "guest_grpc_listen_port": 50053,
                    "trusted_dns": ["10.0.0.53"],
                }
            ],
            "duplicate server": [
                {
                    "server_id": "server-1",
                    "port_ids": [binding().port_id],
                    "accel_role": "client",
                    "grpc_observe_port": 50052,
                    "guest_grpc_listen_port": 50053,
                    "trusted_dns": ["10.0.0.53"],
                },
                {
                    "server_id": "server-1",
                    "port_ids": [observer_binding().port_id],
                    "accel_role": "client",
                    "grpc_observe_port": 50052,
                    "guest_grpc_listen_port": 50054,
                    "trusted_dns": ["10.0.0.54"],
                },
            ],
        }
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name, endpoints in cases.items():
                with self.subTest(name=name), self.assertRaises(AgentError):
                    self._load(
                        root,
                        {"schema_version": 2, "endpoints": endpoints},
                    )

    def test_server_dns_role_is_rejected_on_host_vm_interface(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(AgentError, "guest-side agent"):
                self._load(
                    Path(temp),
                    {
                        "schema_version": 2,
                        "endpoints": [
                            {
                                "server_id": "backend-vm",
                                "port_ids": [observer_binding().port_id],
                                "accel_role": "server",
                                "grpc_observe_port": 50052,
                                "guest_grpc_listen_port": 50052,
                                "dns_cache_file": "/etc/vnet/cache.txt",
                            }
                        ],
                    },
                )

    def test_observer_forbids_dns_cache_configuration(self):
        cases = {
            "trusted DNS": {"trusted_dns": ["10.0.0.53"]},
            "cache file": {"dns_cache_file": "/etc/vnet/cache.txt"},
        }
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name, extra in cases.items():
                with (
                    self.subTest(name=name),
                    self.assertRaisesRegex(AgentError, "observer role forbids"),
                ):
                    self._load(
                        root,
                        {
                            "schema_version": 2,
                            "endpoints": [
                                {
                                    "server_id": "backend-vm",
                                    "port_ids": [observer_binding().port_id],
                                    "accel_role": "observer",
                                    "grpc_observe_port": 50052,
                                    "guest_grpc_listen_port": 50052,
                                    **extra,
                                }
                            ],
                        },
                    )


class DeploymentUnitTest(unittest.TestCase):
    def test_agent_unit_does_not_pass_an_empty_verbose_argument(self):
        root = Path(__file__).resolve().parents[1]
        unit = (
            root
            / "deploy"
            / "systemd"
            / "vnet-dataplane-agent.service"
        ).read_text(encoding="utf-8")

        self.assertNotIn("${VNET_VERBOSE_EVENTS}", unit)
        self.assertNotIn("Environment=VNET_VERBOSE_EVENTS=", unit)

    def test_agent_unit_allows_fail_closed_multi_port_cleanup_to_finish(self):
        root = Path(__file__).resolve().parents[1]
        unit = (
            root
            / "deploy"
            / "systemd"
            / "vnet-dataplane-agent.service"
        ).read_text(encoding="utf-8")

        self.assertIn("TimeoutStopSec=300", unit)


class WatchLifecycleTest(unittest.TestCase):
    def test_watch_returns_failure_when_stop_cleanup_leaves_an_attachment(self):
        driver = FakeDriver()
        current = binding()
        driver.fail_detach.add(current.port_id)
        endpoint = EndpointConfig(
            server_id=current.server_id,
            accel_role="client",
            grpc_observe_port=50052,
            guest_grpc_listen_port=50053,
            port_ids=(current.port_id,),
            trusted_dns=("10.0.0.53",),
        )
        sample = argparse.Namespace(
            result=discovery_result(),
            completed_ms=1_000,
        )
        args = argparse.Namespace(
            interval=0.001,
            policy_lock_root=Path("/run/vnet-dataplane-policy"),
            endpoint_config=Path("/unused/endpoints.json"),
            local_host="master",
            dns_monitor=Path("/unused/dns-monitor"),
            dns_client_bpf=Path("/unused/dns-client.bpf.o"),
            dns_tc_bpf=Path("/unused/dns-tc.bpf.o"),
            grpc_monitor=Path("/unused/grpc-monitor"),
            grpc_bpf=Path("/unused/grpc.bpf.o"),
            cache_policy_txn=Path("/unused/cache-policy-txn"),
            pin_root=Path("/sys/fs/bpf/vnet-dataplane-agent"),
            log_root=Path("/var/log/vnet-dataplane-agent"),
            verbose_events=False,
            missing_grace_cycles=1,
            state_file=Path("/unused/state.json"),
            audit_log=None,
            max_cycles=1,
        )

        with (
            patch(
                "agent.openstack_dataplane_agent.os.geteuid",
                return_value=0,
                create=True,
            ),
            patch(
                "agent.openstack_dataplane_agent._load_endpoint_configs",
                return_value=(endpoint,),
            ),
            patch(
                "agent.openstack_dataplane_agent._local_host",
                return_value="master",
            ),
            patch("agent.openstack_dataplane_agent.OpenStackOvsResolver"),
            patch(
                "agent.openstack_dataplane_agent.ProcessAttachmentDriver",
                return_value=driver,
            ),
            patch(
                "agent.openstack_dataplane_agent._sample_discovery",
                return_value=sample,
            ),
            patch("agent.openstack_dataplane_agent._write_state"),
            patch("agent.openstack_dataplane_agent.signal.signal"),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            result = _watch(args)

        self.assertEqual(result, 1)
        self.assertEqual(reconciled := driver.attached, {current.port_id: current})
        self.assertIn(current.port_id, reconciled)


class ProcessAttachmentDriverTest(unittest.TestCase):
    def test_watch_requires_the_private_production_policy_root(self):
        args = argparse.Namespace(
            interval=1.0,
            policy_lock_root=Path("/tmp/not-the-production-policy-root"),
        )
        with (
            patch(
                "agent.openstack_dataplane_agent.os.geteuid",
                return_value=0,
                create=True,
            ),
            self.assertRaisesRegex(AgentError, "must be exactly"),
        ):
            _watch(args)

    @unittest.skipUnless(
        os.name != "nt" and fcntl is not None,
        "POSIX flock semantics are required",
    )
    def test_enter_quiesce_waits_for_an_inflight_policy_transaction(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)
            driver = ProcessAttachmentDriver(config)
            current = binding()
            config.policy_lock_root.mkdir(mode=0o700, parents=True)
            lock_path = driver._policy_lock_path(current.port_id)
            lock_descriptor = os.open(
                lock_path,
                os.O_RDWR | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            os.fchmod(lock_descriptor, 0o600)
            real_flock = fcntl.flock
            real_flock(lock_descriptor, fcntl.LOCK_EX)
            waiter_blocking = threading.Event()
            finished = threading.Event()
            errors = []

            def observed_flock(descriptor, operation):
                if operation == fcntl.LOCK_EX:
                    waiter_blocking.set()
                return real_flock(descriptor, operation)

            def enter() -> None:
                try:
                    driver._enter_quiesce(current.port_id)
                except Exception as error:
                    errors.append(error)
                finally:
                    finished.set()

            worker = threading.Thread(target=enter)
            with patch(
                "agent.openstack_dataplane_agent.fcntl.flock",
                side_effect=observed_flock,
            ):
                worker.start()
                try:
                    self.assertTrue(waiter_blocking.wait(1.0))
                    self.assertFalse(finished.wait(0.1))
                finally:
                    real_flock(lock_descriptor, fcntl.LOCK_UN)
                    os.close(lock_descriptor)
                    worker.join(1.0)

            self.assertFalse(worker.is_alive())
            self.assertEqual(errors, [])
            self.assertTrue(
                driver._policy_quiesce_path(current.port_id).exists()
            )
            driver._leave_quiesce(current.port_id)

    @unittest.skipUnless(
        os.name != "nt" and fcntl is not None,
        "POSIX flock semantics are required",
    )
    def test_leave_quiesce_waits_for_an_inflight_policy_transaction(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)
            driver = ProcessAttachmentDriver(config)
            current = binding()
            driver._enter_quiesce(current.port_id)
            lock_descriptor = os.open(
                driver._policy_lock_path(current.port_id),
                os.O_RDWR,
            )
            real_flock = fcntl.flock
            real_flock(lock_descriptor, fcntl.LOCK_EX)
            waiter_blocking = threading.Event()
            finished = threading.Event()
            errors = []

            def observed_flock(descriptor, operation):
                if operation == fcntl.LOCK_EX:
                    waiter_blocking.set()
                return real_flock(descriptor, operation)

            def leave() -> None:
                try:
                    driver._leave_quiesce(current.port_id)
                except Exception as error:
                    errors.append(error)
                finally:
                    finished.set()

            worker = threading.Thread(target=leave)
            with patch(
                "agent.openstack_dataplane_agent.fcntl.flock",
                side_effect=observed_flock,
            ):
                worker.start()
                try:
                    self.assertTrue(waiter_blocking.wait(1.0))
                    self.assertFalse(finished.wait(0.1))
                finally:
                    real_flock(lock_descriptor, fcntl.LOCK_UN)
                    os.close(lock_descriptor)
                    worker.join(1.0)

            self.assertFalse(worker.is_alive())
            self.assertEqual(errors, [])
            self.assertFalse(
                driver._policy_quiesce_path(current.port_id).exists()
            )

    @unittest.skipUnless(os.name != "nt", "symlink test requires POSIX")
    def test_enter_quiesce_rejects_a_policy_lock_symlink(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)
            driver = ProcessAttachmentDriver(config)
            current = binding()
            config.policy_lock_root.mkdir(mode=0o700, parents=True)
            target = config.policy_lock_root / "target.lock"
            target.write_text("unchanged", encoding="utf-8")
            target.chmod(0o600)
            lock_path = driver._policy_lock_path(current.port_id)
            lock_path.symlink_to(target.name)

            with self.assertRaisesRegex(
                AgentError, "policy lock acquisition failed"
            ):
                driver._enter_quiesce(current.port_id)

            self.assertEqual(target.read_text(encoding="utf-8"), "unchanged")
            self.assertTrue(lock_path.is_symlink())
            self.assertFalse(
                driver._policy_quiesce_path(current.port_id).exists()
            )

    @unittest.skipUnless(
        os.name != "nt" and fcntl is not None,
        "POSIX flock semantics are required",
    )
    def test_policy_lock_inode_swap_is_rejected_after_flock(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)
            driver = ProcessAttachmentDriver(config)
            current = binding()
            config.policy_lock_root.mkdir(mode=0o700, parents=True)
            lock_path = driver._policy_lock_path(current.port_id)
            lock_descriptor = os.open(
                lock_path,
                os.O_RDWR | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            os.fchmod(lock_descriptor, 0o600)
            real_flock = fcntl.flock
            real_flock(lock_descriptor, fcntl.LOCK_EX)
            waiter_opened = threading.Event()
            finished = threading.Event()
            errors = []

            def observed_flock(descriptor, operation):
                if operation == fcntl.LOCK_EX:
                    waiter_opened.set()
                return real_flock(descriptor, operation)

            def enter() -> None:
                try:
                    driver._enter_quiesce(current.port_id)
                except Exception as error:
                    errors.append(error)
                finally:
                    finished.set()

            worker = threading.Thread(target=enter)
            with patch(
                "agent.openstack_dataplane_agent.fcntl.flock",
                side_effect=observed_flock,
            ):
                worker.start()
                try:
                    self.assertTrue(waiter_opened.wait(1.0))
                    moved_lock = config.policy_lock_root / "old.lock"
                    os.replace(lock_path, moved_lock)
                    replacement_descriptor = os.open(
                        lock_path,
                        os.O_RDWR | os.O_CREAT | os.O_EXCL,
                        0o600,
                    )
                    os.fchmod(replacement_descriptor, 0o600)
                    os.close(replacement_descriptor)
                finally:
                    real_flock(lock_descriptor, fcntl.LOCK_UN)
                    os.close(lock_descriptor)
                    worker.join(1.0)

            self.assertFalse(worker.is_alive())
            self.assertTrue(finished.is_set())
            self.assertEqual(len(errors), 1)
            self.assertIsInstance(errors[0], AgentError)
            self.assertIn("policy lock changed during acquisition", str(errors[0]))
            self.assertFalse(
                driver._policy_quiesce_path(current.port_id).exists()
            )

    @unittest.skipUnless(os.name != "nt", "symlink test requires POSIX")
    def test_enter_quiesce_rejects_a_symlink_without_following_it(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)
            driver = ProcessAttachmentDriver(config)
            current = binding()
            config.policy_lock_root.mkdir(mode=0o700, parents=True)
            target = root / "target"
            target.write_text("unchanged", encoding="utf-8")
            path = driver._policy_quiesce_path(current.port_id)
            path.symlink_to(target)

            with self.assertRaisesRegex(AgentError, "regular file"):
                driver._enter_quiesce(current.port_id)

            self.assertEqual(target.read_text(encoding="utf-8"), "unchanged")
            self.assertTrue(path.is_symlink())

    def test_leave_quiesce_validates_identity_before_rename(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)
            driver = ProcessAttachmentDriver(config)
            current = binding()
            driver._enter_quiesce(current.port_id)
            path = driver._policy_quiesce_path(current.port_id)
            replacement = root / "replacement"
            replacement.write_bytes(b"")
            if os.name != "nt":
                replacement.chmod(0o600)
            os.replace(replacement, path)

            with (
                patch("agent.openstack_dataplane_agent.os.replace") as replace_file,
                self.assertRaisesRegex(AgentError, "replaced"),
            ):
                driver._leave_quiesce(current.port_id)
            replace_file.assert_not_called()

            descriptor = driver._quiesce_fds.pop(current.port_id, None)
            if descriptor is not None:
                os.close(descriptor)
            driver._quiesce_identities.pop(current.port_id, None)

    def test_extracts_xdp_program_id_from_detailed_ip_json(self):
        self.assertEqual(
            _extract_xdp_program_id(
                {
                    "ifname": "tapport",
                    "xdp": {
                        "mode": 2,
                        "prog": {"id": 101, "tag": "abc"},
                    },
                }
            ),
            101,
        )
        self.assertEqual(
            _extract_xdp_program_id({"ifname": "tapport"}),
            0,
        )

    def test_rejects_ambiguous_xdp_program_ids(self):
        with self.assertRaisesRegex(AgentError, "ambiguous XDP"):
            _extract_xdp_program_id(
                {
                    "xdp": {
                        "drv": {"id": 101},
                        "skb": {"id": 102},
                    }
                }
            )

    def test_extracts_tc_program_ids_by_priority_and_handle(self):
        value = [
            {
                "protocol": "all",
                "pref": 1,
                "kind": "bpf",
                "chain": 0,
                "options": {
                    "handle": "0x1",
                    "bpf": {"id": 102},
                },
            },
            {
                "protocol": "all",
                "pref": 1,
                "kind": "bpf",
                "chain": 0,
                "options": {
                    "handle": "0x2",
                    "id": 201,
                },
            },
            {
                "protocol": "all",
                "pref": 9,
                "kind": "bpf",
                "chain": 0,
                "options": {
                    "handle": "0x1",
                    "id": 999,
                },
            },
        ]

        self.assertEqual(
            _extract_tc_program_ids(
                value,
                priority=1,
                handles=(1, 2),
            ),
            {1: 102, 2: 201},
        )

    def test_extracts_tc_program_id_from_iproute2_prog_object(self):
        value = [
            {
                "protocol": "all",
                "pref": 1,
                "kind": "bpf",
                "chain": 0,
                "options": {
                    "handle": "0x2",
                    "bpf_name": "grpc_ingress:[1668]",
                    "direct-action": True,
                    "prog": {
                        "id": 1668,
                        "name": "grpc_ingress",
                        "tag": "54fa36229f341c30",
                        "jited": 1,
                    },
                },
            }
        ]

        self.assertEqual(
            _extract_tc_program_ids(
                value,
                priority=1,
                handles=(1, 2),
            ),
            {1: 0, 2: 1668},
        )

    def test_rejects_unverifiable_target_tc_slot(self):
        with self.assertRaisesRegex(AgentError, "is not BPF"):
            _extract_tc_program_ids(
                [
                    {
                        "protocol": "all",
                        "pref": 1,
                        "kind": "flower",
                        "chain": 0,
                        "options": {"handle": "0x1"},
                    }
                ],
                priority=1,
                handles=(1, 2),
            )
        with self.assertRaisesRegex(AgentError, "no unique program ID"):
            _extract_tc_program_ids(
                [
                    {
                        "protocol": "all",
                        "pref": 1,
                        "kind": "bpf",
                        "chain": 0,
                        "options": {
                            "handle": "0x1",
                            "id": 102,
                            "bpf": {"id": 103},
                        },
                    }
                ],
                priority=1,
                handles=(1, 2),
            )

    def test_tc_program_ids_require_default_chain_and_all_protocol(self):
        value = [
            {
                "protocol": "all",
                "pref": 1,
                "kind": "bpf",
                "chain": 1,
                "options": {"handle": "0x1", "id": 901},
            },
            {
                "protocol": "ip",
                "pref": 1,
                "kind": "bpf",
                "chain": 0,
                "options": {"handle": "0x2", "id": 902},
            },
            {
                "protocol": "all",
                "pref": 1,
                "kind": "bpf",
                "chain": 0,
                "options": {"handle": "0x1", "id": 102},
            },
        ]

        self.assertEqual(
            _extract_tc_program_ids(
                value,
                priority=1,
                handles=(1, 2),
            ),
            {1: 102, 2: 0},
        )

    def test_current_programs_queries_xdp_and_both_tc_directions(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = replace(
                attachment_config(root),
                ip_command="/opt/ip",
                tc_command="/opt/tc",
            )

            def tc_rows(dns_id, grpc_id):
                return [
                    {
                        "protocol": "all",
                        "pref": 1,
                        "kind": "bpf",
                        "chain": 0,
                        "options": {"handle": "0x1", "id": dns_id},
                    },
                    {
                        "protocol": "all",
                        "pref": 1,
                        "kind": "bpf",
                        "chain": 0,
                        "options": {"handle": "0x2", "id": grpc_id},
                    },
                ]

            runner = FakeRunner(
                {
                    (
                        "/opt/ip",
                        "-j",
                        "-details",
                        "link",
                        "show",
                        "dev",
                        "tapport",
                    ): [{"ifname": "tapport", "xdp": {"id": 101}}],
                    (
                        "/opt/tc",
                        "-j",
                        "filter",
                        "show",
                        "dev",
                        "tapport",
                        "ingress",
                    ): tc_rows(102, 201),
                    (
                        "/opt/tc",
                        "-j",
                        "filter",
                        "show",
                        "dev",
                        "tapport",
                        "egress",
                    ): tc_rows(103, 202),
                }
            )
            driver = ProcessAttachmentDriver(config, runner)

            self.assertEqual(
                driver._current_programs(binding()),
                hook_programs(dns_tc_egress=103),
            )

    def test_rejects_non_positive_attach_ready_timeout(self):
        with tempfile.TemporaryDirectory() as temp:
            config = replace(
                attachment_config(Path(temp)),
                attach_ready_timeout_seconds=0,
            )
            with self.assertRaisesRegex(
                AgentError,
                "attach ready timeout seconds must be positive",
            ):
                ProcessAttachmentDriver(config)

    def test_readiness_polls_until_pins_and_owned_programs_exist(self):
        with tempfile.TemporaryDirectory() as temp:
            driver = ProcessAttachmentDriver(
                attachment_config(Path(temp))
            )
            current = binding()
            dns_process = FakeProcess("dns")
            grpc_process = FakeProcess("grpc")
            programs = hook_programs()

            def process_program_ids(process):
                if process.name == "dns":
                    return {101, 102}
                return {201, 202}

            with (
                patch.object(
                    driver,
                    "_missing_pins",
                    side_effect=[["not-ready"], []],
                ) as missing_pins,
                patch.object(
                    driver,
                    "_current_programs",
                    return_value=programs,
                ),
                patch.object(
                    driver,
                    "_process_program_ids",
                    side_effect=process_program_ids,
                ),
                patch(
                    "agent.openstack_dataplane_agent.time.monotonic",
                    side_effect=[0.0, 0.01],
                ),
                patch(
                    "agent.openstack_dataplane_agent.time.sleep"
                ) as sleep,
            ):
                ready = driver._wait_attachment_ready(
                    current,
                    dns_process,
                    grpc_process,
                )

            self.assertEqual(ready, programs)
            self.assertEqual(missing_pins.call_count, 2)
            sleep.assert_called_once_with(0.05)

    def test_readiness_times_out_at_configured_deadline(self):
        with tempfile.TemporaryDirectory() as temp:
            config = replace(
                attachment_config(Path(temp)),
                attach_ready_timeout_seconds=0.1,
            )
            driver = ProcessAttachmentDriver(config)

            with (
                patch.object(
                    driver,
                    "_missing_pins",
                    return_value=["still-missing"],
                ),
                patch(
                    "agent.openstack_dataplane_agent.time.monotonic",
                    side_effect=[0.0, 0.04, 0.1],
                ),
                patch(
                    "agent.openstack_dataplane_agent.time.sleep"
                ) as sleep,
                self.assertRaisesRegex(
                    AgentError,
                    "attachment readiness timed out.*still-missing",
                ),
            ):
                driver._wait_attachment_ready(
                    binding(),
                    FakeProcess("dns"),
                    FakeProcess("grpc"),
                )

            sleep.assert_called_once_with(0.05)

    def test_attach_timeout_stops_processes_and_removes_owned_pins(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            driver = ProcessAttachmentDriver(attachment_config(root))
            current = binding()
            processes = iter((FakeProcess("dns"), FakeProcess("grpc")))
            stopped = []
            driver._start = lambda _command, _path: next(processes)
            driver._stop = lambda process: stopped.append(process.name) or True

            with (
                patch.object(driver, "_ensure_hook_slots_available"),
                patch.object(
                    driver,
                    "_wait_attachment_ready",
                    side_effect=AgentError("attachment readiness timed out"),
                ),
                self.assertRaisesRegex(
                    AgentError,
                    "attachment readiness timed out",
                ),
            ):
                driver.attach(current)

            self.assertEqual(stopped, ["grpc", "dns"])
            self.assertNotIn(current.port_id, driver._managed)
            self.assertFalse(
                driver._port_path(
                    driver._config.pin_root,
                    current.port_id,
                ).exists()
            )

    def test_preexisting_hook_slots_are_never_replaced(self):
        with tempfile.TemporaryDirectory() as temp:
            driver = ProcessAttachmentDriver(
                attachment_config(Path(temp))
            )
            occupied = replace(hook_programs(), grpc_tc_ingress=999)

            with (
                patch.object(
                    driver,
                    "_current_programs",
                    return_value=occupied,
                ),
                patch.object(driver, "_start") as start,
                self.assertRaisesRegex(
                    AgentError,
                    "refusing to replace preexisting hooks",
                ),
            ):
                driver.attach(binding())

            start.assert_not_called()

    def test_client_commands_use_role_specific_dns_and_grpc_config(self):
        with tempfile.TemporaryDirectory() as temp:
            config = attachment_config(Path(temp))
            driver = ProcessAttachmentDriver(config)
            dns_command, grpc_command = driver.commands(binding())

        self.assertEqual(
            dns_command[dns_command.index("--role") + 1], "client"
        )
        self.assertEqual(
            dns_command[dns_command.index("--bpf-object") + 1],
            str(config.dns_client_bpf),
        )
        self.assertEqual(
            dns_command[dns_command.index("--trusted-dns") + 1],
            "10.0.0.53",
        )
        self.assertNotIn("--cache-file", dns_command)
        self.assertEqual(grpc_command[grpc_command.index("--port") + 1], "50052")
        self.assertEqual(
            config.endpoint_configs[0].guest_grpc_listen_port,
            50053,
        )
        for command in (dns_command, grpc_command):
            self.assertEqual(command.count("--initial-runtime-bypass"), 1)
            self.assertLess(
                command.index("--initial-runtime-bypass"),
                command.index("--pin-dir"),
            )
            self.assertNotIn("--verbose-events", command)

    def test_observer_commands_are_tc_observability_only(self):
        with tempfile.TemporaryDirectory() as temp:
            config = client_observer_config(Path(temp))
            driver = ProcessAttachmentDriver(config)
            current = observer_binding()
            dns_command, grpc_command = driver.commands(current)
            port_pin = driver._port_path(config.pin_root, current.port_id)

        self.assertEqual(
            dns_command,
            [
                str(config.dns_monitor),
                "--dev",
                current.interface,
                "--hook",
                "tc",
                "--bpf-object",
                str(config.dns_tc_bpf),
            ],
        )
        for forbidden in (
            "--role",
            "--trusted-dns",
            "--cache-file",
            "--pin-dir",
            "--initial-runtime-bypass",
        ):
            self.assertNotIn(forbidden, dns_command)
        self.assertEqual(grpc_command[grpc_command.index("--port") + 1], "50052")
        self.assertEqual(
            grpc_command[grpc_command.index("--pin-dir") + 1],
            str(port_pin / "grpc"),
        )
        self.assertIn("--initial-runtime-bypass", grpc_command)
        self.assertNotIn("--verbose-events", grpc_command)

    def test_verbose_events_are_explicit_agent_opt_in(self):
        with tempfile.TemporaryDirectory() as temp:
            config = replace(
                attachment_config(Path(temp)),
                verbose_events=True,
            )
            driver = ProcessAttachmentDriver(config)
            dns_command, grpc_command = driver.commands(binding())

        self.assertEqual(dns_command.count("--verbose-events"), 1)
        self.assertEqual(grpc_command.count("--verbose-events"), 1)

    def test_binding_without_endpoint_config_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            driver = ProcessAttachmentDriver(attachment_config(Path(temp)))
            unconfigured = Binding(
                server_id="server-2",
                port_id="bbbbbbbb-cccc-dddd-eeee-ffffffffffff",
                host="master",
                interface="tapother",
                ifindex=15,
            )
            with self.assertRaisesRegex(
                AgentError, "no endpoint config for server server-2"
            ):
                driver.commands(unconfigured)

    def test_binding_with_undeclared_port_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            driver = ProcessAttachmentDriver(attachment_config(Path(temp)))
            undeclared = replace(
                binding(),
                port_id="11111111-2222-3333-4444-555555555555",
            )

            with self.assertRaisesRegex(
                AgentError,
                "not declared for server server-1",
            ):
                driver.commands(undeclared)

    def test_attach_initializes_committed_bypass_before_health(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = replace(
                attachment_config(root),
                command_timeout_seconds=0.75,
            )
            driver = ProcessAttachmentDriver(config)
            current = binding()
            programs = hook_programs()
            processes = iter((FakeProcess("dns"), FakeProcess("grpc")))
            events = []

            def start(_command, _log_path):
                process = next(processes)
                events.append(f"start:{process.name}")
                return process

            def initialize(command, **_kwargs):
                self.assertNotIn(current.port_id, driver._managed)
                operation = command[command.index("--operation") + 1]
                if operation == "force-bypass":
                    events.append("initialize:bypass")
                return transaction_response(operation)

            driver._start = start
            with (
                patch.object(driver, "_missing_pins", return_value=[]),
                patch.object(driver, "_ensure_hook_slots_available"),
                patch.object(
                    driver,
                    "_wait_attachment_ready",
                    return_value=programs,
                ),
                patch.object(
                    driver,
                    "_programs_intact",
                    return_value=True,
                ),
                patch(
                    "agent.openstack_dataplane_agent.subprocess.run",
                    side_effect=initialize,
                ) as run,
            ):
                driver.attach(current)
                self.assertTrue(driver.healthy(current))

            self.assertEqual(
                events,
                ["start:dns", "start:grpc", "initialize:bypass"],
            )
            command = run.call_args_list[0].args[0]
            self.assertTrue(
                all(
                    call.kwargs["timeout"] == 0.75
                    for call in run.call_args_list
                )
            )
            port_pin = driver._port_path(config.pin_root, current.port_id)
            self.assertEqual(
                command,
                [
                    str(config.cache_policy_txn),
                    "--lock-file",
                    str(
                        config.policy_lock_root.resolve()
                        / f"vnet-dataplane-{current.port_id}.lock"
                    ),
                    "--quiesce-file",
                    str(
                        config.policy_lock_root.resolve()
                        / f"vnet-dataplane-{current.port_id}.quiesce"
                    ),
                    "--control-map",
                    str(port_pin / "dns" / "cache_runtime_control"),
                    "--control-map",
                    str(port_pin / "grpc" / "cache_runtime_control"),
                    "--operation",
                    "force-bypass",
                    "--mode",
                    "bypass",
                    "--epoch",
                    "1",
                ],
            )
            self.assertFalse(driver._policy_quiesce_path(current.port_id).exists())

    def test_attach_fence_release_failure_remains_cleanup_reachable(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)
            driver = ProcessAttachmentDriver(config)
            current = binding()
            programs = hook_programs()
            dns_process = FakeProcess("dns")
            grpc_process = FakeProcess("grpc")
            processes = iter((dns_process, grpc_process))
            driver._start = lambda _command, _log_path: next(processes)

            def transaction(command, **_kwargs):
                operation = command[command.index("--operation") + 1]
                return transaction_response(operation)

            with (
                patch.object(driver, "_missing_pins", return_value=[]),
                patch.object(driver, "_ensure_hook_slots_available"),
                patch.object(
                    driver,
                    "_wait_attachment_ready",
                    return_value=programs,
                ),
                patch.object(driver, "_programs_intact", return_value=True),
                patch.object(
                    driver,
                    "_leave_quiesce",
                    side_effect=AgentError("injected fence release failure"),
                ),
                patch(
                    "agent.openstack_dataplane_agent.subprocess.run",
                    side_effect=transaction,
                ),
                self.assertRaisesRegex(AgentError, "fence release failure"),
            ):
                driver.attach(current)

            port_pin = driver._port_path(config.pin_root, current.port_id)
            self.assertIn(current.port_id, driver._managed)
            self.assertTrue(port_pin.exists())
            self.assertTrue(
                driver._policy_quiesce_path(current.port_id).exists()
            )

            dns_process.poll = lambda: 0
            grpc_process.poll = lambda: 0
            stopped = []
            driver._stop = lambda process: stopped.append(process.name) or True
            absent = hook_programs(
                dns_xdp=0,
                dns_tc_ingress=0,
                dns_tc_egress=0,
                grpc_tc_ingress=0,
                grpc_tc_egress=0,
            )
            with (
                patch.object(driver, "_current_programs", return_value=absent),
                patch(
                    "agent.openstack_dataplane_agent.subprocess.run",
                    side_effect=transaction,
                ),
            ):
                driver.detach(current)

            self.assertEqual(stopped, ["grpc", "dns"])
            self.assertNotIn(current.port_id, driver._managed)
            self.assertFalse(port_pin.exists())
            self.assertFalse(
                driver._policy_quiesce_path(current.port_id).exists()
            )

    def test_observer_initializes_only_grpc_runtime_control(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = client_observer_config(root)
            driver = ProcessAttachmentDriver(config)
            current = observer_binding()
            programs = hook_programs(
                dns_xdp=None,
                dns_tc_ingress=111,
                dns_tc_egress=112,
            )
            processes = iter((FakeProcess("dns"), FakeProcess("grpc")))
            driver._start = lambda _command, _log_path: next(processes)

            def initialize(command, **_kwargs):
                operation = command[command.index("--operation") + 1]
                return transaction_response(operation, maps=1)

            with (
                patch.object(driver, "_missing_pins", return_value=[]),
                patch.object(driver, "_ensure_hook_slots_available"),
                patch.object(
                    driver,
                    "_wait_attachment_ready",
                    return_value=programs,
                ),
                patch.object(
                    driver,
                    "_programs_intact",
                    return_value=True,
                ),
                patch.object(
                    driver,
                    "_program_ownership_status",
                    return_value=(True, programs, None),
                ),
                patch(
                    "agent.openstack_dataplane_agent.subprocess.run",
                    side_effect=initialize,
                ) as run,
            ):
                driver.attach(current)
                snapshot = driver.snapshot()[current.port_id]

            port_pin = driver._port_path(config.pin_root, current.port_id)
            command = run.call_args_list[0].args[0]
            self.assertEqual(command.count("--control-map"), 1)
            self.assertEqual(
                command[command.index("--control-map") + 1],
                str(port_pin / "grpc" / "cache_runtime_control"),
            )
            self.assertFalse((port_pin / "dns").exists())
            self.assertEqual(snapshot["accel_role"], "observer")
            self.assertEqual(snapshot["dns_capability"], "tc_observability")
            self.assertEqual(snapshot["grpc_capability"], "tc_observability")

    def test_bypass_initialization_failure_stops_and_cleans_attachment(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)
            driver = ProcessAttachmentDriver(config)
            current = binding()
            processes = iter((FakeProcess("dns"), FakeProcess("grpc")))
            stopped = []
            driver._start = lambda _command, _log_path: next(processes)
            driver._stop = lambda process: stopped.append(process.name) or True

            with (
                patch.object(driver, "_missing_pins", return_value=[]),
                patch.object(driver, "_ensure_hook_slots_available"),
                patch.object(
                    driver,
                    "_wait_attachment_ready",
                    return_value=hook_programs(),
                ),
                patch(
                    "agent.openstack_dataplane_agent.subprocess.run",
                    return_value=transaction_response("read-current", 1),
                ),
                self.assertRaisesRegex(AgentError, "confirm committed BYPASS"),
            ):
                driver.attach(current)

            self.assertEqual(stopped, ["grpc", "dns"])
            self.assertNotIn(current.port_id, driver._managed)
            self.assertFalse(
                driver._port_path(config.pin_root, current.port_id).exists()
            )

    def test_health_requires_processes_and_all_pinned_maps(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)
            driver = ProcessAttachmentDriver(config)
            current = binding()
            programs = hook_programs()
            driver._managed[current.port_id] = _ManagedAttachment(
                binding=current,
                dns_process=FakeProcess("dns"),
                grpc_process=FakeProcess("grpc"),
                programs=programs,
            )
            self.assertFalse(driver.healthy(current))

            port_pin = driver._port_path(config.pin_root, current.port_id)
            for relative in (
                "dns/cache_runtime_control",
                "dns/dns_cache_stats",
                "dns/dns_cache_entries",
                "grpc/cache_runtime_control",
                "grpc/grpc_policy_map",
                "grpc/grpc_response_cache",
            ):
                path = port_pin / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            with (
                patch.object(
                    driver,
                    "_current_programs",
                    return_value=programs,
                ),
                patch.object(
                    driver,
                    "_process_program_ids",
                    return_value={101, 102, 201, 202},
                ),
            ):
                self.assertTrue(driver.healthy(current))
                snapshot = driver.snapshot()[current.port_id]
            self.assertEqual(snapshot["missing_pins"], [])
            self.assertEqual(snapshot["accel_role"], "client")
            self.assertEqual(snapshot["dns_capability"], "xdp_client_cache")
            self.assertEqual(snapshot["grpc_observe_port"], 50052)
            self.assertEqual(snapshot["guest_grpc_listen_port"], 50053)
            self.assertNotIn("grpc_port", snapshot)
            self.assertEqual(snapshot["grpc_capability"], "tc_observability")

    def test_observer_health_requires_only_grpc_pins(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = client_observer_config(root)
            driver = ProcessAttachmentDriver(config)
            current = observer_binding()
            programs = hook_programs(
                dns_xdp=None,
                dns_tc_ingress=111,
                dns_tc_egress=112,
            )
            driver._managed[current.port_id] = _ManagedAttachment(
                binding=current,
                dns_process=FakeProcess("dns"),
                grpc_process=FakeProcess("grpc"),
                programs=programs,
            )

            port_pin = driver._port_path(config.pin_root, current.port_id)
            self.assertFalse(driver.healthy(current))
            self.assertEqual(
                driver._missing_pins(current),
                [
                    str(port_pin / "grpc" / "cache_runtime_control"),
                    str(port_pin / "grpc" / "grpc_policy_map"),
                    str(port_pin / "grpc" / "grpc_response_cache"),
                ],
            )
            for relative in (
                "grpc/cache_runtime_control",
                "grpc/grpc_policy_map",
                "grpc/grpc_response_cache",
            ):
                path = port_pin / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()

            with (
                patch.object(
                    driver,
                    "_current_programs",
                    return_value=programs,
                ),
                patch.object(
                    driver,
                    "_process_program_ids",
                    return_value={111, 112, 201, 202},
                ),
            ):
                self.assertTrue(driver.healthy(current))
                self.assertFalse((port_pin / "dns").exists())
                snapshot = driver.snapshot()[current.port_id]
            self.assertEqual(snapshot["missing_pins"], [])
            self.assertEqual(snapshot["accel_role"], "observer")
            self.assertEqual(snapshot["dns_capability"], "tc_observability")
            self.assertEqual(snapshot["grpc_observe_port"], 50052)
            self.assertEqual(snapshot["guest_grpc_listen_port"], 50052)

    def test_external_hook_deletion_degrades_health_and_snapshot(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            driver = ProcessAttachmentDriver(attachment_config(root))
            current = binding()
            programs = hook_programs()
            driver._managed[current.port_id] = _ManagedAttachment(
                binding=current,
                dns_process=FakeProcess("dns"),
                grpc_process=FakeProcess("grpc"),
                programs=programs,
            )
            for missing in driver._missing_pins(current):
                path = Path(missing)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            deleted = replace(programs, dns_xdp=0)

            with patch.object(
                driver,
                "_current_programs",
                return_value=deleted,
            ):
                self.assertFalse(driver.healthy(current))
                snapshot = driver.snapshot()[current.port_id]

            self.assertFalse(snapshot["healthy"])
            self.assertFalse(snapshot["hook_ownership_verified"])
            self.assertEqual(
                snapshot["current_program_ids"]["dns_xdp"],
                0,
            )
            self.assertEqual(
                snapshot["hook_ownership_error"],
                "hook program IDs changed",
            )

    def test_external_hook_replacement_degrades_without_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            driver = ProcessAttachmentDriver(attachment_config(root))
            current = binding()
            programs = hook_programs()
            driver._managed[current.port_id] = _ManagedAttachment(
                binding=current,
                dns_process=FakeProcess("dns"),
                grpc_process=FakeProcess("grpc"),
                programs=programs,
            )
            for missing in driver._missing_pins(current):
                path = Path(missing)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            replacement = replace(
                programs,
                grpc_tc_ingress=999,
            )

            with (
                patch.object(
                    driver,
                    "_current_programs",
                    return_value=replacement,
                ),
                patch.object(driver, "_stop") as stop,
            ):
                self.assertFalse(driver.healthy(current))
                snapshot = driver.snapshot()[current.port_id]

            stop.assert_not_called()
            self.assertFalse(snapshot["healthy"])
            self.assertFalse(snapshot["hook_ownership_verified"])
            self.assertEqual(
                snapshot["current_program_ids"]["grpc_tc_ingress"],
                999,
            )
            self.assertEqual(
                snapshot["hook_ownership_error"],
                "hook program IDs changed",
            )

    def test_hook_ids_must_still_be_owned_by_monitor_processes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            driver = ProcessAttachmentDriver(attachment_config(root))
            current = binding()
            programs = hook_programs()
            driver._managed[current.port_id] = _ManagedAttachment(
                binding=current,
                dns_process=FakeProcess("dns"),
                grpc_process=FakeProcess("grpc"),
                programs=programs,
            )
            for missing in driver._missing_pins(current):
                path = Path(missing)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()

            def process_program_ids(process):
                if process.name == "dns":
                    return {101, 102}
                return {201}

            with (
                patch.object(
                    driver,
                    "_current_programs",
                    return_value=programs,
                ),
                patch.object(
                    driver,
                    "_process_program_ids",
                    side_effect=process_program_ids,
                ),
            ):
                self.assertFalse(driver.healthy(current))
                snapshot = driver.snapshot()[current.port_id]

            self.assertFalse(snapshot["healthy"])
            self.assertFalse(snapshot["hook_ownership_verified"])
            self.assertEqual(
                snapshot["hook_ownership_error"],
                "hook program IDs are not owned by monitor processes",
            )

    def test_detach_waits_for_monitor_exit_before_fallback_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)
            driver = ProcessAttachmentDriver(config)
            current = binding()
            port_pin = driver._port_path(config.pin_root, current.port_id)
            port_pin.mkdir(parents=True)
            dns_process = FakeProcess("dns")
            grpc_process = FakeProcess("grpc")
            driver._managed[current.port_id] = _ManagedAttachment(
                binding=current,
                dns_process=dns_process,
                grpc_process=grpc_process,
                programs=hook_programs(),
            )
            stopped = []
            driver._stop = lambda process: stopped.append(process.name) or True

            def transaction(command, **_kwargs):
                operation = command[command.index("--operation") + 1]
                return transaction_response(operation)

            with patch(
                "agent.openstack_dataplane_agent.subprocess.run",
                side_effect=transaction,
            ) as run:
                driver.detach(current)

            self.assertEqual(stopped, ["grpc", "dns"])
            self.assertEqual(
                [
                    call.args[0][call.args[0].index("--operation") + 1]
                    for call in run.call_args_list
                ],
                ["force-bypass", "read-current"],
            )
            self.assertFalse(port_pin.exists())
            self.assertFalse(driver._policy_quiesce_path(current.port_id).exists())

    def test_detach_falls_back_to_owned_hook_cleanup_after_monitor_exit(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)

            class RecordingRunner:
                def __init__(self):
                    self.commands = []

                def run(self, args):
                    self.commands.append(tuple(args))
                    return ""

            runner = RecordingRunner()
            driver = ProcessAttachmentDriver(config, runner)
            current = binding()
            port_pin = driver._port_path(config.pin_root, current.port_id)
            port_pin.mkdir(parents=True)

            exited_dns = FakeProcess("dns")
            exited_grpc = FakeProcess("grpc")
            exited_dns.poll = lambda: 0
            exited_grpc.poll = lambda: 0
            driver._managed[current.port_id] = _ManagedAttachment(
                binding=current,
                dns_process=exited_dns,
                grpc_process=exited_grpc,
                programs=hook_programs(),
            )

            stopped = []
            driver._stop = lambda process: stopped.append(process.name) or True
            absent = hook_programs(
                dns_xdp=0,
                dns_tc_ingress=0,
                dns_tc_egress=0,
                grpc_tc_ingress=0,
                grpc_tc_egress=0,
            )

            def transaction(command, **_kwargs):
                operation = command[command.index("--operation") + 1]
                return transaction_response(operation)

            with (
                patch.object(
                    driver,
                    "_current_programs",
                    side_effect=[hook_programs(), absent],
                ),
                patch(
                    "agent.openstack_dataplane_agent.subprocess.run",
                    side_effect=transaction,
                ),
            ):
                driver.detach(current)

            self.assertEqual(stopped, ["grpc", "dns"])
            self.assertEqual(
                runner.commands,
                [
                    (
                        "ip",
                        "link",
                        "set",
                        "dev",
                        "tapport",
                        "xdpgeneric",
                        "off",
                    ),
                    (
                        "tc",
                        "filter",
                        "del",
                        "dev",
                        "tapport",
                        "ingress",
                        "protocol",
                        "all",
                        "pref",
                        "1",
                        "handle",
                        "0x1",
                        "bpf",
                    ),
                    (
                        "tc",
                        "filter",
                        "del",
                        "dev",
                        "tapport",
                        "egress",
                        "protocol",
                        "all",
                        "pref",
                        "1",
                        "handle",
                        "0x1",
                        "bpf",
                    ),
                    (
                        "tc",
                        "filter",
                        "del",
                        "dev",
                        "tapport",
                        "ingress",
                        "protocol",
                        "all",
                        "pref",
                        "1",
                        "handle",
                        "0x2",
                        "bpf",
                    ),
                    (
                        "tc",
                        "filter",
                        "del",
                        "dev",
                        "tapport",
                        "egress",
                        "protocol",
                        "all",
                        "pref",
                        "1",
                        "handle",
                        "0x2",
                        "bpf",
                    ),
                ],
            )
            self.assertFalse(port_pin.exists())
            self.assertFalse(driver._policy_quiesce_path(current.port_id).exists())

    def test_detach_treats_deleted_interface_as_already_clean(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)

            class RecordingRunner:
                def __init__(self):
                    self.commands = []

                def run(self, args):
                    self.commands.append(tuple(args))
                    return ""

            runner = RecordingRunner()
            driver = ProcessAttachmentDriver(config, runner)
            current = binding()
            port_pin = driver._port_path(config.pin_root, current.port_id)
            port_pin.mkdir(parents=True)
            exited_dns = FakeProcess("dns")
            exited_grpc = FakeProcess("grpc")
            exited_dns.poll = lambda: 0
            exited_grpc.poll = lambda: 0
            driver._managed[current.port_id] = _ManagedAttachment(
                binding=current,
                dns_process=exited_dns,
                grpc_process=exited_grpc,
                programs=hook_programs(),
            )
            driver._stop = lambda _process: True

            def transaction(command, **_kwargs):
                operation = command[command.index("--operation") + 1]
                return transaction_response(operation)

            with (
                patch.object(
                    driver,
                    "_current_programs",
                    side_effect=AgentError(
                        'command failed (1): tc -j filter show dev '
                        'tapport ingress: Cannot find device "tapport"'
                    ),
                ),
                patch(
                    "agent.openstack_dataplane_agent.subprocess.run",
                    side_effect=transaction,
                ),
            ):
                driver.detach(current)

            self.assertNotIn(current.port_id, driver._managed)
            self.assertEqual(runner.commands, [])
            self.assertFalse(port_pin.exists())
            self.assertFalse(driver._policy_quiesce_path(current.port_id).exists())

    def test_detach_refuses_fallback_when_hook_ownership_changed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)

            class RecordingRunner:
                def __init__(self):
                    self.commands = []

                def run(self, args):
                    self.commands.append(tuple(args))
                    return ""

            runner = RecordingRunner()
            driver = ProcessAttachmentDriver(config, runner)
            current = binding()
            port_pin = driver._port_path(config.pin_root, current.port_id)
            port_pin.mkdir(parents=True)
            dns_process = FakeProcess("dns")
            grpc_process = FakeProcess("grpc")
            dns_process.poll = lambda: 0
            grpc_process.poll = lambda: 0
            driver._managed[current.port_id] = _ManagedAttachment(
                binding=current,
                dns_process=dns_process,
                grpc_process=grpc_process,
                programs=hook_programs(),
            )
            driver._stop = lambda _process: True

            replaced = replace(hook_programs(), grpc_tc_ingress=999)

            def transaction(command, **_kwargs):
                operation = command[command.index("--operation") + 1]
                return transaction_response(operation)

            with (
                patch.object(driver, "_current_programs", return_value=replaced),
                patch(
                    "agent.openstack_dataplane_agent.subprocess.run",
                    side_effect=transaction,
                ),
                self.assertRaisesRegex(
                    AgentError,
                    "ownership changed",
                ),
            ):
                driver.detach(current)

            self.assertEqual(runner.commands, [])
            self.assertIn(current.port_id, driver._managed)
            self.assertTrue(port_pin.exists())
            self.assertTrue(driver._policy_quiesce_path(current.port_id).exists())

    def test_preexisting_unowned_pins_block_attach_and_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)
            driver = ProcessAttachmentDriver(config)
            current = binding()
            port_pin = driver._port_path(config.pin_root, current.port_id)
            port_pin.mkdir(parents=True)

            with self.assertRaisesRegex(AgentError, "unowned preexisting"):
                driver.attach(current)

            residual = driver.snapshot()[current.port_id]
            self.assertTrue(residual["residual_cleanup_blocked"])
            self.assertIn("ownership is unknown", residual["residual_reason"])
            with self.assertRaisesRegex(AgentError, "cleanup is blocked"):
                driver.detach(current)
            self.assertTrue(port_pin.exists())
            self.assertTrue(
                driver._policy_quiesce_path(current.port_id).exists()
            )

    def test_cleanup_accepts_confirmed_all_missing_maps(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)
            driver = ProcessAttachmentDriver(config)
            current = binding()

            def transaction(command, **_kwargs):
                operation = command[command.index("--operation") + 1]
                if operation == "read-current":
                    return argparse.Namespace(
                        returncode=0,
                        stdout=json.dumps(
                            {
                                "schema_version": 1,
                                "present": False,
                                "maps": 0,
                                "epoch": 0,
                                "mode": 0,
                                "flags": 0,
                            }
                        ),
                        stderr="",
                    )
                return argparse.Namespace(
                    returncode=0,
                    stdout="maps absent",
                    stderr="",
                )

            with patch(
                "agent.openstack_dataplane_agent.subprocess.run",
                side_effect=transaction,
            ) as run:
                driver.detach(current)

            for call in run.call_args_list:
                self.assertIn("--allow-all-missing", call.args[0])
            self.assertFalse(
                driver._policy_quiesce_path(current.port_id).exists()
            )

    def test_observer_detach_stops_tc_monitors_and_cleans_grpc_pins(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = client_observer_config(root)
            driver = ProcessAttachmentDriver(config)
            current = observer_binding()
            port_pin = driver._port_path(config.pin_root, current.port_id)
            (port_pin / "grpc").mkdir(parents=True)
            driver._managed[current.port_id] = _ManagedAttachment(
                binding=current,
                dns_process=FakeProcess("dns"),
                grpc_process=FakeProcess("grpc"),
                programs=hook_programs(
                    dns_xdp=None,
                    dns_tc_ingress=111,
                    dns_tc_egress=112,
                ),
            )
            stopped = []
            driver._stop = lambda process: stopped.append(process.name) or True

            def transaction(command, **_kwargs):
                operation = command[command.index("--operation") + 1]
                return transaction_response(operation, maps=1)

            with patch(
                "agent.openstack_dataplane_agent.subprocess.run",
                side_effect=transaction,
            ) as run:
                driver.detach(current)

            self.assertEqual(stopped, ["grpc", "dns"])
            for call in run.call_args_list:
                command = call.args[0]
                self.assertEqual(command.count("--control-map"), 1)
                self.assertEqual(
                    command[command.index("--control-map") + 1],
                    str(port_pin / "grpc" / "cache_runtime_control"),
                )
            self.assertFalse(port_pin.exists())
            self.assertFalse(driver._policy_quiesce_path(current.port_id).exists())

    def test_detach_keeps_pins_when_bypass_cannot_be_confirmed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = attachment_config(root)
            driver = ProcessAttachmentDriver(config)
            current = binding()
            port_pin = driver._port_path(config.pin_root, current.port_id)
            port_pin.mkdir(parents=True)
            driver._managed[current.port_id] = _ManagedAttachment(
                binding=current,
                dns_process=FakeProcess("dns"),
                grpc_process=FakeProcess("grpc"),
                programs=hook_programs(),
            )
            stopped = []
            driver._stop = lambda process: stopped.append(process.name) or True

            with (
                patch(
                    "agent.openstack_dataplane_agent.subprocess.run",
                    return_value=transaction_response("read-current", 1),
                ),
                self.assertRaisesRegex(AgentError, "confirm committed BYPASS"),
            ):
                driver.detach(current)

            self.assertEqual(stopped, [])
            self.assertTrue(port_pin.exists())
            self.assertIn(current.port_id, driver._managed)
            self.assertTrue(driver._policy_quiesce_path(current.port_id).exists())


if __name__ == "__main__":
    unittest.main()
