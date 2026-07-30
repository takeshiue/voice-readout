# Portable JSON field reader, shared by every hook that parses its stdin JSON.
# Sourced, not executed.
#
# Every hook (notify-speak.sh, summarize-and-speak.sh, session-greet.sh,
# session-farewell.sh, the codex-*.sh equivalents) reads a field out of the
# JSON Claude Code hands it on stdin, and that used to go straight through
# `jq`. Fine on the Termux/proot side (README already asks for
# `apt install jq`), but `jq` is not part of a bare Windows + Git for Windows
# install — Git Bash ships no jq, and nothing here may assume the user has
# chocolatey/scoop/winget set up to fetch one. What Windows DOES always have is
# PowerShell (bundled with the OS since Vista), so json_get_field tries jq
# first and, only when jq is missing, shells out to PowerShell's
# ConvertFrom-Json instead. Neither path requires installing anything beyond
# what already has to be there for Claude Code's own hooks to run.
#
# Deliberately scoped to reading a single top-level field out of hook input —
# the one thing every affected call site needed. settings.json (statusLine
# registration) is a separate, riskier read-modify-write and is left to the
# existing manual-edit fallback (see statusline.sh/doctor.sh) rather than
# grown a parallel PowerShell JSON-editing path here.

have_jq() { command -v jq >/dev/null 2>&1; }

# Resolves to whichever PowerShell binary Git Bash can see, preferring
# powershell.exe (the real Windows shell, as seen from Git Bash) over the bare
# "powershell" alias some setups define. Empty/failure means neither exists,
# which is only expected off Windows.
_ps_bin() {
  if command -v powershell.exe >/dev/null 2>&1; then
    printf 'powershell.exe'
  elif command -v powershell >/dev/null 2>&1; then
    printf 'powershell'
  else
    return 1
  fi
}

# A native Windows process (PowerShell) cannot open a Git Bash /tmp path
# directly; cygpath -w turns it into the C:\... form Windows understands. Falls
# back to the path as-is where cygpath is unavailable (should not happen
# alongside a real PowerShell, but cheap to guard).
_win_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

# json_get_field JSON FIELD — the value of a top-level string field, or empty
# if absent/not a string/JSON is invalid. FIELD is always a fixed literal
# supplied by this plugin's own call sites, never attacker-controlled, so
# splicing it into the PowerShell script text below is safe.
json_get_field() {
  local json="$1" field="$2"
  if have_jq; then
    printf '%s' "$json" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null
    return
  fi
  local ps; ps="$(_ps_bin)" || return 1
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/voice-readout-json.XXXXXX")" || return 1
  local out; out="$(mktemp "${TMPDIR:-/tmp}/voice-readout-json-out.XXXXXX")" || { rm -f "$tmp"; return 1; }
  printf '%s' "$json" > "$tmp"
  # Written to a file rather than printed to stdout: PowerShell writes its
  # console stream in the system codepage (cp932 on a Japanese Windows), not
  # UTF-8, and a message field this plugin actually speaks is Japanese —
  # [Console]::Out.Write of it came back as mojibake (verified 2026-07-31).
  # [System.IO.File]::WriteAllText with an explicit BOM-less UTF8Encoding
  # writes bytes bash can just cat back correctly with no leading BOM —
  # Set-Content -Encoding UTF8 was tried first and prepends one, which then
  # became part of every value read back (also verified 2026-07-31). Same file
  # round-trip speak_windows_sapi already uses for the reverse direction.
  "$ps" -NoProfile -NonInteractive -Command "
    \$ErrorActionPreference = 'SilentlyContinue'
    try {
      \$j = Get-Content -Raw -LiteralPath '$(_win_path "$tmp")' -Encoding UTF8 | ConvertFrom-Json
      \$v = \$j.'$field'
      if (\$null -ne \$v) {
        \$utf8NoBom = New-Object System.Text.UTF8Encoding \$false
        [System.IO.File]::WriteAllText('$(_win_path "$out")', [string]\$v, \$utf8NoBom)
      }
    } catch {}
  " 2>/dev/null
  cat "$out" 2>/dev/null
  rm -f "$tmp" "$out" 2>/dev/null
}

# _json_escape TEXT — minimal JSON string escaping (backslash, double quote,
# newline/CR/tab) for the one place this plugin builds JSON by hand
# (announce_user's {systemMessage: ...} in tts-lib.sh) when jq is unavailable.
# Not a general-purpose escaper — the text here is always this plugin's own
# Japanese notice strings, never third-party input, so control characters
# outside these four are not a case worth handling.
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}
