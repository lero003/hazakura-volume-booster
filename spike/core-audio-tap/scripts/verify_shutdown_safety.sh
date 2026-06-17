#!/usr/bin/env bash
set -euo pipefail

PROCESS_NAME="${PROCESS_NAME:-CoreAudioTapPoC}"
TAP_PATTERN="${TAP_PATTERN:-hbb-poc}"

echo "Checking Hazakura Amp! shutdown safety..."

if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
  echo "FAIL: $PROCESS_NAME is still running." >&2
  pgrep -xl "$PROCESS_NAME" >&2 || true
  exit 1
fi

audio_report="$(system_profiler SPAudioDataType)"
if grep -i "$TAP_PATTERN" <<<"$audio_report" >/dev/null; then
  echo "FAIL: found possible Core Audio tap residue matching '$TAP_PATTERN'." >&2
  grep -i "$TAP_PATTERN" <<<"$audio_report" >&2 || true
  exit 1
fi

echo "OK: no $PROCESS_NAME process and no '$TAP_PATTERN' audio residue found."
