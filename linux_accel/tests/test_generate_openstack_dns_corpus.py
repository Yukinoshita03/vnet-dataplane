import json
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "tools" / "generate_openstack_dns_corpus.py"


class RadarObservedCorpusTest(unittest.TestCase):
    def test_preserves_observed_marginals_and_is_reproducible(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outputs = []
            for suffix in ("one", "two"):
                queries = root / f"queries-{suffix}.txt"
                manifest = root / f"manifest-{suffix}.json"
                cache = root / f"cache-{suffix}.txt"
                subprocess.run(
                    [
                        sys.executable,
                        str(GENERATOR),
                        "--output",
                        str(queries),
                        "--manifest",
                        str(manifest),
                        "--cache-output",
                        str(cache),
                        "--domain",
                        "radar.example.test",
                        "--lines",
                        "50000",
                        "--seed",
                        "20260813",
                        "--profile",
                        "radar-nl-observed",
                    ],
                    check=True,
                )
                outputs.append((queries.read_bytes(), manifest.read_bytes(), cache.read_bytes()))

            self.assertEqual(outputs[0], outputs[1])
            queries = outputs[0][0].decode("ascii").splitlines()
            manifest = json.loads(outputs[0][1])
            qtypes = Counter(row.rsplit(" ", 1)[1] for row in queries)
            self.assertEqual(len(queries), 50000)
            self.assertEqual(
                qtypes,
                Counter({"A": 28300, "AAAA": 15150, "HTTPS": 3150, "PTR": 1800, "TXT": 1250, "NS": 350}),
            )
            self.assertEqual(
                manifest["rcode_counts"],
                {"NOERROR": 44300, "NOTIMP": 50, "NXDOMAIN": 5000, "SERVFAIL": 650},
            )
            self.assertEqual(manifest["resolver_cache_counts"], {"hit": 39250, "miss": 10750})
            self.assertGreater(manifest["cache_entries"], 500)
            self.assertLessEqual(manifest["cache_entries"], 640)
            self.assertGreater(manifest["preloaded_hit_percent"], manifest["xpress_preloaded_hit_percent"])


if __name__ == "__main__":
    unittest.main()
