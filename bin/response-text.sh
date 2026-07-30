#!/bin/bash
# Shared response-to-speech text normalization. Source this file from a hook;
# it intentionally has no side effects and does not inspect host-specific data.

clean_response_for_speech() {
  printf '%s' "$1" \
    | sed -E '/^[[:space:]]*```/,/^[[:space:]]*```/d' \
    | sed -E 's/`([^`]*)`/\1/g' \
    | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' \
    | sed -E 's#https?://[^ ]+##g' \
    | sed -E 's/\*\*([^*]*)\*\*/\1/g; s/__([^_]*)__/\1/g' \
    | sed -E 's/\*([^*]*)\*/\1/g; s/_([^_]*)_/\1/g' \
    | sed -E 's/^#+[[:space:]]*//g' \
    | sed -E 's/^[[:space:]]*[-*+][[:space:]]+//g' \
    | sed -E 's/^>[[:space:]]*//g' \
    | tr -s '[:space:]' ' ' \
    | sed -E 's/^ +| +$//g'
}

excerpt_for_speech() {
  local text="$1" max_chars="${2:-160}" opening boundary
  opening="${text:0:max_chars}"
  if [ "${#text}" -gt "$max_chars" ]; then
    boundary="$(printf '%s' "$opening" | sed -E 's/^(.*[。！？、]).*/\1/')"
    [ -n "$boundary" ] && opening="$boundary"
  fi
  printf '%s' "$opening"
}
