# Third-party notices

## Monitor

The observer adapters under `monitor-probe/source/` derive from
[Monitor](https://github.com/JustinTervala/monitor), originally pinned at
`69b148a3b31350a6bb3546d3dabddf659d891e3b`.

Copyright (c) 2026 Justin Tervala. MIT license; the complete notice is retained
in `monitor-probe/source/LICENSE`. The adapters have been modified for Task
Island. The upstream Electron UI and automatic summary service are not included.

## Immer

Immer 10.2.0 is an MIT-licensed runtime dependency used for Codex state patches.
See `third-party/Immer-LICENSE`. The build also copies the installed package's
license into the app bundle.

## Node.js

The app build bundles the Node.js executable selected from PATH and its complete
license file, including notices for Node's bundled components. The build must
find the license corresponding to that executable, or it fails.

`third-party/Node-v22.19.0-LICENSE` is the license distributed with the tested
Node.js v22.19.0 release. It is used as a fallback only for that exact version.
For another Node installation, set `NODE_LICENSE_PATH` if its license is not in
a recognized installation location.

## Development tools

Pinned development/build dependencies are listed in
`monitor-probe/runtime/package.json` and `package-lock.json`. They are not
checked into this repository. Their package license files accompany their
installed distributions.
