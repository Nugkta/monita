# Monita

<img src="task-island/assets/AppIcon.png" width="96" height="96" alt="Monita app icon">

A compact, native macOS status bar for **Codex** and **Claude Code** tasks, and for coding agents running in **Herdr**. Keep an eye on work while using other apps, then review finished results in one small queue.

> [!IMPORTANT]
> **Codex and Claude Code only, not chat.** Monita follows coding tasks in the Codex desktop app and in Claude Code. It does not follow Claude chat conversations (claude.ai or the Claude app's Chat tab), Cowork, or ChatGPT chats, and there are no plans to add them.

<img src="docs/assets/demo.gif" alt="Animated demo with built-in sample tasks: hovering opens the panel and switches between Running, Input, and Review; dragging it into the menu bar docks it beside the notch, where the ears are the tabs" width="600">

<sub>Demo built from the app's synthetic previews (sample tasks, no real data) by <code>docs/make-demo.py</code>.</sub>

Monita is an independent, experimental project. It uses local app data and private desktop protocols, so coverage can change when Codex or Claude updates.

<details>
<summary><b>Features</b></summary>

- A 216 × 34 floating bar with Running, Input, and Review counts.
- Hover to expand; move away to collapse. Resting on Running, Input, or Review for a moment switches to it; a click still works.
- Drag the floating panel anywhere; it keeps its top centre as it opens and closes, and centres itself when dropped near the middle of the screen.
- On a Mac with a camera housing (notch), push the panel up into the menu bar over the housing to dock it as an island: Running to the left of the housing, Input and Review to the right, no taller than the menu bar. Drag it off to undock.
- One compact task list: Codex in blue, Claude in orange, with Open and Reviewed actions.
- A durable, task-grouped review queue. Opening a task does not mark it reviewed. Confirming a row acknowledges only the results captured by that action; later results remain pending.
- Quiet, distinct completion and input sounds, with a persistent Sound Effects switch.
- Spring expansion motion that preserves its top edge and respects Reduce Motion.
- Last-observed activity is distinguished from confirmed live activity. A hollow running marker means an observation is awaiting sync, not that the app has verified the task is currently running.

</details>

<details>
<summary><b>Coverage</b></summary>

| Source | Available information | Limits |
| --- | --- | --- |
| Codex desktop | Local task catalog, live states for loaded desktop sessions, input requests, and stable completed-result identities | Does not enumerate every host's live tasks. Uses a private observer protocol. |
| Claude Code desktop records | Local runtime registry when present; persisted successful-turn and error identities independent of runtime | Remote/SSH tasks may have completion records without locally observable running/input state. Real-session coverage depends on the desktop version. |
| Herdr (herdr-core) | Live status of coding-agent terminals on this Mac and on every machine connected to the local herdr-core; Herdr desktop's own "seen" marker decides what needs review | Read-only: a Herdr task leaves Review only when viewed in Herdr, and Open brings Herdr forward without selecting the terminal. Needs `~/.local/bin/herdr-core` (or `MONITA_HERDR_CORE`). A Claude session in a local Herdr terminal is listed once, as Herdr. |
| Claude Remote Control list cache | Timestamped running/input/idle observations; inferred endings when an explicitly active observation is followed by a newer idle observation | Not a continuous live feed. Inferred endings are labeled separately and do not claim a successful upstream turn. |

Claude chat, Cowork, and ChatGPT chat are not supported; only Codex and Claude Code tasks are. The app does not install hooks or configure remote hosts. A task existing only in a stale remote list cannot be made live by refreshing Monita's own heartbeat.

</details>

<details>
<summary><b>Requirements</b></summary>

- macOS 13 or later.
- Apple Command Line Tools (`xcode-select --install`).
- Node.js 22.19 or later in the Node 22 line (tested baseline).
- Python 3 for the optional installer.

The build targets the host Mac's architecture. The resulting app bundles Node so end users do not need a separate runtime. Builds use a local ad hoc signature and are not notarized.

Node's license is located from the selected installation. For a layout the build
does not recognize, set `NODE_LICENSE_PATH` to that version's complete LICENSE
file. A checked-in license fallback is provided only for Node v22.19.0.

</details>

<details>
<summary><b>Build and install</b></summary>

From the repository root:

```sh
npm ci --prefix monitor-probe/runtime --ignore-scripts --no-audit --no-fund
sh task-island/release.sh
```

This runs the checks, builds `task-island/Monita.app`, and executes its self-check. It does not install or start monitoring.

The editable icon source and 1024px master are in `task-island/assets/`. The
build uses macOS `sips` and `iconutil` to create all standard icon sizes from
`AppIcon.png`; after editing `AppIcon.svg`, export the updated 1024px PNG there
before building.

To install or update after those checks:

```sh
sh task-island/release.sh --install
```

The installed location is `~/Applications/Monita.app`. Monita was called Task Island before 0.2.14; the installer replaces an installed `Task Island.app` (keeping it in `task-island/backups/`), and review history and settings carry over. The app has a floating panel and menu-bar item instead of a conventional main window. It does not add a login item.

After a successful build, `python3 task-island/update-installed.py --no-launch`
installs without starting monitoring. Existing app bundles are kept in the
ignored `task-island/backups/` directory. Review data is stored separately and
is not changed by the installer.

</details>

<details>
<summary><b>Development checks</b></summary>

```sh
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
```

The tests use synthetic records and temporary resources. Some IPC tests need permission to create local Unix sockets. A model or layout test passing does not establish that a particular real Claude remote session has a working live feed.

For the additional adapted Codex protocol regression suite, run
`node monitor-probe/test.mjs`.

After building, `python3 -m unittest discover -s tests` checks a fresh install,
an update, and unrelated-app protection in temporary directories without
launching the app or touching the normal installation.

Synthetic offscreen previews do not start source observers or play sounds:

```sh
"task-island/Monita.app/Contents/MacOS/Monita" --render-preview /tmp/task-island-review.png --floating
```

`python3 docs/make-demo.py` rebuilds `docs/assets/demo.gif` from these previews (requires Pillow).

</details>

<details>
<summary><b>Privacy and local state</b></summary>

Monita does not call a model, generate summaries, send prompts, answer approvals, resume tasks, or upload task content. Its source observers communicate with the native UI through a private pipe containing allowlisted task/navigation metadata.

The underlying Codex IPC can send a full snapshot into memory before projection. The Claude cache reader temporarily copies and decodes the selected local cache before filtering it; this can include unrelated cached content in memory. Only allowlisted session metadata leaves the parser. Temporary copies are private and removed after reading. Unsupported formats fail closed.

Own review state is saved with private permissions and atomic replacement under:

```text
~/Library/Application Support/TaskIsland/review-ledger.json
```

The folder keeps the project's original name so history from before the rename carries over.

It contains task titles, result identities, and explicit review receipts, not answer bodies. The aggregate `runtime-status.json` in the same directory is for diagnostics. Do not include these files, source-app caches, screenshots of real tasks, credentials, or diagnostic dumps in public issues.

</details>

<details>
<summary><b>Project layout</b></summary>

```text
task-island/       SwiftUI/AppKit app, status bridge, tests, and build scripts
monitor-probe/     Adapted local source observers and pinned JavaScript dependencies
```

</details>

<details>
<summary><b>License and acknowledgments</b></summary>

MIT. The local observer adapters derive from [Monitor](https://github.com/JustinTervala/monitor), copyright 2026 Justin Tervala, pinned originally at `69b148a3b31350a6bb3546d3dabddf659d891e3b`. Its copyright and MIT permission notice are preserved in `monitor-probe/source/LICENSE`.

The app bundles Node.js and Immer with their applicable license notices. See `THIRD_PARTY_NOTICES.md` for the shipped components. This project is not affiliated with OpenAI or Anthropic.

</details>
