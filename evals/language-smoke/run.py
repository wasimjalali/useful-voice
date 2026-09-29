#!/usr/bin/env python3
"""Smoke test: does each major picker language transcribe a plain work sentence?

One spoken sentence per language (macOS `say`), sent to Deepgram Nova-3 with the request the app
sends for a pinned language (`smart_format=true`, `language=<code>`). Prints the transcript next to
what was spoken so a person can judge it; there is no automatic score because word-for-word
matching across scripts says little.

  python3 evals/language-smoke/run.py --out evals/results/raw/2026-09-29-language-smoke.json

The key comes from DEEPGRAM_API_KEY or the Keychain entry the app itself uses.
"""
import argparse, json, os, subprocess, sys, tempfile, urllib.parse, urllib.request
from pathlib import Path

# code, macOS voice, spoken sentence (about tomorrow's ten o'clock meeting and the budget)
CASES = [
    ("es", "Paulina", "mañana tenemos una reunión a las diez y necesitamos revisar el presupuesto"),
    ("fr", "Thomas", "demain nous avons une réunion à dix heures et nous devons revoir le budget"),
    ("it", "Alice", "domani abbiamo una riunione alle dieci e dobbiamo rivedere il budget"),
    ("pt", "Luciana", "amanhã temos uma reunião às dez horas e precisamos revisar o orçamento"),
    ("nl", "Xander", "morgen hebben we een vergadering om tien uur en we moeten het budget bekijken"),
    ("sv", "Alva", "imorgon har vi ett möte klockan tio och vi behöver granska budgeten"),
    ("da", "Sara", "i morgen har vi et møde klokken ti og vi skal gennemgå budgettet"),
    ("fi", "Satu", "huomenna meillä on kokous kymmeneltä ja meidän täytyy tarkistaa budjetti"),
    ("pl", "Zosia", "jutro mamy spotkanie o dziesiątej i musimy przejrzeć budżet"),
    ("ru", "Milena", "завтра у нас встреча в десять часов и нам нужно проверить бюджет"),
    ("tr", "Yelda", "yarın saat onda bir toplantımız var ve bütçeyi gözden geçirmemiz gerekiyor"),
    ("ja", "Kyoko", "明日は十時に会議があります。予算を確認する必要があります"),
    ("ko", "Yuna", "내일 열 시에 회의가 있고 예산을 검토해야 합니다"),
    ("zh", "Tingting", "明天上午十点有一个会议，我们需要审查预算"),
    ("hi", "Lekha", "कल सुबह दस बजे हमारी बैठक है और हमें बजट की समीक्षा करनी है"),
    ("id", "Damayanti", "besok kita ada rapat jam sepuluh dan kita perlu memeriksa anggaran"),
    ("cs", "Zuzana", "zítra máme schůzku v deset hodin a musíme zkontrolovat rozpočet"),
    ("el", "Melina", "αύριο έχουμε συνάντηση στις δέκα και πρέπει να εξετάσουμε τον προϋπολογισμό"),
    ("ro", "Ioana", "mâine avem o întâlnire la ora zece și trebuie să revizuim bugetul"),
]


def api_key():
    key = os.environ.get("DEEPGRAM_API_KEY", "")
    if not key:
        key = subprocess.run(
            ["security", "find-generic-password", "-s", "ai.karko.sadaa", "-a", "deepgram-key", "-w"],
            capture_output=True, text=True).stdout.strip()
    if not key:
        sys.exit("No API key: set DEEPGRAM_API_KEY or store one in the Keychain.")
    return key


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    key, tmp, rows = api_key(), Path(tempfile.mkdtemp()), []
    for code, voice, spoken in CASES:
        wav = tmp / f"{code}.wav"
        subprocess.run(["say", "-v", voice, "-o", str(wav), "--file-format=WAVE",
                        "--data-format=LEI16@16000", spoken], check=True)
        query = urllib.parse.urlencode({"model": "nova-3", "language": code, "smart_format": "true"})
        req = urllib.request.Request(
            "https://api.deepgram.com/v1/listen?" + query, data=wav.read_bytes(), method="POST",
            headers={"Authorization": f"Token {key}", "Content-Type": "audio/wav"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                got = json.load(r)["results"]["channels"][0]["alternatives"][0]["transcript"]
        except Exception as error:  # a rejected language must show up, not hide
            got = f"ERROR: {error}"
        rows.append({"code": code, "voice": voice, "spoken": spoken, "got": got})
        print(f"{code}\n  spoken: {spoken}\n  got:    {got}")
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(rows, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
