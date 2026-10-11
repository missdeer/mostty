#!/usr/bin/env python3
"""Linux-only artifact analysis; no Python runs on the macOS/Windows runners."""
import argparse
import json
import math
from pathlib import Path
import re
import statistics as st

def stats(values):
    values = sorted(values)
    median = st.median(values)
    return {"n": len(values), "median": median, "p95": values[math.ceil(.95 * len(values)) - 1],
            "min": values[0], "max": values[-1], "mad": st.median(abs(x - median) for x in values)}

def analyze(directory):
    meta = json.loads((directory / "metadata.json").read_text())
    records = []
    for trial, side in enumerate(meta["order"]):
        path = directory / f"{side}-{trial}.log"
        for match in re.finditer(r"BENCH (\{[^\r\n]*\})", path.read_text(encoding="utf-8-sig")):
            row = json.loads(match[1])
            row.update(side=side, trial=trial)
            assert row["ns"] > 0 and row["units"] > 0, row
            records.append(row)
    assert records, f"no benchmark records in {directory}"
    cases = sorted({r["case"] for r in records})
    results = []
    for case in cases:
        rows = {side: [r for r in records if r["case"] == case and r["side"] == side] for side in ("base", "head")}
        for side, group in rows.items():
            assert group, (case, side)
            trials = [i for i, s in enumerate(meta["order"]) if s == side]
            for trial in trials:
                samples = [r["sample"] for r in group if r["trial"] == trial]
                assert set(samples) == set(range(meta["samples_per_process"])), (case, side, trial, samples)
                if case != "windows_dispatch":
                    assert len(samples) == meta["samples_per_process"], (case, side, trial)
        assert {r["units"] for r in rows["base"]} == {r["units"] for r in rows["head"]}, (case, "different work")
        assert {r["checksum"] for r in rows["base"]} == {r["checksum"] for r in rows["head"]}, (case, "output differs")
        if case in ("viewport_frames", "macos_font_config"):
            assert all(r["allocations"] == 0 for r in rows["head"]), (case, "warm allocation regression")
        if case == "multipart_scratch":
            assert all(r["retained_bytes"] <= 1024 * 1024 for r in rows["head"]), "scratch retention regression"
        if case == "windows_hover":
            assert all(r["calls"] == 1 for r in rows["head"]), "same-cell probe regression"
        if case == "ligature_keys":
            assert all(r["calls"] == 5000 for r in rows["head"]), "run-key construction regression"
        summary = {s: stats([r["ns"] for r in group]) for s, group in rows.items()}
        ratios = []
        for a, b in ((0, 1), (3, 2), (5, 4), (6, 7)):
            base = st.median(r["ns"] for r in rows["base"] if r["trial"] == a)
            head = st.median(r["ns"] for r in rows["head"] if r["trial"] == b)
            ratios.append(head / base)
        ratio = st.median(ratios)
        noise = max(st.median(abs(x - ratio) for x in ratios),
                    *(v["mad"] / v["median"] / math.sqrt(v["n"]) for v in summary.values()))
        consistent = all(r > 1 for r in ratios) or all(r < 1 for r in ratios)
        signal = consistent and abs(ratio - 1) > 3 * noise
        verdict = ("repeatable increase" if ratio > 1 else "repeatable decrease") if signal else "no clear change above observed noise"
        metrics = {s: {k: stats([r[k] for r in group]) for k in ("allocations", "retained_bytes", "calls")} for s, group in rows.items()}
        results.append(dict(case=case, time_ns=summary, head_base_ratio=ratio, paired_ratios=ratios,
                            observed_noise=noise, timing_verdict=verdict, metrics=metrics,
                            units=rows["base"][0]["units"], units_per_second={s: rows[s][0]["units"] * 1e9 / summary[s]["median"] for s in rows}))
    return dict(metadata=meta, cases=results, raw_samples=records)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    directories = [args.input] if (args.input / "metadata.json").exists() else sorted(p.parent for p in args.input.glob("*/metadata.json"))
    assert directories, "missing benchmark artifacts"
    results = [analyze(p) for p in directories]
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    lines = ["# Runtime benchmark comparison", "", "Timing is report-only. Labels describe consistency across four paired process trials, not statistical proof or an input-to-display latency claim.", "", "| Platform / case | Base median / p95 (ms) | PR median / p95 (ms) | PR/base | Observation |", "|---|---:|---:|---:|---|"]
    for result in results:
        os = result["metadata"]["os"].split()[0]
        for case in result["cases"]:
            a, b = case["time_ns"]["base"], case["time_ns"]["head"]
            lines.append(f'| {os} / {case["case"]} | {a["median"]/1e6:.4f} / {a["p95"]/1e6:.4f} | {b["median"]/1e6:.4f} / {b["p95"]/1e6:.4f} | {case["head_base_ratio"]:.3f} | {case["timing_verdict"]} |')
    lines += ["", "Raw samples, per-process ratios, n/min/max/MAD, checksums, units/s, allocation counts and retained bytes are in results.json and original logs. Retained bytes are allocator-owned scratch/frame storage, not RSS. Windows dispatch durations measure parsing admission, not real keyboard/GPU latency.", "", "A repeatable increase is a review signal; do not discard it or enable a strict timing gate without repeated runner history. Correctness, equal work, sample completeness and deterministic mechanism budgets are hard gates."]
    (args.output / "summary.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))

if __name__ == "__main__":
    main()
