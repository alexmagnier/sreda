#!/usr/bin/env python3
"""results-*.json → docs/EVAL.md table (model × block) + failures."""
import glob, json, os, collections
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
runs = []
for f in sorted(glob.glob(os.path.join(HERE, "results-*.json"))):
    r = json.load(open(f, encoding="utf-8"))
    r["model"] = os.path.basename(f)[len("results-"):-len(".json")].replace("-nothink", " (повтор)")
    runs.append(r)
blocks = []
for r in runs:
    for x in r["results"]:
        if x["block"] not in blocks:
            blocks.append(x["block"])
lines = ["# Экзамен локальных моделей — стартовый набор", "",
         "Задачи синтетические (без клиентских данных),",
         "проверка детерминированная: регулярки, точные числа, исполнение кода в песочнице без сети.",
         "Запуск: `tests/eval/run_eval.py <qwen-work|qwen-lab>`, отчёт: `tests/eval/report.py`.", "",
         "Модель отвечает **напрямую через API** (без Claude Code и без интернета): это замер самой модели.", "",
         "| Блок | " + " | ".join(r["model"] for r in runs) + " |", "|---|" + "---|" * len(runs)]
for b in blocks:
    row = [b]
    for r in runs:
        xs = [x for x in r["results"] if x["block"] == b]
        row.append(f"{sum(x['ok'] for x in xs)}/{len(xs)}" if xs else "—")
    lines.append("| " + " | ".join(row) + " |")
tot = ["**Итого**"]
for r in runs:
    xs = r["results"]
    tot.append(f"**{sum(x['ok'] for x in xs)}/{len(xs)}** · {sum(x['seconds'] for x in xs)/max(len(xs),1):.0f} с/задача")
lines.append("| " + " | ".join(tot) + " |")
lines += ["", "## Провалы", ""]
for r in runs:
    for x in r["results"]:
        if not x["ok"]:
            lines.append(f"- **{r['model']} · {x['id']}** — {'; '.join(x['fails'])[:300]}")
lines += ["", f"_Прогон: {', '.join(r['model'] + ' ' + r['date'] for r in runs)}_", ""]
os.makedirs(os.path.join(REPO, "docs"), exist_ok=True)
open(os.path.join(REPO, "docs", "EVAL.md"), "w", encoding="utf-8").write("\n".join(lines))
print("\n".join(lines))
