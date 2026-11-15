# Changelog

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
