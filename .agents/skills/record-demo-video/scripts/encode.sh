#!/usr/bin/env bash
# Encodes a directory of PNG frames into an H.264 mp4.
#
#   encode.sh <frame-dir> <out.mp4> [fps]
#
# ffmpeg where it exists (the usual case on Linux), otherwise AVFoundation through encode.swift, which
# is how a stock macOS with no ffmpeg installed still gets a video.
set -euo pipefail

FRAME_DIR="${1:?usage: encode.sh <frame-dir> <out.mp4> [fps]}"
OUTPUT="${2:?usage: encode.sh <frame-dir> <out.mp4> [fps]}"
FPS="${3:-8}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COUNT="$(find "$FRAME_DIR" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')"
[ "$COUNT" -gt 0 ] || { echo "no PNG frames in $FRAME_DIR" >&2; exit 1; }

if command -v ffmpeg >/dev/null 2>&1; then
  # glob rather than -i frame-%05d.png: a swallowed mid-navigation screenshot leaves a gap in the
  # numbering, and the numeric pattern stops dead at the first missing frame.
  # yuv420p and even dimensions, or QuickTime and the Linear player show a black rectangle.
  ffmpeg -hide_banner -loglevel error -y \
    -framerate "$FPS" -pattern_type glob -i "$FRAME_DIR/*.png" \
    -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p \
    -vf 'pad=ceil(iw/2)*2:ceil(ih/2)*2' -movflags +faststart "$OUTPUT"
  echo "WROTE $OUTPUT frames=$COUNT fps=$FPS"
elif [ "$(uname -s)" = Darwin ] && command -v swift >/dev/null 2>&1; then
  swift "$SKILL_DIR/encode.swift" "$FRAME_DIR" "$OUTPUT" "$FPS"
else
  echo "no encoder: install ffmpeg (apt install ffmpeg / brew install ffmpeg)." >&2
  echo "  the frames are still in $FRAME_DIR, so encoding can be retried without re-recording." >&2
  exit 1
fi
