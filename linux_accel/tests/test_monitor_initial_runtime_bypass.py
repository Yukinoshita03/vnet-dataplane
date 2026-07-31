import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def source(relative):
    return (ROOT / relative).read_text(encoding="utf-8")


def main_body(text):
    return text.split("int main(", 1)[1]


class InitialRuntimeBypassOrderTest(unittest.TestCase):
    def assert_control_value(self, text):
        self.assertIn("expected.epoch = 1;", text)
        self.assertIn("expected.mode = CACHE_RUNTIME_BYPASS;", text)
        self.assertIn("expected.flags = CACHE_RUNTIME_COMMITTED;", text)
        self.assertIn("bpf_map_update_elem(", text)
        self.assertIn("bpf_map_lookup_elem(", text)

    def test_dns_initializes_after_config_and_before_pin_or_attach(self):
        header = source("src/include/dns_monitor.hpp")
        arguments = source("src/dns_monitor_args.cpp")
        monitor = source("src/dns_monitor.cpp")
        body = main_body(monitor)

        self.assertIn("bool initial_runtime_bypass = false;", header)
        self.assertIn('arg == "--initial-runtime-bypass"', arguments)
        self.assertIn("options->initial_runtime_bypass = true;", arguments)
        self.assertIn(
            "if (options.initial_runtime_bypass &&",
            body,
        )
        initialize = body.index("initialize_runtime_bypass(obj)")
        pin = body.index("pin_dns_maps(obj, options)")
        attach = min(
            body.index("attach_tc_filter("),
            body.index("attach_xdp_program("),
        )
        self.assertLess(body.index("bpf_object__load(obj)"), initialize)
        self.assertLess(
            body.index("install_dns_cache(obj, options, &static_dns_cache)"),
            initialize,
        )
        self.assertLess(body.index("install_client_config(obj, options)"), initialize)
        self.assertLess(initialize, pin)
        self.assertLess(pin, attach)
        self.assert_control_value(monitor)

    def test_server_static_dns_cache_is_refreshed_before_ttl_expiry(self):
        header = source("src/include/dns_monitor.hpp")
        arguments = source("src/dns_monitor_args.cpp")
        monitor = source("src/dns_monitor.cpp")

        self.assertIn("int cache_refresh_ms = 1000;", header)
        self.assertIn('arg == "--cache-refresh-ms"', arguments)
        self.assertIn("options->cache_refresh_ms", arguments)
        self.assertIn("StaticDnsCache", monitor)
        self.assertIn("refresh_dns_cache_if_due", monitor)
        self.assertIn("install_dns_cache_entries", monitor)

    def test_grpc_initializes_after_config_and_before_pin_or_attach(self):
        monitor = source("src/grpc_monitor.cpp")
        body = main_body(monitor)

        self.assertIn("bool initial_runtime_bypass = false;", monitor)
        self.assertIn('arg == "--initial-runtime-bypass"', monitor)
        self.assertIn("options->initial_runtime_bypass = true;", monitor)
        self.assertIn(
            "if (options.initial_runtime_bypass &&",
            body,
        )
        initialize = body.index("initialize_runtime_bypass(obj)")
        pin = body.index("pin_grpc_maps(obj, options.pin_dir)")
        attach = body.index("bpf_tc_attach(&hook")
        self.assertLess(body.index("bpf_object__load(obj)"), initialize)
        self.assertLess(body.index("configure_port(obj, options.port)"), initialize)
        self.assertLess(initialize, pin)
        self.assertLess(pin, attach)
        self.assert_control_value(monitor)


if __name__ == "__main__":
    unittest.main()
