#!/bin/bash
# Offline regression checks for the Codex integration.  No Termux command or
# cloud TTS request is made: only hook contracts and pure text processing run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

for file in \
  bin/response-text.sh \
  bin/session-start.sh \
  bin/codex-session-start.sh \
  bin/codex-session-end.sh \
  bin/codex-permission-speak.sh \
  bin/codex-summarize-and-speak.sh; do
  bash -n "$file"
done

jq -e '
  .name == "voice-readout"
  and .hooks == "./hooks/codex-hooks.json"
' .codex-plugin/plugin.json >/dev/null

jq -e '
  .hooks.SessionStart[0].matcher == "startup|resume"
  and .hooks.SessionStart[0].hooks[0].command == "${PLUGIN_ROOT}/bin/codex-session-start.sh"
  and .hooks.Stop[0].hooks[0].command == "${PLUGIN_ROOT}/bin/codex-summarize-and-speak.sh"
  and (.hooks | has("PermissionRequest") | not)
' hooks/codex-hooks.json >/dev/null

jq -e '
  .hooks.SessionStart[0].hooks[0].command == "${CLAUDE_PLUGIN_ROOT}/bin/session-start.sh"
  and ([.hooks.SessionStart[0].hooks[].command] | index("${CLAUDE_PLUGIN_ROOT}/bin/readout-switch.sh notify") | not)
' hooks/hooks.json >/dev/null

actual="$(bash -c '
  source bin/response-text.sh
  sample=$'"'"'# 見出し\n本文の **強調** と `code`、https://example.test を含みます。'"'"'
  clean_response_for_speech "$sample"
')"
[ "$actual" = '見出し 本文の 強調 と code、 を含みます。' ]

# Codex requires JSON output from a successful Stop hook. This input exercises
# the no-message path, which is deliberately side-effect-free.
actual="$(printf '%s' '{"last_assistant_message":null}' | bash bin/codex-summarize-and-speak.sh)"
[ "$actual" = '{}' ]

printf '%s\n' 'Codex hook tests passed.'
