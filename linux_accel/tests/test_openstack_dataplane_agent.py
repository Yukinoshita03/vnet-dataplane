import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from agent.openstack_dataplane_agent import (
    AttachmentConfig,
    AgentError,
    Binding,
    OpenStackOvsResolver,
    ProcessAttachmentDriver,
    Reconciler,
    _ManagedAttachment,
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

    def attach(self, binding):
        self.actions.append(("attach", binding.port_id, binding.ifindex))
        self.attached[binding.port_id] = binding

    def detach(self, binding):
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


def binding(ifindex=14, interface="tapport"):
    return Binding(
        server_id="server-1",
        port_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        host="master",
        interface=interface,
        ifindex=ifindex,
    )


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
                "status": "ACTIVE",
                "binding_host_id": "compute2",
                "binding_vif_type": "ovs",
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
        self.assertEqual(
            resolver.discover("server-1"),
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


class ReconcilerTest(unittest.TestCase):
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


class ProcessAttachmentDriverTest(unittest.TestCase):
    def test_detach_never_executes_slot_based_hook_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            dns_monitor = root / "dns_monitor"
            dns_bpf = root / "dns.bpf.o"
            grpc_monitor = root / "grpc_monitor"
            grpc_bpf = root / "grpc.bpf.o"
            for path in (dns_monitor, dns_bpf, grpc_monitor, grpc_bpf):
                path.touch()
            config = AttachmentConfig(
                dns_monitor=dns_monitor,
                dns_bpf=dns_bpf,
                grpc_monitor=grpc_monitor,
                grpc_bpf=grpc_bpf,
                trusted_dns="10.0.0.53",
                grpc_port=50052,
                pin_root=root / "bpffs" / "agent",
                log_root=root / "logs",
            )
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
            )
            stopped = []
            driver._stop = lambda process: stopped.append(process.name)

            with patch("agent.openstack_dataplane_agent.subprocess.run") as run:
                driver.detach(current)

            self.assertEqual(stopped, ["grpc", "dns"])
            run.assert_not_called()
            self.assertFalse(port_pin.exists())


if __name__ == "__main__":
    unittest.main()
