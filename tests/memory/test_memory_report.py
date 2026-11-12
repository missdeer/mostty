import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("memory_report", Path(__file__).with_name("report.py"))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)

def run(trial=0):
    renderer = dict.fromkeys(report.LOGICAL_FIELDS, 0)
    renderer.update(cache_lower_bound_bytes=0, glyph_pending=0, glyph_used=0, glyph_slots=0, renderer_image_count=0,
                    uploads=None, metal_source_logical_bytes=None, metal_target_logical_bytes=None)
    terminal = dict(page_virtual_bytes=16384, page_resident_estimate_bytes=16384, primary_image_bytes=0, alternate_image_bytes=0)
    meta = dict(platform="Windows", compiler="0.17.1", mode="release_fast", target_cpu="baseline", backend="d3d11", font="Consolas", font_size_pt=13, dpi=96,
                window_pixels=[320, 200], panes=1, dependencies="pinned", conpty_version="1.25.261109001", input_sha256="a"*64,
                hardware={"cpu":"fixture","gpu":"fixture"}, interval_ms=50, samples=3, steady_samples=2, warmup_seconds=1,
                phase="steady", commit=("b" if report.ORDER[trial] == "base" else "c")*40, scenario="ASCII-control",
                side=report.ORDER[trial], trial=trial, run_group="fixture", role="measurement", schema=1, kind="metadata")
    data = {key:meta[key] for key in ("compiler","mode","target_cpu","backend","font","font_size_pt","dpi","window_pixels")}
    data.update(pane_count=1, active_panes=1, hidden_panes=0, panes=[dict(id=1, viewport_hash="same", cache_state="active", renderer=renderer, terminal=terminal)])
    meta["presentation"] = None; data["presentation"] = None
    samples = [dict(kind="sample", index=i, elapsed_ns=(i+1)*100, phase="steady", os=dict(status="ok", private_bytes=100+i),
                    gpu=dict(status="blocked", dedicated_bytes=None, shared_bytes=None), app=dict(status="ok", data=copy.deepcopy(data))) for i in range(3)]
    return dict(metadata=meta, samples=samples)

class MemoryReportTests(unittest.TestCase):
    def test_paired_os_and_logical_are_separate(self):
        result = report.analyze([run(i) for i in range(8)])[0]
        self.assertEqual(result["status"], "paired")
        self.assertEqual(len(result["paired_ratios"]["private_bytes"]), 4)
        self.assertIn("vt_page_virtual_bytes", result["logical"]["head"])
        self.assertNotIn("vt_page_virtual_bytes", result["os"]["head"])
        self.assertTrue(result["latency_status"].startswith("blocked"))

    def test_conditions_and_missing_trials_fail(self):
        with self.assertRaises(AssertionError): report.analyze([run(i) for i in range(7)])
        rows = [run(i) for i in range(8)]; rows[4]["metadata"]["dpi"] = 144
        with self.assertRaises(AssertionError): report.analyze(rows)

    def test_duplicate_samples_and_missing_metadata_fail(self):
        rows = run()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/"raw.jsonl"
            rows["samples"][1]["index"] = 0
            path.write_text("\n".join(json.dumps(r) for r in [rows["metadata"]]+rows["samples"]))
            with self.assertRaises(AssertionError): report.load_run(path)

    def test_output_mismatch_fails(self):
        rows = [run(i) for i in range(8)]
        for sample in rows[1]["samples"]: sample["app"]["data"]["panes"][0]["viewport_hash"] = "wrong"
        with self.assertRaises(AssertionError): report.analyze(rows)

    def test_upload_and_worker_bounds_are_hard_gates(self):
        data = run()["samples"][0]["app"]["data"]
        data["panes"][0]["renderer"]["uploads"] = dict(active_tasks=2, pending_tasks=0, idle_bytes=0, idle_tasks=0, active_bytes=17*1024**2)
        with self.assertRaises(AssertionError): report.budgets(data)
        data["panes"][0]["renderer"]["uploads"]["active_tasks"] = 1
        report.budgets(data)
        data["wallpaper_decode"] = dict(active=2, queued=0, ready=0)
        with self.assertRaises(AssertionError): report.budgets(data)

    def test_disable_requires_priming_and_releases_all_images(self):
        rows = run(); rows["metadata"]["phase"] = "images-disabled"
        self.assertTrue(report.cleanup(rows).startswith("blocked"))
        before = copy.deepcopy(rows["samples"][0]["app"]["data"])
        before["panes"][0]["renderer"]["renderer_image_count"] = 1
        rows["metadata"]["precondition_app"] = before
        self.assertEqual(report.cleanup(rows), "pass")
        rows["samples"][-1]["app"]["data"]["panes"][0]["terminal"]["alternate_image_bytes"] = 4
        with self.assertRaises(AssertionError): report.cleanup(rows)

    def test_trim_is_not_os_working_set(self):
        data = run()["samples"][0]["app"]["data"]
        data["panes"][0]["cache_state"] = "trimmed"
        report.budgets(data)
        data["panes"][0]["renderer"]["cpu_pixel_bytes"] = 4
        with self.assertRaises(AssertionError): report.budgets(data)

    def test_metal_device_bytes_are_deduplicated(self):
        sample = run()["samples"][0]
        pane = sample["app"]["data"]["panes"][0]
        pane["metal_device_registry_id"] = 123; pane["renderer"]["metal_device_allocated_bytes"] = 456
        sample["app"]["data"]["panes"].append(copy.deepcopy(pane))
        self.assertEqual(report.logical(sample)["metal_device_allocated_bytes_deduplicated"], 456)

    def test_smoke_and_missing_hardware_are_never_mostty_passes(self):
        row = run(); row["metadata"]["role"] = "smoke"
        for sample in row["samples"]: sample["app"] = dict(status="blocked",data=None)
        result = report.analyze([row])[0]
        self.assertIn("smoke only", result["status"])
        self.assertEqual(result["application_resources"], "blocked")
        self.assertEqual(result["gpu_status"], ["blocked"])

if __name__ == "__main__": unittest.main()
