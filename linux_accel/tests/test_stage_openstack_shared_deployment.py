import ast
import importlib.util
import base64
import hashlib
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock
import subprocess


ROOT = Path(__file__).resolve().parents[2]
SYSTEMD_ROOT = ROOT / "linux_accel" / "deploy" / "systemd"
SUDOERS_FILE = ROOT / "linux_accel" / "deploy" / "sudoers" / "vnet-dataplane-shared"
SCRIPT = ROOT / "linux_accel" / "bench" / "stage_openstack_shared_deployment.py"
PREFLIGHT_SCRIPT = (
    ROOT / "linux_accel" / "bench" / "openstack_shared_cluster_preflight.py"
)
CLIENT_PORT_ID = "11111111-2222-3333-4444-555555555555"
BACKEND_PORT_ID = "22222222-3333-4444-5555-666666666666"
CLIENT_SERVER_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
BACKEND_SERVER_ID = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
OWNER_PROJECT_ID = "cccccccc-dddd-eeee-ffff-000000000001"
OWNERSHIP_TAG = "vnet-dataplane-owner-shared-yoga-test"
CLIENT_MAC = "fa:16:3e:00:00:21"
BACKEND_MAC = "fa:16:3e:00:00:22"


def fingerprint(seed):
    digest = hashlib.sha256(seed.encode("ascii")).digest()
    return "SHA256:" + base64.b64encode(digest).decode("ascii").rstrip("=")


def inventory_value():
    return {
        "schema_version": 1,
        "clock_tolerance_ms": 10,
        "allowed_server_ids": [CLIENT_SERVER_ID, BACKEND_SERVER_ID],
        "allowed_port_ids": [CLIENT_PORT_ID, BACKEND_PORT_ID],
        "owner_project_id": OWNER_PROJECT_ID,
        "ownership_tag": OWNERSHIP_TAG,
        "port_server_bindings": {
            CLIENT_PORT_ID: CLIENT_SERVER_ID,
            BACKEND_PORT_ID: BACKEND_SERVER_ID,
        },
        "port_fixed_ipv4s": {
            CLIENT_PORT_ID: "10.42.0.21",
            BACKEND_PORT_ID: "10.42.0.22",
        },
        "port_mac_addresses": {
            CLIENT_PORT_ID: CLIENT_MAC,
            BACKEND_PORT_ID: BACKEND_MAC,
        },
        "minimum_target_capacity": {
            "vcpus": 2,
            "memory_mb": 2048,
            "disk_gb": 10,
        },
        "roles": {
            "controller": {
                "address": "172.25.6.11",
                "ssh_user": "ubuntu",
                "expected_hostname": "controller",
                "host_key_fingerprint": fingerprint("controller"),
                "expected_clock_reference": "192.0.2.1",
                "openstack_cloud": "vnet-readonly",
            },
            "source": {
                "address": "172.25.6.13",
                "ssh_user": "ubuntu",
                "expected_hostname": "compute2",
                "host_key_fingerprint": fingerprint("source"),
                "expected_clock_reference": "192.0.2.1",
                "allowed_libvirt_domains": [
                    "instance-000001",
                    "instance-000002",
                ],
                "required_ovs_bridges": ["br-int"],
                "required_tap_interfaces": ["tap-client", "tap-backend"],
                "required_port_bindings": {
                    CLIENT_PORT_ID: "tap-client",
                    BACKEND_PORT_ID: "tap-backend",
                },
            },
            "target": {
                "address": "172.25.6.14",
                "ssh_user": "ubuntu",
                "expected_hostname": "compute3",
                "host_key_fingerprint": fingerprint("target"),
                "expected_clock_reference": "192.0.2.1",
                "allowed_libvirt_domains": [],
                "required_ovs_bridges": ["br-int"],
                "required_tap_interfaces": [],
                "required_port_bindings": {},
            },
        },
    }


def normalized_inventory():
    name = "test_stage_preflight_dependency"
    spec = importlib.util.spec_from_file_location(name, PREFLIGHT_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
        return module.validate_inventory(inventory_value())
    finally:
        sys.modules.pop(name, None)


def reproducible_topology():
    inventory = inventory_value()
    return {
        "schema_version": 1,
        "deployment_id": "shared-yoga-test",
        "known_hosts_file": (
            "/etc/vnet-dataplane-agent/known_hosts.shared-yoga-test"
        ),
        "inventory": inventory,
        "hosts": {
            "controller": {"ssh_destination": "ubuntu@172.25.6.11"},
            "source": {
                "nova_host": "compute2",
                "ssh_destination": "ubuntu@172.25.6.13",
            },
            "target": {
                "nova_host": "compute3",
                "ssh_destination": "ubuntu@172.25.6.14",
            },
        },
        "interfaces": {
            "source": {"client": "tap-client", "backend": "tap-backend"},
            "target": {"client": "tap-client", "backend": "tap-backend"},
        },
        "guests": {
            "client": {
                "server_id": CLIENT_SERVER_ID,
                "port_id": CLIENT_PORT_ID,
                "private_ipv4": "10.42.0.21",
                "mac_address": CLIENT_MAC,
                "ssh_destination": "ubuntu@10.42.0.21",
                "interface": "ens3",
            },
            "backend": {
                "server_id": BACKEND_SERVER_ID,
                "port_id": BACKEND_PORT_ID,
                "private_ipv4": "10.42.0.22",
                "mac_address": BACKEND_MAC,
                "ssh_destination": "ubuntu@10.42.0.22",
                "interface": "ens3",
            },
        },
    }


def write_reproducible_bundle(root, module):
    renderer = module._renderer_module()
    topology = root / "topology.json"
    topology.write_text(json.dumps(reproducible_topology()), encoding="utf-8")
    artifact_root = root / "trusted-artifacts"
    for relative in renderer.required_artifact_paths():
        path = artifact_root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if "/deploy/systemd/" in relative:
            path.write_bytes((SYSTEMD_ROOT / Path(relative).name).read_bytes())
        else:
            path.write_bytes(f"trusted:{relative}\n".encode("ascii"))
    bundle = root / "reproducible-bundle"
    renderer.render_bundle(topology, bundle, artifact_root)
    return topology, artifact_root, bundle


def canonical_sha256(value):
    payload = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def preflight_value():
    inventory = normalized_inventory()
    roles = inventory["roles"]
    return {
        "schema_version": 1,
        "generated_at": "2026-08-01T09:04:00Z",
        "status": "allowed",
        "deploy_allowed": True,
        "snapshot": {
            "collection_started_at": "2026-08-01T09:03:30Z",
            "confirmation_started_at": "2026-08-01T09:03:58Z",
            "confirmation_completed_at": "2026-08-01T09:04:00Z",
            "duration_ms": 2000.0,
            "command_count": 19,
            "required_command_count": 19,
            "max_duration_seconds": 60.0,
            "confirmed": True,
        },
        "inventory": {
            "sha256": canonical_sha256(inventory),
            "roles": {
                role: {
                    "address": node["address"],
                    "expected_hostname": node["expected_hostname"],
                    "host_key_fingerprint": node["host_key_fingerprint"],
                }
                for role, node in roles.items()
            },
        },
        "host_identity": [
            {
                "role": role,
                "address": node["address"],
                "expected_hostname": node["expected_hostname"],
                "expected_host_key_fingerprint": node["host_key_fingerprint"],
                "observed_host_key_fingerprint": node["host_key_fingerprint"],
                "host_key_verified": True,
            }
            for role, node in roles.items()
        ],
        "gates": [
            {"name": name, "passed": True}
            for name in (
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
            )
        ],
    }


ROLE_UNITS = {
    "controller": (
        "vnet-dataplane-shared-epoch-coordinator.service",
        "vnet-dataplane-shared-metrics-controller.service",
    ),
    "source": ("vnet-dataplane-shared-agent.service",),
    "target": ("vnet-dataplane-shared-agent.service",),
}

ROLE_ARTIFACTS = {
    "controller": (
        "agent/openstack_epoch_coordinator.py",
        "agent/openstack_metrics_bridge.py",
    ),
    "source": (
        "agent/openstack_dataplane_agent.py",
        "build/dns_monitor",
        "build/dns_client_cache.bpf.o",
        "build/dns_monitor.bpf.o",
        "build/grpc_monitor",
        "build/grpc_monitor.bpf.o",
        "build/cache_policy_txn",
    ),
    "target": (
        "agent/openstack_dataplane_agent.py",
        "build/dns_monitor",
        "build/dns_client_cache.bpf.o",
        "build/dns_monitor.bpf.o",
        "build/grpc_monitor",
        "build/grpc_monitor.bpf.o",
        "build/cache_policy_txn",
    ),
}


def write_bundle(root):
    bundle = root / "bundle"
    files = []

    def add(role, source, target, mode, payload):
        path = bundle / source
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        files.append(
            {
                "role": role,
                "source": source,
                "target": target,
                "mode": mode,
                "sha256": hashlib.sha256(payload).hexdigest(),
            }
        )

    for role in ("controller", "source", "target"):
        add(
            role,
            f"{role}/config.env",
            "/etc/vnet-dataplane-shared/config.env",
            "0600",
            f"VNET_DEPLOYMENT_ROLE={role}\n".encode("ascii"),
        )
        for relative in ROLE_ARTIFACTS[role]:
            mode = "0755" if relative.endswith((".py", "monitor", "txn")) else "0644"
            add(
                role,
                f"artifacts/{role}/{relative}",
                f"/opt/vnet-dataplane-shared/{relative}",
                mode,
                f"verified-linux-artifact:{role}:{relative}\n".encode("ascii"),
            )
        for unit in ROLE_UNITS[role]:
            payload = (SYSTEMD_ROOT / unit).read_bytes()
            add(
                role,
                f"systemd/{unit}",
                f"/etc/systemd/system/{unit}",
                "0644",
                payload,
            )
        if role in ("source", "target"):
            add(
                role,
                f"{role}/vnet-dataplane-shared.sudoers",
                "/etc/vnet-dataplane-shared/vnet-dataplane-shared.sudoers.pending",
                "0600",
                SUDOERS_FILE.read_bytes(),
            )

    inventory = normalized_inventory()
    manifest = {
        "schema_version": 1,
        "deployment_id": "shared-yoga-test",
        "inventory_sha256": canonical_sha256(inventory),
        "topology_sha256": "a" * 64,
        "files": files,
        "units": [
            {
                "role": role,
                "name": unit,
                "enabled": False,
                "started": False,
            }
            for role in ("controller", "source", "target")
            for unit in ROLE_UNITS[role]
        ],
        "hosts": [
            dict(
                {
                    "role": role,
                    "ssh_destination": (
                        f"ubuntu@{inventory['roles'][role]['address']}"
                    ),
                },
                **(
                    {"nova_host": inventory["roles"][role]["expected_hostname"]}
                    if role != "controller"
                    else {}
                ),
            )
            for role in ("controller", "source", "target")
        ],
        "guest_files": [],
    }
    (bundle / "bundle-manifest.json").write_text(
        json.dumps(manifest), encoding="utf-8"
    )
    return bundle


def call_stage_deployment(module, inventory, preflight, bundle, runner, **kwargs):
    manifest = Path(bundle) / "bundle-manifest.json"
    trusted_digest = hashlib.sha256(manifest.read_bytes()).hexdigest()
    if not kwargs.get("dry_run", False) and "recovery_path" not in kwargs:
        kwargs["recovery_path"] = Path(bundle).parent / "stage-recovery.json"
    return module.stage_deployment(
        inventory,
        preflight,
        bundle,
        runner,
        expected_bundle_manifest_sha256=trusted_digest,
        **kwargs,
    )


class FakeRunner:
    def __init__(self):
        self.calls = []

    def verify_host_key(self, role, node, timeout):
        self.calls.append(("verify", role))
        return node["host_key_fingerprint"]

    def inspect_node(self, role, node, files, units, timeout):
        self.calls.append(("inspect", role))
        return {
            "activation_marker_absent": True,
            "targets": [
                {"target": item["target"], "exists": False, "symlink": False}
                for item in files
            ],
            "units": {
                unit: {"active": "inactive", "enabled": "disabled"}
                for unit in units
            },
        }

    def stage_node(self, *args, **kwargs):
        raise AssertionError("dry-run must not stage")

    def rollback_node(self, *args, **kwargs):
        raise AssertionError("dry-run must not roll back")


class FakeStageRunner(FakeRunner):
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
        self.calls.append(("stage", role))
        return {
            "status": "staged",
            "backup_root": (
                f"/var/backups/vnet-dataplane-shared/{backup_id}"
            ),
            "rollback_manifest": (
                "/var/backups/vnet-dataplane-shared/"
                f"{backup_id}/rollback-manifest.json"
            ),
            "manager_reloaded": False,
            "targets": [
                {
                    "target": item["target"],
                    "sha256": item["sha256"],
                    "mode": item["mode"],
                    "owner": "root:root",
                    "symlink": False,
                }
                for item in files
            ],
            "units": {
                unit: {"active": "inactive", "enabled": "disabled"}
                for unit in units
            },
        }

    def rollback_node(
        self, role, node, backup_id, bundle_manifest_sha256, timeout
    ):
        self.calls.append(("rollback", role))
        return {"status": "rolled_back", "manager_reloaded": False}


class FailingTargetRunner(FakeStageRunner):
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
        if role == "target":
            self.calls.append(("stage", role))
            raise RuntimeError("sensitive remote failure")
        return super().stage_node(
            role,
            node,
            files,
            units,
            backup_id,
            bundle_manifest_sha256,
            timeout,
        )


class ActiveUnitRunner(FakeRunner):
    def inspect_node(self, role, node, files, units, timeout):
        result = super().inspect_node(role, node, files, units, timeout)
        if role == "source":
            result["units"][units[0]]["active"] = "active"
        return result


class ExistingTargetRunner(FakeRunner):
    def inspect_node(self, role, node, files, units, timeout):
        result = super().inspect_node(role, node, files, units, timeout)
        if role == "source":
            result["targets"][0]["exists"] = True
        return result


class StaleActivationMarkerRunner(FakeRunner):
    def inspect_node(self, role, node, files, units, timeout):
        result = super().inspect_node(role, node, files, units, timeout)
        if role == "source":
            result["activation_marker_absent"] = False
        return result


def load_module():
    name = "stage_openstack_shared_deployment"
    spec = importlib.util.spec_from_file_location(name, SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    finally:
        sys.modules.pop(name, None)
    return module


def load_remote_systemctl_state(module):
    tree = ast.parse(module._REMOTE_HELPER_SOURCE)
    functions = [
        node
        for node in tree.body
        if isinstance(node, ast.FunctionDef)
        and node.name in {"fail", "systemctl_state"}
    ]
    namespace = {
        "subprocess": subprocess,
        "UNIT_TARGETS": {"vnet-test.service": "/etc/systemd/system/vnet-test.service"},
    }
    exec(compile(ast.Module(body=functions, type_ignores=[]), "<helper-test>", "exec"), namespace)
    return namespace["systemctl_state"]


class SharedSystemdUnitTest(unittest.TestCase):
    def test_shared_units_are_uniquely_named_and_stage_locked(self):
        names = {
            "vnet-dataplane-shared-agent.service",
            "vnet-dataplane-shared-metrics-controller.service",
            "vnet-dataplane-shared-epoch-coordinator.service",
        }

        contents = {
            name: (SYSTEMD_ROOT / name).read_text(encoding="ascii")
            for name in names
        }

        for name, content in contents.items():
            self.assertIn("RefuseManualStart=yes", content, name)
            self.assertIn(
                "ConditionPathExists=/run/vnet-dataplane-shared-activation/approved",
                content,
                name,
            )
            self.assertIn(
                "EnvironmentFile=/etc/vnet-dataplane-shared/", content, name
            )
            self.assertNotIn("ExecStart=/bin/sh", content, name)
            self.assertNotIn("vnet-dataplane-agent.service", content, name)
        self.assertIn(
            "/var/log/vnet-dataplane-agent/shared-${VNET_DEPLOYMENT_ID}",
            contents["vnet-dataplane-shared-agent.service"],
        )
        self.assertIn(
            "TimeoutStopSec=300",
            contents["vnet-dataplane-shared-agent.service"],
        )
        self.assertIn(
            "TimeoutStopSec=120",
            contents["vnet-dataplane-shared-epoch-coordinator.service"],
        )


class SharedStageDeploymentTest(unittest.TestCase):
    def test_preflight_snapshot_contract_matches_collector(self):
        module = load_module()
        collector = module._preflight_module()

        self.assertEqual(
            module.PREFLIGHT_SNAPSHOT_COMMAND_COUNT,
            collector.SNAPSHOT_CONFIRMATION_COMMAND_COUNT,
        )
        self.assertEqual(
            module.PREFLIGHT_MAX_SNAPSHOT_SECONDS,
            collector.MAX_SNAPSHOT_CONFIRMATION_SECONDS,
        )
        self.assertIn("snapshot.confirmed", module.REQUIRED_PREFLIGHT_GATES)

    def test_bundle_must_reproduce_from_trusted_topology_and_artifacts(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            topology, artifact_root, bundle = write_reproducible_bundle(root, module)
            manifest_sha256 = module.verify_reproducible_bundle(
                topology, artifact_root, bundle
            )
            self.assertEqual(
                manifest_sha256,
                hashlib.sha256((bundle / "bundle-manifest.json").read_bytes()).hexdigest(),
            )

            manifest_path = bundle / "bundle-manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            record = next(
                item
                for item in manifest["files"]
                if item["role"] == "source"
                and item["target"]
                == "/opt/vnet-dataplane-shared/bin/cache_policy_txn"
            )
            payload = b"#!/bin/sh\nexec /bin/sh\n"
            (bundle / record["source"]).write_bytes(payload)
            record["sha256"] = hashlib.sha256(payload).hexdigest()
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaisesRegex(module.DeploymentError, "reproducible"):
                module.verify_reproducible_bundle(
                    topology, artifact_root, bundle
                )

    def test_dry_run_verifies_every_node_without_remote_mutation(self):
        module = load_module()
        runner = FakeRunner()
        with tempfile.TemporaryDirectory() as temporary:
            report = call_stage_deployment(
                module,
                inventory_value(),
                preflight_value(),
                write_bundle(Path(temporary)),
                runner,
                dry_run=True,
                now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
            )

        self.assertEqual(report["status"], "dry_run")
        self.assertFalse(report["staged"])
        self.assertEqual(
            runner.calls,
            [
                ("verify", "source"),
                ("inspect", "source"),
                ("verify", "target"),
                ("inspect", "target"),
                ("verify", "controller"),
                ("inspect", "controller"),
            ],
        )
        self.assertTrue(all(node["status"] == "verified" for node in report["nodes"]))
        serialized = json.dumps(report).lower()
        self.assertNotIn("verified-linux-artifact", serialized)
        self.assertNotIn("private_key", serialized)
        self.assertNotIn("auth_token", serialized)

    def test_stage_is_sequential_and_reports_verified_backups(self):
        module = load_module()
        runner = FakeStageRunner()
        with tempfile.TemporaryDirectory() as temporary:
            recovery = Path(temporary) / "stage-recovery.json"
            report = call_stage_deployment(
                module,
                inventory_value(),
                preflight_value(),
                write_bundle(Path(temporary)),
                runner,
                recovery_path=recovery,
                now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
            )
            recovered = json.loads(recovery.read_text(encoding="ascii"))

        self.assertEqual(report["status"], "staged")
        self.assertTrue(report["staged"])
        self.assertEqual(
            runner.calls,
            [
                ("verify", "source"),
                ("inspect", "source"),
                ("verify", "target"),
                ("inspect", "target"),
                ("verify", "controller"),
                ("inspect", "controller"),
                ("stage", "source"),
                ("stage", "target"),
                ("stage", "controller"),
            ],
        )
        self.assertEqual(
            {node["status"] for node in report["nodes"]}, {"staged"}
        )
        self.assertTrue(report["rollback"]["available"])
        self.assertTrue(
            report["rollback"]["remote_manifest"].startswith(
                "/var/backups/vnet-dataplane-shared/codex-backup-20260801T090500Z-"
            )
        )
        self.assertFalse(report["safety"]["services_started"])
        self.assertFalse(report["safety"]["services_enabled"])
        self.assertFalse(report["safety"]["systemd_manager_reloaded"])
        self.assertFalse(report["activation_ready"])
        self.assertEqual(
            report["pending_gates"], list(module.ACTIVATION_PENDING_GATES)
        )
        self.assertEqual(recovered, report)

    def test_recovery_intent_precedes_inspect_and_each_stage_request(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            recovery = root / "stage-recovery.json"

            class ObservingRunner(FakeStageRunner):
                def __init__(self):
                    super().__init__()
                    self.inspect_snapshots = []
                    self.stage_snapshots = []

                def inspect_node(self, role, node, files, units, timeout):
                    self.inspect_snapshots.append(
                        (role, json.loads(recovery.read_text(encoding="ascii")))
                    )
                    return super().inspect_node(role, node, files, units, timeout)

                def stage_node(self, role, *args):
                    self.stage_snapshots.append(
                        (role, json.loads(recovery.read_text(encoding="ascii")))
                    )
                    return super().stage_node(role, *args)

            runner = ObservingRunner()
            call_stage_deployment(
                module,
                inventory_value(),
                preflight_value(),
                write_bundle(root),
                runner,
                recovery_path=recovery,
                now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
            )

        first_inspect = runner.inspect_snapshots[0][1]
        self.assertEqual(first_inspect["operation"], "stage_recovery_intent")
        self.assertTrue(
            all(node["inspection_state"] == "pending" for node in first_inspect["nodes"])
        )
        for role, snapshot in runner.stage_snapshots:
            states = {node["role"]: node["stage_state"] for node in snapshot["nodes"]}
            self.assertEqual(states[role], "requested")
        self.assertEqual(
            {
                node["role"]: node["stage_state"]
                for node in runner.stage_snapshots[-1][1]["nodes"]
            },
            {"source": "confirmed", "target": "confirmed", "controller": "requested"},
        )

    def test_existing_recovery_intent_blocks_before_ssh(self):
        module = load_module()
        runner = FakeStageRunner()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            recovery = root / "stage-recovery.json"
            recovery.write_text('{"status":"unresolved"}\n', encoding="ascii")
            with self.assertRaisesRegex(module.DeploymentError, "already exists"):
                call_stage_deployment(
                    module,
                    inventory_value(),
                    preflight_value(),
                    write_bundle(root),
                    runner,
                    recovery_path=recovery,
                    now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
                )
        self.assertEqual(runner.calls, [])

    def test_atomic_json_replace_synchronizes_parent_directory(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "evidence.json"
            with mock.patch.object(module, "_fsync_parent_directory") as sync:
                module.atomic_write_json(output, {"status": "durable"})
        sync.assert_called_once_with(output)

    def test_missing_recovery_parent_is_rejected_before_ssh(self):
        module = load_module()
        runner = FakeStageRunner()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(
                module.DeploymentError, "parent must already exist"
            ):
                call_stage_deployment(
                    module,
                    inventory_value(),
                    preflight_value(),
                    write_bundle(root),
                    runner,
                    recovery_path=root / "missing" / "recovery.json",
                    now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
                )
        self.assertEqual(runner.calls, [])

    def test_stage_output_failure_leaves_a_rollback_usable_recovery_receipt(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            topology, artifact_root, bundle = write_reproducible_bundle(root, module)
            inventory_path = root / "inventory.json"
            preflight_path = root / "preflight.json"
            recovery_path = root / "recovery.json"
            output_path = root / "final-output.json"
            inventory = inventory_value()
            preflight = preflight_value()
            current = datetime.now(timezone.utc)
            current_text = current.isoformat().replace("+00:00", "Z")
            preflight["generated_at"] = current_text
            preflight["snapshot"].update(
                {
                    "collection_started_at": current_text,
                    "confirmation_started_at": current_text,
                    "confirmation_completed_at": current_text,
                    "duration_ms": 0.0,
                }
            )
            inventory_path.write_text(json.dumps(inventory), encoding="utf-8")
            preflight_path.write_text(json.dumps(preflight), encoding="utf-8")

            real_atomic_write = module.atomic_write_json

            def fail_final_output(path, value, **kwargs):
                if Path(path) == output_path:
                    raise OSError("simulated final evidence failure")
                return real_atomic_write(path, value, **kwargs)

            with mock.patch.object(
                module, "atomic_write_json", side_effect=fail_final_output
            ):
                exit_code = module.main(
                    [
                        "--inventory",
                        str(inventory_path),
                        "--preflight",
                        str(preflight_path),
                        "--topology",
                        str(topology),
                        "--artifact-root",
                        str(artifact_root),
                        "--bundle",
                        str(bundle),
                        "--output",
                        str(output_path),
                        "--recovery-output",
                        str(recovery_path),
                        "--stage",
                    ],
                    runner=FakeStageRunner(),
                )
            recovery = json.loads(recovery_path.read_text(encoding="ascii"))
            rollback_runner = FakeStageRunner()
            rollback = module.rollback_deployment(
                inventory,
                recovery,
                rollback_runner,
            )

        self.assertEqual(exit_code, 3)
        self.assertEqual(recovery["operation"], "stage_only")
        self.assertEqual(recovery["status"], "staged")
        self.assertEqual(rollback["status"], "rolled_back")
        self.assertEqual(
            [call for call in rollback_runner.calls if call[0] == "rollback"],
            [("rollback", "controller"), ("rollback", "target"), ("rollback", "source")],
        )

    def test_same_second_stages_use_distinct_transaction_ids(self):
        module = load_module()
        current = datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc)
        reports = []
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            for temporary in (first, second):
                reports.append(
                    call_stage_deployment(
                        module,
                        inventory_value(),
                        preflight_value(),
                        write_bundle(Path(temporary)),
                        FakeStageRunner(),
                        now=current,
                    )
                )

        self.assertNotEqual(reports[0]["backup_id"], reports[1]["backup_id"])
        for report in reports:
            self.assertIn(
                f"-{report['bundle_manifest_sha256'][:12]}-",
                report["backup_id"],
            )

    def test_explicit_rollback_uses_receipt_and_reverse_node_order(self):
        module = load_module()
        runner = FakeStageRunner()
        current = datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temporary:
            bundle = write_bundle(Path(temporary))
            receipt = call_stage_deployment(
                module,
                inventory_value(),
                preflight_value(),
                bundle,
                runner,
                now=current,
            )
            runner.calls.clear()
            report = module.rollback_deployment(
                inventory_value(),
                receipt,
                runner,
                now=current,
            )

        self.assertEqual(report["status"], "rolled_back")
        self.assertFalse(report["staged"])
        self.assertFalse(report["safety"]["systemd_manager_reloaded"])
        self.assertEqual(
            runner.calls,
            [
                ("verify", "controller"),
                ("rollback", "controller"),
                ("verify", "target"),
                ("rollback", "target"),
                ("verify", "source"),
                ("rollback", "source"),
            ],
        )

    def test_rollback_cli_does_not_require_build_or_bundle_inputs(self):
        module = load_module()
        current = datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inventory = inventory_value()
            receipt = call_stage_deployment(
                module,
                inventory,
                preflight_value(),
                write_bundle(root),
                FakeStageRunner(),
                now=current,
            )
            inventory_path = root / "inventory.json"
            receipt_path = root / "receipt.json"
            output_path = root / "rollback.json"
            inventory_path.write_text(json.dumps(inventory), encoding="utf-8")
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            runner = FakeStageRunner()

            exit_code = module.main(
                [
                    "--inventory",
                    str(inventory_path),
                    "--receipt",
                    str(receipt_path),
                    "--output",
                    str(output_path),
                    "--rollback",
                ],
                runner=runner,
            )
            report = json.loads(output_path.read_text(encoding="ascii"))

        self.assertEqual(exit_code, 0)
        self.assertEqual(report["status"], "rolled_back")
        self.assertEqual(
            [call for call in runner.calls if call[0] == "rollback"],
            [("rollback", "controller"), ("rollback", "target"), ("rollback", "source")],
        )

    def test_rollback_cli_never_overwrites_its_stage_receipt(self):
        module = load_module()
        current = datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inventory = inventory_value()
            receipt = call_stage_deployment(
                module,
                inventory,
                preflight_value(),
                write_bundle(root),
                FakeStageRunner(),
                now=current,
            )
            inventory_path = root / "inventory.json"
            receipt_path = root / "receipt.json"
            inventory_path.write_text(json.dumps(inventory), encoding="utf-8")
            original = json.dumps(receipt)
            receipt_path.write_text(original, encoding="utf-8")
            runner = FakeStageRunner()

            exit_code = module.main(
                [
                    "--inventory",
                    str(inventory_path),
                    "--receipt",
                    str(receipt_path),
                    "--output",
                    str(receipt_path),
                    "--rollback",
                ],
                runner=runner,
            )

            self.assertEqual(exit_code, 2)
            self.assertEqual(receipt_path.read_text(encoding="utf-8"), original)
            self.assertEqual(runner.calls, [])

    def test_partial_recovery_intent_rolls_back_confirmed_and_unknown_nodes(self):
        module = load_module()

        class UnknownTargetRunner(FakeStageRunner):
            def rollback_node(self, role, *args):
                self.calls.append(("rollback", role))
                return {
                    "status": "no_transaction" if role == "target" else "rolled_back",
                    "manager_reloaded": False,
                }

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt = call_stage_deployment(
                module,
                inventory_value(),
                preflight_value(),
                write_bundle(root),
                FakeStageRunner(),
                now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
            )
            receipt.update(
                {"operation": "stage_recovery_intent", "status": "staging", "staged": False}
            )
            for node in receipt["nodes"]:
                node["stage_state"] = {
                    "source": "confirmed",
                    "target": "requested",
                    "controller": "not_requested",
                }[node["role"]]
                node["rollback_state"] = "not_requested"
            runner = UnknownTargetRunner()
            report = module.rollback_deployment(inventory_value(), receipt, runner)

        self.assertEqual(report["status"], "rolled_back")
        self.assertEqual(
            [call for call in runner.calls if call[0] == "rollback"],
            [("rollback", "target"), ("rollback", "source")],
        )
        self.assertEqual(
            [node["status"] for node in report["nodes"]],
            ["no_transaction", "rolled_back"],
        )

    def test_confirmed_recovery_node_rejects_missing_remote_transaction(self):
        module = load_module()

        class MissingTransactionRunner(FakeStageRunner):
            def rollback_node(self, role, *args):
                self.calls.append(("rollback", role))
                return {"status": "no_transaction", "manager_reloaded": False}

        with tempfile.TemporaryDirectory() as temporary:
            receipt = call_stage_deployment(
                module,
                inventory_value(),
                preflight_value(),
                write_bundle(Path(temporary)),
                FakeStageRunner(),
                now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
            )
            receipt.update(
                {"operation": "stage_recovery_intent", "status": "staging", "staged": False}
            )
            for node in receipt["nodes"]:
                node["stage_state"] = (
                    "confirmed" if node["role"] == "source" else "not_requested"
                )
                node["rollback_state"] = "not_requested"
            runner = MissingTransactionRunner()
            with self.assertRaises(module.RollbackDeploymentError):
                module.rollback_deployment(inventory_value(), receipt, runner)

        self.assertEqual(
            [call for call in runner.calls if call[0] == "rollback"],
            [("rollback", "source")],
        )

    def test_remote_systemctl_state_accepts_only_confirmed_status_protocol(self):
        module = load_module()
        state = load_remote_systemctl_state(module)
        results = [
            subprocess.CompletedProcess([], 3, "inactive\n", ""),
            subprocess.CompletedProcess([], 1, "disabled\n", ""),
        ]
        with mock.patch.object(subprocess, "run", side_effect=results) as run:
            observed = state("vnet-test.service")
        self.assertEqual(observed, {"active": "inactive", "enabled": "disabled"})
        self.assertTrue(all(call.kwargs["timeout"] == 10 for call in run.call_args_list))

    def test_remote_systemctl_state_fails_closed_on_abnormal_or_empty_output(self):
        module = load_module()
        state = load_remote_systemctl_state(module)
        cases = (
            [subprocess.CompletedProcess([], 1, "inactive\n", "")],
            [subprocess.CompletedProcess([], 3, "", "")],
            [
                subprocess.CompletedProcess([], 3, "inactive\n", ""),
                subprocess.CompletedProcess([], 1, "", ""),
            ],
        )
        for results in cases:
            with self.subTest(results=results):
                with mock.patch.object(subprocess, "run", side_effect=results):
                    with self.assertRaisesRegex(RuntimeError, "rejected"):
                        state("vnet-test.service")

    def test_remote_systemctl_state_fails_closed_on_timeout(self):
        module = load_module()
        state = load_remote_systemctl_state(module)
        with mock.patch.object(
            subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(["systemctl"], 10),
        ):
            with self.assertRaisesRegex(RuntimeError, "rejected"):
                state("vnet-test.service")

    def test_rollback_rejects_receipt_with_another_manifest(self):
        module = load_module()
        runner = FakeStageRunner()
        current = datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temporary:
            bundle = write_bundle(Path(temporary))
            receipt = call_stage_deployment(
                module,
                inventory_value(),
                preflight_value(),
                bundle,
                runner,
                now=current,
            )
            runner.calls.clear()
            receipt["bundle_manifest_sha256"] = "0" * 64
            with self.assertRaisesRegex(module.DeploymentError, "receipt"):
                module.rollback_deployment(
                    inventory_value(),
                    receipt,
                    runner,
                    now=current,
                )
        self.assertEqual(runner.calls, [])

    def test_later_node_failure_rolls_back_completed_nodes_and_stops(self):
        module = load_module()
        runner = FailingTargetRunner()
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(module.DeploymentError, "target") as raised:
                call_stage_deployment(
                    module,
                    inventory_value(),
                    preflight_value(),
                    write_bundle(Path(temporary)),
                    runner,
                    now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
                )

        self.assertEqual(
            runner.calls,
            [
                ("verify", "source"),
                ("inspect", "source"),
                ("verify", "target"),
                ("inspect", "target"),
                ("verify", "controller"),
                ("inspect", "controller"),
                ("stage", "source"),
                ("stage", "target"),
                ("rollback", "target"),
                ("rollback", "source"),
            ],
        )
        self.assertNotIn("sensitive remote failure", str(raised.exception))
        self.assertEqual(raised.exception.failed_role, "target")
        self.assertFalse(raised.exception.rollback_incomplete)
        self.assertTrue(
            raised.exception.backup_id.startswith("codex-backup-20260801T090500Z-")
        )

    def test_bundle_cannot_redirect_a_role_to_another_ssh_destination(self):
        module = load_module()
        runner = FakeRunner()
        with tempfile.TemporaryDirectory() as temporary:
            bundle = write_bundle(Path(temporary))
            manifest_path = bundle / "bundle-manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["hosts"][1]["ssh_destination"] = "ubuntu@172.25.6.12"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaisesRegex(module.DeploymentError, "destination"):
                call_stage_deployment(
                    module,
                    inventory_value(),
                    preflight_value(),
                    bundle,
                    runner,
                    dry_run=True,
                    now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
                )

        self.assertEqual(runner.calls, [])

    def test_default_runner_uses_pinned_ed25519_public_key_only_ssh(self):
        module = load_module()
        key = bytes(range(32))
        key_text = base64.b64encode(key).decode("ascii")
        expected_fingerprint = (
            "SHA256:"
            + base64.b64encode(hashlib.sha256(key).digest())
            .decode("ascii")
            .rstrip("=")
        )
        node = {
            "address": "172.25.6.13",
            "ssh_user": "ubuntu",
            "expected_hostname": "compute2",
            "host_key_fingerprint": expected_fingerprint,
        }
        calls = []

        def run(argv, **kwargs):
            command = list(argv)
            calls.append((command, kwargs))
            if command[0] == "ssh-keyscan":
                return subprocess.CompletedProcess(
                    command,
                    0,
                    f"172.25.6.13 ssh-ed25519 {key_text}\n",
                    "",
                )
            request = json.loads(kwargs["input"])
            self.assertEqual(request["action"], "inspect")
            response = {
                "ok": True,
                "activation_marker_absent": True,
                "targets": [
                    {
                        "target": "/etc/vnet-dataplane-shared/config.env",
                        "exists": False,
                        "symlink": False,
                    }
                ],
                "units": {
                    "vnet-dataplane-shared-agent.service": {
                        "active": "inactive",
                        "enabled": "disabled",
                    }
                },
            }
            return subprocess.CompletedProcess(
                command, 0, json.dumps(response), ""
            )

        with mock.patch.object(module.subprocess, "run", side_effect=run):
            runner = module.SSHStageRunner()
            try:
                self.assertEqual(
                    runner.verify_host_key("source", node, 3), expected_fingerprint
                )
                result = runner.inspect_node(
                    "source",
                    node,
                    [
                        {
                            "target": "/etc/vnet-dataplane-shared/config.env",
                            "mode": "0600",
                            "sha256": "a" * 64,
                            "payload": b"not-sent-by-inspect",
                        }
                    ],
                    ("vnet-dataplane-shared-agent.service",),
                    3,
                )
            finally:
                runner.close()

        self.assertFalse(result["targets"][0]["exists"])
        ssh, kwargs = next(item for item in calls if item[0][0] == "ssh")
        for option in (
            "BatchMode=yes",
            "PasswordAuthentication=no",
            "KbdInteractiveAuthentication=no",
            "PreferredAuthentications=publickey",
            "IdentitiesOnly=yes",
            "StrictHostKeyChecking=yes",
            "HostKeyAlgorithms=ssh-ed25519",
            "ForwardAgent=no",
            "ClearAllForwardings=yes",
        ):
            self.assertIn(option, ssh)
        self.assertEqual(ssh[-2], "ubuntu@172.25.6.13")
        self.assertIn("sudo -n -- /usr/bin/python3 -I -B -c", ssh[-1])
        request = json.loads(kwargs["input"])
        self.assertNotIn("payload_b64", json.dumps(request))

    def test_tampered_bundle_file_is_rejected_before_ssh(self):
        module = load_module()
        runner = FakeRunner()
        with tempfile.TemporaryDirectory() as temporary:
            bundle = write_bundle(Path(temporary))
            (bundle / "source" / "config.env").write_text(
                "tampered=true\n", encoding="ascii"
            )
            with self.assertRaisesRegex(module.DeploymentError, "SHA256"):
                call_stage_deployment(
                    module,
                    inventory_value(),
                    preflight_value(),
                    bundle,
                    runner,
                    dry_run=True,
                    now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
                )
        self.assertEqual(runner.calls, [])

    def test_manifest_cannot_authorize_a_broader_sudoers_fragment(self):
        module = load_module()
        runner = FakeRunner()
        with tempfile.TemporaryDirectory() as temporary:
            bundle = write_bundle(Path(temporary))
            manifest_path = bundle / "bundle-manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            record = next(
                item
                for item in manifest["files"]
                if item["role"] == "source"
                and item["target"]
                == "/etc/vnet-dataplane-shared/vnet-dataplane-shared.sudoers.pending"
            )
            payload = b"ubuntu ALL=(root) NOPASSWD: ALL\n"
            (bundle / record["source"]).write_bytes(payload)
            record["sha256"] = hashlib.sha256(payload).hexdigest()
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaisesRegex(module.DeploymentError, "least-privilege"):
                call_stage_deployment(
                    module,
                    inventory_value(),
                    preflight_value(),
                    bundle,
                    runner,
                    dry_run=True,
                    now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
                )
        self.assertEqual(runner.calls, [])

    def test_stale_preflight_is_rejected_before_ssh(self):
        module = load_module()
        runner = FakeRunner()
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(module.DeploymentError, "stale"):
                call_stage_deployment(
                    module,
                    inventory_value(),
                    preflight_value(),
                    write_bundle(Path(temporary)),
                    runner,
                    dry_run=True,
                    now=datetime(2026, 8, 1, 10, 0, tzinfo=timezone.utc),
                )
        self.assertEqual(runner.calls, [])

    def test_incomplete_snapshot_confirmation_is_rejected_before_ssh(self):
        module = load_module()
        runner = FakeRunner()
        preflight = preflight_value()
        preflight["snapshot"]["command_count"] -= 1
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(module.DeploymentError, "command set"):
                call_stage_deployment(
                    module,
                    inventory_value(),
                    preflight,
                    write_bundle(Path(temporary)),
                    runner,
                    dry_run=True,
                    now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
                )
        self.assertEqual(runner.calls, [])

    def test_preflight_expiring_during_inspection_blocks_all_remote_writes(self):
        module = load_module()
        runner = FakeRunner()
        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch.object(
                module,
                "_utc_now_datetime",
                side_effect=[
                    datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
                    datetime(2026, 8, 1, 9, 6, 1, tzinfo=timezone.utc),
                ],
            ):
                with self.assertRaisesRegex(
                    module.DeploymentError, "expired during pre-stage inspection"
                ):
                    call_stage_deployment(
                        module,
                        inventory_value(),
                        preflight_value(),
                        write_bundle(Path(temporary)),
                        runner,
                        dry_run=True,
                        max_preflight_age_seconds=120,
                    )
        self.assertEqual(
            runner.calls,
            [
                ("verify", "source"),
                ("inspect", "source"),
                ("verify", "target"),
                ("inspect", "target"),
                ("verify", "controller"),
                ("inspect", "controller"),
            ],
        )

    def test_preflight_expiring_between_nodes_rolls_back_completed_stage(self):
        module = load_module()
        runner = FakeStageRunner()
        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch.object(
                module,
                "_utc_now_datetime",
                side_effect=[
                    datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
                    datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
                    datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
                    datetime(2026, 8, 1, 9, 6, 1, tzinfo=timezone.utc),
                ],
            ):
                with self.assertRaises(module.StageDeploymentError) as raised:
                    call_stage_deployment(
                        module,
                        inventory_value(),
                        preflight_value(),
                        write_bundle(Path(temporary)),
                        runner,
                        max_preflight_age_seconds=120,
                    )

        self.assertEqual(raised.exception.failed_role, "target")
        self.assertFalse(raised.exception.rollback_incomplete)
        self.assertIn(("stage", "source"), runner.calls)
        self.assertIn(("rollback", "source"), runner.calls)
        self.assertNotIn(("stage", "target"), runner.calls)
        self.assertNotIn(("stage", "controller"), runner.calls)

    def test_incomplete_preflight_gate_set_is_rejected_before_ssh(self):
        module = load_module()
        runner = FakeRunner()
        preflight = preflight_value()
        preflight["gates"] = preflight["gates"][:-1]
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(module.DeploymentError, "gate set"):
                call_stage_deployment(
                    module,
                    inventory_value(),
                    preflight,
                    write_bundle(Path(temporary)),
                    runner,
                    dry_run=True,
                    now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
                )
        self.assertEqual(runner.calls, [])

    def test_active_shared_unit_blocks_before_any_file_is_staged(self):
        module = load_module()
        runner = ActiveUnitRunner()
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(module.DeploymentError, "source"):
                call_stage_deployment(
                    module,
                    inventory_value(),
                    preflight_value(),
                    write_bundle(Path(temporary)),
                    runner,
                    now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
                )
        self.assertEqual(
            runner.calls, [("verify", "source"), ("inspect", "source")]
        )

    def test_existing_shared_target_blocks_instead_of_overwriting(self):
        module = load_module()
        runner = ExistingTargetRunner()
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                module.DeploymentError, "pre-stage verification failed on source"
            ):
                call_stage_deployment(
                    module,
                    inventory_value(),
                    preflight_value(),
                    write_bundle(Path(temporary)),
                    runner,
                    now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
                )
        self.assertEqual(
            runner.calls, [("verify", "source"), ("inspect", "source")]
        )

    def test_stale_activation_marker_blocks_staging(self):
        module = load_module()
        runner = StaleActivationMarkerRunner()
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                module.DeploymentError, "pre-stage verification failed on source"
            ):
                call_stage_deployment(
                    module,
                    inventory_value(),
                    preflight_value(),
                    write_bundle(Path(temporary)),
                    runner,
                    now=datetime(2026, 8, 1, 9, 5, tzinfo=timezone.utc),
                )
        self.assertEqual(
            runner.calls, [("verify", "source"), ("inspect", "source")]
        )

    def test_remote_helper_never_reloads_or_activates_systemd_during_stage(self):
        module = load_module()
        compile(module._REMOTE_HELPER_SOURCE, "<remote-helper>", "exec")
        source = module._REMOTE_HELPER_SOURCE
        self.assertNotIn('"daemon-reload"', source)
        self.assertNotIn("daemon_reload", source)
        self.assertIn('"is-active"', source)
        self.assertIn('"is-enabled"', source)
        self.assertIn('"/usr/sbin/visudo", "-cf"', source)
        tree = ast.parse(source)
        functions = {
            node.name: node
            for node in tree.body
            if isinstance(node, ast.FunctionDef)
        }
        restore_calls = {
            node.func.id
            for node in ast.walk(functions["restore"])
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
        }
        self.assertIn("fsync_parent", restore_calls)
        backup_fsync_arguments = {
            ast.unparse(node.args[0])
            for node in ast.walk(functions["create_backup"])
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "fsync_parent"
            and len(node.args) == 1
        }
        self.assertEqual(
            backup_fsync_arguments,
            {"BACKUP_BASE", "backup_root", "files_root"},
        )
        self.assertIn("os.O_EXCL", source)
        self.assertIn("os.link(temporary, path", source)
        self.assertIn("fcntl.flock", source)
        self.assertIn('manifest.get("bundle_manifest_sha256")', source)
        self.assertIn('manifest["transactions"]', source)
        self.assertIn('transaction["published"] = True', source)
        self.assertIn('record["staged_sha256"]', source)
        for forbidden in ('"start"', '"stop"', '"restart"', '"enable"', '"disable"'):
            self.assertNotIn(forbidden, source)

    def test_remote_inspect_is_lock_free_but_stage_and_rollback_are_locked(self):
        module = load_module()
        source = module._REMOTE_HELPER_SOURCE
        tree = ast.parse(source)
        functions = {
            node.name: node
            for node in tree.body
            if isinstance(node, ast.FunctionDef)
        }

        def source_for(name):
            return ast.get_source_segment(source, functions[name])

        def called_names(statements):
            wrapper = ast.Module(body=list(statements), type_ignores=[])
            return {
                node.func.id
                for node in ast.walk(wrapper)
                if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
            }

        def action_branch(action):
            return next(
                node
                for node in ast.walk(functions["main"])
                if isinstance(node, ast.If)
                and action
                in {
                    value.value
                    for value in ast.walk(node.test)
                    if isinstance(value, ast.Constant)
                    and isinstance(value.value, str)
                }
            )

        inspect_source = source_for("inspect")
        main_source = source_for("main")
        lock_source = source_for("run_locked")
        self.assertNotIn("os.open", inspect_source)
        self.assertNotIn("O_CREAT", inspect_source)
        self.assertNotIn("flock", inspect_source)
        self.assertNotIn("os.open", main_source)
        self.assertNotIn("O_CREAT", main_source)
        self.assertNotIn("flock", main_source)
        self.assertIn("os.open", lock_source)
        self.assertIn("O_CREAT", lock_source)
        self.assertIn("fcntl.flock", lock_source)
        self.assertEqual(called_names(action_branch("inspect").body), {"inspect"})
        self.assertIn("run_locked", called_names(action_branch("stage").body))
        self.assertIn("run_locked", called_names(action_branch("rollback").body))
        self.assertIn("inspect", called_names(functions["stage"].body))


if __name__ == "__main__":
    unittest.main()
