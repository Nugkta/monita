import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { changes, describeAppended, describeCache, describeJsonStore, findById, keyShape, maskPath, recordState, scan, summarizeRows } from './probe-claude-chat';

const SECRET = 'PRIVATE_Quarterly plan for Acme';
const cache = () => ({ timestamp: 1_000, clientState: { queries: [
  { queryKey: ['chat_conversation_list', { limit: 30, starred: false }, '3f2b1c9e-0000-4000-8000-000000000001'],
    state: { dataUpdatedAt: 900_000, data: { pages: [{ data: [
      { uuid: '3f2b1c9e-0000-4000-8000-0000000000aa', name: SECRET, summary: SECRET, is_starred: false, current_status: 'running',
        model: 'PRIVATE model note with spaces', updated_at: '2026-11-14T23:50:00Z', 'weird key!': SECRET },
      { uuid: '3f2b1c9e-0000-4000-8000-0000000000bb', name: SECRET, is_starred: true, current_status: 'idle', updated_at: '2026-11-14T23:40:00Z' },
    ] }] } } },
  { queryKey: ['sessions_api_list_sessions', SECRET],
    state: { dataUpdatedAt: 950_000, data: [{ id: 'session_01AbCdEfGhIjKlMnOp', title: SECRET, worker_status: 'running', session_status: 'running',
      connection_status: 'connected', environment_kind: 'bridge', last_message: { text: SECRET, role: 'assistant' } }] } },
  { queryKey: [SECRET], state: { dataUpdatedAt: 0, data: SECRET } },
] } });

test('the cache description names lists, fields and status values, and nothing a person wrote', () => {
  const text = describeCache(cache(), 1_000_000, '01abcdefghijklmnop').join('\n');
  for (const expected of ['chat_conversation_list', 'sessions_api_list_sessions', 'current_status: running×1 idle×1', 'is_starred',
    'worker_status: running×1', 'uuid ids: uuid×2', 'id ids: session_…×1', 'refreshed 50s ago', '{limit,starred}', 'appears in the cache 1 time'])
    assert.ok(text.includes(expected), `missing ${expected}\n${text}`);
  assert.ok(!text.includes('PRIVATE'), text);
  assert.ok(!text.includes('Acme') && !text.includes('weird key'), text);
  assert.ok(!text.includes('01AbCdEf') && !text.includes('3f2b1c9e'), 'ids themselves are never printed');
  assert.ok(describeCache({}, 1, undefined)[0].includes('no query list'));
});

test('status-style fields print values only when they are short code tokens', () => {
  const summary = summarizeRows([{ status: 'running', state: SECRET, kind: 'Has Spaces', type: 'x'.repeat(40), is_active: true, title: 'idle' }]);
  assert.deepEqual([...summary.states.keys()].sort(), ['is_active', 'status']);
  assert.equal(summary.states.get('status')?.get('running'), 1);
  assert.ok(summary.fields.has('title') && !summary.states.has('title'), 'a title is never treated as a status even if it looks like one');
});

test('a conversation is located by id and reported by structural path and status only', () => {
  const hits = findById(cache(), '01ABCDEFGHIJKLMNOP');
  assert.equal(hits.length, 1);
  assert.ok(hits[0].where.includes('matched in id') && hits[0].states.includes('worker_status=running'));
  assert.ok(!JSON.stringify(hits).includes('PRIVATE') && !JSON.stringify(hits).includes('01AbCd'));
  assert.equal(findById(cache(), 'not-present-anywhere').length, 0);
});

test('query keys and paths lose every user-specific part', () => {
  assert.deepEqual(keyShape(['list_things', 'session_01AbCdEfGh', 7, { org: SECRET }]), { name: 'list_things', rest: 'session_…, number, {org}' });
  assert.equal(keyShape([SECRET]).name, '<string>');
  assert.equal(keyShape(['3f2b1c9e-0000-4000-8000-000000000001']).name, '<uuid>');
  assert.equal(maskPath('local-agent-mode-sessions/3f2b1c9e-0000-4000-8000-000000000001/local_abcdef123456.json'),
    'local-agent-mode-sessions/<uuid>/local_<id>.json');
  assert.equal(maskPath('local-agent-mode-sessions/My Secret Project/notes for boss.md'), 'local-agent-mode-sessions/<name>/<name>.md');
  assert.equal(maskPath('IndexedDB/https_claude.ai_0.indexeddb.leveldb/000123.log'), 'IndexedDB/<name>.leveldb/<n>.log');
  assert.equal(maskPath('logs/sessions/metadata.json'), 'logs/sessions/metadata.json');
  assert.equal(maskPath('top-level-store'), 'top-level-store');
});

test('log growth is reduced to counts, bracket tags and fixed keywords', () => {
  const text = describeAppended(`2026-11-14 23:50:01 [info] [SessionManager] Turn completed for "${SECRET}"\n[warn] stream idle ${SECRET}\n`);
  assert.ok(text.startsWith('2 lines'));
  for (const expected of ['info×1', 'SessionManager×1', 'warn×1', 'turn×1', 'complete×1', 'stream×1', 'idle×1']) assert.ok(text.includes(expected), text);
  assert.ok(!text.includes('PRIVATE') && !text.includes('Acme'));
});

test('stores on disk are described by layout, field names and changes only', t => {
  const root = mkdtempSync(join(tmpdir(), 'task-island-chat-probe-')); t.after(() => rmSync(root, { recursive: true, force: true }));
  const dir = join(root, 'local-agent-mode-sessions', '3f2b1c9e-0000-4000-8000-000000000001', 'My Secret Project'); mkdirSync(dir, { recursive: true });
  const file = join(dir, 'local_abcdef123456.json');
  writeFileSync(file, JSON.stringify({ sessionId: 'local_abcdef123456', title: SECRET, status: 'running', isArchived: false, lastActivityAt: 1794700000123,
    cloudSessionId: 'session_01AbCdEfGhIjKlMnOp', initialMessage: SECRET }));
  writeFileSync(join(dir, `${SECRET}.txt`), SECRET);
  const store = join(root, 'local-agent-mode-sessions');
  const described = describeJsonStore(store, '01abcdefghijklmnop').join('\n');
  for (const expected of ['1 JSON records', 'title', 'status: running×1', 'isArchived: false×1', 'sessionId ids: local_…×1', 'this conversation is in 1 record'])
    assert.ok(described.includes(expected), described);
  assert.ok(!described.includes('PRIVATE') && !described.includes('Secret Project') && !described.includes('abcdef123456'), described);
  const state = recordState(store, '01abcdefghijklmnop');
  assert.ok(state.includes('status=running') && state.includes('lastActivityAt=#') && !state.includes('PRIVATE') && !state.includes('1794700000123'), state);
  const before = scan(root);
  appendFileSync(join(dir, `${SECRET}.txt`), 'more');
  writeFileSync(join(dir, 'new-file.jsonl'), 'x');
  const changed = [...changes(before, scan(root))].map(([path, change]) => `${path} ${change.grew}`).sort();
  assert.deepEqual(changed, ['local-agent-mode-sessions/<uuid>/<name>/<name>.jsonl (new) 1', 'local-agent-mode-sessions/<uuid>/<name>/<name>.txt 4']);
});
