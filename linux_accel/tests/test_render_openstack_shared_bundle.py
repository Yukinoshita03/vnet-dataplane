import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


LINUX_ACCEL = Path(__file__).resolve().parents[1]
if str(LINUX_ACCEL) not in sys.path:
    sys.path.insert(0, str(LINUX_ACCEL))

from agent.openstack_dataplane_agent import _load_endpoint_configs
from agent.openstack_epoch_coordinator import load_config as load_coordinator_config
from agent.openstack_guest_endpoint_agent import load_endpoint_config
from agent.openstack_metrics_bridge import load_config as load_metrics_config
from bench import render_openstack_shared_bundle as renderer
from bench.openstack_shared_cluster_preflight import validate_inventory


CLIENT_SERVER_ID = "11111111-2222-3333-4444-555555555555"
CLIENT_PORT_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
BACKEND_SERVER_ID = "66666666-7777-8888-9999-aaaaaaaaaaaa"
BACKEND_PORT_ID = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
OWNER_PROJECT_ID = "cccccccc-dddd-eeee-ffff-000000000001"
OWNERSHIP_TAG = "vnet-dataplane-owner-shared-yoga-test"
CLIENT_MAC = "fa:16:3e:00:00:21"
BACKEND_MAC = "fa:16:3e:00:00:22"


def fingerprint(seed):
    import base64

    value = hashlib.sha256(seed.encode("ascii")).digest()
    return "SHA256:" + base64.b64encode(value).decode("ascii").rstrip("=")


def topology_value():
    return {
        "schema_version": 1,
        "deployment_id": "shared-yoga-test",
        "known_hosts_file": (
            "/etc/vnet-dataplane-agent/known_hosts.shared-yoga-test"
        ),
        "inventory": {
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
                "disk_gb": 20,
            },
            "roles": {
                "controller": {
                    "address": "172.25.6.11",
                    "ssh_user": "ubuntu",
                    "expected_hostname": "controller",
                    "host_key_fingerprint": fingerprint("controller"),
                    "expected_clock_reference": "192.0.2.1",
                    "openstack_cloud": "shared-readonly",
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
                    "required_tap_interfaces": [
                        "tapclient-src",
                        "tapbackend-src",
                    ],
                    "required_port_bindings": {
                        CLIENT_PORT_ID: "tapclient-src",
                        BACKEND_PORT_ID: "tapbackend-src",
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
        },
        "hosts": {
            "controller": {
                "ssh_destination": "ubuntu@172.25.6.11",
            },
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
            "source": {
                "client": "tapclient-src",
                "backend": "tapbackend-src",
            },
            "target": {
                "client": "tapclient-src",
                "backend": "tapbackend-src",
            },
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


def write_topology(root, value=None):
    path = root / "topology.json"
    path.write_text(
        json.dumps(value if value is not None else topology_value()),
        encoding="utf-8",
    )
    return path


def write_artifacts(root):
    artifact_root = root / "artifacts-input"
    for relative in renderer.required_artifact_paths():
        path = artifact_root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes((f"artifact:{relative}\n").encode("ascii"))
    return artifact_root


class RenderOpenStackSharedBundleTest(unittest.TestCase):
    def test_renders_valid_credential_free_three_host_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            topology_path = write_topology(root)
            artifact_root = write_artifacts(root)
            output = root / "bundle"

            manifest = renderer.render_bundle(topology_path, output, artifact_root)

            expected = {
                "bundle-manifest.json",
                "controller/coordinator.json",
                "controller/coordinator.env",
                "controller/metrics-bridge.json",
                "controller/metrics-bridge.env",
                "source/endpoints.json",
                "source/agent.env",
                "target/endpoints.json",
                "target/agent.env",
                "guest-files/client/endpoint.json",
                "guest-files/client/guest-endpoint.env",
                "guest-files/backend/endpoint.json",
                "guest-files/backend/guest-endpoint.env",
                "source/tools/cache_policy_txn",
                "source/tools/snapshot_log",
                "source/shared.sudoers",
                "target/tools/cache_policy_txn",
                "target/tools/snapshot_log",
                "target/shared.sudoers",
            }
            expected.update(
                f"artifacts/{relative}"
                for relative in renderer.required_artifact_paths()
                if "/deploy/systemd/" not in relative
            )
            expected.update(
                f"systemd/{Path(relative).name}"
                for relative in renderer.required_artifact_paths()
                if "/deploy/systemd/" in relative
            )
            observed = {
                path.relative_to(output).as_posix()
                for path in output.rglob("*")
                if path.is_file()
            }
            self.assertEqual(observed, expected)

            normalized_inventory = validate_inventory(topology_value()["inventory"])
            inventory_bytes = renderer.canonical_json_bytes(normalized_inventory)
            self.assertEqual(
                manifest["inventory_sha256"], hashlib.sha256(inventory_bytes).hexdigest()
            )
            self.assertEqual(
                {item["role"] for item in manifest["files"]},
                {"controller", "source", "target"},
            )
            self.assertEqual(
                {item["role"] for item in manifest["hosts"]},
                {"controller", "source", "target"},
            )
            self.assertEqual(
                {item["role"] for item in manifest["guest_files"]},
                {"client", "backend"},
            )
            config_records = [
                item
                for item in manifest["files"]
                if item["target"].startswith("/etc/vnet-dataplane-shared/")
            ]
            self.assertTrue(config_records)
            self.assertTrue(all(item["mode"] == "0600" for item in config_records))
            pending_sudoers = [
                item
                for item in manifest["files"]
                if item["target"]
                == "/etc/vnet-dataplane-shared/vnet-dataplane-shared.sudoers.pending"
            ]
            self.assertEqual(len(pending_sudoers), 2)
            self.assertTrue(all(item["mode"] == "0600" for item in pending_sudoers))
            self.assertFalse(
                any(
                    item["target"].startswith("/etc/sudoers.d/")
                    for item in manifest["files"]
                )
            )
            for item in manifest["files"] + manifest["guest_files"]:
                payload = (output / item["source"]).read_bytes()
                self.assertEqual(item["sha256"], hashlib.sha256(payload).hexdigest())

            coordinator_path = output / "controller" / "coordinator.json"
            coordinator = json.loads(coordinator_path.read_text(encoding="utf-8"))
            load_coordinator_config(coordinator_path)
            compute_sources = [
                item
                for item in coordinator["state_sources"]
                if item["kind"] == "compute_agent"
            ]
            self.assertEqual(
                {item["name"] for item in compute_sources}, {"compute2", "compute3"}
            )
            remote_compute_publishers = [
                item
                for item in coordinator["publishers"]
                if item["target_kind"] == "compute_port"
            ]
            self.assertEqual(
                {item["host"] for item in remote_compute_publishers},
                {"compute2", "compute3"},
            )
            self.assertEqual(
                {item["ssh_destination"] for item in remote_compute_publishers},
                {"ubuntu@172.25.6.13", "ubuntu@172.25.6.14"},
            )

            metrics_path = output / "controller" / "metrics-bridge.json"
            metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
            load_metrics_config(metrics_path)
            commands = [
                item["command"]
                for item in coordinator["state_sources"] + metrics["sources"]
                if "command" in item
            ] + [item["command"] for item in coordinator["publishers"]]
            self.assertTrue(commands)
            for command in commands:
                self.assertIn("BatchMode=yes", command)
                self.assertIn("StrictHostKeyChecking=yes", command)
                self.assertIn("HostKeyAlgorithms=ssh-ed25519", command)
                self.assertIn(
                    "UserKnownHostsFile=/etc/vnet-dataplane-agent/known_hosts.shared-yoga-test",
                    command,
                )

            for role, nova_host in (("source", "compute2"), ("target", "compute3")):
                endpoints_path = output / role / "endpoints.json"
                endpoints = _load_endpoint_configs(endpoints_path)
                self.assertEqual(len(endpoints), 2)
                self.assertEqual(
                    {item.server_id: item.port_ids for item in endpoints},
                    {
                        CLIENT_SERVER_ID: (CLIENT_PORT_ID,),
                        BACKEND_SERVER_ID: (BACKEND_PORT_ID,),
                    },
                )
                env = (output / role / "agent.env").read_text(encoding="ascii")
                self.assertIn(f"VNET_LOCAL_HOST={nova_host}\n", env)
                self.assertIn("OS_CLOUD=shared-readonly\n", env)
                self.assertIn("VNET_DEPLOYMENT_ID=shared-yoga-test\n", env)

            client = load_endpoint_config(
                output / "guest-files" / "client" / "endpoint.json"
            )
            backend = load_endpoint_config(
                output / "guest-files" / "backend" / "endpoint.json"
            )
            self.assertEqual(client.interface, "ens3")
            self.assertEqual(backend.interface, "ens3")

            serialized = json.dumps(manifest).lower()
            for forbidden in ("password", "private_key", "auth_token", "secret"):
                self.assertNotIn(forbidden, serialized)

            for role in ("source", "target"):
                cache_wrapper = output / role / "tools" / "cache_policy_txn"
                rejected = subprocess.run(
                    [
                        sys.executable,
                        str(cache_wrapper),
                        "--control-map",
                        "/sys/fs/bpf/unowned/cache_runtime_control",
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
                )
                self.assertNotEqual(rejected.returncode, 0)
                sudoers = (output / role / "shared.sudoers").read_text(
                    encoding="ascii"
                )
                self.assertIn("/bin/cache_policy_txn *", sudoers)
                self.assertNotIn("/build/cache_policy_txn *", sudoers)

    def test_rejects_unsafe_or_noncanonical_identity_fields(self):
        cases = {}

        value = topology_value()
        value["deployment_id"] = "../shared"
        cases["deployment"] = value

        value = topology_value()
        value["guests"]["client"]["port_id"] = CLIENT_PORT_ID.upper()
        cases["UUID"] = value

        value = topology_value()
        value["guests"]["client"]["private_ipv4"] = "192.0.2.10"
        value["guests"]["client"]["ssh_destination"] = "ubuntu@192.0.2.10"
        cases["private IPv4"] = value

        value = topology_value()
        value["guests"]["client"]["private_ipv4"] = "10.42.0.31"
        value["guests"]["client"]["ssh_destination"] = "ubuntu@10.42.0.31"
        cases["fixed IPv4 addresses"] = value

        value = topology_value()
        value["guests"]["client"]["mac_address"] = "FA:16:3E:00:00:21"
        cases["lowercase MAC"] = value

        value = topology_value()
        value["guests"]["client"]["mac_address"] = "fa:16:3e:00:00:31"
        cases["guest MAC addresses"] = value

        value = topology_value()
        value["interfaces"]["target"]["backend"] = "tap;unsafe"
        cases["interface"] = value

        value = topology_value()
        value["hosts"]["source"]["nova_host"] = "ubuntu@172.25.6.13"
        cases["Nova host"] = value

        value = topology_value()
        value["interfaces"]["target"]["client"] = "tapclient-dst"
        cases["port-stable"] = value

        for expected, candidate in cases.items():
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                topology_path = write_topology(root, candidate)
                artifact_root = write_artifacts(root)
                with self.assertRaisesRegex(renderer.BundleError, expected):
                    renderer.render_bundle(
                        topology_path, root / "bundle", artifact_root
                    )

    def test_rejects_credentials_unknown_fields_and_existing_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            value = topology_value()
            value["hosts"]["controller"]["password"] = "do-not-store"
            topology_path = write_topology(root, value)
            artifact_root = write_artifacts(root)
            with self.assertRaisesRegex(renderer.BundleError, "unknown field"):
                renderer.render_bundle(topology_path, root / "bundle", artifact_root)

            topology_path = write_topology(root)
            output = root / "existing"
            output.mkdir()
            (output / "keep").write_text("owned by user", encoding="ascii")
            with self.assertRaisesRegex(renderer.BundleError, "already exists"):
                renderer.render_bundle(topology_path, output, artifact_root)
            self.assertEqual((output / "keep").read_text(encoding="ascii"), "owned by user")

    def test_concurrent_output_creation_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            topology_path = write_topology(root)
            artifact_root = write_artifacts(root)
            output = root / "raced-output"
            publish = renderer._publish_directory_exclusive

            def create_competing_output(source, destination):
                destination.mkdir()
                (destination / "keep").write_text("owned by another process", encoding="ascii")
                publish(source, destination)

            with mock.patch.object(
                renderer,
                "_publish_directory_exclusive",
                side_effect=create_competing_output,
            ):
                with self.assertRaisesRegex(renderer.BundleError, "already exists"):
                    renderer.render_bundle(topology_path, output, artifact_root)

            self.assertEqual(
                (output / "keep").read_text(encoding="ascii"),
                "owned by another process",
            )

    def test_missing_build_artifact_fails_before_bundle_is_created(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            topology_path = write_topology(root)
            artifact_root = write_artifacts(root)
            missing = artifact_root / "linux_accel" / "build" / "grpc_monitor"
            missing.unlink()
            output = root / "bundle"

            with self.assertRaisesRegex(renderer.BundleError, "required artifact"):
                renderer.render_bundle(topology_path, output, artifact_root)

            self.assertFalse(output.exists())

    def test_duplicate_topology_field_fails_before_bundle_is_created(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            topology_path = root / "topology.json"
            topology_path.write_text(
                '{"schema_version":1,"schema_version":1}', encoding="utf-8"
            )
            output = root / "bundle"

            with self.assertRaisesRegex(
                renderer.BundleError, "duplicate topology field"
            ):
                renderer.render_bundle(topology_path, output, root / "artifacts")

            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
