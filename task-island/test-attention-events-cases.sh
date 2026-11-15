#!/bin/sh
set -eu
cd "$(dirname "$0")"
test_dir=$(mktemp -d /tmp/task-island-attention-test.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  -module-cache-path "$test_dir/module-cache" \
  -framework Foundation -framework Combine \
  LiveModel.swift attention-events-cases.swift \
  -o "$test_dir/attention-events-cases"
"$test_dir/attention-events-cases"
