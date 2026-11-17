#!/usr/bin/env python3
"""Patch a Qwen3.8 chat template for use behind Claude Code.

1. Mid-conversation system messages. Claude Code (2.1.3xx) sends a `system` turn inside `messages`
   (the "# Environment" block). Qwen's template raises "System message must be at the beginning."
   → LM Studio answers HTTP 500 and Claude Code retries until it gives up. ChatML itself handles a
   system block anywhere, so the patch renders it as `<|im_start|>system ... <|im_end|>`.
2. Default reasoning effort. The template defaults to `xhigh` ("think carefully, validate key
   assumptions, consider alternatives…") and LM Studio can only switch thinking on/off, so every
   agent step thinks for minutes. The patch sets the default to `medium` (Qwen's own level,
   no extra instruction). Override with --effort.

Usage: patch-chat-template.py IN.jinja OUT.jinja [--effort xhigh|medium|low]
Idempotent; exits non-zero if the expected constructs are not found exactly once.
"""
import re
import sys

MARKER = "{#- claude-local patch: mid-conversation system messages #}"
RAISE = "{{- raise_exception('System message must be at the beginning.') }}"
RENDER = r"{{- '<|im_start|>system\n' + content + '<|im_end|>' + '\n' }}"
EFFORT_RE = re.compile(r"reasoning_effort\|default\('(xhigh|medium|low)'\)")


def patch(text: str, effort: str = "medium") -> str:
    if MARKER not in text:
        count = text.count(RAISE)
        if count != 1:
            sys.exit(f"expected exactly 1 system-message check, found {count}")
        text = MARKER + "\n" + text.replace(RAISE, RENDER)
    found = EFFORT_RE.findall(text)
    if len(found) != 1:
        sys.exit(f"expected exactly 1 reasoning_effort default, found {len(found)}")
    return EFFORT_RE.sub(f"reasoning_effort|default('{effort}')", text)


if __name__ == "__main__":
    args = sys.argv[1:]
    effort = "medium"
    if "--effort" in args:
        i = args.index("--effort")
        effort = args[i + 1]
        del args[i:i + 2]
    if effort not in ("xhigh", "medium", "low"):
        sys.exit("effort must be xhigh, medium or low")
    src, dst = args
    with open(src, encoding="utf-8") as f:
        out = patch(f.read(), effort)
    with open(dst, "w", encoding="utf-8") as f:
        f.write(out)
    print(f"patched: {dst} (default reasoning effort: {effort})")
