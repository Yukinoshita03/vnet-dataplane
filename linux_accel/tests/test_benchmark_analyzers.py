import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


RESPERF = load_module("analyze_resperf", ROOT / "tools" / "analyze_resperf.py")
BMC = load_module(
    "analyze_bmc_competitor_bench",
    ROOT / "tools" / "analyze_bmc_competitor_bench.py",
)


class ResperfAnalyzerTest(unittest.TestCase):
    def test_capacity_stops_at_first_interval_over_threshold(self):
        rows = [
            {"actual_qps": 100.0, "responses_qps": 100.0, "target_qps": 100.0, "loss_pct": 0.0, "avg_latency_s": 0.00001},
            {"actual_qps": 200.0, "responses_qps": 198.0, "target_qps": 200.0, "loss_pct": 1.0, "avg_latency_s": 0.00002},
            {"actual_qps": 300.0, "responses_qps": 294.0, "target_qps": 300.0, "loss_pct": 2.0, "avg_latency_s": 0.00003},
            {"actual_qps": 400.0, "responses_qps": 400.0, "target_qps": 400.0, "loss_pct": 0.0, "avg_latency_s": 0.00004},
        ]
        result = RESPERF.capacity_before_loss(rows, 1.0)
        self.assertEqual(result["responses_qps"], 198.0)
        self.assertEqual(result["actual_qps"], 200.0)
        self.assertEqual(result["avg_latency_us"], 20.0)

    def test_log_and_plot_invariants(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = root / "resperf.log"
            plot = root / "resperf.plot"
            log.write_text(
                "[Status] Testing complete\n\nStatistics:\n"
                "  Queries sent:         100\n"
                "  Queries completed:    99\n"
                "  Queries lost:         1\n"
                "  Run time (s):         1.000000\n"
                "  Maximum throughput:   99.000000 qps\n"
                "  Lost at that point:   1.00%\n"
            )
            plot.write_text(
                "# time target_qps actual_qps responses_per_sec failures_per_sec avg_latency connections conn_avg_latency\n"
                "0.250 100.00 100.00 99.00 1.00 0.000020 0.00 0.000000\n"
            )
            parsed_log = RESPERF.parse_log(log)
            parsed_plot = RESPERF.parse_plot(plot)
            self.assertEqual(parsed_log["queries_completed"], 99)
            self.assertAlmostEqual(parsed_plot[0]["loss_pct"], 1.0)


class BmcAnalyzerTest(unittest.TestCase):
    def test_aggregate_preserves_total_failure_rate(self):
        common = {
            "profile": "openstack",
            "qps": 100.0,
            "avg_us": 10.0,
            "p50_us": 9.0,
            "p95_us": 12.0,
            "p99_us": 15.0,
            "backend_delta": 100,
            "backend_offload_pct": 0.0,
            "attempted": 50_000,
        }
        rows = [
            {**common, "mode": "nohook", "failed": 0},
            {**common, "mode": "bmc", "failed": 1},
            {**common, "mode": "bmc", "failed": 0},
            {**common, "mode": "linux-accel", "failed": 0},
        ]
        summaries = BMC.aggregate(rows)
        bmc = next(row for row in summaries if row["mode"] == "bmc")
        self.assertEqual(bmc["failed_total"], 1.0)
        self.assertEqual(bmc["attempted_total"], 100_000.0)
        self.assertAlmostEqual(bmc["failure_pct_total"], 0.001)


if __name__ == "__main__":
    unittest.main()
