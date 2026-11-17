#!/bin/zsh
# Status line for claude-local sessions: always shows which mode is active.
cat >/dev/null   # Claude Code sends session JSON on stdin; not needed here
case "${CLAUDE_LOCAL_MODE:-}" in
  offline) print -n -- $'\e[32m🔒 ЛОКАЛЬНО · БЕЗ ИНТЕРНЕТА\e[0m · '"${CLAUDE_LOCAL_LABEL:-}" ;;
  net)     print -n -- $'\e[33m🌐 ЛОКАЛЬНО · С ИНТЕРНЕТОМ\e[0m · '"${CLAUDE_LOCAL_LABEL:-}" ;;
  *)       print -n -- $'\e[31m⚠ режим не определён — перезапусти через claude-local\e[0m' ;;
esac
