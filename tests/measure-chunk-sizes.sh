#!/bin/bash
# Finds chunk sizes that keep a backend's readout both quick to start and free of
# mid-readout gaps, by generating real audio and reconstructing the playback
# schedule on paper rather than listening to it.
#
# Why this exists: gemini's first chunk measured 14.2s to first sound on this
# machine (2026-08-15) with slack down to +2.5s on the next seam, and those two
# numbers move in OPPOSITE directions — shrinking chunk 0 starts the audio sooner
# but leaves less time to generate chunk 1, so tuning against either one alone
# walks into the other. This measures both for each candidate and reports the
# configurations that satisfy both.
#
# Nothing is played. gen_cloud() only generates, and _audio_duration() reads the
# length back off the file, so the whole schedule (when each chunk would start,
# how long it would run, how much margin each generation had) is arithmetic. A
# run therefore costs generation time only, not generation + playback time.
#
# Usage: measure-chunk-sizes.sh [BACKEND] [TEXT_FILE]
#   BACKEND    default gemini
#   TEXT_FILE  default the built-in sample (a ~1400 char passage)
#
# Writes a table to stdout and the raw samples to .tmp/chunk-measure-<backend>.tsv

set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source bin/tts-lib.sh

BACKEND="${1:-gemini}"
TEXT_FILE="${2:-}"

# Pass/fail thresholds, fixed BEFORE any measurement so the conclusion cannot be
# fitted to whatever the numbers happened to be.
#   first sound: gemini's fixed TTFB is 6-10s by this file's own measurements, so
#     nothing under that is reachable; 10s is the least bad achievable target.
#   min slack: the observed run-to-run swing that pushed real readouts negative
#     was 2-3s (slack-2.2 and slack-0.1 in the log), so +5s absorbs one bad
#     moment without the listener hearing it.
MAX_FIRST_SOUND=10.0
MIN_SLACK=5.0

mkdir -p .tmp
OUT_TSV=".tmp/chunk-measure-${BACKEND}.tsv"
: > "$OUT_TSV"

if [ -n "$TEXT_FILE" ]; then
  TEXT="$(cat "$TEXT_FILE")"
else
  TEXT="どんな顔で出ればいいのか、ドアの内側でしばらく考えた。答えは出なかった。普通の顔がいちばんいいはずなのに、普通の顔というのがどういうものか思い出せなかった。出ていくと、彼は窓の外を見ていた。振り向かなかったので、わたしは横顔を見た。雨は、さっきよりひどくなっていた。庇から落ちる水が線ではなく面になっていて、路面が白く跳ねていた。止む気配がまったくなかった。それを見て、うれしいと思った。思ってしまってから、自分の心の底を覗いたような気持ちになった。雨がやまなければ、まだここにいられる。そう考えたのだ。誰かが困る雨を、自分の都合で喜んだのだ。しかも今日は金曜日で、明日は仕事がない。そのことまで頭をよぎって、わたしはそれを恥ずかしいと思った。彼が振り向いて、すみません、と言った。車があれば送っていけるんだけど、持ってなくて。そんなこと、と言った。全然、気にしないでください。言いながら、心の奥で、車がなくて助かったと思っていた。声に出したこととまるで反対のことを、同じ息で思っていた。窓の外で、雨がまだ強くなっていく音がした。"
fi

# The lead is what the schedule below assumes the player issues each chunk early
# by. Read from the live config so the measurement matches this machine's actual
# behaviour (0 on Windows/ffplay) rather than a number invented here.
LEAD="$(_cloud_play_lead)"

now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }

# Candidates: (first, chunk_max). first is what buys time-to-first-sound;
# chunk_max is what buys slack on every later seam. Deliberately crossed rather
# than swept one at a time — the interaction between them is the whole problem.
CANDIDATES="
40 200
40 260
60 200
60 260
80 200
80 260
110 260
110 320
"

printf 'backend=%s  text=%d chars  lead=%ss\n' "$BACKEND" "${#TEXT}" "$LEAD"
printf 'thresholds: first sound <= %ss, min slack >= %ss\n\n' "$MAX_FIRST_SOUND" "$MIN_SLACK"
printf '%-10s %-10s %-8s %-11s %-11s %s\n' first chunk_max chunks 'first_snd' 'min_slack' verdict
printf '%s\n' '--------------------------------------------------------------------------'

BEST_FIRST=""; BEST_MAX=""; BEST_SND=""

while read -r first cmax; do
  [ -n "${first:-}" ] || continue

  # Split with the candidate sizes. second_max is left at gemini's tuned 200
  # (_engine_default) so this varies only what it claims to vary.
  second="$(get_tuning_num_for CLOUD_SECOND_CHUNK_CHARS "$BACKEND" 120)"
  chunks=()
  while IFS= read -r -d '' c; do [ -n "$c" ] && chunks+=("$c"); done \
    < <(split_into_speech_chunks "$TEXT" "$cmax" "$first" "$second")
  n=${#chunks[@]}
  [ "$n" -gt 0 ] || continue

  # Generate every chunk and record how long each took and how long its audio
  # runs. Generation is sequential here on purpose: the real pipeline prefetches,
  # but a per-chunk cost measured under concurrency would fold the machine's
  # parallelism into a number meant to describe the API.
  gen_secs=(); aud_secs=()
  t_start="$(now)"
  ok=yes
  for (( i = 0; i < n; i++ )); do
    g0="$(now)"
    if ! gen_cloud "$BACKEND" "${chunks[$i]}" "measure-${first}-${cmax}-${i}" 2>/dev/null; then
      ok=no; break
    fi
    g1="$(now)"
    gen_secs+=("$(elapsed "$g0" "$g1")")
    f="$(_cloud_audio_path "$BACKEND" "measure-${first}-${cmax}-${i}")"
    aud_secs+=("$(_audio_duration "$f" 2>/dev/null || echo 0)")
    rm -f "$f" 2>/dev/null
  done
  if [ "$ok" != yes ]; then
    printf '%-10s %-10s %-8s %-11s %-11s %s\n' "$first" "$cmax" "$n" '-' '-' 'GEN FAILED'
    continue
  fi

  # Reconstruct the schedule the player would have followed.
  #   chunk 0 starts as soon as it is generated; each later chunk starts when the
  #   previous one ends, minus the lead. slack[k] is how much earlier chunk k was
  #   ready than it was needed — negative means the listener hears a gap.
  read -r first_snd min_slack <<EOF
$(printf '%s\n' "${gen_secs[@]}" | paste -d' ' - <(printf '%s\n' "${aud_secs[@]}") | awk -v lead="$LEAD" '
    { g[NR] = $1; a[NR] = $2; n = NR }
    END {
      # Cumulative generation: the pipeline generates ahead, so chunk k is ready
      # at the sum of generation times up to k (sequential worst case, which is
      # what a single-threaded prefetch depth of 1 gives).
      ready = 0
      for (k = 1; k <= n; k++) { ready += g[k]; r[k] = ready }
      play_end = r[1] + a[1]
      minslack = 1e9
      for (k = 2; k <= n; k++) {
        need = play_end - lead        # when chunk k has to be ready by
        s = need - r[k]
        if (s < minslack) minslack = s
        start = (r[k] > need ? r[k] : need)
        play_end = start + a[k]
      }
      if (n == 1) minslack = 999
      printf "%.1f %.1f", r[1], minslack
    }')
EOF

  verdict="ok"
  awk -v f="$first_snd" -v m="$MAX_FIRST_SOUND" 'BEGIN { exit !(f > m) }' && verdict="slow start"
  awk -v s="$min_slack" -v m="$MIN_SLACK" 'BEGIN { exit !(s < m) }' && \
    verdict="$([ "$verdict" = ok ] && echo 'tight seam' || echo 'both')"

  printf '%-10s %-10s %-8s %-11s %-11s %s\n' "$first" "$cmax" "$n" "$first_snd" "$min_slack" "$verdict"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$first" "$cmax" "$n" "$first_snd" "$min_slack" "$verdict" >> "$OUT_TSV"

  # Track the fastest start among configurations that pass BOTH tests.
  if [ "$verdict" = ok ]; then
    if [ -z "$BEST_SND" ] || awk -v a="$first_snd" -v b="$BEST_SND" 'BEGIN { exit !(a < b) }'; then
      BEST_SND="$first_snd"; BEST_FIRST="$first"; BEST_MAX="$cmax"
    fi
  fi
done <<< "$CANDIDATES"

printf '\n'
if [ -n "$BEST_FIRST" ]; then
  printf 'recommended: CLOUD_FIRST_CHUNK_CHARS=%s CLOUD_CHUNK_CHARS=%s (first sound %ss)\n' \
    "$BEST_FIRST" "$BEST_MAX" "$BEST_SND"
  printf 'apply with:\n'
  printf '  bash bin/toggle.sh tune CLOUD_FIRST_CHUNK_CHARS_%s %s\n' "$(printf '%s' "$BACKEND" | tr '[:lower:]' '[:upper:]')" "$BEST_FIRST"
  printf '  bash bin/toggle.sh tune CLOUD_CHUNK_CHARS_%s %s\n' "$(printf '%s' "$BACKEND" | tr '[:lower:]' '[:upper:]')" "$BEST_MAX"
else
  printf 'no candidate passed both thresholds — see %s\n' "$OUT_TSV"
fi
