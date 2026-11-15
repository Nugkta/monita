#!/bin/sh
# Double-click in Finder: runs every check, builds, and replaces the installed
# Monita only if all of it passes. The previous app is kept as a backup.
# The full output is also kept in task-island/.install-log.txt.
cd "$(dirname "$0")/.." || exit 1
log=task-island/.install-log.txt
if sh task-island/release.sh --install > "$log" 2>&1; then
  tail -n 30 "$log"
  printf '\n%s\n' 'RESULT: installed' | tee -a "$log"
else
  grep -n 'error:' "$log" | head -n 20
  printf '\n%s\n' 'RESULT: failed, nothing installed' | tee -a "$log"
fi
