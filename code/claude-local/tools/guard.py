#!/usr/bin/env python3
"""Security helpers for bin/claude-local (called with /usr/bin/python3 -I).

  guard.py clients  LIST                      → resolved client paths, one per line (warnings → stderr)
  guard.py inside   PATH ROOT...              → exit 0 if PATH is ROOT or below it (compared by inode)
  guard.py same     PATH ROOT...              → exit 0 if PATH is exactly one of ROOTs (by inode)
  guard.py policy   MODE SRC.json OUT.json LIST
  guard.py sandbox-net OUT.sb HOME WORKDIR CONF REPO BIN LIST EXTRA_ALLOW_LIST SKILLS_LIST
  guard.py sync-skills CONF SKILLS_LIST         → CONF/skills = exactly the listed skills
  guard.py trust CONF WORKDIR                   → mark WORKDIR trusted in CONF/.claude.json

Paths are matched against what is actually on disk: APFS is case- and normalization-insensitive,
so list entries are resolved component by component with NFC + casefold comparison (an entry typed
in NFC still finds a folder stored in NFD, "лиды" finds "Лиды"). Globs only when the entry has * or ?.
"""
import fnmatch
import json
import os
import sys
import unicodedata

NFC = lambda s: unicodedata.normalize("NFC", s)
NFD = lambda s: unicodedata.normalize("NFD", s)


def key(s):
    return NFC(s).casefold()


def match_path(pattern):
    parts = [p for p in pattern.split("/") if p]
    current = ["/"]
    for part in parts:
        is_glob = any(c in part for c in "*?")
        pk = key(part).replace("[", "[[]") if is_glob else key(part)
        nxt = []
        for base in current:
            try:
                names = os.listdir(base)
            except OSError:
                continue
            for n in names:
                nk = key(n)
                if (fnmatch.fnmatchcase(nk, pk) if is_glob else nk == pk):
                    nxt.append(os.path.join(base, n))
        current = nxt
        if not current:
            break
    return current


def read_list(path):
    home = os.path.expanduser("~")
    out = []
    for raw in open(path, encoding="utf-8"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("~"):
            line = home + line[1:]
        out.append(line)
    return out


def clients(list_path, warn=True):
    res = []
    for entry in read_list(list_path):
        hits = match_path(entry)
        if not hits and warn:
            print(f"⚠ client-folders.list: «{entry}» не найдено на диске — правило не действует", file=sys.stderr)
        res.extend(os.path.realpath(h) for h in hits)
    return sorted(set(res))


def ids(paths):
    out = set()
    for p in paths:
        try:
            st = os.stat(p)
            out.add((st.st_dev, st.st_ino))
        except OSError:
            pass
    return out


def inside(path, roots):
    targets = ids(roots)
    p = os.path.realpath(path)
    while True:
        try:
            st = os.stat(p)
            if (st.st_dev, st.st_ino) in targets:
                return True
        except OSError:
            pass
        if p == "/":
            return False
        p = os.path.dirname(p)


def atomic_write(path, text):
    """Write via a unique temp file + rename: concurrent launches never see a half-written file."""
    import tempfile
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".tmp-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def build_policy(mode, src, out, list_path):
    policy = json.load(open(src, encoding="utf-8"))
    if mode == "net":
        deny = policy.setdefault("permissions", {}).setdefault("deny", [])
        for c in clients(list_path):
            suffix = "/**" if os.path.isdir(c) else ""
            for form in {c, NFC(c), NFD(c)}:
                for tool in ("Read", "Edit", "Write"):
                    deny.append(f"{tool}(/{form}{suffix})")  # "//abs" = absolute path
    policy["_generated"] = f"built by claude-local from config/policy-{mode}.json — do not edit"
    atomic_write(out, json.dumps(policy, ensure_ascii=False, indent=2))


def sbq(p):
    return '"' + p.replace("\\", "\\\\").replace('"', '\\"') + '"'


def forms(p):
    out = {p, NFC(p), NFD(p)}
    for x in list(out):
        if x.startswith("/Users/"):
            out.add("/System/Volumes/Data" + x)
        if x.startswith("/private/"):
            out.add(x[len("/private"):])
    return sorted(out)


def sub(paths):
    return "\n  ".join(f"(subpath {sbq(f)})" for p in paths for f in forms(p))


def lit(paths):
    return "\n  ".join(f"(literal {sbq(f)})" for p in paths for f in forms(p))


def skill_sources(skills_list):
    """name → source dir from a skills list (default ~/.claude/skills/<name>). Repo file = source of truth."""
    home = os.path.expanduser("~")
    out = {}
    for raw in open(skills_list, encoding="utf-8"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        name, _, src = line.partition(" ")
        src = src.strip() or os.path.join(home, ".claude", "skills", name)
        if os.path.isfile(os.path.join(src, "SKILL.md")):
            out[name] = os.path.realpath(src)
    return out


def sync_skills(conf, skills_list):
    """Make CONF/skills contain exactly the listed skills (planted links/files are removed)."""
    d = os.path.join(conf, "skills")
    os.makedirs(d, exist_ok=True)
    want = skill_sources(skills_list)
    for n in os.listdir(d):
        p = os.path.join(d, n)
        if n not in want or not os.path.islink(p) or os.path.realpath(p) != want[n]:
            if os.path.islink(p) or os.path.isfile(p):
                os.unlink(p)
            else:
                sys.exit(f"unexpected directory in {d}: {n} — remove it manually")
    for n, src in want.items():
        p = os.path.join(d, n)
        if not os.path.lexists(p):
            os.symlink(src, p)


def trust_folder(conf, workdir):
    """Mark WORKDIR as trusted in CONF/.claude.json (the dialog defaults to "No, exit").
    Safe here: project settings, hooks and .mcp.json are ignored by the launcher
    (--setting-sources user, --strict-mcp-config) and the kernel sandbox applies anyway."""
    p = os.path.join(conf, ".claude.json")
    try:
        state = json.load(open(p, encoding="utf-8"))
    except FileNotFoundError:
        state = {}
    except (OSError, ValueError):
        return          # half-written by Claude Code right now — never overwrite it with a stub
    # Claude Code keys trust by the git root when the folder is inside a repo (review 2026-11-16 night)
    targets = [os.path.realpath(workdir)]
    d = targets[0]
    while d != "/":
        if os.path.exists(os.path.join(d, ".git")):
            if d not in targets:
                targets.append(d)
            break
        d = os.path.dirname(d)
    projects = state.setdefault("projects", {})
    todo = [t for t in targets if projects.get(t, {}).get("hasTrustDialogAccepted") is not True]
    if not todo:
        return
    for t in todo:
        projects.setdefault(t, {})["hasTrustDialogAccepted"] = True
    atomic_write(p, json.dumps(state, ensure_ascii=False, indent=2))


def user_dirs():
    import subprocess
    res = []
    for name in ("DARWIN_USER_TEMP_DIR", "DARWIN_USER_CACHE_DIR"):
        try:
            res.append(os.path.realpath(subprocess.check_output(["/usr/bin/getconf", name], text=True).strip()))
        except Exception:
            pass
    return res


def under(path, roots):
    return any(path == r or path.startswith(r.rstrip("/") + "/") for r in roots)


# Claude Code's runtime state inside a config dir — the ONLY things a session may write there.
# Everything else in CONF (CLAUDE.md, rules/, output-styles/, settings*.json, skills/, agents/, commands/,
# hooks, plugins/, keybindings.json, bin/, .policy.json, sandbox profiles…) shapes a later session.
CONF_WRITABLE_DIRS = ("projects", "sessions", "session-env", "shell-snapshots", "todos", "file-history", "tmp",
                      "backups", "logs", "debug", "plans", "statsig", "cache", "paste-cache", "image-cache",
                      "state", "ide", "telemetry", "usage-data")
CONF_WRITABLE_PREFIXES = (".claude.json", "history.jsonl", ".last-cleanup", "mcp-needs-auth-cache.json")

# Paths that a LATER process outside the sandbox executes or obeys — never writable from a session,
# wherever they are (adversarial review 2026-11-16 night: git core.fsmonitor in the work folder ran on the
# next unsandboxed `git status` and carried a canary out; .vscode/ settings/tasks are read by VS Code).
LATER_EXEC_REGEXES = (
    r'#"/\.git/(config|hooks|info|modules)(/|$)"', r'#"/\.git/config\.lock$"', r'#"/\.gitmodules$"',
    r'#"/\.(vscode|idea|devcontainer)(/|$)"', r'#"/\.envrc$"', r'#"/\.claude/(settings[^/]*\.json|hooks|agents|commands|skills|rules)"',
    r'#"/\.mcp\.json$"', r'#"/projects/[^/]+/memory(/|$)"')


def conf_write_rules(conf):
    """SBPL: CONF closed for writing except Claude Code's runtime state."""
    allow = " ".join(f"(subpath {sbq(os.path.join(conf, d))})" for d in CONF_WRITABLE_DIRS)
    pre = " ".join(f"(prefix {sbq(os.path.join(conf, f))})" for f in CONF_WRITABLE_PREFIXES)
    return f"(deny file-write* (subpath {sbq(conf)}))\n(allow file-write* {allow}\n  {pre})"


def lock_dir(home):
    return os.path.join(home, "Library", "Caches", "claude-local-locks")


def build_net_sandbox(out, home, workdir, conf, repo, binfile, list_path, extra_list, skills_list):
    real = os.path.realpath
    home, workdir, conf, repo = real(home), real(workdir), real(conf), real(repo)
    extra = [real(p) for p in read_list(extra_list)] if os.path.exists(extra_list) else []
    dotfiles = [os.path.join(home, f) for f in (".zshrc", ".zprofile", ".zshenv", ".zlogin", ".gitconfig", ".npmrc")]
    sensitive = [os.path.join(home, p) for p in (
        ".claude", ".claude-local", ".ssh", ".gnupg", ".lmstudio", ".aws", ".config/gh",
        "Library/Keychains", "Library/Application Support/Syncthing", "Library/Mobile Documents",
        "Library/Messages", "Library/Mail")] + [f"/private/tmp/claude-{os.getuid()}", "/private/tmp/claude"]
    sensitive.append(lock_dir(home))
    clientp = clients(list_path)
    sensitive += user_dirs()   # macOS per-user temp/cache: other apps' temp copies, QuickLook thumbnails
    # skills to re-allow come from the REPO list, never from the (writable) config dir; a skill that
    # would point into a client or sensitive place is dropped
    # (~/.claude itself is closed — history, credentials — but ~/.claude/skills is exactly where skills live)
    skills_home = os.path.join(home, ".claude", "skills")
    skills = [s for s in skill_sources(skills_list).values()
              if not under(s, clientp) and (under(s, [skills_home]) or not under(s, sensitive))]
    # outside the home folder: external drives, shared folders, other processes' temp files
    outside = ["/Volumes", "/Users/Shared", "/private/tmp", "/private/var/tmp"]
    later = "\n  ".join(f"(regex {r})" for r in LATER_EXEC_REGEXES)
    profile = f""";; GENERATED by claude-local at launch (tools/guard.py) — do not edit.
;; Online mode: internet is allowed, but the home folder is closed except what the session needs,
;; client folders and secrets are closed even inside allowed folders. WRITES are closed everywhere
;; (also outside the home folder: /Applications, /opt/homebrew…) except the work folder and Claude
;; Code's runtime state. Covers Bash, MCP servers and every child process.
(version 1)
(allow default)

;; READ: home and shared places are closed by default
(deny file-read-data (subpath {sbq(home)}) (subpath {sbq("/System/Volumes/Data" + home)})
  {sub(outside)})
(allow file-read-data
  {sub([workdir, conf, repo, os.path.join(home, ".cache"), os.path.join(home, ".local/bin"),
        os.path.join(home, ".config/git")] + extra)}
  {lit(dotfiles)})
;; client data and secrets stay closed even when the work folder is a parent of them
(deny file-read-data
  {sub(sensitive + clientp)})
;; what the session itself needs from inside the closed places
(allow file-read-data
  {lit([binfile])}
  {sub(skills) if skills else ''})

;; WRITE: default-deny (review 2026-11-16 night: with only $HOME closed the lab could rewrite
;; /Applications/«Локальный Claude».app, /opt/homebrew/bin and cached browsers = escape on next use)
(deny file-write*)
(allow file-write*
  {sub([workdir] + extra)}
  (literal "/dev/null") (literal "/dev/zero") (literal "/dev/tty") (literal "/dev/dtracehelper")
  (regex #"^/dev/ttys[0-9]+$") (regex #"^/dev/fd/"))
{conf_write_rules(conf)}
(deny file-write*
  {sub(sensitive + clientp + [repo])}
  {later})

;; LOCAL SERVICES: only the LM Studio API. Closes e.g. the Syncthing REST API on 127.0.0.1:8384,
;; which could be told to share client folders with a new device (adversarial review N2).
;; IPv6 is closed entirely: "localhost" does not match IPv4-mapped forms like [::ffff:127.0.0.1]
;; (retest round 2). Internet still works over IPv4.
;; NB: explicit ip4/ip6 — mixing `ip "localhost:*"` with an ip6 rule silently stops matching IPv4
;; (measured 2026-11-16), so every rule names its family.
(deny network-outbound (remote ip4 "localhost:*"))
(deny network-outbound (remote ip6 "*:*"))
(allow network-outbound (remote ip4 "localhost:1234"))
;; unix sockets: only the DNS resolver and syslog (no ssh-agent, docker, Chrome bridge, other apps)
(deny network-outbound (remote unix-socket))
(allow network-outbound
  (remote unix-socket (path-literal "/private/var/run/mDNSResponder"))
  (remote unix-socket (path-literal "/private/var/run/syslog")))

;; Unsandboxed helpers: AppleEvents (Finder could copy a client file into the work folder),
;; LaunchServices, the pasteboard (may hold client text the user copied).
(deny appleevent-send)
(deny mach-lookup
  (global-name "com.apple.coreservices.launchservicesd")
  (global-name "com.apple.coreservices.quarantine-resolver")
  (global-name "com.apple.lsd.mapdb")
  (global-name "com.apple.lsd.modifydb")
  (global-name "com.apple.lsd.openwith")
  (global-name "com.apple.lsd.icons")
  (global-name "com.apple.pasteboard.1"))
"""
    atomic_write(out, profile)


if __name__ == "__main__":
    cmd, *a = sys.argv[1:]
    if cmd == "clients":
        print("\n".join(clients(a[0])))
    elif cmd == "inside":
        sys.exit(0 if inside(a[0], a[1:]) else 1)
    elif cmd == "same":
        sys.exit(0 if ids([a[0]]) & ids(a[1:]) else 1)
    elif cmd == "policy":
        build_policy(*a)
    elif cmd == "sandbox-net":
        build_net_sandbox(*a)
    elif cmd == "sync-skills":
        sync_skills(*a)
    elif cmd == "trust":
        trust_folder(*a)
    else:
        sys.exit(f"unknown command {cmd}")
