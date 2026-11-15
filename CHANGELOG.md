# Changelog

## 0.2.15

- A task that starts running again is no longer listed under both Running and
  Review. While it is confirmed running, it is left out of Review (list and
  counts); its results stay pending, unacknowledged, and it returns to Review
  when it stops. A stale "last seen running" observation does not hide it.

## 0.2.14

- Renamed from Task Island to **Monita**. The app is now `Monita.app` (menu:
  Show, Hide and Quit Monita). The installer replaces an installed
  `Task Island.app` that has Monita's bundle identifier, keeps it in
  `task-island/backups/`, and leaves any other app of that name alone.
- Unchanged on purpose, so nothing is lost: the bundle identifier
  `local.taskisland.status` (which also holds settings such as docking and
  sounds) and the `~/Library/Application Support/TaskIsland` data folder with
  the review history.

## 0.2.13

- Drag the docked island off the camera housing to undock it; it becomes the
  floating panel under the pointer. A short press is still a click.
- Compact island ears fit their contents: 52 points for Running, 88 for Input
  and Review. Open, the list stays centred under the housing.
- Only a press in the ears can drag the island off, so a sloppy click in the
  open list still reaches its row. After a drag, only moving onto a tab
  switches it, and hover never switches tabs while an Open is in flight.

## 0.2.12

- Dragging the floating panel no longer opens or closes it, and its position is
  kept by its top centre, so it stays lined up open and closed. Dropped within
  24 points of the screen's centre line, it centres itself.
- Docked layout is now an island beside the camera housing at menu-bar height,
  replacing the bar that hung below it. Dock by pushing the panel into the menu
  bar over the housing; undock from the status menu ("Movable Panel").
- Removed the optional Claude chat probe and its cache inspection hook. Claude
  chat remains out of scope.

## 0.2.11

- Hovering Running, Input, or Review for 0.1 seconds selects it. Only the
  pointer's own movement counts, so tabs sliding under a still pointer while
  the panel opens never switch it.

## 0.2.10

- Spring-based expansion and collapse, with stable top-edge positioning,
  interruption/reversal handling, and Reduce Motion support.
- Last-observed running activity can use a hollow marker while awaiting sync;
  it remains distinct from confirmed live activity and is limited to two hours.
- Compact 216×34 English interface with provider colors, hover expansion,
  optional completion/input sounds, and task-grouped review acknowledgments.
- Claude persisted-turn/error metadata is separate from current runtime state;
  remote cache active-to-idle transitions can produce separately labeled
  inferred endings. Remote live-state coverage remains limited.

This is the initial public source snapshot. Earlier local development notes,
task histories, installed apps, and diagnostic dumps are intentionally excluded.
