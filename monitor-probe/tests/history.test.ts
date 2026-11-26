import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';
import { readCodexHistory } from '../source/src/providers/codex/history';

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
    CREATE TABLE threads(id TEXT PRIMARY KEY, archived INTEGER, rollout_path TEXT);
    CREATE TABLE thread_read_receipts(thread_id TEXT PRIMARY KEY, first_unread_turn TEXT, last_published_turn TEXT);
  `);
  history.exec(`
    CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, status TEXT, rollout_ordinal INTEGER,
      started_at INTEGER, completed_at INTEGER, PRIMARY KEY(thread_id, turn_id));
  `);
  state.prepare('INSERT INTO threads VALUES (?, 0, ?)').run(id, rollout);
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
  assert.equal(active.get(id)?.status, 'running');
  assert.equal(active.get(id)?.attentionKey, null);
});

test('only a receipt for the terminal head supplies read state and the canonical result ID', async t => {
  const { home, state, history } = fixture(t);
  history.prepare("UPDATE thread_turns SET status = 'completed', completed_at = ? WHERE turn_id = 'turn-new'").run(start + 10);
  const read = () => readCodexHistory(home, [id], async () => { throw new Error('No writer check for completed turns'); }, now);
  assert.equal((await read()).has(id), false);
  state.exec("UPDATE thread_read_receipts SET last_published_turn = 'turn-new', first_unread_turn = 'turn-old'");
  const unread = (await read()).get(id);
  assert.equal(unread?.status, 'review');
  assert.equal(unread?.attentionKey, 'result:turn-new');
  state.exec('UPDATE thread_read_receipts SET first_unread_turn = NULL');
  const seen = (await read()).get(id);
  assert.equal(seen?.status, 'read');
  assert.equal(seen?.attentionKey, unread?.attentionKey);
});
