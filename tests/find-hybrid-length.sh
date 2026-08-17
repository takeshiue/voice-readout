#!/bin/bash
# Finds the shortest on-device opening that still covers a cloud engine's first
# chunk generation, by binary search over the length rather than by trying values
# and keeping whichever happened to pass.
#
# The handover succeeds when
#     time spent speaking the opening on-device  >=  time to generate cloud chunk 0
# so the quantity being searched for is the smallest opening whose speech time
# clears the generation time. Below it the readout speaks a SECOND on-device unit
# and keeps doing so until the cloud catches up, which is what the repeated
# `windows-sapi` lines in the log are.
#
# Why binary search and not a sweep: a sweep tells you that some value passed, not
# where the boundary is, so it cannot distinguish "comfortably enough" from "only
# just enough" — and only-just-enough fails on a slow run. Bracketing the boundary
# between a known pass and a known fail and halving the interval converges on it
# in log2(range) rounds, and the value shipped is then the boundary PLUS margin,
# chosen deliberately instead of inherited from whatever the sweep tried.
#
# Each candidate is tested REPS times and must pass every time. Generation time
# varies run to run (elevenlabs measured 8.2-13.7s on 2026-08-15), so a single
# pass is not evidence — it may just have caught a fast generation.
#
# No audio is played. Generation is timed by calling gen_cloud() directly and the
# on-device speech time comes from _ondevice_speech_secs(), whose model was
# calibrated against SAPI the same day (105 chars / 14.1s measured vs 14.5s
# predicted), so the comparison needs no speaker.
#
# THE RESULT IS PER PLATFORM, NOT JUST PER ENGINE. It is a length in characters,
# and what a length costs in SECONDS is a property of the on-device engine: SAPI
# speaks 7.4 chars/sec after a 0.3s start, termux-tts-speak 5.0 after 4.6s, so the
# same number is a different amount of cover on each. Android also pays a ~1.9s
# termux-media-player round trip that Windows does not. A value found here must
# therefore be recorded as a Windows value and never copied to a phone install
# (nor the reverse) — see docs/hybrid-tuning.md, which keeps them apart.
#
# Usage: find-hybrid-length.sh [BACKEND] [REPS]
#   BACKEND  default elevenlabs
#   REPS     generations per candidate, default 3

set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source bin/tts-lib.sh

# The speech-time model this search compares against is only calibrated for SAPI
# (see _ondevice_speech_secs). Run on Android it would still print a number, and
# that number would be wrong — refuse instead.
if command -v termux-tts-speak >/dev/null 2>&1; then
  echo "This search is calibrated for Windows/SAPI only; run it there." >&2
  exit 1
fi

BACKEND="${1:-elevenlabs}"
REPS="${2:-3}"

# Search bounds. LO is expected to fail and HI to pass; both are verified before
# the search starts rather than assumed, because a search over a bracket that
# does not actually bracket the boundary returns a confident wrong answer.
LO=40
HI=200
# Stop when the interval is this small. 10 chars is ~1.4s of speech at SAPI's
# 7.4 chars/sec — finer than the run-to-run variation in generation time, so
# splitting further would be measuring noise.
TOL=10
# Added to the boundary for the value actually shipped. The boundary is by
# definition the length that only just covers the SLOWEST generation seen during
# the search; a generation slower than any of those is a normal event, and the
# cost of being short is an audible extra on-device unit while the cost of being
# long is a few seconds more of the local voice. 20 chars ~ 2.7s.
MARGIN=20

# Sentence-bounded filler, long enough that any candidate length can be cut from
# it. Content is irrelevant to the measurement; what matters is that the text is
# the same for every candidate so generation time varies only with LENGTH.
# Must be comfortably longer than HI + one cloud chunk, or the tail left after
# the opening is too short to split and the probe measures a chunk that the real
# readout would never produce.
SRC="ハイブリッド引き継ぎの検証を行います。ローカル音声で冒頭を読み上げ、そのあいだにクラウド音声の生成を終わらせることが目的です。生成が間に合わない場合は、ローカル音声が次の単位を読み始めてしまい、区切り音が二回以上鳴ることになります。読み上げ速度は毎秒およそ七文字で、生成にかかる時間はエンジンによって変わります。この文章は計測のための素材であり、内容そのものに意味はありません。同じ文章を使うことで、文字数以外の条件を揃えています。区切り音の回数を数えることで、引き継ぎが一度で済んだかどうかを判定できます。二回以上鳴る場合は、ローカル音声の長さが不足しているという意味になります。値を決めるときは平均ではなく最大値を使います。平均に合わせると、生成が遅かった回に引き継ぎが失敗するからです。境界そのものを採用せず、余裕を足した値を採用するのも同じ理由によるものです。実測を重ねることで、どの程度のばらつきがあるのかも見えてきます。プラットフォームによって読み上げ速度が違うため、この値はそのまま他の環境へ持ち込むことはできません。"

printf 'backend=%s  reps=%d  bracket=[%d,%d]  tol=%d  margin=%d\n\n' \
  "$BACKEND" "$REPS" "$LO" "$HI" "$TOL" "$MARGIN"

now() { date +%s.%N; }

# _probe CHARS — generate chunk 0 REPS times for an opening of CHARS characters
# and report whether the opening covers the slowest of those generations.
# Prints: "PASS|FAIL speech_secs worst_gen_secs each,each,each"
_probe() {
  local chars="$1"
  # Bash substring expansion, NOT `cut -c`: cut counts BYTES in this environment,
  # so a Japanese source was sliced mid-character (40 "chars" gave 13 characters
  # plus a broken one) and every length in the search meant something other than
  # what it said. ${var:offset:len} counts characters, matching ${#var}, which is
  # what _ondevice_speech_secs and the rest of the plugin measure in.
  local opening="${SRC:0:$chars}"
  local speech; speech="$(_ondevice_speech_secs "$opening")"

  # What the cloud has to generate while that opening is being spoken is chunk 0
  # of the REST of the text — the same split speak_hybrid hands to the pipeline.
  local rest="${SRC:$chars}"
  local cmax fmax smax
  cmax="$(get_tuning_num_for CLOUD_CHUNK_CHARS "$BACKEND" 200)"
  fmax="$(get_tuning_num_for CLOUD_FIRST_CHUNK_CHARS "$BACKEND" 80)"
  smax="$(get_tuning_num_for CLOUD_SECOND_CHUNK_CHARS "$BACKEND" 120)"
  local chunk0=""
  while IFS= read -r -d '' c; do chunk0="$c"; break; done \
    < <(split_into_speech_chunks "$rest" "$cmax" "$fmax" "$smax")
  [ -n "$chunk0" ] || { printf 'FAIL %s 0 no-chunk' "$speech"; return; }

  local worst=0 list="" r t0 t1 el
  for (( r = 0; r < REPS; r++ )); do
    t0="$(now)"
    if ! gen_cloud "$BACKEND" "$chunk0" "probe-${chars}-${r}" 2>/dev/null; then
      printf 'FAIL %s 0 gen-error' "$speech"; return
    fi
    t1="$(now)"
    el="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')"
    rm -f "$(_cloud_audio_path "$BACKEND" "probe-${chars}-${r}")" 2>/dev/null
    list="${list}${list:+,}${el}"
    awk -v e="$el" -v w="$worst" 'BEGIN{exit !(e>w)}' && worst="$el"
  done

  # Pass only if the opening covers the WORST generation of this round: the
  # criterion is "every repetition handed over", not "the average would have".
  if awk -v s="$speech" -v w="$worst" 'BEGIN{exit !(s>=w)}'; then
    printf 'PASS %s %s %s' "$speech" "$worst" "$list"
  else
    printf 'FAIL %s %s %s' "$speech" "$worst" "$list"
  fi
}

# Verify the bracket before searching it. If HI fails, the answer is above the
# range; if LO passes, it is below. Either way the search would converge on an
# endpoint and report it as the boundary, which is the confident-wrong-answer
# case this guards against.
printf 'bracket check\n'
read -r v_hi s_hi w_hi l_hi <<< "$(_probe "$HI")"
printf '  %3d chars: %s  speech %ss vs worst gen %ss  [%s]\n' "$HI" "$v_hi" "$s_hi" "$w_hi" "$l_hi"
if [ "$v_hi" != PASS ]; then
  printf '\nHI bound does not pass — the needed length is above %d. Raise HI and rerun.\n' "$HI"
  exit 1
fi
read -r v_lo s_lo w_lo l_lo <<< "$(_probe "$LO")"
printf '  %3d chars: %s  speech %ss vs worst gen %ss  [%s]\n' "$LO" "$v_lo" "$s_lo" "$w_lo" "$l_lo"
if [ "$v_lo" = PASS ]; then
  printf '\nLO bound already passes — the boundary is below %d. Lower LO and rerun.\n' "$LO"
  exit 1
fi

printf '\nbinary search\n'
lo="$LO"; hi="$HI"; round=0
while [ "$(( hi - lo ))" -gt "$TOL" ]; do
  round=$(( round + 1 ))
  mid=$(( (lo + hi) / 2 ))
  read -r verdict speech worst list <<< "$(_probe "$mid")"
  printf '  round %d  [%3d,%3d] try %3d: %s  speech %ss vs worst gen %ss  [%s]\n' \
    "$round" "$lo" "$hi" "$mid" "$verdict" "$speech" "$worst" "$list"
  if [ "$verdict" = PASS ]; then hi="$mid"; else lo="$mid"; fi
done

recommend=$(( hi + MARGIN ))
printf '\nboundary between %d (fail) and %d (pass)\n' "$lo" "$hi"
printf 'recommended: HYBRID_MIN_ONDEVICE_CHARS_%s = %d  (boundary %d + margin %d)\n' \
  "$(printf '%s' "$BACKEND" | tr '[:lower:]' '[:upper:]')" "$recommend" "$hi" "$MARGIN"
printf 'apply with:\n  bash bin/toggle.sh tune HYBRID_MIN_ONDEVICE_CHARS_%s %d\n' \
  "$(printf '%s' "$BACKEND" | tr '[:lower:]' '[:upper:]')" "$recommend"
