import json, os, subprocess, sys, tempfile, time, unittest

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "island-hook.py")


class HookTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = os.path.join(self.tmp.name, "island", "waiting")

    def tearDown(self):
        self.tmp.cleanup()

    def run_hook(self, payload, raw=None):
        env = dict(os.environ, CLAUDE_CONFIG_DIR=self.tmp.name)
        data = raw if raw is not None else json.dumps(payload).encode()
        t = time.time()
        p = subprocess.run([sys.executable, "-I", "-S", HOOK], input=data, env=env, capture_output=True)
        dt = time.time() - t
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout, b"")
        self.assertEqual(p.stderr, b"")
        self.assertLess(dt, 0.5)   # hook latency guard; generous so a busy Mac does not fail the install

    def read(self, sid="abc"):
        with open(os.path.join(self.dir, sid + ".json")) as f:
            return json.load(f)

    def files(self):
        return os.listdir(self.dir) if os.path.isdir(self.dir) else []

    def ev(self, name, **kw):
        d = {"session_id": "abc", "cwd": "/x/proj", "hook_event_name": name}
        d.update(kw)
        return d

    def step(self, payload):
        time.sleep(0.003)  # ensure a later ms timestamp
        self.run_hook(payload)

    def test_waiting_events(self):
        cases = [
            (self.ev("PermissionRequest", tool_name="Bash"), "нужно разрешение: Bash"),
            (self.ev("Notification", notification_type="permission_prompt", message="m1"), "m1"),
            (self.ev("Notification", notification_type="elicitation_dialog", message="m2"), "m2"),
            (self.ev("Notification", notification_type="elicitation_url_dialog", message="m3"), "m3"),
            (self.ev("Notification", notification_type="agent_needs_input", message="m4"), "m4"),
            (self.ev("Elicitation", message="q"), "q"),
        ]
        for p, msg in cases:
            self.step(p)
            d = self.read()
            self.assertTrue(d["waiting"], p)
            self.assertFalse(d["error"])
            self.assertEqual(d["message"], msg)
        self.assertEqual(oct(os.stat(os.path.join(self.dir, "abc.json")).st_mode & 0o777), "0o600")
        self.assertEqual(oct(os.stat(self.dir).st_mode & 0o777), "0o700")

    def test_subagent_permission_request_is_waiting(self):
        self.step(self.ev("PermissionRequest", tool_name="Edit", agent_id="sub1"))
        self.assertTrue(self.read()["waiting"])

    def test_stop_failure_is_error(self):
        self.step(self.ev("StopFailure"))
        d = self.read()
        self.assertTrue(d["error"])
        self.assertFalse(d["waiting"])
        self.assertEqual(d["message"], "ошибка API")

    def test_resolve_events(self):
        for name, extra in [("PostToolUse", {}), ("PostToolUseFailure", {}), ("UserPromptSubmit", {}),
                            ("Stop", {}), ("Notification", {"notification_type": "idle_prompt"})]:
            self.step(self.ev("PermissionRequest", tool_name="Bash"))
            self.assertTrue(self.read()["waiting"])
            self.step(self.ev(name, **extra))
            d = self.read()
            self.assertFalse(d["waiting"], name)
            self.assertFalse(d["error"], name)
        self.step(self.ev("StopFailure"))
        self.step(self.ev("UserPromptSubmit"))
        self.assertFalse(self.read()["error"])

    def test_ordering_older_does_not_overwrite_newer(self):
        self.step(self.ev("PermissionRequest", tool_name="Bash"))
        d = self.read()
        d["ts_ms"] = int(time.time() * 1000) + 60_000   # a "newer" stored event
        with open(os.path.join(self.dir, "abc.json"), "w") as f:
            json.dump(d, f)
        self.step(self.ev("Stop"))
        self.assertTrue(self.read()["waiting"])         # older Stop ignored

    def test_ts_captured(self):
        before = int(time.time() * 1000)
        self.run_hook(self.ev("StopFailure"))
        self.assertGreaterEqual(self.read()["ts_ms"], before)

    def test_session_end_deletes(self):
        self.step(self.ev("PermissionRequest", tool_name="Bash"))
        self.assertEqual(self.files(), ["abc.json"])
        self.step(self.ev("SessionEnd"))
        self.assertEqual(self.files(), [])

    def test_ignored_events(self):
        for n in ["SessionStart", "PreToolUse", "SubagentStop"]:
            self.run_hook(self.ev(n))
        self.run_hook(self.ev("Notification", notification_type="auth_success"))
        self.assertEqual(self.files(), [])

    def test_garbage_inputs(self):
        for raw in [b"", b"not json {{{", b"[1,2,3]", b"\xff\xfe\x00", b"x" * (3 * 1024 * 1024)]:
            self.run_hook(None, raw=raw)
        self.run_hook({"hook_event_name": "Stop"})
        self.run_hook({"session_id": "../../etc", "hook_event_name": "Stop"})
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "etc.json")))
        for f in self.files():
            self.assertTrue(f.endswith(".json") and "/" not in f)

    def test_no_prompt_or_tool_data_persisted(self):
        self.step(self.ev("PermissionRequest", tool_name="Bash", prompt="TOPSECRET",
                          tool_input={"cmd": "TOPSECRET"}, tool_response="TOPSECRET"))
        self.step(self.ev("PostToolUse", prompt="TOPSECRET", tool_input={"c": "TOPSECRET"}))
        for f in self.files():
            with open(os.path.join(self.dir, f)) as fh:
                self.assertNotIn("TOPSECRET", fh.read())


if __name__ == "__main__":
    unittest.main()
