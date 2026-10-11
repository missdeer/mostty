"""Linux analyzer contract tests: missing evidence must never pass a gate."""
import json
from pathlib import Path
import tempfile
import unittest

import report


class ReportTests(unittest.TestCase):
    def setUp(self):
        scratch = Path(__file__).resolve().parents[2] / "tmp"
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.order = ["base", "head", "head", "base", "head", "base", "base", "head"]
        self.cases = ["ligature_keys", "viewport_frames", "multipart_scratch", "plain_output_control", "small_sixel_control"]

    def write(self, mutate=lambda rows: None, windows=False):
        cases = self.cases.copy()
        if windows:
            cases += ["windows_hover", "windows_ligature_runs"]
            cases += [prefix + suffix for prefix in ("windows_", "windows_saturated_")
                      for suffix in ("dispatch", "all_panes_progress", "output_total")]
        meta = dict(os="Microsoft Windows" if windows else "Linux", order=self.order, samples_per_process=15)
        (self.directory / "metadata.json").write_text(json.dumps(meta))
        for i, side in enumerate(self.order):
            rows = [dict(case=case, sample=n, ns=1000 + n, units=1, checksum=42,
                         allocations=0, retained_bytes=128, dispatch=0,
                         calls=5000 if case == "windows_ligature_runs" else 1)
                    for case in cases for n in range(15)]
            mutate(rows)
            (self.directory / f"{side}-{i}.log").write_text("\n".join("BENCH " + json.dumps(r) for r in rows))

    def test_complete_platform_evidence(self):
        self.write(windows=True)
        self.assertEqual(len(report.analyze(self.directory)["cases"]), 13)

    def test_case_missing_from_both_sides_fails(self):
        self.write(lambda rows: rows.__setitem__(slice(None), [r for r in rows if r["case"] != "multipart_scratch"]))
        with self.assertRaisesRegex(AssertionError, "missing or unexpected"):
            report.analyze(self.directory)

    def test_duplicate_sample_fails(self):
        self.write(lambda rows: rows.append(rows[0].copy()))
        with self.assertRaises(AssertionError):
            report.analyze(self.directory)

    def test_missing_sample_fails(self):
        self.write(lambda rows: rows.pop())
        with self.assertRaises(AssertionError):
            report.analyze(self.directory)

    def test_duplicate_dispatch_fails(self):
        self.write(lambda rows: rows.append(next(r.copy() for r in rows if r["case"] == "windows_dispatch")), windows=True)
        with self.assertRaisesRegex(AssertionError, "duplicate or missing dispatch"):
            report.analyze(self.directory)

    def test_real_production_hash_budget_fails(self):
        def regress(rows):
            for row in rows:
                if row["case"] == "windows_ligature_runs":
                    row["calls"] = 160000
        self.write(regress, windows=True)
        with self.assertRaisesRegex(AssertionError, "production run hash regression"):
            report.analyze(self.directory)

    def test_output_mismatch_fails(self):
        self.write()
        path = self.directory / "head-1.log"
        path.write_text(path.read_text().replace('"checksum": 42', '"checksum": 43'))
        with self.assertRaisesRegex(AssertionError, "output differs"):
            report.analyze(self.directory)


if __name__ == "__main__":
    unittest.main()
