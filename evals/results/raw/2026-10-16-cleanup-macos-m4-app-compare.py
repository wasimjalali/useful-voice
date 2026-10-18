#!/usr/bin/env python3
"""Compares the app-pipeline runs on the M4 (Metal) with the round 4 Linux llama-server runs.

  python3 evals/results/raw/2026-10-16-cleanup-macos-m4-app-compare.py

For each set: do the Swift rules match the TypeScript rules the eval scores; does the Swift
pipeline's final text match run_eval's rules+s1+guard final (the TypeScript guard); how many
raw model answers match Linux llama-server's; and the spoken words lost by the app's own final
text, case by case.
"""
import json, sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "evals" / "cleanup"))
import run_eval  # noqa: E402

RAW = REPO / "evals" / "results" / "raw"
for name, cases_file in (("insample", "cases.json"), ("heldout", "heldout.json")):
    cases = {c["id"]: c for c in json.loads((REPO / "evals" / "cleanup" / cases_file).read_text())}
    app = json.loads((RAW / f"2026-10-16-cleanup-macos-m4-app-{name}-scored.json").read_text())
    linux = json.loads((RAW / f"2026-10-16-cleanup-r4-linux-{name}.json").read_text())
    rows = {r["id"]: r for r in app["raw"]["runs"]["rules+s1"]}
    lrows = {r["id"]: r for r in linux["raw"]["runs"]["rules+s1"]}
    ids = app["raw"]["cases_ids"]
    rules_diff = [i for i in ids if app["raw"]["rules_text"][i] != linux["raw"]["rules_text"][i]]
    guard_diff = [i for i in ids if rows[i]["pipeline_text"] != app["finals"]["rules+s1+guard"][i]]
    same_output = sum(rows[i]["output"] == lrows[i]["output"] for i in ids)
    outcomes = {}
    for i in ids:
        outcomes[rows[i]["outcome"]] = outcomes.get(rows[i]["outcome"], 0) + 1
    lost = {i: run_eval.words_lost(cases[i], rows[i]["pipeline_text"]) for i in ids}
    print(f"== {name}: {len(ids)} cases")
    print(f"Swift rules differ from TS rules: {rules_diff or 'none'}")
    print(f"Swift pipeline final differs from run_eval rules+s1+guard final: {guard_diff or 'none'}")
    print(f"raw model answer identical to Linux llama-server round 4: {same_output}/{len(ids)}")
    print(f"outcomes: {dict(sorted(outcomes.items()))}")
    print(f"app final, words lost: {sum(lost.values())} in {sum(1 for v in lost.values() if v)} cases")
    for i in ids:
        if lost[i]:
            print(f"  {i} ({'clean' if not cases[i]['needs_edit'] else 'dirty'}) lost {lost[i]}: "
                  f"{cases[i]['input']!r} -> {rows[i]['pipeline_text']!r}")
    for i in ids:
        if rows[i]["output"] != lrows[i]["output"]:
            print(f"  differs from Linux {i}: mac {rows[i]['output']!r} | linux {lrows[i]['output']!r}")
