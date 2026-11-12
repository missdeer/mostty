#!/usr/bin/env python3
"""Portable artifact analysis on Linux; native collectors use PowerShell/Swift."""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import statistics

ORDER = ["base", "head", "head", "base", "head", "base", "base", "head"]
CONDITIONS = ("platform", "compiler", "mode", "target_cpu", "backend", "presentation", "font", "font_size_pt", "dpi", "window_pixels",
              "panes", "dependencies", "conpty_version", "input_sha256", "hardware", "interval_ms",
              "samples", "steady_samples", "warmup_seconds", "phase")
OS_FIELDS = ("private_bytes", "working_set_bytes", "paged_memory_bytes", "physical_footprint_bytes", "resident_bytes")
LOGICAL_FIELDS = ("atlas_logical_bytes", "glyph_index_requested_bytes", "renderer_image_logical_bytes", "cpu_pixel_bytes",
                  "cpu_grid_bytes", "shaping_storage_bytes", "wallpaper_logical_bytes", "staging_retained_logical_bytes")

def logical(sample):
    if sample["app"]["status"] != "ok":
        return {}
    data = sample["app"]["data"]
    result = {}
    owners = list(renderers(data))
    for key in LOGICAL_FIELDS:
        values = [r[key] for _, r in owners if r.get(key) is not None]
        if values:
            result[key] = sum(values)
    for key in ("page_virtual_bytes", "page_resident_estimate_bytes", "primary_image_bytes", "alternate_image_bytes"):
        result["vt_" + key] = sum(p["terminal"][key] for p in data["panes"])
    uploads = [r["uploads"] for _, r in owners if r.get("uploads") is not None]
    if uploads:
        result["vulkan_active_allocation_bytes"] = sum(u["active_bytes"] for u in uploads)
        result["vulkan_idle_allocation_bytes"] = sum(u["idle_bytes"] for u in uploads)
    devices = {}
    for pane, r in owners:
        device = pane.get("metal_device_registry_id")
        if device is not None and r.get("metal_device_allocated_bytes") is not None:
            devices[str(device)] = max(devices.get(str(device), 0), r["metal_device_allocated_bytes"])
    if devices:
        result["metal_device_allocated_bytes_deduplicated"] = sum(devices.values())
    return result

def renderers(data):
    for pane in data.get("panes", []):
        yield pane, pane["renderer"]
    if data.get("process_renderer") is not None:
        yield {}, data["process_renderer"]

def budgets(data):
    assert data["pane_count"] == len(data["panes"]), "pane registry count differs"
    assert data["active_panes"] + data["hidden_panes"] == data["pane_count"], "visibility count differs"
    for pane, r in renderers(data):
        assert r["glyph_pending"] <= r["glyph_used"] <= r["glyph_slots"], "glyph ownership count differs"
        u = r.get("uploads")
        if u is not None:
            assert 0 <= u["active_tasks"] <= 128 and 0 <= u["pending_tasks"] <= 64, "unbounded upload tasks"
            assert 0 <= u["idle_bytes"] <= 8 * 1024**2 and 0 <= u["idle_tasks"] <= 64, "unbounded upload pool"
            assert 0 <= u["active_bytes"] <= 1024**3, "unbounded upload bytes"
            assert u["active_bytes"] <= 16 * 1024**2 or u["active_tasks"] == 1, "large upload is not exclusive"
        if pane.get("cache_state") == "trimmed":
            for key in ("cache_lower_bound_bytes", "glyph_index_requested_bytes", "cpu_pixel_bytes", "cpu_grid_bytes",
                        "shaping_storage_bytes", "renderer_image_count"):
                assert r[key] == 0, f"trimmed pane retains {key}"
            for key in ("metal_source_logical_bytes", "metal_target_logical_bytes"):
                assert r.get(key) in (None, 0), f"trimmed pane retains {key}"
        host = pane.get("host")
        if host and not host["visible"]:
            assert not host["render_timer_running"] and not host["blink_timer_running"], "hidden periodic timers remain"
    worker = data.get("wallpaper_decode")
    if worker is not None:
        assert all(0 <= worker[k] <= 1 for k in ("active", "queued", "ready")), "unbounded wallpaper work"

def load_run(path):
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8-sig").splitlines() if line.strip()]
    assert rows and rows[0]["kind"] == "metadata" and rows[0]["schema"] == 1, f"invalid metadata: {path}"
    meta, samples = rows[0], rows[1:]
    assert meta["platform"] in ("Windows", "macOS")
    for key in CONDITIONS + ("commit", "scenario", "side", "trial", "run_group", "role"):
        assert key in meta, f"missing {key}: {path}"
    assert meta["role"] in ("smoke", "measurement")
    assert meta["samples"] >= 2 and 1 <= meta["steady_samples"] <= meta["samples"]
    assert [s["index"] for s in samples] == list(range(meta["samples"])), f"missing/duplicate samples: {path}"
    assert all(s["kind"] == "sample" and s["phase"] == meta["phase"] for s in samples)
    assert all(a["elapsed_ns"] < b["elapsed_ns"] for a, b in zip(samples, samples[1:])), "clock not monotonic"
    for sample in samples:
        if sample["os"]["status"] == "ok":
            assert any(k in sample["os"] for k in OS_FIELDS), "OS sample has no memory metric"
            assert all(sample["os"][k] >= 0 for k in OS_FIELDS if k in sample["os"])
        if sample["app"]["status"] == "ok":
            data = sample["app"]["data"]
            budgets(data)
            assert data["pane_count"] == meta["panes"], "unexpected pane count"
            # Native snapshots verify the supplied build/config identity. macOS
            # records these on each pane, Windows records them on the envelope.
            observed = data if "compiler" in data else next(iter(data["panes"]), None)
            if observed:
                for key in ("compiler", "mode", "target_cpu", "backend", "presentation", "font", "font_size_pt", "dpi"):
                    assert observed[key] == meta[key], f"declared {key} differs from running app"
                assert list(observed["window_pixels"]) == list(meta["window_pixels"]), "pixel geometry differs"
    if meta["role"] == "smoke":
        assert all(s["os"]["status"] == "ok" for s in samples), "native collector smoke could not sample itself"
    return {"path": str(path), "metadata": meta, "samples": samples}

def stats(values, steady):
    values = sorted(values)
    return {"n": len(values), "median": statistics.median(values),
            "p95": values[math.ceil(.95 * len(values)) - 1], "p99": values[math.ceil(.99 * len(values)) - 1],
            "sampled_peak": max(values), "steady_median": statistics.median(steady)}

def checksum(run):
    rows = run["samples"][-run["metadata"]["steady_samples"]:]
    values = []
    for sample in rows:
        if sample["app"]["status"] != "ok":
            return None
        panes = sample["app"]["data"]["panes"]
        order = run["metadata"].get("pane_order")
        if order is not None:
            by_id = {str(p["id"]): p for p in panes}
            assert len(order) == len(panes) and set(map(str, order)) == by_id.keys(), "pane order mapping differs"
            panes = [by_id[str(pane)] for pane in order]
        # IDs may differ by process, but fixture-to-pane association must not.
        # Sorting hashes would silently accept output swapped between panes.
        values.append([p["viewport_hash"] for p in panes])
    assert values and all(v == values[0] for v in values), "steady viewport is still changing"
    return values[0]

def cleanup(run):
    meta = run["metadata"]
    phase = meta["phase"]
    if phase not in ("images-disabled", "trimmed", "panes-closed"):
        return "not-applicable"
    before = meta.get("precondition_app")
    if not before:
        return "blocked: missing pre-action resource snapshot"
    for sample in run["samples"][-meta["steady_samples"]:]:
        if sample["app"]["status"] != "ok":
            return "blocked: application resource API unavailable"
        data = sample["app"]["data"]
        if phase == "images-disabled":
            assert any(r["renderer_image_count"] > 0 for _, r in renderers(before)), "image cleanup was never primed"
            for pane in data["panes"]:
                assert pane["renderer"]["renderer_image_count"] == 0, "renderer image survived disable"
                assert pane["terminal"]["primary_image_bytes"] == pane["terminal"]["alternate_image_bytes"] == 0
        elif phase == "trimmed":
            targets = set(map(str, meta.get("target_panes", [])))
            assert targets, "trim requires explicit target pane IDs"
            current = {str(p["id"]): p for p in data["panes"]}
            assert targets <= current.keys()
            assert any(r["cache_lower_bound_bytes"] > 0 for _, r in renderers(before)), "trim was never primed"
            assert all(current[p]["cache_state"] == "trimmed" for p in targets), "target pane did not trim"
        else:
            removed = set(map(str, meta.get("closed_panes", [])))
            assert removed, "close requires explicit pane IDs"
            assert removed <= {str(p["id"]) for p in before["panes"]}, "closed panes were never live"
            assert not removed & {str(p["id"]) for p in data["panes"]}, "closed pane remains registered"
    return "pass"

def analyze(runs):
    groups = defaultdict(list)
    for run in runs:
        meta = run["metadata"]
        groups[(meta["platform"], meta["run_group"], meta["scenario"], meta["phase"])].append(run)
    results = []
    for key, group in sorted(groups.items()):
        smoke = all(r["metadata"]["role"] == "smoke" for r in group)
        result = {"platform": key[0], "run_group": key[1], "scenario": key[2], "phase": key[3],
                  "status": "collector smoke only; Mostty resources/hardware gains unmeasured" if smoke else "paired",
                  "cleanup": [cleanup(r) for r in group], "os": {}, "logical": {}, "application_resources": "blocked"}
        if not smoke:
            group.sort(key=lambda r: r["metadata"]["trial"])
            assert [r["metadata"]["trial"] for r in group] == list(range(8)), "require eight distinct ABBA/BAAB trials"
            assert [r["metadata"]["side"] for r in group] == ORDER, "trial order must be ABBA BAAB"
            first = group[0]["metadata"]
            hardware = first["hardware"]
            if not hardware.get("cpu") or not hardware.get("gpu") or hardware.get("status") == "blocked":
                result["status"] = "blocked: incomplete hardware identity; OS samples are report-only"
            for run in group:
                assert all(run["metadata"][field] == first[field] for field in CONDITIONS), "comparison conditions differ"
            for side in ("base", "head"):
                assert len({r["metadata"]["commit"] for r in group if r["metadata"]["side"] == side}) == 1, "mixed revision on one side"
            hashes = [checksum(r) for r in group]
            if all(h is not None for h in hashes):
                assert all(h == hashes[0] for h in hashes), "VT viewport/SGR output differs"
                result["application_resources"] = "budget checks and VT viewport/SGR checksum pass; GPU pixels require native oracle evidence"
            else:
                result["application_resources"] = "blocked: missing application resource API/checksum"
        for side in sorted({r["metadata"]["side"] for r in group}):
            selected = [r for r in group if r["metadata"]["side"] == side]
            metrics = {}
            for field in OS_FIELDS:
                values = [s["os"][field] for r in selected for s in r["samples"] if s["os"]["status"] == "ok" and field in s["os"]]
                steady = [s["os"][field] for r in selected for s in r["samples"][-r["metadata"]["steady_samples"]:] if s["os"]["status"] == "ok" and field in s["os"]]
                if values and steady:
                    metrics[field] = stats(values, steady)
            result["os"][side] = metrics
            resource_metrics = {}
            observations = [logical(s) for r in selected for s in r["samples"]]
            steady_observations = [logical(s) for r in selected for s in r["samples"][-r["metadata"]["steady_samples"]:]]
            for name in sorted({name for sample in observations for name in sample}):
                values = [sample[name] for sample in observations if name in sample]
                steady = [sample[name] for sample in steady_observations if name in sample]
                if steady:
                    resource_metrics[name] = stats(values, steady)
            result["logical"][side] = resource_metrics
        result["paired_ratios"] = {}
        if not smoke:
            for field in OS_FIELDS:
                medians = []
                for run in group:
                    values = [s["os"][field] for s in run["samples"][-run["metadata"]["steady_samples"]:] if s["os"]["status"] == "ok" and field in s["os"]]
                    medians.append(statistics.median(values) if values else None)
                if all(v is not None and v > 0 for v in medians):
                    result["paired_ratios"][field] = [medians[h] / medians[b] for b, h in ((0, 1), (3, 2), (5, 4), (6, 7))]
        result["gpu_status"] = sorted({s["gpu"]["status"] for r in group for s in r["samples"]})
        result["gpu"] = {}
        for side in result["os"]:
            result["gpu"][side] = {}
            selected = [r for r in group if r["metadata"]["side"] == side]
            for field in ("dedicated_bytes", "shared_bytes"):
                values = [s["gpu"][field] for r in selected for s in r["samples"] if s["gpu"]["status"] == "ok" and s["gpu"].get(field) is not None]
                if values:
                    result["gpu"][side][field] = stats(values, values)
        result["latency_status"] = "blocked: collectors do not measure input-to-present latency"
        result["external_latency"] = {}
        if all(r["metadata"].get("latency_source") and r["metadata"].get("input_to_present_ns") for r in group):
            assert len({r["metadata"]["latency_source"] for r in group}) == 1, "latency endpoints differ"
            for side in result["os"]:
                values = [v for r in group if r["metadata"]["side"] == side for v in r["metadata"]["input_to_present_ns"]]
                assert all(isinstance(v, (int, float)) and v >= 0 for v in values)
                result["external_latency"][side] = stats(values, values)
            result["latency_status"] = "external evidence: " + group[0]["metadata"]["latency_source"]
        result["energy_status"] = "blocked: collectors do not measure energy"
        results.append(result)
    return results

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path); parser.add_argument("output", type=Path)
    parser.add_argument("--require-native-smoke", action="store_true")
    args = parser.parse_args()
    paths = sorted(args.input.rglob("*.jsonl")) if args.input.is_dir() else [args.input]
    assert paths, "no native memory artifacts"
    runs = [load_run(p) for p in paths]
    if args.require_native_smoke:
        assert {r["metadata"]["platform"] for r in runs if r["metadata"]["role"] == "smoke"} == {"Windows", "macOS"}, "native collector smoke artifact missing"
    fixtures = [json.loads(p.read_text(encoding="utf-8-sig")) for p in args.input.rglob("memory-fixture*.json")] if args.input.is_dir() else []
    if args.require_native_smoke:
        by_case = defaultdict(list)
        for fixture in fixtures: by_case[fixture["case"]].append(fixture)
        assert set(by_case) == {"cjk-cold", "wallpaper-control"}, "native fixture artifact missing"
        assert all(len(rows) == 2 and rows[0] == rows[1] for rows in by_case.values()), "native fixture bytes differ or artifact missing"
    results = analyze(runs)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "results.json").write_text(json.dumps({"results": results, "raw_runs": runs, "native_input_fixtures": fixtures}, indent=2) + "\n")
    lines = ["# Native memory evidence", "", "OS memory is report-only. Sampled peaks are not true allocation peaks. Logical/resource bytes, Metal device allocation and OS footprint overlap and must not be added."]
    for result in results:
        lines += [f'\n{result["platform"]} / {result["scenario"]}: {result["status"]}; {result["application_resources"]}. Cleanup: {", ".join(result["cleanup"])}. GPU capability: {", ".join(result["gpu_status"])}.\n']
        lines += ["| Side | OS metric | Steady median bytes | Sampled peak bytes |", "|---|---|---:|---:|"]
        for side, metrics in result["os"].items():
            for name, value in metrics.items():
                lines.append(f'| {result["platform"]} / {result["scenario"]} / {result["phase"]} / {side} | {name} | {value["steady_median"]:.0f} | {value["sampled_peak"]} |')
        if any(result["logical"].values()):
            lines += ["", "Application categories (overlapping logical extents / requested allocations; separate from OS):", "",
                      "| Side | Resource metric | Steady median bytes | Sampled peak bytes |", "|---|---|---:|---:|"]
            for side, metrics in result["logical"].items():
                for name, value in metrics.items():
                    lines.append(f'| {side} | {name} | {value["steady_median"]:.0f} | {value["sampled_peak"]} |')
        if result["paired_ratios"]:
            lines += ["", "| OS metric | Four paired head/base ratios (report only) | Median ratio |", "|---|---|---:|"]
            for name, ratios in result["paired_ratios"].items():
                lines.append(f'| {name} | {", ".join(f"{v:.3f}" for v in ratios)} | {statistics.median(ratios):.3f} |')
        if any(result["gpu"].values()):
            lines += ["", "GPU process counters (separate, overlapping scope):", "", "| Side | Counter | Median bytes | Sampled peak bytes |", "|---|---|---:|---:|"]
            for side, metrics in result["gpu"].items():
                for name, value in metrics.items():
                    lines.append(f'| {side} | {name} | {value["median"]:.0f} | {value["sampled_peak"]} |')
        lines += ["", result["latency_status"] + ". " + result["energy_status"] + "."]
        if result["external_latency"]:
            lines += ["", "| Side | External input-to-present p95 ns | p99 ns | n |", "|---|---:|---:|---:|"]
            for side, value in result["external_latency"].items():
                lines.append(f'| {side} | {value["p95"]:.0f} | {value["p99"]:.0f} | {value["n"]} |')
    lines += ["", "Application counters and original samples are preserved separately in results.json. A passed collector smoke is not a passed Mostty memory benchmark. Missing GPU/hardware/pixel/latency evidence is blocked, never zero or passed."]
    (args.output / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))

if __name__ == "__main__":
    main()
