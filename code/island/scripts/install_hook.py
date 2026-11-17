#!/usr/bin/python3
"""Merge/remove Island hook entries in Claude Code settings.json (idempotent, atomic, with backup).

Usage: install_hook.py [--settings PATH] [--uninstall]
"""
import argparse, json, os, shutil, sys, tempfile, time

MARK = ".claude-island/hook.py"
# `|| true`: whatever happens (file deleted, python missing) the hook exits 0 — exit 2 on Stop would
# block Claude from stopping.
COMMAND = '/usr/bin/python3 -I -S "$HOME/.claude-island/hook.py" >/dev/null 2>&1 || true'
# event -> (async, timeout)
EVENTS = {
    "PermissionRequest": (False, 3),
    "Notification": (True, 5),
    "Elicitation": (True, 5),
    "PostToolUse": (True, 5),
    "PostToolUseFailure": (True, 5),
    "UserPromptSubmit": (True, 5),
    "Stop": (False, 3),
    "StopFailure": (True, 5),
    "SessionEnd": (False, 2),
}


def is_ours(h):
    return isinstance(h, dict) and MARK in str(h.get("command", ""))


def strip_ours(hooks):
    """Remove our entries everywhere; drop groups/events left empty. Returns True if changed."""
    changed = False
    for ev in list(hooks.keys()):
        groups = hooks[ev]
        if not isinstance(groups, list):
            continue
        new_groups = []
        for g in groups:
            inner = g.get("hooks") if isinstance(g, dict) else None
            if isinstance(inner, list):
                kept = [h for h in inner if not is_ours(h)]
                if len(kept) != len(inner):
                    changed = True
                    if not kept:
                        continue
                    g = dict(g, hooks=kept)
            new_groups.append(g)
        if new_groups:
            hooks[ev] = new_groups
        else:
            del hooks[ev]
            changed = True
    return changed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--settings", default=os.path.expanduser("~/.claude/settings.json"))
    ap.add_argument("--uninstall", action="store_true")
    a = ap.parse_args()
    path = a.settings

    data = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            raw = f.read()
        if raw.strip():
            data = json.loads(raw)
        if not isinstance(data, dict):
            sys.exit("settings.json is not a JSON object")
    elif a.uninstall:
        print("no settings file, nothing to do")
        return

    before = json.dumps(data, sort_keys=True)
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        hooks = {}
    strip_ours(hooks)  # normalise: re-adding below keeps it idempotent without duplicates
    if not a.uninstall:
        for ev, (is_async, timeout) in EVENTS.items():
            entry = {"type": "command", "command": COMMAND, "timeout": timeout}
            if is_async:
                entry["async"] = True
            hooks.setdefault(ev, []).append({"hooks": [entry]})
    if hooks:
        data["hooks"] = hooks
    else:
        data.pop("hooks", None)

    if json.dumps(data, sort_keys=True) == before:
        print("no changes")
        return

    out = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    json.loads(out)  # validate
    if os.path.exists(path):
        bak = "%s.bak-island-%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(path, bak)
        print("backup:", bak)
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings-island-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(out)
        if os.path.exists(path):
            shutil.copymode(path, tmp)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    print("uninstalled" if a.uninstall else "installed", "->", path)


if __name__ == "__main__":
    main()
