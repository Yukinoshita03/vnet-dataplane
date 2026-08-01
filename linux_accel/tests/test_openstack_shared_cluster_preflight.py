import contextlib
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "bench"
    / "openstack_shared_cluster_preflight.py"
)


def load_module():
    name = "openstack_shared_cluster_preflight"
    spec = importlib.util.spec_from_file_location(name, MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    finally:
        sys.modules.pop(name, None)
    return module


FINGERPRINTS = {
    "controller": "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "source": "SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
    "target": "SHA256:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
}

CLIENT_PORT_ID = "11111111-1111-1111-1111-111111111111"
BACKEND_PORT_ID = "22222222-2222-2222-2222-222222222222"
CLIENT_SERVER_ID = "33333333-3333-3333-3333-333333333333"
BACKEND_SERVER_ID = "44444444-4444-4444-4444-444444444444"
OWNER_PROJECT_ID = "55555555-5555-5555-5555-555555555555"
OWNERSHIP_TAG = "vnet-dataplane-owner-shared-yoga-test"
CLIENT_IPV4 = "10.42.0.21"
BACKEND_IPV4 = "10.42.0.22"
CLIENT_MAC = "fa:16:3e:00:00:21"
BACKEND_MAC = "fa:16:3e:00:00:22"


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
            CLIENT_PORT_ID: CLIENT_IPV4,
            BACKEND_PORT_ID: BACKEND_IPV4,
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
                "host_key_fingerprint": FINGERPRINTS["controller"],
                "expected_clock_reference": "192.0.2.1",
                "openstack_cloud": "vnet-readonly",
            },
            "source": {
                "address": "172.25.6.13",
                "ssh_user": "ubuntu",
                "expected_hostname": "compute2",
                "host_key_fingerprint": FINGERPRINTS["source"],
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
                "host_key_fingerprint": FINGERPRINTS["target"],
                "expected_clock_reference": "192.0.2.1",
                "allowed_libvirt_domains": [],
                "required_ovs_bridges": ["br-int"],
                "required_tap_interfaces": [],
                "required_port_bindings": {},
            },
        },
    }


def chrony(
    offset_seconds=0.001,
    leap="Normal",
    reference_id="192.0.2.1",
    root_delay_seconds=0.002,
    root_dispersion_seconds=0.001,
):
    direction = "fast" if offset_seconds >= 0 else "slow"
    return (
        f"Reference ID    : {reference_id}\n"
        "Stratum         : 3\n"
        f"System time     : {abs(offset_seconds):.9f} seconds {direction} of NTP time\n"
        f"Root delay      : {root_delay_seconds:.9f} seconds\n"
        f"Root dispersion : {root_dispersion_seconds:.9f} seconds\n"
        f"Leap status     : {leap}\n"
    )


def ovs_names(*names):
    return json.dumps({"headings": ["name"], "data": [[name] for name in names]})


def ovs_interfaces(*bindings):
    return json.dumps(
        {
            "headings": ["name", "external_ids"],
            "data": [
                [
                    name,
                    ["map", [["iface-id", iface_id]]] if iface_id else ["map", []],
                ]
                for name, iface_id in bindings
            ],
        }
    )


def passing_outputs():
    common = {}
    for role, hostname in (
        ("controller", "controller"),
        ("source", "compute2"),
        ("target", "compute3"),
    ):
        common[(role, "hostname")] = hostname + "\n"
        common[(role, "clock_tracking")] = chrony()
        common[(role, "active_sessions")] = ""

    common.update(
        {
            ("controller", "nova_services"): json.dumps(
                [
                    {
                        "Binary": "nova-scheduler",
                        "Host": "controller",
                        "Status": "enabled",
                        "State": "up",
                    },
                    {
                        "Binary": "nova-conductor",
                        "Host": "controller",
                        "Status": "enabled",
                        "State": "up",
                    },
                    {
                        "Binary": "nova-compute",
                        "Host": "compute2",
                        "Status": "enabled",
                        "State": "up",
                    },
                    {
                        "Binary": "nova-compute",
                        "Host": "compute3",
                        "Status": "enabled",
                        "State": "up",
                    },
                ]
            ),
            ("controller", "neutron_agents"): json.dumps(
                [
                    {
                        "Agent Type": "OVN Controller agent",
                        "Host": host,
                        "Alive": ":-)",
                        "State": "UP",
                    }
                    for host in ("controller", "compute2", "compute3")
                ]
            ),
            ("controller", "migrations"): "[]",
            ("controller", "servers"): json.dumps(
                [
                    {
                        "ID": CLIENT_SERVER_ID,
                        "Name": "owned-client",
                        "Status": "ACTIVE",
                        "Host": "compute2",
                        "Instance Name": "instance-000001",
                        "Project ID": OWNER_PROJECT_ID,
                        "Tags": [OWNERSHIP_TAG],
                    },
                    {
                        "ID": BACKEND_SERVER_ID,
                        "Name": "owned-backend",
                        "Status": "ACTIVE",
                        "Host": "compute2",
                        "Instance Name": "instance-000002",
                        "Project ID": OWNER_PROJECT_ID,
                        "Tags": [OWNERSHIP_TAG],
                    },
                ]
            ),
            ("controller", "ports"): json.dumps(
                [
                    {
                        "ID": CLIENT_PORT_ID,
                        "Status": "ACTIVE",
                        "Device Owner": "compute:nova",
                        "Device ID": CLIENT_SERVER_ID,
                        "Binding Host ID": "compute2",
                        "Project ID": OWNER_PROJECT_ID,
                        "Tags": [OWNERSHIP_TAG],
                        "Fixed IP Addresses": [{"ip_address": CLIENT_IPV4}],
                        "MAC Address": CLIENT_MAC,
                    },
                    {
                        "ID": BACKEND_PORT_ID,
                        "Status": "ACTIVE",
                        "Device Owner": "compute:nova",
                        "Device ID": BACKEND_SERVER_ID,
                        "Binding Host ID": "compute2",
                        "Project ID": OWNER_PROJECT_ID,
                        "Tags": [OWNERSHIP_TAG],
                        "Fixed IP Addresses": [{"ip_address": BACKEND_IPV4}],
                        "MAC Address": BACKEND_MAC,
                    },
                ]
            ),
            ("controller", "hypervisors"): json.dumps(
                [
                    {
                        "Hypervisor Hostname": "compute2",
                        "State": "up",
                        "Status": "enabled",
                        "VCPUs": 8,
                        "VCPUs Used": 2,
                        "Memory MB": 16384,
                        "Memory MB Used": 4096,
                        "Local GB": 200,
                        "Local GB Used": 40,
                    },
                    {
                        "Hypervisor Hostname": "compute3",
                        "State": "up",
                        "Status": "enabled",
                        "VCPUs": 8,
                        "VCPUs Used": 1,
                        "Memory MB": 16384,
                        "Memory MB Used": 2048,
                        "Local GB": 200,
                        "Local GB Used": 20,
                    },
                ]
            ),
            ("source", "libvirt_domains"): "instance-000001\ninstance-000002\n",
            ("target", "libvirt_domains"): "",
            ("source", "ovs_bridges"): ovs_names("br-int", "br-ex"),
            ("target", "ovs_bridges"): ovs_names("br-int", "br-ex"),
            ("source", "ovs_interfaces"): ovs_interfaces(
                ("tap-client", CLIENT_PORT_ID),
                ("tap-backend", BACKEND_PORT_ID),
                ("patch-int", None),
            ),
            ("target", "ovs_interfaces"): ovs_interfaces(("patch-int", None)),
            ("source", "br_int_ports"): "patch-int\ntap-client\ntap-backend\n",
            ("target", "br_int_ports"): "patch-int\n",
            ("source", "links"): json.dumps(
                [
                    {"ifname": "lo"},
                    {"ifname": "tap-client"},
                    {"ifname": "tap-backend"},
                ]
            ),
            ("target", "links"): json.dumps([{"ifname": "lo"}]),
        }
    )
    return common


class FakeRunner:
    def __init__(self, module, outputs=None, fingerprints=None):
        self.module = module
        self.outputs = outputs or passing_outputs()
        self.fingerprints = fingerprints or dict(FINGERPRINTS)
        self.verifications = []
        self.commands = []

    def verify_host_key(self, role, node, timeout):
        self.verifications.append((role, node["address"], timeout))
        return self.fingerprints[role]

    def run(self, role, node, command_id, argv, timeout):
        self.commands.append((role, command_id, tuple(argv)))
        if not self.module.is_command_allowed(role, command_id, argv):
            raise AssertionError(f"non-allowlisted command: {role}/{command_id}/{argv}")
        value = self.outputs[(role, command_id)]
        if isinstance(value, subprocess.CompletedProcess):
            return value
        return subprocess.CompletedProcess(list(argv), 0, value, "")


def gate(report, name):
    return next(item for item in report["gates"] if item["name"] == name)


class OpenStackSharedClusterPreflightTest(unittest.TestCase):
    def test_all_read_only_gates_pass_and_evidence_has_no_credentials(self):
        module = load_module()
        runner = FakeRunner(module)

        report = module.run_preflight(inventory_value(), runner, timeout=3)

        self.assertTrue(report["deploy_allowed"])
        self.assertTrue(all(item["passed"] for item in report["gates"]))
        self.assertEqual(
            {item["role"] for item in report["host_identity"]},
            {"controller", "source", "target"},
        )
        self.assertEqual(report["clock"]["tolerance_ms"], 10)
        self.assertEqual(report["workloads"]["unrelated_server_ids"], [])
        self.assertEqual(report["capacity"]["target_host"], "compute3")
        expected_inventory = module.validate_inventory(inventory_value())
        canonical = json.dumps(
            expected_inventory,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
        ).encode("utf-8")
        self.assertEqual(
            report["inventory"]["sha256"], hashlib.sha256(canonical).hexdigest()
        )
        self.assertEqual(len(runner.verifications), 3)
        self.assertTrue(runner.commands)
        self.assertTrue(report["snapshot"]["confirmed"])
        self.assertEqual(
            report["snapshot"]["command_count"],
            module.SNAPSHOT_CONFIRMATION_COMMAND_COUNT,
        )
        self.assertEqual(
            {item["phase"] for item in report["commands"]},
            {"initial", "confirmation"},
        )
        for role, command_id, argv in runner.commands:
            self.assertTrue(module.is_command_allowed(role, command_id, argv))
        serialized = json.dumps(report).lower()
        for forbidden in ("password", "private_key", "auth_token", "secret"):
            self.assertNotIn(forbidden, serialized)
        for command in report["commands"]:
            self.assertNotIn("stdout", command)
            self.assertNotIn("stderr", command)
            self.assertIn("stdout_sha256", command)

    def test_failed_end_of_collection_confirmation_blocks_deployment(self):
        module = load_module()

        class ConfirmationFailureRunner(FakeRunner):
            def __init__(self):
                super().__init__(module)
                self.migration_calls = 0

            def run(self, role, node, command_id, argv, timeout):
                if role == "controller" and command_id == "migrations":
                    self.migration_calls += 1
                    if self.migration_calls == 2:
                        self.commands.append((role, command_id, tuple(argv)))
                        return subprocess.CompletedProcess(
                            list(argv), 1, "", "confirmation failed"
                        )
                return super().run(role, node, command_id, argv, timeout)

        report = module.run_preflight(
            inventory_value(), ConfirmationFailureRunner()
        )

        self.assertFalse(report["deploy_allowed"])
        self.assertFalse(report["snapshot"]["confirmed"])
        self.assertFalse(gate(report, "snapshot.confirmed")["passed"])
        self.assertFalse(gate(report, "commands.success")["passed"])

    def test_invalid_inventory_is_rejected_before_runner_is_used(self):
        module = load_module()
        value = inventory_value()
        value["roles"]["controller"]["password"] = "must-not-leak"
        runner = FakeRunner(module)

        with self.assertRaisesRegex(module.InventoryError, "unknown field"):
            module.run_preflight(value, runner)

        self.assertEqual(runner.verifications, [])
        self.assertEqual(runner.commands, [])

    def test_controller_cloud_name_is_required_and_shell_safe(self):
        module = load_module()
        for value in (None, "-bad", "bad cloud", "$(id)"):
            inventory = inventory_value()
            if value is None:
                del inventory["roles"]["controller"]["openstack_cloud"]
            else:
                inventory["roles"]["controller"]["openstack_cloud"] = value
            with self.subTest(value=value):
                with self.assertRaises(module.InventoryError):
                    module.validate_inventory(inventory)

    def test_role_identity_is_pinned_to_the_shared_cluster(self):
        module = load_module()
        value = inventory_value()
        value["roles"]["source"]["address"] = "172.25.6.12"

        with self.assertRaisesRegex(module.InventoryError, "source identity"):
            module.validate_inventory(value)

        value = inventory_value()
        for field in ("address", "expected_hostname", "host_key_fingerprint"):
            value["roles"]["source"][field], value["roles"]["target"][field] = (
                value["roles"]["target"][field],
                value["roles"]["source"][field],
            )
        with self.assertRaisesRegex(module.InventoryError, "source identity"):
            module.validate_inventory(value)

    def test_boolean_schema_version_is_not_accepted_as_integer_one(self):
        module = load_module()
        value = inventory_value()
        value["schema_version"] = True

        with self.assertRaisesRegex(module.InventoryError, "schema_version"):
            module.validate_inventory(value)

    def test_host_key_mismatch_blocks_node_commands_and_deployment(self):
        module = load_module()
        fingerprints = dict(FINGERPRINTS)
        fingerprints["target"] = FINGERPRINTS["source"]
        runner = FakeRunner(module, fingerprints=fingerprints)

        report = module.run_preflight(inventory_value(), runner)

        self.assertFalse(report["deploy_allowed"])
        self.assertFalse(gate(report, "host_key.target")["passed"])
        self.assertFalse(
            any(role == "target" for role, _command_id, _argv in runner.commands)
        )

    def test_malformed_observed_host_key_is_not_copied_to_evidence(self):
        module = load_module()
        fingerprints = dict(FINGERPRINTS)
        fingerprints["target"] = "credential-like-untrusted-runner-output"

        report = module.run_preflight(
            inventory_value(), FakeRunner(module, fingerprints=fingerprints)
        )

        target = next(
            item for item in report["host_identity"] if item["role"] == "target"
        )
        self.assertFalse(target["host_key_verified"])
        self.assertNotIn("observed_host_key_fingerprint", target)
        self.assertNotIn("credential-like", json.dumps(report))

    def test_allowlist_rejects_nearby_and_mutating_commands(self):
        module = load_module()

        approved = {
            "controller": {
                "hostname": ("hostname",),
                "clock_tracking": ("chronyc", "-n", "tracking"),
                "active_sessions": ("who",),
                "nova_services": (
                    "openstack", "compute", "service", "list", "-f", "json"
                ),
                "neutron_agents": (
                    "openstack", "network", "agent", "list", "-f", "json"
                ),
                "migrations": (
                    "openstack", "server", "migration", "list", "-f", "json"
                ),
                "servers": (
                    "openstack", "server", "list", "--all-projects", "--long",
                    "-f", "json",
                ),
                "ports": (
                    "openstack", "port", "list", "--long", "-f", "json"
                ),
                "hypervisors": (
                    "openstack", "hypervisor", "list", "--long", "-f", "json"
                ),
            },
            "source": {
                "hostname": ("hostname",),
                "clock_tracking": ("chronyc", "-n", "tracking"),
                "active_sessions": ("who",),
                "libvirt_domains": (
                    "virsh", "--connect", "qemu:///system", "--readonly", "list",
                    "--name",
                ),
                "ovs_bridges": (
                    "ovs-vsctl", "--format=json", "--columns=name", "list", "Bridge"
                ),
                "ovs_interfaces": (
                    "ovs-vsctl", "--format=json", "--columns=name,external_ids",
                    "list", "Interface",
                ),
                "br_int_ports": ("ovs-vsctl", "list-ports", "br-int"),
                "links": ("ip", "-json", "link", "show"),
            },
        }
        approved["target"] = dict(approved["source"])
        self.assertEqual(
            {
                role: dict(commands)
                for role, commands in module.READ_ONLY_COMMANDS.items()
            },
            approved,
        )

        self.assertFalse(
            module.is_command_allowed("source", "hostname", ("hostname", "--fqdn"))
        )
        self.assertFalse(
            module.is_command_allowed(
                "controller",
                "servers",
                ("openstack", "server", "delete", CLIENT_SERVER_ID),
            )
        )
        self.assertFalse(
            module.is_command_allowed("controller", "unknown", ("who",))
        )

    def test_default_runner_pins_key_and_disables_password_authentication(self):
        module = load_module()
        key = bytes(range(32))
        key_text = __import__("base64").b64encode(key).decode("ascii")
        fingerprint = (
            "SHA256:"
            + __import__("base64")
            .b64encode(__import__("hashlib").sha256(key).digest())
            .decode("ascii")
            .rstrip("=")
        )
        node = {
            "address": "172.25.6.13",
            "ssh_user": "ubuntu",
            "host_key_fingerprint": fingerprint,
        }
        calls = []

        def subprocess_runner(argv, **kwargs):
            command = list(argv)
            calls.append(command)
            if command[0] == "ssh-keyscan":
                line = f"172.25.6.13 ssh-ed25519 {key_text}\n"
                return subprocess.CompletedProcess(command, 0, line, "")
            if command[0] == "ssh":
                return subprocess.CompletedProcess(command, 0, "compute2\n", "")
            raise AssertionError(command)

        with mock.patch.object(module.subprocess, "run", side_effect=subprocess_runner):
            runner = module.SSHReadOnlyRunner()
            try:
                observed = runner.verify_host_key("source", node, 3)
                result = runner.run("source", node, "hostname", ("hostname",), 3)
            finally:
                runner.close()

        self.assertEqual(observed, fingerprint)
        self.assertEqual(result.stdout, "compute2\n")
        ssh = next(command for command in calls if command[0] == "ssh")
        self.assertIn("BatchMode=yes", ssh)
        self.assertIn("PasswordAuthentication=no", ssh)
        self.assertIn("KbdInteractiveAuthentication=no", ssh)
        self.assertIn("StrictHostKeyChecking=yes", ssh)
        self.assertIn("HostKeyAlgorithms=ssh-ed25519", ssh)
        self.assertIn("ClearAllForwardings=yes", ssh)
        self.assertIn(os.devnull, ssh)
        self.assertEqual(ssh[-2:], ["ubuntu@172.25.6.13", "hostname"])

    def test_controller_openstack_command_uses_named_cloud(self):
        module = load_module()
        key = bytes(range(32))
        key_text = __import__("base64").b64encode(key).decode("ascii")
        fingerprint = (
            "SHA256:"
            + __import__("base64")
            .b64encode(__import__("hashlib").sha256(key).digest())
            .decode("ascii")
            .rstrip("=")
        )
        node = {
            "address": "172.25.6.11",
            "ssh_user": "ubuntu",
            "host_key_fingerprint": fingerprint,
            "openstack_cloud": "vnet-readonly",
        }
        calls = []

        def subprocess_runner(argv, **kwargs):
            command = list(argv)
            calls.append(command)
            if command[0] == "ssh-keyscan":
                line = f"172.25.6.11 ssh-ed25519 {key_text}\n"
                return subprocess.CompletedProcess(command, 0, line, "")
            if command[0] == "ssh":
                return subprocess.CompletedProcess(command, 0, "[]\n", "")
            raise AssertionError(command)

        with mock.patch.object(module.subprocess, "run", side_effect=subprocess_runner):
            runner = module.SSHReadOnlyRunner()
            try:
                runner.verify_host_key("controller", node, 3)
                for command_name, argv in module.READ_ONLY_COMMANDS[
                    "controller"
                ].items():
                    if argv[0] == "openstack":
                        runner.run("controller", node, command_name, argv, 3)
            finally:
                runner.close()

        ssh_commands = [command for command in calls if command[0] == "ssh"]
        self.assertEqual(
            len(ssh_commands),
            sum(
                argv[0] == "openstack"
                for argv in module.READ_ONLY_COMMANDS["controller"].values()
            ),
        )
        for ssh in ssh_commands:
            self.assertIn("OS_CLOUD=vnet-readonly", ssh[-1])
            self.assertNotIn("password", ssh[-1].lower())

    def test_explicit_identity_file_is_owner_only_and_used(self):
        module = load_module()
        key = bytes(range(32))
        key_text = __import__("base64").b64encode(key).decode("ascii")
        fingerprint = (
            "SHA256:"
            + __import__("base64")
            .b64encode(__import__("hashlib").sha256(key).digest())
            .decode("ascii")
            .rstrip("=")
        )
        node = {
            "address": "172.25.6.13",
            "ssh_user": "ubuntu",
            "host_key_fingerprint": fingerprint,
        }
        calls = []

        def subprocess_runner(argv, **kwargs):
            command = list(argv)
            calls.append(command)
            if command[0] == "ssh-keyscan":
                line = f"172.25.6.13 ssh-ed25519 {key_text}\n"
                return subprocess.CompletedProcess(command, 0, line, "")
            return subprocess.CompletedProcess(command, 0, "compute2\n", "")

        with tempfile.TemporaryDirectory() as tmp:
            identity = Path(tmp) / "id_ed25519"
            identity.write_text("test-only", encoding="ascii")
            identity.chmod(0o600)
            with mock.patch.object(
                module.subprocess, "run", side_effect=subprocess_runner
            ):
                runner = module.SSHReadOnlyRunner(identity_file=identity)
                try:
                    runner.verify_host_key("source", node, 3)
                    runner.run("source", node, "hostname", ("hostname",), 3)
                finally:
                    runner.close()

        ssh = next(command for command in calls if command[0] == "ssh")
        self.assertIn("IdentitiesOnly=yes", ssh)
        self.assertEqual(ssh[ssh.index("-i") + 1], str(identity.absolute()))

    @unittest.skipIf(os.name == "nt", "POSIX permission bits are not enforced")
    def test_group_readable_identity_is_rejected(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            identity = Path(tmp) / "id_ed25519"
            identity.write_text("test-only", encoding="ascii")
            identity.chmod(0o640)
            with self.assertRaisesRegex(module.RunnerError, "owner-only"):
                module.SSHReadOnlyRunner(identity_file=identity)

    def test_clock_tolerance_is_a_hard_gate(self):
        module = load_module()
        outputs = passing_outputs()
        outputs[("source", "clock_tracking")] = chrony(0.050)
        runner = FakeRunner(module, outputs=outputs)

        report = module.run_preflight(inventory_value(), runner)

        self.assertFalse(report["deploy_allowed"])
        self.assertFalse(gate(report, "clock.synchronized")["passed"])
        self.assertGreater(report["clock"]["max_absolute_offset_ms"], 10)

    def test_clock_reference_is_reported_and_root_distance_is_a_hard_gate(self):
        module = load_module()
        outputs = passing_outputs()
        outputs[("source", "clock_tracking")] = chrony(
            reference_id="192.0.2.2"
        )
        outputs[("target", "clock_tracking")] = chrony(
            root_dispersion_seconds=1.0
        )

        report = module.run_preflight(
            inventory_value(), FakeRunner(module, outputs=outputs)
        )

        self.assertFalse(report["deploy_allowed"])
        self.assertFalse(gate(report, "clock.synchronized")["passed"])
        self.assertFalse(report["clock"]["reference_consistent"])
        self.assertGreater(report["clock"]["roles"]["target"]["root_distance_ms"], 10)

    def test_different_clock_reference_ids_block_with_healthy_root_distance(self):
        module = load_module()
        outputs = passing_outputs()
        outputs[("source", "clock_tracking")] = chrony(
            reference_id="192.0.2.2"
        )

        report = module.run_preflight(
            inventory_value(), FakeRunner(module, outputs=outputs)
        )

        self.assertFalse(report["deploy_allowed"])
        self.assertFalse(gate(report, "clock.synchronized")["passed"])
        self.assertFalse(report["clock"]["reference_consistent"])
        self.assertFalse(report["clock"]["reference_topology_verified"])

    def test_explicit_multi_hop_clock_reference_topology_is_allowed(self):
        module = load_module()
        inventory = inventory_value()
        inventory["roles"]["source"]["expected_clock_reference"] = "172.25.6.11"
        inventory["roles"]["target"]["expected_clock_reference"] = "172.25.6.11"
        outputs = passing_outputs()
        outputs[("source", "clock_tracking")] = chrony(
            0.001, reference_id="172.25.6.11"
        )
        outputs[("target", "clock_tracking")] = chrony(
            0.001, reference_id="172.25.6.11"
        )

        report = module.run_preflight(
            inventory, FakeRunner(module, outputs=outputs)
        )

        self.assertTrue(report["deploy_allowed"])
        self.assertFalse(report["clock"]["reference_consistent"])
        self.assertTrue(report["clock"]["reference_topology_verified"])

    def test_target_tap_may_be_absent_before_first_migration(self):
        module = load_module()
        inventory = inventory_value()
        outputs = passing_outputs()
        outputs[("target", "ovs_interfaces")] = ovs_interfaces(("patch-int", None))
        outputs[("target", "links")] = json.dumps([{"ifname": "lo"}])

        report = module.run_preflight(
            inventory, FakeRunner(module, outputs=outputs)
        )

        self.assertTrue(report["deploy_allowed"])
        self.assertTrue(gate(report, "tap.target")["passed"])
        self.assertLessEqual(report["clock"]["max_pairwise_error_bound_ms"], 10)

    def test_source_port_uuid_must_match_ovs_iface_id(self):
        module = load_module()
        outputs = passing_outputs()
        outputs[("source", "ovs_interfaces")] = ovs_interfaces(
            ("tap-client", BACKEND_PORT_ID),
            ("tap-backend", CLIENT_PORT_ID),
            ("patch-int", None),
        )

        report = module.run_preflight(
            inventory_value(), FakeRunner(module, outputs=outputs)
        )

        self.assertFalse(report["deploy_allowed"])
        self.assertFalse(gate(report, "tap.source")["passed"])
        mismatches = report["ovs_tap"]["source"]["mismatched_port_bindings"]
        self.assertEqual(len(mismatches), 2)

    def test_tap_must_be_unique_on_br_int_and_absent_from_target(self):
        module = load_module()
        cases = []

        outputs = passing_outputs()
        outputs[("source", "br_int_ports")] = "patch-int\ntap-client\n"
        cases.append(("source", outputs, "missing_br_int_tap_interfaces"))

        outputs = passing_outputs()
        outputs[("source", "ovs_interfaces")] = ovs_interfaces(
            ("tap-client", CLIENT_PORT_ID),
            ("tap-client-clone", CLIENT_PORT_ID),
            ("tap-backend", BACKEND_PORT_ID),
            ("patch-int", None),
        )
        outputs[("source", "br_int_ports")] += "tap-client-clone\n"
        cases.append(("source", outputs, "mismatched_port_bindings"))

        outputs = passing_outputs()
        outputs[("target", "ovs_interfaces")] = ovs_interfaces(
            ("tap-client", CLIENT_PORT_ID),
            ("patch-int", None),
        )
        outputs[("target", "br_int_ports")] = "patch-int\ntap-client\n"
        outputs[("target", "links")] = json.dumps(
            [{"ifname": "lo"}, {"ifname": "tap-client"}]
        )
        cases.append(("target", outputs, "unexpected_owned_tap_interfaces"))

        for role, outputs, evidence_field in cases:
            with self.subTest(role=role, evidence_field=evidence_field):
                report = module.run_preflight(
                    inventory_value(), FakeRunner(module, outputs=outputs)
                )
                self.assertFalse(report["deploy_allowed"])
                self.assertFalse(gate(report, f"tap.{role}")["passed"])
                self.assertTrue(report["ovs_tap"][role][evidence_field])

    def test_neutron_port_must_belong_to_expected_server_on_source(self):
        module = load_module()
        outputs = passing_outputs()
        ports = json.loads(outputs[("controller", "ports")])
        ports[0]["Device ID"], ports[1]["Device ID"] = (
            ports[1]["Device ID"],
            ports[0]["Device ID"],
        )
        outputs[("controller", "ports")] = json.dumps(ports)

        report = module.run_preflight(
            inventory_value(), FakeRunner(module, outputs=outputs)
        )

        self.assertFalse(report["deploy_allowed"])
        self.assertFalse(gate(report, "resources.ports")["passed"])
        self.assertEqual(
            {item["port_id"] for item in report["resources"]["ports"]},
            {CLIENT_PORT_ID, BACKEND_PORT_ID},
        )

    def test_resource_project_and_ownership_tag_are_hard_gates(self):
        module = load_module()
        outputs = passing_outputs()
        servers = json.loads(outputs[("controller", "servers")])
        servers[0]["Project ID"] = "66666666-6666-6666-6666-666666666666"
        outputs[("controller", "servers")] = json.dumps(servers)
        ports = json.loads(outputs[("controller", "ports")])
        ports[1]["Tags"] = []
        outputs[("controller", "ports")] = json.dumps(ports)

        report = module.run_preflight(
            inventory_value(), FakeRunner(module, outputs=outputs)
        )

        self.assertFalse(report["deploy_allowed"])
        self.assertFalse(gate(report, "resources.servers")["passed"])
        self.assertFalse(gate(report, "resources.ports")["passed"])
        self.assertFalse(report["resources"]["servers"][0]["healthy"])
        self.assertFalse(report["resources"]["ports"][1]["healthy"])

    def test_port_ip_mac_and_extra_nic_are_hard_gates(self):
        module = load_module()
        outputs = passing_outputs()
        ports = json.loads(outputs[("controller", "ports")])
        ports[0]["Fixed IP Addresses"] = [{"ip_address": "10.42.0.31"}]
        ports[1]["MAC Address"] = "fa:16:3e:00:00:32"
        extra_port_id = "77777777-7777-7777-7777-777777777777"
        ports.append(
            {
                "ID": extra_port_id,
                "Status": "ACTIVE",
                "Device Owner": "compute:nova",
                "Device ID": CLIENT_SERVER_ID,
                "Binding Host ID": "compute2",
                "Project ID": OWNER_PROJECT_ID,
                "Tags": [OWNERSHIP_TAG],
                "Fixed IP Addresses": [{"ip_address": "10.42.0.99"}],
                "MAC Address": "fa:16:3e:00:00:99",
            }
        )
        outputs[("controller", "ports")] = json.dumps(ports)

        report = module.run_preflight(
            inventory_value(), FakeRunner(module, outputs=outputs)
        )

        self.assertFalse(report["deploy_allowed"])
        self.assertFalse(gate(report, "resources.ports")["passed"])
        evidence = report["resources"]["ports"]
        self.assertFalse(next(item for item in evidence if item["port_id"] == CLIENT_PORT_ID)["healthy"])
        self.assertFalse(next(item for item in evidence if item["port_id"] == BACKEND_PORT_ID)["healthy"])
        extra = next(item for item in evidence if item["port_id"] == extra_port_id)
        self.assertTrue(extra["unexpected"])

    def test_owned_servers_must_be_active_on_source_and_match_libvirt_domains(self):
        module = load_module()
        outputs = passing_outputs()
        servers = json.loads(outputs[("controller", "servers")])
        servers[0]["Host"] = "compute3"
        servers[1]["Instance Name"] = "unowned-domain"
        outputs[("controller", "servers")] = json.dumps(servers)

        report = module.run_preflight(
            inventory_value(), FakeRunner(module, outputs=outputs)
        )

        self.assertFalse(report["deploy_allowed"])
        self.assertFalse(gate(report, "resources.servers")["passed"])

    def test_shared_activity_and_active_migration_block_deployment(self):
        module = load_module()
        outputs = passing_outputs()
        outputs[("target", "active_sessions")] = (
            "researcher pts/2 2026-08-01 09:00 (192.0.2.10)\n"
        )
        outputs[("target", "libvirt_domains")] = "other-domain\n"
        outputs[("controller", "servers")] = json.dumps(
            [
                {
                    "ID": "server-other",
                    "Status": "SHUTOFF",
                    "Host": "compute3",
                }
            ]
        )
        outputs[("controller", "migrations")] = json.dumps(
            [{"ID": "migration-7", "Status": "running"}]
        )

        report = module.run_preflight(
            inventory_value(), FakeRunner(module, outputs=outputs)
        )

        self.assertFalse(report["deploy_allowed"])
        self.assertFalse(gate(report, "sessions.clear")["passed"])
        self.assertFalse(gate(report, "workloads.clear")["passed"])
        self.assertFalse(gate(report, "migrations.idle")["passed"])
        self.assertEqual(report["sessions"]["target"]["count"], 1)
        self.assertEqual(report["workloads"]["unrelated_server_ids"], ["server-other"])
        self.assertEqual(report["migrations"]["active_ids"], ["migration-7"])

    def test_service_capacity_and_ovs_tap_failures_are_independent_gates(self):
        module = load_module()
        outputs = passing_outputs()
        nova = json.loads(outputs[("controller", "nova_services")])
        nova[-1]["Binary"] = "nova-scheduler"
        outputs[("controller", "nova_services")] = json.dumps(nova)
        neutron = json.loads(outputs[("controller", "neutron_agents")])
        neutron[-1]["Agent Type"] = "unrelated-agent"
        outputs[("controller", "neutron_agents")] = json.dumps(neutron)
        hypervisors = json.loads(outputs[("controller", "hypervisors")])
        hypervisors[-1]["VCPUs Used"] = -100
        hypervisors[-1]["Memory MB Used"] = -100
        hypervisors[-1]["Local GB Used"] = -100
        outputs[("controller", "hypervisors")] = json.dumps(hypervisors)
        outputs[("target", "ovs_bridges")] = ovs_names("br-ex")
        outputs[("target", "ovs_interfaces")] = "not-json"
        outputs[("source", "links")] = json.dumps([{"ifname": "lo"}])

        report = module.run_preflight(
            inventory_value(), FakeRunner(module, outputs=outputs)
        )

        self.assertFalse(report["deploy_allowed"])
        for name in (
            "nova.services",
            "neutron.agents",
            "capacity.target",
            "ovs.target",
            "tap.source",
            "tap.target",
        ):
            self.assertFalse(gate(report, name)["passed"], name)

    def test_command_failure_is_sanitized_and_fails_closed(self):
        module = load_module()
        outputs = passing_outputs()
        outputs[("source", "active_sessions")] = subprocess.CompletedProcess(
            ["who"], 1, "sensitive stdout", "password=do-not-record"
        )

        report = module.run_preflight(
            inventory_value(), FakeRunner(module, outputs=outputs)
        )

        self.assertFalse(report["deploy_allowed"])
        self.assertFalse(gate(report, "commands.success")["passed"])
        serialized = json.dumps(report)
        self.assertNotIn("sensitive stdout", serialized)
        self.assertNotIn("do-not-record", serialized)

    def test_cli_writes_report_atomically_with_injected_runner(self):
        module = load_module()
        runner = FakeRunner(module)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            inventory_path = root / "inventory.json"
            output_path = root / "evidence" / "preflight.json"
            inventory_path.write_text(json.dumps(inventory_value()), encoding="utf-8")
            stdout = io.StringIO()

            with contextlib.redirect_stdout(stdout):
                returncode = module.main(
                    [
                        "--inventory",
                        str(inventory_path),
                        "--output",
                        str(output_path),
                        "--timeout",
                        "3",
                    ],
                    runner=runner,
                )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            printed = json.loads(stdout.getvalue())
            leftovers = list(output_path.parent.glob(".*.tmp"))

        self.assertEqual(returncode, 0)
        self.assertTrue(report["deploy_allowed"])
        self.assertEqual(printed["deploy_allowed"], True)
        self.assertEqual(printed["output"], str(output_path))
        self.assertEqual(leftovers, [])

    def test_invalid_json_cli_writes_fail_closed_report_without_runner_calls(self):
        module = load_module()
        runner = FakeRunner(module)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            inventory_path = root / "inventory.json"
            output_path = root / "preflight.json"
            inventory_path.write_text('{"schema_version": 1,}', encoding="utf-8")
            stderr = io.StringIO()

            with contextlib.redirect_stderr(stderr):
                returncode = module.main(
                    ["--inventory", str(inventory_path), "--output", str(output_path)],
                    runner=runner,
                )

            report = json.loads(output_path.read_text(encoding="utf-8"))

        self.assertEqual(returncode, 2)
        self.assertFalse(report["deploy_allowed"])
        self.assertEqual(report["status"], "invalid_inventory")
        self.assertNotIn("must-not-leak", json.dumps(report))
        self.assertEqual(runner.verifications, [])
        self.assertEqual(runner.commands, [])

    def test_atomic_writer_preserves_previous_output_when_replace_fails(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "preflight.json"
            output.write_text('{"old":true}\n', encoding="utf-8")
            with mock.patch.object(module.os, "replace", side_effect=OSError("boom")):
                with self.assertRaises(OSError):
                    module.atomic_write_json(output, {"new": True})
            leftovers = list(output.parent.glob(f".{output.name}.*.tmp"))
            current = output.read_text(encoding="utf-8")

        self.assertEqual(current, '{"old":true}\n')
        self.assertEqual(leftovers, [])

    def test_cli_refuses_to_overwrite_an_input_before_remote_checks(self):
        module = load_module()
        runner = FakeRunner(module)
        with tempfile.TemporaryDirectory() as tmp:
            inventory_path = Path(tmp) / "inventory.json"
            original = json.dumps(inventory_value())
            inventory_path.write_text(original, encoding="utf-8")

            returncode = module.main(
                [
                    "--inventory",
                    str(inventory_path),
                    "--output",
                    str(inventory_path),
                ],
                runner=runner,
            )

            self.assertEqual(returncode, 2)
            self.assertEqual(inventory_path.read_text(encoding="utf-8"), original)
            self.assertEqual(runner.verifications, [])
            self.assertEqual(runner.commands, [])


if __name__ == "__main__":
    unittest.main()
