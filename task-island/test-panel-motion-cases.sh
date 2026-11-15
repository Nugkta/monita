#!/bin/sh
set -eu
cd "$(dirname "$0")"
test_dir=$(mktemp -d /tmp/task-island-motion-test.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  -module-cache-path "$test_dir/module-cache" \
  -framework Foundation \
  PanelMotion.swift panel-motion-cases.swift \
  -o "$test_dir/panel-motion-cases"
"$test_dir/panel-motion-cases"
