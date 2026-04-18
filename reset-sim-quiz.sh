#!/usr/bin/env bash
# Delete quiz.sqlite (+ WAL/SHM) from the currently-running iOS simulator.
# Runs pull-sim-quiz.sh first to back up before deleting.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Back up first
echo "=== Backing up before delete ==="
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
SIM_DB=$(find ~/Library/Developer/CoreSimulator/Devices/"$SIM_UUID" -name "quiz.sqlite" 2>/dev/null | head -1)
if [[ -z "$SIM_DB" ]]; then
  echo "quiz.sqlite not found in simulator $SIM_UUID" >&2
  exit 1
fi
SIM_DIR=$(dirname "$SIM_DB")

# Delete quiz.sqlite and any WAL/SHM sidecar files
echo ""
echo "=== Deleting ==="
for f in "$SIM_DIR"/quiz.sqlite* "$SIM_DIR"/chat.sqlite*; do
  [[ -e "$f" ]] || continue
  rm "$f"
  echo "Deleted: $(basename "$f")"
done
echo "Done."
