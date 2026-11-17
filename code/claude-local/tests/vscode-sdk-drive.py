#!/usr/bin/env python3
"""Drive the VS Code wrapper exactly the way the Claude Code VS Code extension does: clean environment,
<bundled binary> + SDK args, stream-json + control protocol (initialize, permission requests).
Use it after every Claude Code / extension update — the extension's arguments change between versions.

usage: tests/vscode-sdk-drive.py WORKDIR work|lab "prompt" [--allow-tools] [--timeout S] [--then "2nd prompt"]
Prints a compact event log and the final result; exit 0 if a result arrived without error.
Loads the model (heavy): run on AC power."""
import glob, json, os, subprocess, sys, threading, time

wd, profile, prompt = sys.argv[1], sys.argv[2], sys.argv[3]
allow = "--allow-tools" in sys.argv
timeout = 600
if "--timeout" in sys.argv:
    timeout = int(sys.argv[sys.argv.index("--timeout") + 1])
repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
home = os.path.expanduser("~")
wrapper = os.path.join(repo, "bin", "claude-lab-vscode" if profile == "lab" else "claude-local-vscode")
conf = os.path.join(home, ".claude-local-net" if profile == "lab" else ".claude-local")
bundled = sorted(glob.glob(os.path.join(home, ".vscode/extensions/anthropic.claude-code-*-darwin-arm64/resources/native-binary/claude")))
if not bundled:
    sys.exit("Claude Code extension for VS Code not found in ~/.vscode/extensions")
env = {"HOME": home, "USER": os.environ.get("USER", ""), "LANG": "en_US.UTF-8",
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
       # what the extension sets (claudeCode.environmentVariables from bin/local-vscode)
       "CLAUDE_CONFIG_DIR": conf, "ANTHROPIC_BASE_URL": "http://127.0.0.1:1234",
       "ANTHROPIC_AUTH_TOKEN": "lmstudio-local", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
       "DISABLE_TELEMETRY": "1", "CLAUDE_CODE_ENTRYPOINT": "claude-vscode", "MCP_CONNECTION_NONBLOCKING": "true"}
os.chdir(wd)
args = [wrapper, bundled[-1],
        "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
        "--thinking=adaptive", "--model=default", "--permission-prompt-tool=stdio",
        "--setting-sources=user,project,local", "--permission-mode=default", "--include-partial-messages",
        "--mcp-config", json.dumps({"mcpServers": {}}),
        "--debug", "--debug-to-stderr", "--enable-auth-status", "--no-chrome", "--replay-user-messages"]
t0 = time.time()
p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1, env=env)
err_lines = []
threading.Thread(target=lambda: [err_lines.append(l) for l in p.stderr], daemon=True).start()

def send(obj):
    p.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n"); p.stdin.flush()

send({"type": "control_request", "request_id": "init-1",
      "request": {"subtype": "initialize", "hooks": None}})
send({"type": "user", "session_id": "", "parent_tool_use_id": None,
      "message": {"role": "user", "content": [{"type": "text", "text": prompt}]}})

then = sys.argv[sys.argv.index("--then") + 1] if "--then" in sys.argv else None
result = None; tools = []; first_token = None; text_parts = []; init_info = {}
timer = threading.Timer(timeout, lambda: p.kill()); timer.start()
for line in p.stdout:
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    t = ev.get("type")
    if t == "control_response" and ev.get("response", {}).get("request_id") == "init-1":
        r = ev["response"]
        init_info = {"subtype": r.get("subtype"), "error": r.get("error"),
                     "models": [m.get("value") for m in (r.get("response") or {}).get("models", [])][:6],
                     "account": (r.get("response") or {}).get("account")}
        print(f"[{time.time()-t0:6.1f}s] initialize: {json.dumps(init_info, ensure_ascii=False)[:400]}")
    elif t == "control_request":
        req = ev.get("request", {})
        if req.get("subtype") == "can_use_tool":
            name = req.get("tool_name"); tools.append(name)
            beh = "allow" if allow else "deny"
            print(f"[{time.time()-t0:6.1f}s] permission ask: {name} {json.dumps(req.get('input'), ensure_ascii=False)[:200]} -> {beh}")
            resp = {"behavior": "allow", "updatedInput": req.get("input")} if allow else {"behavior": "deny", "message": "denied by test"}
            send({"type": "control_response", "response": {"subtype": "success", "request_id": ev.get("request_id"), "response": resp}})
        else:
            send({"type": "control_response", "response": {"subtype": "success", "request_id": ev.get("request_id"), "response": {}}})
    elif t == "system" and ev.get("subtype") == "init":
        print(f"[{time.time()-t0:6.1f}s] system init: model={ev.get('model')} tools={ev.get('tools')} mcp={ev.get('mcp_servers')} perm={ev.get('permissionMode')} apiKeySource={ev.get('apiKeySource')}")
    elif t == "stream_event":
        if first_token is None and ev.get("event", {}).get("type") == "content_block_delta":
            first_token = time.time() - t0
            print(f"[{first_token:6.1f}s] first token")
    elif t == "assistant":
        for b in ev.get("message", {}).get("content", []):
            if b.get("type") == "tool_use":
                print(f"[{time.time()-t0:6.1f}s] tool_use: {b.get('name')} {json.dumps(b.get('input'), ensure_ascii=False)[:200]}")
            elif b.get("type") == "text":
                text_parts.append(b.get("text", ""))
    elif t == "result":
        u = ev.get("usage") or {}
        print(f"[{time.time()-t0:6.1f}s] turn result: in={u.get('input_tokens')} cache_read={u.get('cache_read_input_tokens')} out={u.get('output_tokens')} ms={ev.get('duration_api_ms')}")
        result = ev
        if then:
            print("--- second message ---"); t0 = time.time(); first_token = None
            send({"type": "user", "session_id": "", "parent_tool_use_id": None,
                  "message": {"role": "user", "content": [{"type": "text", "text": then}]}})
            then = None
            continue
        break
timer.cancel()
try:
    p.stdin.close()
except Exception:
    pass
try:
    p.wait(timeout=15)
except Exception:
    p.kill()
dt = time.time() - t0
if result is None:
    print(f"NO RESULT after {dt:.1f}s, rc={p.returncode}")
    print("stderr tail:\n" + "".join(err_lines[-25:]))
    sys.exit(1)
print(f"[{dt:6.1f}s] result: subtype={result.get('subtype')} is_error={result.get('is_error')} turns={result.get('num_turns')} first_token={first_token and round(first_token,1)}s")
txt = result.get("result") or "\n".join(text_parts)
print("ANSWER:\n" + (txt if len(txt) < 3000 else txt[:1500] + "\n…\n" + txt[-1200:]))
errs = [l for l in err_lines if "rror" in l and "debug" not in l.lower()][:8]
if errs:
    print("stderr errors:\n" + "".join(errs)[:2000])
sys.exit(0 if not result.get("is_error") else 2)
