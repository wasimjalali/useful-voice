#!/usr/bin/env python3
"""English cleanup eval: does a small local model beat the deterministic rules?

Variants (all scored on cases.json against a do-nothing baseline):
  none                 the Deepgram text as it is
  rules                the shipped TypeScript cleanup rules (windows/src/core/formatting)
  rules+s1             rules, then S1-mini (Q4_K_M), control line mapped from app category
  rules+sf             rules, then SpeakoFlow Mini (Q4_K_M)
  ...+guard            the same model output through the shipped CleanupGuard; a reject
                       falls back to the rules-only text
  s1-fixed             ablation: S1-mini with the card's default control line for every case
                       (the mapped run differs only in Context: email for email apps)
  s1-semicasual        ablation: the first mapping tried, semi-casual for chat and coding apps
  s1-raw, sf-raw       ablation: the model reads the raw text, no rules step first

Scores are reported separately (a model that never edits wins restraint and scores zero on
edits, so no single number is used):
  restraint       clean cases returned byte for byte
  edit accuracy   cases that need an edit and came back as the expected (or accepted) text
  content loss    cases where a content word of the expected text is missing
  content add     cases where a content word appears that is in neither input nor expected
  guard reject    share of model outputs the guard threw away

Needs: node + `npm ci` in windows/ (esbuild bundles the shipped TS core), a llama.cpp
release (`--fetch` downloads and checks the pinned one) and the two GGUF files (`--fetch`).

  python3 evals/cleanup/run_eval.py --fetch --work /tmp/cleanup-work --out evals/results/raw/<file>.json
  python3 evals/cleanup/run_eval.py --rescore evals/results/raw/<file>.json     # score again, no models
"""
import argparse, hashlib, json, os, platform, re, shutil, signal, statistics, subprocess, sys, tarfile
import threading, time, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent

LLAMA = {
    "tag": "b11669",
    "assets": {
        "linux-x64": ("llama-b11669-bin-ubuntu-x64.tar.gz",
                      "cf07c1c112d709bd67e522017471de57ed0ec8bea031d732c5422351c07f65ac"),
        "macos-arm64": ("llama-b11669-bin-macos-arm64.tar.gz",
                        "dbed55493d72bc1ba2babc8770d669c2289b5bc4ee9fb2a4dfc158d45b7d13fd"),
    },
}
MODELS = {
    "s1": {
        "name": "S1-mini by Superwhisper",
        "repo": "superwhisper/s1-mini-GGUF",
        "revision": "34add00a48a2e5d24e5a4ee5405a99620a3a240c",
        "file": "s1-mini-q4_k_m.gguf",
        "sha256": "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634",
        "size": 484219808,
    },
    "sf": {
        "name": "SpeakoFlow Mini 0.8B",
        "repo": "SpeakoFlow/speakoflow-mini",
        "revision": "835431771f72820251fe6c6b4b07f12b000e2647",
        "file": "SpeakoFlow-Mini-0.8B-Q4_K_M.gguf",
        "sha256": "530e0a5d4e9314e3bae2c92aecf3ab39ca48e8cfecac41372058f9fcb742329d",
        "size": 541903616,
    },
}
SF_SYSTEM = (HERE / "prompts" / "speakoflow-system.txt").read_text(encoding="utf-8").rstrip("\n")
FIXED_CONTROL = {"category": "other", "style": "semi-formal"}

# Model runs: name -> (model, what the model reads, control line mode)
MODEL_RUNS = {
    "rules+s1": ("s1", "rules", "mapped"),
    "rules+sf": ("sf", "rules", None),
    "s1-fixed": ("s1", "rules", "fixed"),
    "s1-semicasual": ("s1", "rules", "semicasual"),
    "s1-raw": ("s1", "raw", "mapped"),
    "sf-raw": ("sf", "raw", None),
}
HEADLINE = ["none", "rules", "rules+s1", "rules+s1+guard", "rules+sf", "rules+sf+guard"]


# ---------------------------------------------------------------- fetch

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url, dest, want_sha):
    dest = Path(dest)
    if dest.exists() and sha256(dest) == want_sha:
        return
    print(f"downloading {url}", flush=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(url, timeout=600) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f, 1 << 20)
    got = sha256(tmp)
    if got != want_sha:
        tmp.unlink()
        sys.exit(f"SHA-256 mismatch for {url}: got {got}, want {want_sha}")
    tmp.rename(dest)


def platform_key():
    if sys.platform == "darwin":
        return "macos-arm64" if platform.machine() == "arm64" else "macos-x64"
    return "linux-x64"


def fetch(work):
    work.mkdir(parents=True, exist_ok=True)
    key = platform_key()
    if key not in LLAMA["assets"]:
        sys.exit(f"no pinned llama.cpp release for {key}")
    name, want = LLAMA["assets"][key]
    tgz = work / name
    download(f"https://github.com/ggml-org/llama.cpp/releases/download/{LLAMA['tag']}/{name}", tgz, want)
    root = work / "llama"
    if not (root / f"llama-{LLAMA['tag']}" / "llama-server").exists():
        root.mkdir(exist_ok=True)
        with tarfile.open(tgz) as t:
            t.extractall(root, filter="data")
    models = work / "models"
    models.mkdir(exist_ok=True)
    for m in MODELS.values():
        download(f"https://huggingface.co/{m['repo']}/resolve/{m['revision']}/{m['file']}",
                 models / m["file"], m["sha256"])
    return root / f"llama-{LLAMA['tag']}", models


# ---------------------------------------------------------------- shipped TS core

def build_core(out_dir):
    esbuild = REPO / "windows" / "node_modules" / ".bin" / "esbuild"
    if not esbuild.exists():
        sys.exit("run `npm ci` in windows/ first (esbuild bundles the shipped TS core)")
    Path(out_dir).mkdir(parents=True, exist_ok=True)
    out = Path(out_dir) / "core.mjs"
    subprocess.run([str(esbuild), str(HERE / "core_entry.ts"), "--bundle", "--platform=node",
                    "--format=esm", f"--outfile={out}", "--log-level=error"], check=True)
    return out


def core(bundle, op, items):
    p = subprocess.run(["node", str(HERE / "core_cli.mjs"), str(bundle), op],
                       input=json.dumps(items), capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"core_cli {op} failed: {p.stderr}")
    return json.loads(p.stdout)


# ---------------------------------------------------------------- llama-server

class Server:
    def __init__(self, bin_dir, model_path, port, ngl, threads, ctx):
        self.bin_dir, self.model_path, self.port = Path(bin_dir), model_path, port
        self.ngl, self.threads, self.ctx = ngl, threads, ctx
        self.proc = None
        self.peak_rss_kb = 0
        self._stop = threading.Event()

    def start(self):
        cmd = [str(self.bin_dir / "llama-server"), "-m", str(self.model_path),
               "--jinja", "--chat-template-kwargs", '{"enable_thinking":false}',
               "--temp", "0", "-c", str(self.ctx), "-np", "1", "--port", str(self.port),
               "--host", "127.0.0.1"]
        if self.threads:
            cmd += ["-t", str(self.threads)]
        if self.ngl is not None:
            cmd += ["-ngl", str(self.ngl)]
        env = dict(os.environ)
        env["LD_LIBRARY_PATH"] = str(self.bin_dir) + ":" + env.get("LD_LIBRARY_PATH", "")
        env["DYLD_LIBRARY_PATH"] = str(self.bin_dir) + ":" + env.get("DYLD_LIBRARY_PATH", "")
        self.log = open(Path(self.model_path).parent / f"server-{self.port}.log", "w")
        self.proc = subprocess.Popen(cmd, stdout=self.log, stderr=subprocess.STDOUT, env=env)
        self.cmd = cmd
        t0 = time.time()
        while time.time() - t0 < 300:
            if self.proc.poll() is not None:
                sys.exit(f"llama-server exited early, see {self.log.name}")
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health", timeout=2) as r:
                    if json.load(r).get("status") == "ok":
                        break
            except Exception:
                time.sleep(0.5)
        else:
            sys.exit("llama-server did not become healthy in 300 s")
        threading.Thread(target=self._poll_rss, daemon=True).start()

    def _rss_kb(self):
        try:
            return int(subprocess.run(["ps", "-o", "rss=", "-p", str(self.proc.pid)],
                                      capture_output=True, text=True).stdout.strip() or 0)
        except Exception:
            return 0

    def _poll_rss(self):
        while not self._stop.is_set() and self.proc.poll() is None:
            self.peak_rss_kb = max(self.peak_rss_kb, self._rss_kb())
            time.sleep(0.05)

    def peak_rss_mb(self):
        """Peak resident set size. Linux reads VmHWM (the kernel's own high-water mark)."""
        kb = self.peak_rss_kb
        try:
            for line in open(f"/proc/{self.proc.pid}/status"):
                if line.startswith("VmHWM:"):
                    kb = max(kb, int(line.split()[1]))
        except OSError:
            pass
        return round(kb / 1024, 1)

    def chat(self, system, user, timeout=120):
        body = {
            "messages": ([{"role": "system", "content": system}] if system else [])
            + [{"role": "user", "content": user}],
            "temperature": 0,
            "seed": 0,
            "chat_template_kwargs": {"enable_thinking": False},
        }  # no max_tokens: generation stops at the end-of-sequence token
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/v1/chat/completions",
                                     json.dumps(body).encode(), {"Content-Type": "application/json"})
        t0 = time.perf_counter()
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.load(r)
        ms = (time.perf_counter() - t0) * 1000
        msg = data["choices"][0]["message"]
        return {
            "output": msg.get("content") or "",
            "reasoning": bool(msg.get("reasoning_content")),
            "finish": data["choices"][0].get("finish_reason"),
            "latency_ms": round(ms, 1),
            "prompt_tokens": data.get("usage", {}).get("prompt_tokens"),
            "completion_tokens": data.get("usage", {}).get("completion_tokens"),
            "timings": {k: data.get("timings", {}).get(k)
                        for k in ("prompt_ms", "predicted_ms", "predicted_per_second")},
        }

    def stop(self):
        self._stop.set()
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(20)
            except subprocess.TimeoutExpired:
                self.proc.kill()


# ---------------------------------------------------------------- scoring

STOP = set("""a an the and or but nor so yet of to in on at by for with from into onto over under about as than then
that this these those there here is are was were be been being am do does did done have has had having will would
shall should can could may might must i me my mine we us our you your he him his she her it its they them their who
whom whose which what when where why how if not just also very really too quite some any all each both few more most
other such only own same up down out off again once now well oh okay ok yeah yes um uh erm er hmm like know""".split())
NUMBER_WORDS = set("""zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen
sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million
first second third fourth fifth sixth seventh eighth ninth tenth twelfth""".split())
CUES = set("wait sorry scratch oops whoops rather mean actually correction instead make".split())
SYMBOLS = set("at dot dash slash underscore hash colon comma period percent dollar dollars cents point".split())


def tokens(text):
    out = []
    for m in re.finditer(r"[A-Za-z0-9]+(?:['’][A-Za-z]+)?", text):
        out.append(m.group(0).lower().replace("'", "").replace("’", ""))
    return out


AMPM = re.compile(r"\b[ap]\.?\s?m\b\.?", re.IGNORECASE)


def content(text):
    """Content words: no function words, numbers, correction cues, spoken symbols or a.m./p.m. marks."""
    return {t for t in tokens(AMPM.sub(" ", text))
            if t not in STOP and t not in NUMBER_WORDS and t not in CUES and t not in SYMBOLS
            and not any(c.isdigit() for c in t)}


def score_case(case, final):
    accepted = [case["expected"]] + case.get("accept", [])
    exact = final in accepted
    exp_c, in_c, out_c = content(case["expected"]), content(case["input"]), content(final)
    return {
        "exact": exact,
        "unchanged": final == case["input"],
        "loss": bool(exp_c - out_c),
        "add": bool(out_c - in_c - exp_c),
    }


def pct(n, d):
    return round(100.0 * n / d, 1) if d else None


def summarise(cases, finals, rules_ok, guard_rejects=None):
    """finals: id -> final text. Returns metrics overall and per split/group."""
    def block(subset):
        clean = [c for c in subset if not c["needs_edit"]]
        edit = [c for c in subset if c["needs_edit"]]
        sc = {c["id"]: score_case(c, finals[c["id"]]) for c in subset}
        rule_edit = [c for c in edit if rules_ok[c["id"]]]
        model_edit = [c for c in edit if not rules_ok[c["id"]]]
        out = {
            "n": len(subset), "n_clean": len(clean), "n_edit": len(edit),
            "restraint": pct(sum(sc[c["id"]]["unchanged"] for c in clean), len(clean)),
            "edit_accuracy": pct(sum(sc[c["id"]]["exact"] for c in edit), len(edit)),
            "edit_accuracy_rules_fixable": pct(sum(sc[c["id"]]["exact"] for c in rule_edit), len(rule_edit)),
            "edit_accuracy_model_needed": pct(sum(sc[c["id"]]["exact"] for c in model_edit), len(model_edit)),
            "n_rules_fixable": len(rule_edit), "n_model_needed": len(model_edit),
            "content_loss": pct(sum(s["loss"] for s in sc.values()), len(subset)),
            "content_add": pct(sum(s["add"] for s in sc.values()), len(subset)),
            "clean_wrong": [c["id"] for c in clean if not sc[c["id"]]["unchanged"]],
            "loss_ids": [c["id"] for c in subset if sc[c["id"]]["loss"]],
        }
        if guard_rejects is not None:
            out["guard_reject"] = pct(sum(guard_rejects[c["id"]] is not None for c in subset), len(subset))
        return out
    res = {"all": block(cases), "dev": block([c for c in cases if c["split"] == "dev"]),
           "test": block([c for c in cases if c["split"] == "test"])}
    res["by_group"] = {}
    for g in sorted({c["group"] for c in cases}):
        sub = [c for c in cases if c["group"] == g]
        res["by_group"][g] = {"n": len(sub),
                              "exact": pct(sum(score_case(c, finals[c["id"]])["exact"] for c in sub), len(sub))}
    return res


def lat_stats(ms):
    ms = sorted(ms)
    if not ms:
        return {}
    p95 = ms[min(len(ms) - 1, int(round(0.95 * (len(ms) - 1))))]
    return {"n": len(ms), "median_ms": round(statistics.median(ms), 1), "p95_ms": round(p95, 1),
            "mean_ms": round(statistics.mean(ms), 1), "max_ms": round(max(ms), 1)}


# ---------------------------------------------------------------- run

def pick_subset(cases, n):
    if not n or n >= len(cases):
        return cases
    step = len(cases) / n
    return [cases[int(i * step)] for i in range(n)]


def evaluate(args):
    cases = json.loads((HERE / "cases.json").read_text(encoding="utf-8"))
    cases = pick_subset(cases, args.subset)
    work = Path(args.work)
    bin_dir, models_dir = fetch(work) if args.fetch else (Path(args.llama_dir), Path(args.models_dir))
    scratch = work / "build"
    scratch.mkdir(parents=True, exist_ok=True)
    bundle = build_core(scratch)

    inputs = [c["input"] for c in cases]
    rules_text = dict(zip([c["id"] for c in cases], core(bundle, "rules", inputs)))
    controls = core(bundle, "control", [{"category": c["app"], "style": c.get("style")} for c in cases])
    control_of = dict(zip([c["id"] for c in cases], controls))
    fixed_line = core(bundle, "control", [FIXED_CONTROL])[0]
    s1_system = core(bundle, "prompt", None)

    raw = {"cases_ids": [c["id"] for c in cases], "rules_text": rules_text, "runs": {}, "servers": {}}
    wanted = [v for v in MODEL_RUNS if args.variants is None or v in args.variants]
    for key in ("s1", "sf"):
        runs = [v for v in wanted if MODEL_RUNS[v][0] == key]
        if not runs:
            continue
        m = MODELS[key]
        srv = Server(bin_dir, models_dir / m["file"], args.port + (0 if key == "s1" else 1), args.ngl, args.threads, args.ctx)
        srv.start()
        system = s1_system if key == "s1" else SF_SYSTEM
        try:
            for _ in range(args.warmup):  # not scored: first requests pay one-off costs
                srv.chat(system, (control_of[cases[0]["id"]] + "\n" if key == "s1" else "") + "Hello there, this is a warm up.")
            for name in runs:
                _, reads, ctl = MODEL_RUNS[name]
                rows = []
                for i, c in enumerate(cases):
                    text = rules_text[c["id"]] if reads == "rules" else c["input"]
                    if key == "s1":
                        line = fixed_line if ctl == "fixed" else control_of[c["id"]]
                        if ctl == "semicasual" and c["app"] in ("chat", "coding"):
                            line = line.replace("[Styling: semi-formal]", "[Styling: semi-casual]")
                        user = line + "\n" + text
                    else:
                        user = text
                    r = srv.chat(system, user)
                    r.update(id=c["id"], model_input=text)
                    rows.append(r)
                    if (i + 1) % 25 == 0:
                        print(f"  {name}: {i + 1}/{len(cases)}", flush=True)
                raw["runs"][name] = rows
            raw["servers"][key] = {"cmd": srv.cmd, "peak_rss_mb": srv.peak_rss_mb(),
                                   "model": {k: m[k] for k in ("name", "repo", "revision", "file", "sha256", "size")}}
        finally:
            srv.stop()
    raw["meta"] = {
        "date": time.strftime("%Y-%m-%d"), "platform": platform.platform(), "machine": platform.machine(),
        "cpu_count": os.cpu_count(), "python": platform.python_version(),
        "llama_cpp": LLAMA["tag"], "ngl": args.ngl, "threads": args.threads, "ctx": args.ctx, "warmup": args.warmup,
        "subset": args.subset, "label": args.label,
        "node": subprocess.run(["node", "--version"], capture_output=True, text=True).stdout.strip(),
    }
    return cases, raw, bundle


def rescore(cases, raw, bundle, limits=None):
    ids = [c["id"] for c in cases]
    rules_text = raw["rules_text"]
    rules_ok = {c["id"]: rules_text[c["id"]] in [c["expected"]] + c.get("accept", []) for c in cases}
    finals = {"none": {c["id"]: c["input"] for c in cases}, "rules": dict(rules_text)}
    summary = {"none": summarise(cases, finals["none"], rules_ok), "rules": summarise(cases, finals["rules"], rules_ok)}
    latency, guard_detail = {}, {}
    for name, rows in raw["runs"].items():
        by_id = {r["id"]: r for r in rows}
        outs = {i: by_id[i]["output"] for i in ids}
        finals[name] = {i: outs[i] for i in ids}
        summary[name] = summarise(cases, finals[name], rules_ok)
        gitems = [{"rules": by_id[i]["model_input"], "output": outs[i], **({"limits": limits} if limits else {})} for i in ids]
        verdicts = core(bundle, "guard", gitems)
        rejects = {i: (None if v["accepted"] else v["reason"]) for i, v in zip(ids, verdicts)}
        gname = name + "+guard"
        finals[gname] = {i: (verdicts[k]["text"] if verdicts[k]["accepted"] else rules_text[i]) for k, i in enumerate(ids)}
        summary[gname] = summarise(cases, finals[gname], rules_ok, rejects)
        # Was the reject right? A reject is right when the raw model output was not accepted text.
        right = wrong = 0
        by_case = {c["id"]: c for c in cases}
        reasons = {}
        for i in ids:
            if rejects[i] is None:
                continue
            reasons[rejects[i]] = reasons.get(rejects[i], 0) + 1
            if score_case(by_case[i], outs[i])["exact"]:
                wrong += 1
            else:
                right += 1
        guard_detail[gname] = {"rejects": sum(1 for v in rejects.values() if v), "reasons": reasons,
                               "reject_of_exact_output": wrong, "reject_of_inexact_output": right,
                               "ids": {i: r for i, r in rejects.items() if r}}
        latency[name] = lat_stats([r["latency_ms"] for r in rows])
        latency[name]["share_over_1s"] = pct(sum(r["latency_ms"] > 1000 for r in rows), len(rows))
        latency[name]["share_over_2s"] = pct(sum(r["latency_ms"] > 2000 for r in rows), len(rows))
        latency[name]["share_over_3s"] = pct(sum(r["latency_ms"] > 3000 for r in rows), len(rows))
        latency[name]["reasoning_outputs"] = sum(r["reasoning"] for r in rows)
        latency[name]["think_tag_outputs"] = sum("<think" in r["output"].lower() for r in rows)
    pooled = {}
    for key in ("s1", "sf"):
        ms = [r["latency_ms"] for name, rows in raw["runs"].items() if MODEL_RUNS[name][0] == key for r in rows]
        if ms:
            pooled[key] = lat_stats(ms)
    return {"summary": summary, "latency": latency, "latency_pooled": pooled, "guard": guard_detail, "rules_ok_ids": [i for i, v in rules_ok.items() if v]}, finals


def print_report(res, order=None):
    names = [n for n in (order or HEADLINE) if n in res["summary"]] + [n for n in res["summary"] if n not in (order or HEADLINE)]
    print(f"{'variant':24} {'restraint':>9} {'edit acc':>8} {'rules-fix':>9} {'model-need':>10} {'loss':>6} {'add':>6} {'guard rej':>9}")
    for n in names:
        a = res["summary"][n]["all"]
        print(f"{n:24} {a['restraint']!s:>9} {a['edit_accuracy']!s:>8} {a['edit_accuracy_rules_fixable']!s:>9} "
              f"{a['edit_accuracy_model_needed']!s:>10} {a['content_loss']!s:>6} {a['content_add']!s:>6} {a.get('guard_reject', '')!s:>9}")
    for n, l in res["latency"].items():
        print(f"latency {n:20} median {l['median_ms']} ms  p95 {l['p95_ms']} ms  (n={l['n']})")
    for k, l in res.get("latency_pooled", {}).items():
        print(f"latency pooled {k:13} median {l['median_ms']} ms  p95 {l['p95_ms']} ms  (n={l['n']})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fetch", action="store_true", help="download and verify llama.cpp and the models into --work")
    ap.add_argument("--work", default="/tmp/cleanup-eval-work")
    ap.add_argument("--llama-dir", help="folder holding llama-server (without --fetch)")
    ap.add_argument("--models-dir", help="folder holding the two GGUF files (without --fetch)")
    ap.add_argument("--out", help="raw + scored results JSON")
    ap.add_argument("--variants", nargs="*", choices=list(MODEL_RUNS), help="model runs to execute (default all)")
    ap.add_argument("--subset", type=int, default=0, help="run an even sample of N cases (CI latency run)")
    ap.add_argument("--ngl", type=int, default=None, help="GPU layers (macOS: 0 = CPU, 99 = Metal)")
    ap.add_argument("--threads", type=int, default=None)
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--ctx", type=int, default=8192, help="llama-server context size (-c)")
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--label", default="")
    ap.add_argument("--rescore", help="re-score an existing --out file without running the models")
    ap.add_argument("--fetch-only", action="store_true")
    args = ap.parse_args()

    if args.fetch_only:
        fetch(Path(args.work))
        return
    if args.rescore:
        data = json.loads(Path(args.rescore).read_text())
        cases = [c for c in json.loads((HERE / "cases.json").read_text(encoding="utf-8")) if c["id"] in set(data["raw"]["cases_ids"])]
        bundle = build_core(Path(args.work))
        res, _ = rescore(cases, data["raw"], bundle)
        print_report(res)
        data["result"] = res
        Path(args.rescore).write_text(json.dumps(data, indent=1, ensure_ascii=False))
        return
    cases, raw, bundle = evaluate(args)
    res, finals = rescore(cases, raw, bundle)
    print_report(res)
    for key, s in raw["servers"].items():
        print(f"peak RSS {key}: {s['peak_rss_mb']} MB")
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps({"raw": raw, "result": res, "finals": finals}, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
