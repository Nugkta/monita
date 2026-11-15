#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/task-island-review-test.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  -module-cache-path /tmp/task-island-live-module-cache \
  -framework Foundation -framework Combine \
  task-island/LiveModel.swift task-island/review-cases.swift \
  -o "$test_dir/review-cases"
"$test_dir/review-cases"
