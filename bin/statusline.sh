#!/bin/bash
# statusLine command: show the current readout state at the bottom of the
# Claude Code console, so "will the next response be spoken or not" is visible
# at a glance. Reads the exact same config file and stop-switch path the hooks
# use, so it can never disagree with what actually gets spoken. Looks like:
#   voice readout | greet 🔊🔇 | notif 🔊 gemini | resp 🔊 sum inworld | ×1.2
#   voice readout | greet 🔊🔊 | notif 🔊 local | resp 🔊 full gemini | ×1.3 | 🔔
# (×N = reading pace, 🔔 = chunk marker on)
#
# On a terminal too narrow for all of it, the segments wrap onto further rows
# rather than being cut off:
#   voice readout | greet 🔊🔊 | notif 🔊 inworld
#   resp 🔊 full inworld | ×1.3 | 🔔
#
# Wiring it up is this script's own job:
#
#   statusline.sh --install     register in settings.json
#   statusline.sh --uninstall   remove that registration
#
# statusLine is not a plugin component — Claude Code has no such slot, only
# Skills / Agents / Hooks / MCP / LSP — so unlike the hooks it cannot register
# itself through the manifest. The README used to ask the user to hand-write an
# absolute path into settings.json instead, which is the one part of installing
# this plugin that was manual, error-prone, and (for a marketplace install)
# version-dependent. Doing it here removes the hand-written path entirely: the
# script that knows where it lives is this one.
#
# Claude Code pipes session JSON on stdin; we don't need it, so we ignore it.
# The command runs on every render, so keep it to cheap file reads only — hence
# the --install branch returning long before any of the rendering work below.

set -u

# --- Registration (--install / --uninstall). --------------------------------
# Placed first so the render path — which is called with no arguments on every
# single frame — pays one string comparison and nothing else.
case "${1:-}" in
  --install|--uninstall|--repair)
    ACTION="$1"; shift
    # Which settings file. Written to the USER's settings, never a project's:
    # the plugin is enabled globally, so its status line belongs to every
    # session, and a project's .claude/settings.json is usually committed —
    # putting a machine-specific absolute path in there would break it for
    # everyone else who checks out that repo. --file names another one
    # explicitly, for anyone who wants a different scope; there is deliberately
    # no attempt to GUESS a project directory (a script run by hand gets no
    # CLAUDE_PROJECT_DIR, so any guess would just be $PWD, which is not the
    # same thing).
    # CLAUDE_CONFIG_DIR relocates the whole config directory (it is a real
    # Claude Code variable, not a guess — verified in the binary), so honour it
    # or we would write to a file nothing reads.
    SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
    FORCE=0
    FILE_GIVEN=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --file) SETTINGS="${2:-}"; FILE_GIVEN=1; shift 2 ;;
        --force) FORCE=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
      esac
    done

    SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    # Does an existing registration belong to this plugin? Both commands ask,
    # and getting it wrong in either direction is bad: claim someone else's
    # statusLine and they lose it, disown one of ours and neither --install nor
    # --uninstall can touch the entry again.
    #
    # A path carrying the plugin name is the ordinary case. The second form is
    # "${CLAUDE_PLUGIN_ROOT}/bin/statusline.sh", written by hand: it is the
    # natural guess, since every hook in this plugin is registered exactly that
    # way — and it is broken by construction. statusLine is not a plugin
    # component, so nothing expands the variable and Claude Code runs
    # "/bin/statusline.sh", which fails with no status line, no error and no
    # clue. Left unrecognised it was also the one registration neither command
    # could repair, having no "voice-readout" in it to match on. Seen live on
    # 2026-07-25.
    #
    # The variable has to appear literally in the value to qualify. An expanded
    # absolute path that merely ends in statusline.sh is NOT claimed: the name
    # is a generic one that plenty of other status lines use, and a working
    # registration pointing somewhere else is exactly what must be left alone.
    is_ours() {
      case "$1" in
        *voice-readout*)                        return 0 ;;
        *'${CLAUDE_PLUGIN_ROOT}'*statusline.sh) return 0 ;;
        *'$CLAUDE_PLUGIN_ROOT'*statusline.sh)   return 0 ;;
      esac
      return 1
    }

    # --repair: run from the SessionStart hook, not by hand.
    #
    # A marketplace install unpacks this script under
    # .../cache/<plugin>/<version>/, so upgrading the plugin MOVES it and the
    # absolute path sitting in settings.json goes stale. The status line then
    # simply stops appearing — no error, no clue, same silent failure as the
    # unexpanded ${CLAUDE_PLUGIN_ROOT} form. Hooks, unlike statusLine, ARE
    # plugin components and do get ${CLAUDE_PLUGIN_ROOT} expanded, so the hook
    # always reaches the current copy; the current copy knows where it lives and
    # can put the path back.
    #
    # Checked every session because nothing announces "you were just upgraded",
    # and a check is two file reads. WRITING happens only when the stored value
    # actually differs, so the ordinary session touches nothing and leaves no
    # backup churn.
    #
    # It repairs, it never installs: an absent registration stays absent.
    # Enabling a plugin is not consent to have a status line appear, and the
    # user may have removed it on purpose — re-adding it every launch would make
    # it impossible to get rid of.
    #
    # Silent by design. A SessionStart hook's stdout is fed to Claude as
    # context, so anything printed here would show up in the conversation every
    # single launch; the repair is recorded in the plugin log instead.
    if [ "$ACTION" = "--repair" ]; then
      command -v jq >/dev/null 2>&1 || exit 0

      # Everything this branch has to say goes to the plugin log, never stdout.
      rlog() {
        [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -d "${CLAUDE_PLUGIN_DATA}" ] || return 0
        printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" info "statusline: $1" \
          >> "${CLAUDE_PLUGIN_DATA}/voice-readout.log" 2>/dev/null
      }

      # --- Register once, on the first session after an install. ------------
      # Nothing fires when a plugin is installed — Claude Code has no such hook
      # event — so the first session that runs any of this plugin's hooks is the
      # only "just installed" signal there is. Without this the status line
      # simply never appeared unless someone read the README and ran --install
      # by hand; that is how it went missing on 2026-07-25, when reinstalling
      # the plugin stripped the registration (uninstall.sh does that on purpose)
      # and nothing ever put it back.
      #
      # A marker file makes it once per install rather than once per session,
      # which is what keeps the original promise intact: remove the status line
      # and it stays removed. The marker lives in the plugin's data directory,
      # so a genuine reinstall — which recreates that directory — is treated as
      # a fresh install and registers again.
      #
      # Only ever adds a registration where there is NONE. An existing entry is
      # left to the repair pass below: ours gets its path corrected, anyone
      # else's is not ours to overwrite.
      #
      # The marker is written whatever the outcome, including failure. A retry
      # every launch would be an install attempt the user never asked for, over
      # and over, with no way to say no.
      MARKER=""
      [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -d "${CLAUDE_PLUGIN_DATA}" ] \
        && MARKER="${CLAUDE_PLUGIN_DATA}/.statusline-bootstrapped"
      if [ -n "$MARKER" ] && [ ! -e "$MARKER" ]; then
        : > "$MARKER" 2>/dev/null
        [ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS" 2>/dev/null
        if jq -e . "$SETTINGS" >/dev/null 2>&1 \
           && [ -z "$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null)" ]; then
          if jq --arg cmd "$SELF" '.statusLine = {type: "command", command: $cmd}' \
               "$SETTINGS" > "${SETTINGS}.tmp" 2>/dev/null && [ -s "${SETTINGS}.tmp" ]; then
            mv "${SETTINGS}.tmp" "$SETTINGS"
            rlog "first run: registered in ${SETTINGS} -> ${SELF}"
          else
            rm -f "${SETTINGS}.tmp"
            rlog "first run: could not write ${SETTINGS}"
          fi
        fi
      fi

      TARGETS="$SETTINGS"
      # Hooks — unlike a hand-run script — are given CLAUDE_PROJECT_DIR, so the
      # project pair can be repaired too rather than only warned about. A
      # project file is only ever touched if it already points at this plugin.
      if [ "$FILE_GIVEN" -eq 0 ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
        TARGETS="$TARGETS
${CLAUDE_PROJECT_DIR}/.claude/settings.json
${CLAUDE_PROJECT_DIR}/.claude/settings.local.json"
      fi

      while IFS= read -r sf; do
        [ -n "$sf" ] && [ -f "$sf" ] || continue
        cur="$(jq -r '.statusLine.command // ""' "$sf" 2>/dev/null)" || continue
        [ -n "$cur" ] || continue                 # not registered: leave it so
        is_ours "$cur" || continue                # someone else's: not ours to move
        [ "$cur" = "$SELF" ] && continue          # already right: no write
        cp "$sf" "${sf}.bak-voice-readout" 2>/dev/null
        if jq --arg cmd "$SELF" '.statusLine = {type: "command", command: $cmd}' \
             "$sf" > "${sf}.tmp" 2>/dev/null && [ -s "${sf}.tmp" ]; then
          mv "${sf}.tmp" "$sf"
          rlog "repaired stale path in ${sf}: ${cur} -> ${SELF}"
        else
          rm -f "${sf}.tmp"
        fi
      done <<EOF
$TARGETS
EOF
      exit 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
      echo "jq が無いので settings.json を編集できません。次の行を手で追加してください:" >&2
      echo "  \"statusLine\": { \"type\": \"command\", \"command\": \"$SELF\" }" >&2
      exit 1
    fi

    mkdir -p "$(dirname "$SETTINGS")" 2>/dev/null
    [ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
    if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
      echo "$SETTINGS が JSON として読めません。手で直してから再実行してください。" >&2
      exit 1
    fi

    CURRENT="$(jq -r '.statusLine.command // ""' "$SETTINGS")"

    if [ "$ACTION" = "--uninstall" ]; then
      if [ -z "$CURRENT" ]; then
        echo "- statusLine は登録されていません: $SETTINGS"
      elif is_ours "$CURRENT"; then
        cp "$SETTINGS" "${SETTINGS}.bak-voice-readout" 2>/dev/null
        jq 'del(.statusLine)' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
        echo "✓ statusLine の登録を外しました: $SETTINGS"
      else
        echo "- statusLine は別のスクリプトを指しているので触りません: $CURRENT"
      fi
      exit 0
    fi

    # --install. An existing registration for something else is the user's own
    # choice and is not silently replaced.
    if [ -n "$CURRENT" ] && ! is_ours "$CURRENT" && [ "$FORCE" -ne 1 ]; then
      echo "既に別の statusLine が登録されています:" >&2
      echo "  $CURRENT" >&2
      echo "置き換えるなら --force を付けて再実行してください。" >&2
      exit 1
    fi

    # Repointing a broken variable form at a real path is a repair, not a
    # re-registration, and it is worth saying so: the symptom was an empty
    # status line, so "登録しました" alone would read as having changed nothing.
    case "$CURRENT" in
      *CLAUDE_PLUGIN_ROOT*)
        echo "- 展開されない \${CLAUDE_PLUGIN_ROOT} を含む登録が入っていました。"
        echo "  statusLine ではこの変数は展開されないため、絶対パスに置き換えます。"
        ;;
    esac

    cp "$SETTINGS" "${SETTINGS}.bak-voice-readout" 2>/dev/null
    if jq --arg cmd "$SELF" '.statusLine = {type: "command", command: $cmd}' "$SETTINGS" > "${SETTINGS}.tmp" \
       && [ -s "${SETTINGS}.tmp" ]; then
      mv "${SETTINGS}.tmp" "$SETTINGS"
      echo "✓ statusLine を登録しました: $SETTINGS"
      echo "  → $SELF"
      echo "  次に Claude Code と何かやり取りすると表示されます（再起動は不要）。"
    else
      rm -f "${SETTINGS}.tmp"
      echo "! 書き込みに失敗しました: $SETTINGS" >&2
      exit 1
    fi

    # A project's settings take precedence over the user's, key by key. So a
    # project that defines its own statusLine hides the one just registered
    # while you work in it — which otherwise looks exactly like the
    # registration not having worked. Only the current directory can be
    # checked from here, and it is only ever reported, never edited.
    for pf in "$PWD/.claude/settings.json" "$PWD/.claude/settings.local.json"; do
      [ -f "$pf" ] || continue
      other="$(jq -r '.statusLine.command // ""' "$pf" 2>/dev/null)"
      case "$other" in
        ""|*voice-readout*) ;;
        *)
          echo
          echo "⚠ このディレクトリのプロジェクト設定にも statusLine があります:"
          echo "    $pf"
          echo "    $other"
          echo "  プロジェクト設定の方が優先されるため、ここで作業している間は"
          echo "  そちらが表示されます（他の場所では上の登録が有効です）。"
          ;;
      esac
    done
    exit 0
    ;;
  --help|-h)
    echo "Usage: statusline.sh [--install|--uninstall] [--file <settings.json>] [--force]"
    echo "  --repair は SessionStart フックが呼ぶ内部用。登録済みのパスが古ければ書き直します"
    echo "  （未登録なら何もしません）。"
    echo "  引数なしで実行すると、Claude Code の statusLine コマンドとして1行を出力します。"
    exit 0
    ;;
esac

# ${#s} must count characters, not bytes, for the width arithmetic below.
export LC_ALL=C.utf8

# How wide the row actually is. Claude Code captures this script's output rather
# than attaching it to the terminal, so tput and every language-level width
# probe report the fallback 80 — it exports COLUMNS instead (v2.1.153+). Older
# versions export nothing, and no information means no wrapping: one long line,
# exactly what this script did before.
# Columns are held back for the interface's own spacing around the row, which
# is not exposed anywhere and had to be measured: at a real COLUMNS of 59 the
# row was still cut after 55, so the usable width is COLUMNS-4, not COLUMNS-2.
# (The `padding` setting in settings.json only ever ADDS to this, so it cannot
# buy any of it back.)
COLS=0
case "${COLUMNS:-}" in
  ''|*[!0-9]*) ;;
  *) COLS=$(( COLUMNS - 4 )) ;;
esac

# Display width in terminal columns. Every emoji this script prints is a single
# code point that occupies two columns, so the character count plus one per
# emoji is exact — no need for a wcwidth table or an external process, and this
# runs on every render.
# The declaration is split deliberately: written as `local s="$1" w=${#s}`, the
# ${#s} is expanded before s is local, so it measures the CALLER's s — emit()'s
# loop variable — and every width came out short enough that nothing ever
# wrapped.
dwidth() {
  local s="$1"
  local w=${#s} t e
  for e in 🔊 🔇 🔔 🛑; do
    t="${s//$e/}"
    w=$(( w + ${#s} - ${#t} ))
  done
  printf '%s' "$w"
}

# Collect segments, then emit them packed into rows that fit COLS. Wrapping to a
# second row rather than trimming content: the terminal is a phone, its width
# varies with the handset, the font size and the orientation, so any fixed
# budget is wrong for somebody. Truncation also fails silently in the worst way
# — the ellipsis lands mid-value, so the number you wanted is the part you lose.
SEGMENTS=()
seg() { SEGMENTS+=("$1"); }
emit() {
  local line="" cand s
  for s in "${SEGMENTS[@]}"; do
    [ -z "$s" ] && continue
    if [ -z "$line" ]; then cand="$s"; else cand="$line | $s"; fi
    if [ -n "$line" ] && [ "$COLS" -gt 0 ] && [ "$(dwidth "$cand")" -gt "$COLS" ]; then
      printf '%s\n' "$line"
      line="$s"
    else
      line="$cand"
    fi
  done
  [ -n "$line" ] && printf '%s' "$line"
}

# Read the SAME config the hooks read. Hooks run with CLAUDE_PLUGIN_DATA set by
# Claude Code, but a statusLine command does NOT get that variable — so falling
# back to /tmp (as the hooks' own default does) reads a different, stale file
# and the line lies about the state. Prefer CLAUDE_PLUGIN_DATA when present,
# otherwise point straight at the plugin's real data dir, never /tmp.
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  CONFIG_FILE="$CLAUDE_PLUGIN_DATA/voice-readout-config"
else
  CONFIG_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/voice-readout-voice-readout/voice-readout-config"
fi
# Fixed absolute path, matching readout-switch.sh / tts-lib.sh. The stop switch
# deliberately does NOT honour CLAUDE_PLUGIN_DATA, so neither does this reader.
STOP_SWITCH_FILE="/data/data/com.termux/files/home/.voice-readout-stopped"

# Read one KEY=value from the config. Prints nothing if unset or file missing.
# Enable semantics match is_enabled(): only the literal "off" disables; an
# absent key (or no file at all) counts as on.
cfg() {
  [ -f "$CONFIG_FILE" ] || return
  grep -E "^$1=" "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2
}

# The stop switch is the top-level cutoff: when it's pressed nothing is spoken,
# no matter what resp/notif say. Show that instead of the per-toggle state so an
# enabled toggle can't be mistaken for "it should be talking but isn't".
if [ -e "$STOP_SWITCH_FILE" ]; then
  # Named like every other state of this row: it is the one people stare at
  # while wondering what stopped talking.
  seg 'voice readout'
  seg '🛑 ALL MUTED'
  emit
  exit 0
fi

# ON -> speaker with sound, OFF -> muted speaker. Only "off" is off.
icon() { [ "$1" = "off" ] && printf '🔇' || printf '🔊'; }

# Display-only names. The line has to fit a phone terminal, but abbreviating the
# services themselves (gem/inw/elab) failed the only test that matters: you have
# to recognise the engine at a glance, and "gem" does not read as Gemini. So the
# product names stay spelled out; only elevenlabs is shortened, to its own common
# 11labs. The width is bought back from separators and labels instead.
# ondevice, which has no product name, becomes "local" — it says what the actual
# distinction is (runs here, no network) — rather than "dev" (reads as
# development) or "ond" (unpronounceable). English rather than 端末, a column
# shorter, so the line needs no redesign when the UI is translated.
# Config values are NOT renamed: `toggle.sh backend ondevice` still takes the
# long name; only what is drawn here differs (README carries the mapping).
short_backend() {
  case "$1" in
    ondevice)   printf 'local' ;;
    gemini)     printf 'gemini' ;;
    inworld)    printf 'inworld' ;;
    elevenlabs) printf '11labs' ;;
    *)          printf '%s' "$1" ;;
  esac
}

# Each readout function can use a different backend, so show each one's backend
# next to its own icon — the backend NAME (gemini/inworld/elevenlabs/ondevice),
# not the full model string. Notifications use TTS_BACKEND_NOTIFICATION; the
# response uses TTS_BACKEND_FULL or _SUMMARY depending on the mode. Both fall
# back to the global TTS_BACKEND, then to ondevice (the shipped default).
notif_backend="$(cfg TTS_BACKEND_NOTIFICATION)"
[ -n "$notif_backend" ] || notif_backend="$(cfg TTS_BACKEND)"
[ -n "$notif_backend" ] || notif_backend="ondevice"

# Full mode reads verbatim; summary mode runs the response through the
# summarizer first. Mark that difference on the line with a short tag before the
# backend — "full" or "sum" — always printed, so the live mode is readable on
# its own rather than inferred from the absence of a tag.
if [ "$(cfg READOUT_MODE)" = "full" ]; then
  resp_backend="$(cfg TTS_BACKEND_FULL)"
  resp_mode="full "
else
  resp_backend="$(cfg TTS_BACKEND_SUMMARY)"
  resp_mode="sum "
fi
[ -n "$resp_backend" ] || resp_backend="$(cfg TTS_BACKEND)"
[ -n "$resp_backend" ] || resp_backend="ondevice"

# The two 決まり文句 (session start / session end) are toggled independently of
# the readout itself, and both play fixed clips rather than a chosen backend —
# so they get one shared "greet" segment with no backend name: left icon is the
# startup greeting (STARTUP_GREETING), right icon the farewell
# (SESSION_END_GREETING).
# Segments are divided by " | ". Spaces alone did not read as boundaries — every
# field is itself space-separated, so the eye cannot tell where "greet" ends and
# "notif" begins. A plain ASCII pipe rather than a box-drawing bar: renders in
# any terminal font, and costs one column. The pipe is padded: the unpadded form
# was a width economy from when the row was cut off at the edge, and once the
# segments wrap there is nothing left to buy with it — only legibility to lose.
# Which plugin this row belongs to. Spelled in English rather than カタカナ:
# that rule exists for text the TTS engines have to pronounce (they read
# "voice-readout" as レッドアウト), and nothing here is ever spoken.
seg 'voice readout'
seg "$(printf 'greet %s%s' \
  "$(icon "$(cfg STARTUP_GREETING)")" "$(icon "$(cfg SESSION_END_GREETING)")")"
seg "$(printf 'notif %s %s' \
  "$(icon "$(cfg NOTIFICATION_READOUT)")" "$(short_backend "$notif_backend")")"
seg "$(printf 'resp %s %s%s' \
  "$(icon "$(cfg STOP_READOUT)")" "$resp_mode" "$(short_backend "$resp_backend")")"

# Chunk marker: shown ONLY while it is on. It is off almost always, so a
# permanent segment would spend width on "off" every session — and the one
# moment the state matters is when cues are sounding and it is not obvious why.
# Appearing at all is therefore the signal: cues are on because you asked. The
# bell alone, with no "mark" label: when it is visible there is only one thing
# it can mean, so the word is five columns spent on nothing.
# Reading pace, always shown: it applies to whichever engine is speaking, and
# "is it me or is this fast today" is exactly the question the line should
# answer without asking. 1.0 is roughly an announcer's pace; see resolve_speed()
# in tts-lib.sh for how each engine's own knob is derived from it.
# The "speed" label is dropped for the same reason the bell carries no "mark":
# × is a multiplier sign, and nothing else on this line is a multiplier. The
# label cost six columns off the right edge of a phone terminal, which is where
# this segment sits — so the number itself was what got cut.
speed="$(cfg READOUT_SPEED)"; [ -n "$speed" ] || speed="1.2"
seg "×$speed"

[ "$(cfg CHUNK_MARKER)" = "on" ] && seg '🔔'

emit

exit 0
