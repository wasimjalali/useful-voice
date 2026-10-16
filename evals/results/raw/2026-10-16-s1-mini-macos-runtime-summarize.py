#!/usr/bin/env python3
"""Min and max of every number the write-up quotes, computed from the raw log, with the run
and step each extreme comes from.

Usage: summarize.py 2026-10-16-s1-mini-macos-runtime-ci.log > 2026-10-16-s1-mini-macos-runtime-summary.txt
"""
import re
import sys
from collections import defaultdict

rows = defaultdict(list)  # name -> [(value, run, step)]
bench = []  # (run, mode, threads, test, tps)
loads = []  # (run, step, kind, ms)
for line in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r"run (\d+) \| (.*?) \| (.*)$", line.rstrip("\n"))
    if not m:
        continue
    run, step, text = m.groups()

    def add(name, value):
        rows[name].append((float(value), run, step))

    t = re.search(r"MEASURE (cpuOnly|metal) run ([\d.]+) ms.*native prompt ([\d.]+) ms, native generate ([\d.]+) ms", text)
    if t:
        add(f"{t[1]} cleanup, whole call (ms)", t[2])
        add(f"{t[1]} cleanup, prompt decode (ms)", t[3])
    t = re.search(r"MEASURE (cpuOnly|metal) median ([\d.]+) ms", text)
    if t:
        add(f"{t[1]} cleanup, median of 5 (ms)", t[2])
    t = re.search(r"MEASURE (cpuOnly|metal) load ([\d.]+) ms.*resident: ([\d.]+), footprint: ([\d.]+)", text)
    if t:
        loads.append((run, step, t[1], float(t[2])))
        add(f"{t[1]} loaded resident (MB)", t[3])
        add(f"{t[1]} loaded footprint (MB)", t[4])
    t = re.search(r"MEASURE baseline \(resident: ([\d.]+), footprint: ([\d.]+)", text)
    if t:
        add("baseline resident (MB)", t[1])
        add("baseline footprint (MB)", t[2])
    t = re.search(r"MEASURE after \w+ unload \(resident: ([\d.]+), footprint: ([\d.]+)", text)
    if t:
        add("after unload resident (MB)", t[1])
        add("after unload footprint (MB)", t[2])
    t = re.search(r"MEASURE probe (cpuOnly|metal) prompt decode #\d+ status 0 ([\d.]+) ms", text)
    if t:
        add(f"probe {t[1]}, prompt decode of 97 tokens (ms)", t[2])
    t = re.search(r"MEASURE probe (cpuOnly|metal) single-token decodes ms (.*)$", text)
    if t:
        for v in t[2].split():
            add(f"probe {t[1]}, single-token decode (ms)", v)
    t = re.search(r"MEASURE pool \w+ threads 3 run ([\d.]+) ms \(prompt decode ([\d.]+)", text)
    if t:
        add("earlier probe with a ggml threadpool attached, 3 threads, whole call (ms)", t[1])
    t = re.search(r"MEASURE qos .* run ([\d.]+) ms \(native prompt ([\d.]+)", text)
    if t:
        add("earlier probe by thread QoS, whole call (ms)", t[1])
    r = re.match(r"\| qwen3 0\.6B Q4_K - Medium\s*\|[^|]*\|[^|]*\|\s*([\w,]+)\s*\|\s*(\d+)\s*\|(?:\s*(none)\s*\|)?\s*(pp\d+|tg\d+)\s*\|\s*([\d.]+)", text)
    if r:
        bench.append((run, "CPU only (-dev none)" if r[3] else "default", r[2], r[4], float(r[5])))

print("Computed by 2026-10-16-s1-mini-macos-runtime-summarize.py from the raw log.\n")
for name in sorted(rows):
    vals = rows[name]
    lo, hi = min(vals), max(vals)
    print(f"{name}: min {lo[0]:.1f} (run {lo[1]}, {lo[2]}), max {hi[0]:.1f} (run {hi[1]}, {hi[2]}), n={len(vals)}")
print("\nLoad times (ms) per run and step:")
for run, step, kind, ms in loads:
    print(f"  run {run} | {step} | {kind} load {ms:.0f}")
print("\nllama-bench (official release CLI, tokens per second; ms per token = 1000 / tg):")
for run, mode, threads, test, tps in bench:
    extra = f"  ({1000 / tps:.1f} ms per token)" if test.startswith("tg") else ""
    print(f"  run {run} | {mode}, {threads} threads | {test} {tps:.1f}{extra}")
