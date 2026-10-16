#!/usr/bin/env python3
"""Pulls the measurement lines out of downloaded macos job logs into one labelled raw log.

Usage: extract.py OUT RUNID:HEAD:LOGFILE [RUNID:HEAD:LOGFILE ...]
Logs come from `gh run view RUNID --log --job JOBID`. Each kept line is written as
`run RUNID | step | text` with the runner timestamp removed.
"""
import re
import sys

KEEP = re.compile(
    r"MEASURE|COEXIST|\| (model|---|qwen3)|^build: |Apple M1|^7516192768$|hw\.optional\.arm\.FEAT_(DotProd|I8MM|BF16)|"
    r"Test run with|Test (measure|bothFrameworksLoadInOneProcess|s1MiniRunsBetweenTwoWhisperContexts|"
    r"aPassedDeadlineStopsTheRun|pipelineWithTheRealModel)\(\) (passed|skipped)")

out = open(sys.argv[1], "w")
for spec in sys.argv[2:]:
    run, head, path = spec.split(":", 2)
    out.write(f"=== run {run}, head {head}, log {path.rsplit('/', 1)[-1]} ===\n")
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split("\t", 2)
        if len(parts) != 3:
            continue
        step, text = parts[1], re.sub(r"^﻿?\d{4}-\d\d-\d\dT[\d:.]+Z ", "", parts[2])
        if KEEP.search(text):
            out.write(f"run {run} | {step} | {text}\n")
