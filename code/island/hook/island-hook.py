#!/usr/bin/python3 -I -S
# Island hook for Claude Code: overlay for states Claude Code's own session file lacks (waiting, error).
# Writes ${CLAUDE_CONFIG_DIR:-~/.claude}/island/waiting/<sessionId>.json. Never prints, always exits 0.
# Stores NO prompts, tool inputs or tool responses.
import sys, os, json, time, re

T0_MS = time.time_ns() // 1000000   # captured at hook START (ordering of async hooks)
MAX_STDIN = 1024 * 1024
WAIT_NOTIF = {"permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"}
RESOLVE = {"PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "Stop"}


def classify(ev, data):
    """Return (waiting, error, message) or None to ignore."""
    if ev == "PermissionRequest":
        tool = str(data.get("tool_name") or "")[:80]
        return True, False, ("нужно разрешение: " + tool) if tool else "нужно разрешение"
    if ev == "Elicitation":
        return True, False, (str(data.get("message") or "")[:200] or "нужен ответ")
    if ev == "Notification":
        nt = data.get("notification_type")
        if nt in WAIT_NOTIF:
            return True, False, (str(data.get("message") or "")[:200] or None)
        if nt == "idle_prompt":
            return False, False, None
        return None
    if ev in RESOLVE:
        return False, False, None
    if ev == "StopFailure":
        return False, True, "ошибка API"
    return None


def main():
    raw = sys.stdin.buffer.read(MAX_STDIN + 1)
    if not raw or len(raw) > MAX_STDIN:
        return
    data = json.loads(raw.decode("utf-8", "replace"))
    if not isinstance(data, dict):
        return
    sid = re.sub(r"[^A-Za-z0-9_-]", "", str(data.get("session_id") or ""))[:80]
    if not sid:
        return
    ev = str(data.get("hook_event_name") or "")
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    d = os.path.join(base, "island", "waiting")
    path = os.path.join(d, sid + ".json")

    if ev == "SessionEnd":
        try:
            os.unlink(path)
        except OSError:
            pass
        return

    res = classify(ev, data)
    if res is None:
        return
    waiting, error, message = res

    try:
        with open(path, "rb") as f:
            old = json.loads(f.read(65536).decode("utf-8", "replace"))
        if isinstance(old, dict) and T0_MS <= int(old.get("ts_ms") or 0):
            return  # a newer (or same-ms) event already won
    except BaseException:
        pass

    out = {"session_id": sid, "waiting": waiting, "error": error, "ts_ms": T0_MS,
           "event": ev, "message": message}
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(out, f, ensure_ascii=False)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass


try:
    main()
except BaseException:
    pass
os._exit(0)
