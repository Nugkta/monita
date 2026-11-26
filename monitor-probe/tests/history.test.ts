import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';
import { CodexProvider } from '../source/src/providers/codex';
import { readCodexHistory } from '../source/src/providers/codex/history';
import type { Session } from '../source/src/shared/types';

const id = 'task-local';
const start = 1_800_000_000;
const now = (start + 500) * 1000;

function fixture(t: { after: (fn: () => void) => void }) {
  const home = mkdtempSync(join(tmpdir(), 'monita-history-'));
  const rollout = join(home, 'sessions', 'local-task.jsonl');
  mkdirSync(join(home, 'sessions'));
  writeFileSync(rollout, '');
  const state = new DatabaseSync(join(home, 'state_5.sqlite'));
  const history = new DatabaseSync(join(home, 'thread_history_1.sqlite'));
  t.after(() => {
    history.close();
    state.close();
    rmSync(home, { recursive: true, force: true });
  });
  state.exec(`
    CREATE TABLE threads(id TEXT PRIMARY KEY, archived INTEGER, rollout_path TEXT,
      title TEXT, cwd TEXT, source TEXT, updated_at INTEGER);
    CREATE TABLE thread_read_receipts(thread_id TEXT PRIMARY KEY, first_unread_turn TEXT, last_published_turn TEXT);
  `);
  history.exec(`
    CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, status TEXT, rollout_ordinal INTEGER,
      started_at INTEGER, completed_at INTEGER, PRIMARY KEY(thread_id, turn_id));
  `);
  state.prepare("INSERT INTO threads VALUES (?, 0, ?, 'Local task', NULL, 'cli', ?)").run(id, rollout, start);
  state.prepare('INSERT INTO thread_read_receipts VALUES (?, NULL, ?)').run(id, 'turn-old');
  const add = history.prepare('INSERT INTO thread_turns VALUES (?, ?, ?, ?, ?, ?)');
  add.run(id, 'turn-old', 'completed', 10, start - 100, start - 50);
  add.run(id, 'turn-new', 'inProgress', 20, start, null);
  return { home, rollout, state, history };
}

test('an unfinished turn needs its own live writer from the same process lifetime', async t => {
  const { home, rollout } = fixture(t);
  const unowned = await readCodexHistory(home, [id], async () => new Map(), now);
  assert.equal(unowned.has(id), false);
  const stale = await readCodexHistory(home, [id], async () => new Map([[rollout, start + 1]]), now);
  assert.equal(stale.has(id), false);
  const active = await readCodexHistory(home, [id], async paths => {
    assert.deepEqual(paths, [rollout]);
    return new Map([[rollout, start - 1]]);
  }, now);
  assert.equal(active.get(id)?.snapshot.status, 'running');
  assert.equal(active.get(id)?.snapshot.attentionKey, null);
});

test('only a receipt for the terminal head supplies read state and the canonical result ID', async t => {
  const { home, state, history } = fixture(t);
  history.prepare("UPDATE thread_turns SET status = 'completed', completed_at = ? WHERE turn_id = 'turn-new'").run(start + 10);
  const read = () => readCodexHistory(home, [id], async () => { throw new Error('No writer check for completed turns'); }, now);
  assert.equal((await read()).has(id), false);
  state.exec("UPDATE thread_read_receipts SET last_published_turn = 'turn-new', first_unread_turn = 'turn-old'");
  const unread = (await read()).get(id)?.snapshot;
  assert.equal(unread?.status, 'review');
  assert.equal(unread?.attentionKey, 'result:turn-new');
  state.exec('UPDATE thread_read_receipts SET first_unread_turn = NULL');
  const seen = (await read()).get(id)?.snapshot;
  assert.equal(seen?.status, 'read');
  assert.equal(seen?.attentionKey, unread?.attentionKey);
});

test('an older persisted result does not hide a newer hook turn', async t => {
  const { home, history } = fixture(t);
  const seconds = Math.floor(Date.now() / 1000);
  history.exec("DELETE FROM thread_turns WHERE turn_id = 'turn-new'");
  history.prepare("UPDATE thread_turns SET started_at = ?, completed_at = ? WHERE turn_id = 'turn-old'")
    .run(seconds - 25, seconds - 20);
  const hooks = join(home, 'hooks');
  const hookFile = join(hooks, `${id}.json`);
  mkdirSync(hooks, { mode: 0o700 });
  const writeActivity = (turnId: string, at: number) => writeFileSync(hookFile, JSON.stringify({
    version: 1, sessionId: id, activity: { event: 'UserPromptSubmit', turnId, at },
  }), { mode: 0o600 });
  writeActivity('turn-old', (seconds - 22) * 1000);

  let current: Session | undefined;
  const provider = new CodexProvider(home, hooks);
  t.after(() => provider.stop());
  await provider.start({ health() {}, sessions(rows) { current = rows.find(row => row.externalId === id); } });
  assert.equal(current?.status, 'read');
  writeActivity('turn-new', (seconds - 10) * 1000);
  await provider.refresh();
  assert.equal(current?.status, 'running');
  assert.equal(current?.attentionKey, null);
});
