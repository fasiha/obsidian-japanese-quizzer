#!/usr/bin/env bash
# Replace quiz.sqlite (+ WAL/SHM) in the currently-running iOS simulator
# with the quiz.sqlite given as the first argument (e.g. one pulled from a phone).
# Backs up the simulator's existing quiz.sqlite first via pull-sim-quiz.sh.
# Usage: ./push-sim-quiz.sh path/to/quiz.sqlite
set -euo pipefail

SRC_DB="${1:-}"
if [[ -z "$SRC_DB" || ! -f "$SRC_DB" ]]; then
  echo "Usage: $0 path/to/quiz.sqlite" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$(dirname "$SRC_DB")" && pwd)"
SRC_NAME="$(basename "$SRC_DB")"

# Back up the simulator's current database first
echo "=== Backing up current simulator database ==="
"$SCRIPT_DIR/pull-sim-quiz.sh"
echo ""

# Find the booted simulator UUID
SIM_UUID=$(xcrun simctl list devices | grep 'Booted' | grep -oE '[A-F0-9-]{36}' | head -1)
if [[ -z "$SIM_UUID" ]]; then
  echo "No booted simulator found." >&2
  exit 1
fi
echo "Simulator: $SIM_UUID"

# Find quiz.sqlite inside that simulator's data
SIM_DB=$(find ~/Library/Developer/CoreSimulator/Devices/"$SIM_UUID" -name "quiz.sqlite" 2>/dev/null | grep /Documents/ | head -1)
if [[ -z "$SIM_DB" ]]; then
  echo "quiz.sqlite not found in simulator $SIM_UUID" >&2
  exit 1
fi
SIM_DIR=$(dirname "$SIM_DB")

# Quit the app so it does not hold the database open while we replace it
xcrun simctl terminate "$SIM_UUID" me.aldebrn.Pug 2>/dev/null || true

# Delete the simulator's quiz.sqlite and its WAL/SHM sidecar files, so a stale
# WAL from the old database cannot be applied to the new one
echo ""
echo "=== Replacing ==="
for f in "$SIM_DIR"/quiz.sqlite*; do
  [[ -e "$f" ]] || continue
  rm "$f"
  echo "Deleted: $(basename "$f")"
done

# Copy the new quiz.sqlite and any sidecar files that sit next to it
for f in "$SRC_DIR"/"$SRC_NAME" "$SRC_DIR"/"$SRC_NAME"-wal "$SRC_DIR"/"$SRC_NAME"-shm; do
  [[ -e "$f" ]] || continue
  cp "$f" "$SIM_DIR/"
  echo "Copied: $f → $SIM_DIR/"
done
echo "Done."
