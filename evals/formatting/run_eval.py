#!/usr/bin/env python3
"""Run spoken test sentences through the real Deepgram request and score the transcripts.

Audio is synthesised with macOS `say`, so the run is repeatable without a microphone.
Each variant is the query string the app sends (see DeepgramProvider.makeRequest).

  python3 evals/formatting/run_eval.py --variant baseline --out evals/results/raw/<file>.json
  python3 evals/formatting/run_eval.py --variant candidate --out ...

The key comes from DEEPGRAM_API_KEY or the Keychain entry the app itself uses.
"""
import argparse, json, os, subprocess, sys, tempfile, urllib.parse, urllib.request
from pathlib import Path

HERE = Path(__file__).parent
VOICES = {"en": "Samantha", "de": "Anna"}

# Query params per variant, mirroring the app: smart_format on, plus what each variant adds.
VARIANTS = {
    "baseline": {"smart_format": "true", "numerals": "true"},   # app before the fix
    "candidate": {"smart_format": "true"},                        # numerals dropped
    "punctuate": {"punctuate": "true", "paragraphs": "true"},     # no numerals, no smart_format
}


def api_key():
    key = os.environ.get("DEEPGRAM_API_KEY", "")
    if not key:
        key = subprocess.run(
            ["security", "find-generic-password", "-s", "ai.karko.sadaa", "-a", "deepgram-key", "-w"],
            capture_output=True, text=True).stdout.strip()
    if not key:
        sys.exit("No API key: set DEEPGRAM_API_KEY or store one in the Keychain.")
    return key


def synth(text, voice, path):
    subprocess.run(["say", "-v", voice, "-o", str(path), "--file-format=WAVE",
                    "--data-format=LEI16@16000", text], check=True)


def transcribe(wav, lang, params, key):
    query = {"model": "nova-3", "language": lang, **params}
    req = urllib.request.Request(
        "https://api.deepgram.com/v1/listen?" + urllib.parse.urlencode(query),
        data=wav.read_bytes(), method="POST",
        headers={"Authorization": f"Token {key}", "Content-Type": "audio/wav"})
    with urllib.request.urlopen(req, timeout=60) as r:
        body = json.load(r)
    return body["results"]["channels"][0]["alternatives"][0]["transcript"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", choices=VARIANTS, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", nargs="*", help="re-run just these case ids and update them in --out")
    args = ap.parse_args()
    key, cases = api_key(), json.loads((HERE / "cases.json").read_text())
    previous = {r["id"]: r for r in json.loads(Path(args.out).read_text())["rows"]} if args.only else {}
    rows, tmp = [], Path(tempfile.mkdtemp())
    for c in cases:
        if args.only is not None and c["id"] not in args.only:
            rows.append({**c, "got": previous[c["id"]]["got"], "pass": previous[c["id"]]["pass"]})
            continue
        wav = tmp / f"{c['id']}.wav"
        synth(c["spoken"], c.get("voice", VOICES[c["lang"]]), wav)
        got = transcribe(wav, c["lang"], VARIANTS[args.variant], key)
        ok = got in [c["expected"], *c.get("accept", [])]
        rows.append({**c, "got": got, "pass": ok})
        print(("PASS" if ok else "FAIL"), c["id"], "|", got, "" if ok else f"| want: {c['expected']}")
    passed = sum(r["pass"] for r in rows)
    print(f"\n{args.variant}: {passed}/{len(rows)} passed")
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps({"variant": args.variant, "params": VARIANTS[args.variant],
                                          "passed": passed, "total": len(rows), "rows": rows}, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
