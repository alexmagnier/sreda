#!/usr/bin/env python3
"""Security helpers for bin/claude-local (called with /usr/bin/python3 -I).

  guard.py clients  LIST                      → resolved client paths, one per line (warnings → stderr)
  guard.py inside   PATH ROOT...              → exit 0 if PATH is ROOT or below it (compared by inode)
  guard.py same     PATH ROOT...              → exit 0 if PATH is exactly one of ROOTs (by inode)
  guard.py policy   MODE SRC.json OUT.json LIST
  guard.py sandbox-net OUT.sb HOME WORKDIR CONF REPO BIN LIST EXTRA_ALLOW_LIST SKILLS_LIST
  guard.py sync-skills CONF SKILLS_LIST         → CONF/skills = exactly the listed skills
  guard.py trust CONF WORKDIR                   → mark WORKDIR trusted in CONF/.claude.json
  guard.py import-session SID CLOUD_PROJECTS OFFLINE_PROJECTS
                                                → continue a regular (cloud) session in the offline mode:
                                                  copy CLOUD/<project>/<SID>.jsonl → OFFLINE/<project>/ (one way)

Paths are matched against what is actually on disk: APFS is case- and normalization-insensitive,
so list entries are resolved component by component with NFC + casefold comparison (an entry typed
in NFC still finds a folder stored in NFD, "лиды" finds "Лиды"). Globs only when the entry has * or ?.
"""
import fnmatch
import json
import os
import re
import stat
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


SESSION_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
IMPORT_MAX_BYTES = 512 * 1024 * 1024
_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def _open_dir(path):
    """Open PATH as a directory with NO symlink in any component (walks from /): a session that replaced a
    folder with a link (adversarial review 20.11: ~/.claude-local/projects → Lab history or ~/.claude) is
    refused instead of followed. Returns an fd; raises OSError."""
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in [x for x in os.path.abspath(path).split(os.sep) if x]:
            nfd = os.open(part, _DIR, dir_fd=fd)
            os.close(fd)
            fd = nfd
        return fd
    except BaseException:
        os.close(fd)
        raise


def _sub_dir(parent_fd, name, create):
    """Child directory of an open directory, never through a link; created 0700 if asked."""
    try:
        return os.open(name, _DIR, dir_fd=parent_fd)
    except FileNotFoundError:
        if not create:
            raise
        try:
            os.mkdir(name, 0o700, dir_fd=parent_fd)
        except FileExistsError:
            pass
        return os.open(name, _DIR, dir_fd=parent_fd)


def import_session(sid, cloud_root, offline_projects):
    """20.11.2026: «начал в облаке — продолжил локально». VS Code shows the folder's regular (cloud)
    sessions in the history list of «Локальный Claude»; --resume <id> of one of them found nothing in the
    offline history. Copy that transcript ONE WAY: CLOUD/<project>/<id>.jsonl → OFFLINE/<project>/.
    Every path is opened component by component without following links, and every write goes relative to
    an already open directory (no check-then-use race). Never writes under CLOUD; the launcher never calls
    this for the Lab. Silent no-op when there is nothing to do. Returns 0, or 1 on refusal."""
    if not isinstance(sid, str) or not SESSION_ID.fullmatch(sid):
        return 0                                      # titles, paths, garbage: not ours to handle
    name = sid + ".jsonl"
    try:
        cfd = _open_dir(cloud_root)
    except OSError:
        return 0                                      # no cloud history (or it is behind a link): nothing to do
    fds = [cfd]
    try:
        try:
            conf_fd = _open_dir(os.path.dirname(os.path.abspath(offline_projects)))
        except OSError:
            print("import-session: папка локальной истории недоступна или подменена ссылкой — отказ", file=sys.stderr)
            return 1
        fds.append(conf_fd)
        # before creating anything: the destination must not lie inside the cloud history (APFS ignores case,
        # so compare by inode via inside(), not by string — review 20.11)
        if inside(os.path.dirname(os.path.abspath(offline_projects)), [cloud_root]):
            print("import-session: назначение внутри облачной истории — отказ", file=sys.stderr)
            return 1
        try:
            ofd = _sub_dir(conf_fd, os.path.basename(os.path.abspath(offline_projects)), create=True)
        except OSError:
            print("import-session: projects локальной истории подменена ссылкой — отказ", file=sys.stderr)
            return 1
        fds.append(ofd)
        o, c = os.fstat(ofd), os.fstat(cfd)
        if (o.st_dev, o.st_ino) == (c.st_dev, c.st_ino) or inside(offline_projects, [cloud_root]) \
                or inside(cloud_root, [offline_projects]):
            print("import-session: источник и назначение пересекаются — отказ", file=sys.stderr)
            return 1
        for proj in os.listdir(ofd):                  # already in the offline history: continue that copy
            try:
                pfd = os.open(proj, _DIR, dir_fd=ofd)
            except OSError:
                continue
            try:
                os.stat(name, dir_fd=pfd, follow_symlinks=False)
                return 0
            except OSError:
                pass
            finally:
                os.close(pfd)
        found = []
        for proj in os.listdir(cfd):
            if proj.startswith("."):
                continue
            try:
                pfd = os.open(proj, _DIR, dir_fd=cfd)  # a linked project folder is skipped
            except OSError:
                continue
            try:
                st = os.stat(name, dir_fd=pfd, follow_symlinks=False)
            except OSError:
                os.close(pfd)
                continue
            if stat.S_ISREG(st.st_mode):
                found.append((proj, pfd))
            else:
                os.close(pfd)
        fds += [f for _, f in found]
        if len(found) != 1:
            return 0                                  # none (normal «not found») or ambiguous
        proj, pfd = found[0]
        try:
            sfd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=pfd)
        except OSError:
            return 0
        with os.fdopen(sfd, "rb") as f:
            st = os.fstat(f.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_uid != os.getuid():
                return 0                              # FIFO swapped in, hard link to elsewhere, foreign file
            if st.st_size > IMPORT_MAX_BYTES:
                print(f"import-session: облачная сессия больше {IMPORT_MAX_BYTES >> 20} МБ — не переношу", file=sys.stderr)
                return 0
            data = f.read(IMPORT_MAX_BYTES + 1)
        cut = data.rfind(b"\n")                       # a live session may be mid-write: drop a partial line
        data = data[:cut + 1] if cut >= 0 else b""
        if not data:
            return 0
        try:
            dfd = _sub_dir(ofd, proj, create=True)
        except OSError:
            print("import-session: папка проекта в локальной истории подменена ссылкой — отказ", file=sys.stderr)
            return 1
        fds.append(dfd)
        tmp = ".import-%d-%s" % (os.getpid(), os.urandom(6).hex())
        tfd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
        try:
            with os.fdopen(tfd, "wb") as t:
                t.write(data)
                t.flush()
                os.fsync(t.fileno())
            try:                                      # no-clobber: a concurrent launch may have won
                os.link(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd, follow_symlinks=False)
            except FileExistsError:
                return 0
        finally:
            try:
                os.unlink(tmp, dir_fd=dfd)
            except OSError:
                pass
        print(f"↪ облачная сессия {sid[:8]} перенесена в локальную историю: продолжаешь на локальной модели без "
              "интернета. Облачная копия не меняется, локальное продолжение в облако не попадёт.", file=sys.stderr)
        return 0
    finally:
        for f in fds:
            try:
                os.close(f)
            except OSError:
                pass

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
    elif cmd == "import-session":
        sys.exit(import_session(*a))
    else:
        sys.exit(f"unknown command {cmd}")
