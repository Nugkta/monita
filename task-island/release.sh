#!/bin/sh
# Check, build and self-check in one go. Run on the Mac. Nothing is installed or
# launched unless --install is given.
set -eu
cd "$(dirname "$0")/.."
node monitor-probe/runtime/node_modules/typescript/bin/tsc --noEmit -p task-island/tsconfig.json
node task-island/test.mjs
sh task-island/test-review-cases.sh
sh task-island/test-group-review-cases.sh
sh task-island/test-quiet-ui-cases.sh
sh task-island/test-attention-events-cases.sh
sh task-island/test-sound-effects-cases.sh
sh task-island/test-hover-expansion-cases.sh
sh task-island/test-panel-motion-cases.sh
sh task-island/test-herdr-cases.sh
sh task-island/build.sh
"task-island/Monita.app/Contents/MacOS/Monita" --self-check
if [ "${1:-}" = "--install" ]; then
  python3 task-island/update-installed.py
else
  printf '%s\n' 'All checks and the build passed. Nothing was installed; run again with --install to replace the installed app.'
fi
