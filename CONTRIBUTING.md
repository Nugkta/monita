# Contributing

Monita is experimental. Please keep changes focused and distinguish
synthetic tests from real desktop-session validation.

1. Follow the setup steps in README.md.
2. Run `sh task-island/release.sh` before submitting a pull request. It builds
   and self-checks without installing or starting source observers.
3. For observer changes, also run `node monitor-probe/test.mjs` and add a
   synthetic regression for the state or protocol change.
4. Explain which desktop version and session surface you tested: local Code,
   Remote Control, SSH, or CLI. Never infer current activity from file recency.

Do not attach real transcripts, source-app caches, review ledgers, credentials,
or screenshots containing private task data. Use synthetic fixtures and
aggregate diagnostics. The optional chat probe is a deliberate diagnostic tool;
it is not part of normal app startup and its output should be reviewed before
sharing.

Preserve result identities, review receipts, source/host isolation, original
observation timestamps, and fail-closed behavior for unsupported formats.
Keep the UI compact; prefer a task row over additional permanent controls.
