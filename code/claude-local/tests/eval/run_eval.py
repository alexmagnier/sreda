#!/usr/bin/env python3
"""Seed exam for the local models (see 02_ВЫБОР-МОДЕЛЕЙ.md of the kit).

usage: run_eval.py MODEL_ID [--only BLOCK] [--out results-<model>.json]
Sends each task in tasks.json to LM Studio (127.0.0.1:1234, Anthropic /v1/messages) with the harness
rules (config/CLAUDE.md) as the system prompt, scores the answer deterministically, prints a table.
Code tasks are executed in a kernel sandbox without network. Synthetic data only — no client files.
"""
import http.client, json, os, re, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
model = sys.argv[1]
only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else os.path.join(HERE, f"results-{model}.json")
tasks = json.load(open(os.path.join(HERE, "tasks.json"), encoding="utf-8"))
system = open(os.path.join(REPO, "config", "CLAUDE.md"), encoding="utf-8").read()


thinking_off = "--no-thinking" in sys.argv
rescore = "--rescore" in sys.argv


def ask(prompt):
    body = {"model": model, "max_tokens": 6000, "system": system,
            "messages": [{"role": "user", "content": prompt}]}
    if thinking_off:
        body["thinking"] = {"type": "disabled"}
    c = http.client.HTTPConnection("127.0.0.1", 1234, timeout=900)
    t0 = time.time()
    c.request("POST", "/v1/messages", json.dumps(body),
              {"content-type": "application/json", "anthropic-version": "2023-06-01"})
    r = json.loads(c.getresponse().read())
    dt = time.time() - t0
    text = "".join(b.get("text", "") for b in r.get("content", []) if b.get("type") == "text")
    u = r.get("usage", {})
    return text, dt, u.get("output_tokens", 0), r.get("error")


def run_code(answer, tests):
    m = re.findall(r"```(?:python|py)?\s*\n(.*?)```", answer, re.S)
    code = m[-1] if m else answer
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, "t.py")
        open(f, "w", encoding="utf-8").write(code + "\n\n" + tests + "\n")
        prof = f'(version 1)(allow default)(deny network*)(deny file-write*)(allow file-write* (subpath "{os.path.realpath(d)}") (literal "/dev/null"))'
        try:
            p = subprocess.run(["sandbox-exec", "-p", prof, "/usr/bin/python3", "-I", f], capture_output=True,
                               text=True, timeout=30)
            ok = "ALL_OK" in p.stdout
            return ok, (p.stderr.strip().splitlines() or [""])[-1][:200]
        except subprocess.TimeoutExpired:
            return False, "timeout"


def score(t, ans):
    c = t.get("checks", {})
    fails = []
    for rx in c.get("regex", []):
        if not re.search(rx, ans, re.I):
            fails.append(f"нет /{rx}/")
    for rx in c.get("must_not_regex", []):
        if re.search(rx, ans, re.I | re.M):
            fails.append(f"есть запрещённое /{rx}/")
    if "line_without" in c:
        lw = c["line_without"]
        for line in ans.splitlines():
            if lw["contains"].lower() in line.lower() and re.search(lw["no_regex"], line):
                fails.append(f"выдумана цифра в строке «{line.strip()[:80]}»")
    if "json_equals" in c:
        try:
            s = ans.strip()
            s = re.sub(r"^```(?:json)?\s*|\s*```$", "", s)
            got = json.loads(s)
            if got != c["json_equals"]:
                fails.append(f"json не совпал: {got}")
        except ValueError:
            fails.append("не чистый JSON")
    if "code_tests" in t:
        ok, err = run_code(ans, t["code_tests"])
        if not ok:
            fails.append(f"тесты кода: {err}")
    return fails


results = []
prev = {}
if rescore:   # re-check saved answers against the current tasks.json (no model calls)
    prev = {x["id"]: x for x in json.load(open(out, encoding="utf-8"))["results"]}
for t in tasks:
    if only and t["block"] != only:
        continue
    if rescore:
        if t["id"] not in prev:
            continue
        ans, dt, ntok, err = prev[t["id"]]["answer"], prev[t["id"]]["seconds"], prev[t["id"]]["output_tokens"], None
    else:
        ans, dt, ntok, err = ask(t["prompt"])
    fails = [f"ошибка API: {err}"] if err else score(t, ans)
    results.append({"id": t["id"], "block": t["block"], "ok": not fails, "fails": fails,
                    "seconds": round(dt, 1), "output_tokens": ntok, "answer": ans})
    print(f"{'✅' if not fails else '❌'} {t['id']:<22} {dt:6.1f}s {ntok:5d} tok  {'; '.join(fails)[:160]}", flush=True)

json.dump({"model": model, "date": time.strftime("%Y-%m-%d %H:%M"), "results": results},
          open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
n = len(results); k = sum(r["ok"] for r in results)
print(f"=== {model}: {k}/{n} · среднее время {sum(r['seconds'] for r in results)/max(n,1):.0f} с")
