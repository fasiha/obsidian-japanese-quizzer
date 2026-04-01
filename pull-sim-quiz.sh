#!/usr/bin/env bash
# Pull quiz.sqlite (+ WAL/SHM) from the currently-running iOS simulator
# into a timestamped backup directory.
set -euo pipefail

# Find the booted simulator UUID
SIM_UUID=$(xcrun simctl list devices | grep 'Booted' | grep -oE '[A-F0-9-]{36}' | head -1)
if [[ -z "$SIM_UUID" ]]; then
  echo "No booted simulator found." >&2
  exit 1
fi
echo "Simulator: $SIM_UUID"

# Find quiz.sqlite inside that simulator's data
SIM_DB=$(find ~/Library/Developer/CoreSimulator/Devices/"$SIM_UUID" -name "quiz.sqlite" 2>/dev/null | head -1)
if [[ -z "$SIM_DB" ]]; then
  echo "quiz.sqlite not found in simulator $SIM_UUID" >&2
  exit 1
fi
SIM_DIR=$(dirname "$SIM_DB")

# Create timestamped backup directory
TIMESTAMP=$(date +%Y-%m-%dT%H-%M-%S)
DEST="quiz-backup-$TIMESTAMP"
mkdir "$DEST"

# Copy quiz.sqlite and any WAL/SHM sidecar files
for f in "$SIM_DIR"/quiz.sqlite*; do
  [[ -e "$f" ]] || continue
  cp "$f" "$DEST/"
  echo "Copied: $f → $DEST/"
done
