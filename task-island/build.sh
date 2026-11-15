#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
node task-island/build.mjs
mkdir -p /tmp/task-island-live-module-cache
app_dir='task-island/Task Island.app'
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/licenses"
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  -module-cache-path /tmp/task-island-live-module-cache \
  -framework AppKit -framework SwiftUI -framework Combine \
  task-island/TaskIsland.swift task-island/LiveModel.swift task-island/UIFixtures.swift task-island/ReviewCommands.swift task-island/SoundEffects.swift task-island/HoverExpansion.swift task-island/PanelMotion.swift \
  -o "$app_dir/Contents/MacOS/TaskIsland"
cp task-island/Info.plist "$app_dir/Contents/Info.plist"
cp task-island/bridge.mjs "$app_dir/Contents/Resources/bridge.mjs"
node_path=$(command -v node)
cp "$node_path" "$app_dir/Contents/Resources/node"
node_license=$(node task-island/resolve-node-license.mjs "$node_path")
cp "$node_license" "$app_dir/Contents/Resources/licenses/Node-LICENSE"
cp LICENSE "$app_dir/Contents/Resources/licenses/TaskIsland-LICENSE"
cp monitor-probe/source/LICENSE "$app_dir/Contents/Resources/licenses/Monitor-LICENSE"
cp monitor-probe/runtime/node_modules/immer/LICENSE "$app_dir/Contents/Resources/licenses/Immer-LICENSE"
codesign --force --sign - "$app_dir/Contents/Resources/node"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '%s\n' 'Built Task Island.app with bundled runtime; no app launched.'
