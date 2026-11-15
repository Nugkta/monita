import test from 'node:test';
import assert from 'node:assert/strict';
import { CodexProvider } from '../source/src/providers/codex/index';
import type { Session } from '../source/src/shared/types';

const id = 'aaaaaa';
const turn = { turnId: 'turn-1', status: 'inProgress', turnStartedAtMs: 1 };
function state13(overrides: Record<string, any> = {}) {
  return {
    id, title: 'Synthetic task', cwd: null,
    threadRuntimeStatus: { type: 'active', activeFlags: [] },
    hasUnreadTurn: false, requests: [], turns: [],
    turnHistory: { kind: 'canonical', history: {
      generation: 0, isComplete: true,
      entitiesByKey: { slot1: { ...turn } },
      islands: [{ id: 'island-1', entries: [{ key: 'entry-1', value: 'slot1' }],
        olderBoundary: { status: 'exhausted' }, newerBoundary: { status: 'exhausted' } }],
    } },
    ...overrides,
  };
}
function fixture() {
  // Constructor and direct message handling only: no start(), socket, watcher,
  // process query, source files, or real conversation data are used by tests.
  const provider = new CodexProvider('/tmp/synthetic-provider-only', '/tmp/synthetic-hooks-only') as any;
  const base: Session = { id: `codex:${id}`, provider: 'codex', externalId: id, hostId: 'local',
    title: 'Synthetic task', directory: null, status: 'unknown', detail: '',
    updatedAt: 0, observedAt: 0, evidence: 'unavailable', attentionKey: null, archived: false };
  const resyncs: string[] = [];
  const health: any[] = [];
  provider.tracked = [id];
  // refreshNow normally establishes this association from the local catalog.
  provider.hosts.set(id, 'local');
  provider.sessions.set(id, base);
  provider.connected = true;
  provider.transport = { resync: (value: string) => resyncs.push(value), stop() {}, track() {}, trackThreads() {} };
  provider.callbacks = { sessions() {}, health: (value: any) => health.push(value) };
  const send = (change: any, version = 13, owner: any = 'owner-a', extra: any = {}) =>
    provider.handleMessage({ method: 'thread-stream-state-changed', version,
      sourceClientId: owner, params: { hostId: 'local', conversationId: id, change, ...extra } });
  return {
    provider, resyncs, health, send,
    snapshot: (state = state13(), revision = 1, version = 13, owner: any = 'owner-a') =>
      send({ type: 'snapshot', revision, conversationState: state }, version, owner),
    patch: (patches: any[], baseRevision = 1, revision = 2, version = 13, owner = 'owner-a') =>
      send({ type: 'patches', baseRevision, revision, patches }, version, owner),
    read: (unread: any, owner: any = 'owner-a', version = 3) =>
      provider.handleMessage({ method: 'thread-read-state-changed', version,
        sourceClientId: owner, params: { hostId: 'local', conversationId: id, hasUnreadTurn: unread } }),
    session: () => provider.sessions.get(id) as Session,
  };
}

test('v13 snapshot and ordered updates distinguish working, input, unread result and source read', () => {
  const f = fixture();
  f.snapshot(state13({ prompt: 'PRIVATE_BODY', responses: ['PRIVATE_BODY'] }));
  assert.equal(f.session().status, 'running');
  assert.equal(f.provider.live.get(id).version, 13);
  f.patch([{ op: 'replace', path: ['requests'], value: [{ id: 'request-1',
    method: 'item/requestApproval', params: { prompt: 'PRIVATE_BODY' } }] }]);
  assert.equal(f.session().awaitingInput, true);
  assert.equal(f.session().attentionKey, 'request:request-1');
  f.patch([
    { op: 'replace', path: ['requests'], value: [] },
    { op: 'replace', path: ['threadRuntimeStatus'], value: { type: 'idle' } },
    { op: 'replace', path: ['hasUnreadTurn'], value: true },
    { op: 'replace', path: ['turnHistory', 'history', 'entitiesByKey', 'slot1', 'status'], value: 'completed' },
  ], 2, 3);
  assert.equal(f.session().status, 'review');
  assert.equal(f.session().awaitingInput, false);
  assert.equal(f.session().attentionKey, 'result:turn-1');
  assert.ok(!JSON.stringify(f.provider.live.get(id).state).includes('PRIVATE_BODY'));
  f.read(false);
  assert.equal(f.session().status, 'read');
  assert.equal(f.session().attentionKey, 'result:turn-1');
  assert.deepEqual(f.resyncs, []);
});

test('v13 gaps invalidate current state, request a new snapshot, then recover', () => {
  const f = fixture();
  f.snapshot();
  f.patch([{ op: 'replace', path: ['hasUnreadTurn'], value: true }], 4, 5);
  assert.equal(f.session().status, 'unknown');
  assert.equal(f.session().evidence, 'unavailable');
  assert.equal(f.session().attentionKey, null);
  assert.deepEqual(f.resyncs, [id]);
  f.snapshot(state13(), 6);
  assert.equal(f.session().status, 'running');
  f.patch([{ op: 'replace', path: ['threadRuntimeStatus'], value: { type: 'idle' } }], 5, 6);
  assert.equal(f.session().status, 'running', 'duplicate/outdated revisions do not replace current state');
});

test('v13 rejects patches before a snapshot, from another owner, or from another stream version', () => {
  for (const mode of ['no-snapshot', 'wrong-owner', 'wrong-version']) {
    const f = fixture();
    if (mode !== 'no-snapshot') f.snapshot();
    f.patch([{ op: 'replace', path: ['hasUnreadTurn'], value: true }], 1, 2,
      mode === 'wrong-version' ? 11 : 13, mode === 'wrong-owner' ? 'owner-b' : 'owner-a');
    assert.equal(f.session().status, 'unknown', mode);
    assert.equal(f.provider.live.has(id), false, mode);
    assert.deepEqual(f.resyncs, [id], mode);
  }
});

test('a fresh validated snapshot can change owners without accepting old-owner read receipts', () => {
  const f = fixture();
  f.snapshot(state13(), 20);
  f.snapshot(state13({ threadRuntimeStatus: { type: 'idle' }, hasUnreadTurn: true }), 1, 13, 'owner-b');
  assert.equal(f.session().status, 'review');
  f.read(false, 'owner-a');
  assert.equal(f.session().status, 'unknown');
  assert.equal(f.session().attentionKey, null);
  assert.deepEqual(f.resyncs, [id]);
  f.snapshot(state13({ threadRuntimeStatus: { type: 'idle' }, hasUnreadTurn: true }), 1, 13, 'owner-b');
  f.read(false, 'owner-b');
  assert.equal(f.session().status, 'read');
});

test('v13 read receipts with no sender, malformed data, or unsupported versions require resync', () => {
  for (const [unread, owner, version] of [[false, null, 3], ['false', 'owner-a', 3], [false, 'owner-a', 4]]) {
    const f = fixture();
    f.snapshot();
    f.read(unread, owner, version as number);
    assert.equal(f.session().status, 'unknown');
    assert.deepEqual(f.resyncs, [id]);
  }
});

test('v13 validates snapshot shapes, identity, revisions and source owners before exposing states', () => {
  for (const [state, revision, owner] of [
    [state13({ requests: {} }), 1, 'owner-a'],
    [state13({ threadRuntimeStatus: { type: 'unexpected' } }), 1, 'owner-a'],
    [state13({ hasUnreadTurn: 'false' }), 1, 'owner-a'],
    [state13({ id: 'bbbbbb' }), 1, 'owner-a'],
    [state13(), -1, 'owner-a'],
    [state13(), 1, ''],
  ] as const) {
    const f = fixture();
    f.snapshot(state as any, revision, 13, owner);
    assert.equal(f.session().status, 'unknown');
    assert.equal(f.provider.live.has(id), false);
    assert.deepEqual(f.resyncs, [id]);
  }
});

test('v13 validates patched identity and state shape and never publishes unsupported running state', () => {
  for (const patches of [
    [{ op: 'replace', path: ['id'], value: 'bbbbbb' }],
    [{ op: 'replace', path: ['threadRuntimeStatus'], value: { type: 'unexpected' } }],
    [{ op: 'replace', path: ['hasUnreadTurn'], value: 'false' }],
    [{ op: 'replace', path: [], value: state13({ id: 'bbbbbb' }) }],
  ]) {
    const f = fixture();
    f.snapshot();
    f.patch(patches);
    assert.equal(f.session().status, 'unknown');
    assert.equal(f.session().attentionKey, null);
    assert.deepEqual(f.resyncs, [id]);
  }
});

test('unrecognized stream versions invalidate, while legacy11 and legacy receipt3 remain supported', () => {
  const f = fixture();
  f.snapshot();
  f.send({ type: 'snapshot', revision: 2, conversationState: state13() }, 14);
  assert.equal(f.session().status, 'unknown');
  assert.equal(f.health.at(-1).state, 'degraded');
  const legacy = { id, threadRuntimeStatus: { type: 'idle' }, hasUnreadTurn: true,
    requests: [], turns: [{ ...turn, status: 'completed' }] };
  f.snapshot(legacy as any, 3, 11);
  assert.equal(f.session().status, 'review');
  assert.equal(f.session().attentionKey, 'result:turn-1');
  f.provider.handleMessage({ method: 'thread-read-state-changed', version: 3,
    params: { hostId: 'local', threadId: id, hasUnreadTurn: false } });
  assert.equal(f.session().status, 'read');
});

test('unknown canonical head retains runtime/read observation but does not invent a completion identity', () => {
  const f = fixture();
  const partial = state13({ threadRuntimeStatus: { type: 'idle' }, hasUnreadTurn: true });
  partial.turns = [{ ...turn, turnId: 'stale-legacy', turnStartedAtMs: 999999 }] as any;
  partial.turnHistory.history.islands[0].newerBoundary.status = 'available';
  f.snapshot(partial);
  assert.equal(f.session().status, 'review');
  assert.equal(f.session().evidence, 'live');
  assert.equal(f.session().attentionKey, null);
});

test('an old hook cannot override current desktop state when the canonical head or timestamp is unverified', () => {
  for (const missing of ['head', 'timestamp']) {
    const f = fixture();
    const current = state13({ threadRuntimeStatus: { type: 'idle' }, hasUnreadTurn: false });
    current.turnHistory.history.entitiesByKey.slot1.status = 'completed';
    if (missing === 'head') current.turnHistory.history.islands[0].newerBoundary.status = 'available';
    else delete (current.turnHistory.history.entitiesByKey.slot1 as any).turnStartedAtMs;
    f.provider.hookRecords.set(id, { version: 1, sessionId: id,
      completion: { event: 'TurnComplete', turnId: 'older-hook-turn', at: Date.now() + 1 } });
    f.snapshot(current);
    assert.equal(f.session().status, 'read', missing);
    assert.equal(f.session().evidence, 'live', missing);
    if (missing === 'head') assert.equal(f.session().attentionKey, null);
    else assert.equal(f.session().attentionKey, 'result:turn-1');
  }
});

test('untracked messages are ignored and source-window disconnect invalidates its owned state', () => {
  const f = fixture();
  const untracked = 'untracked1';
  f.send({ type: 'snapshot', revision: 1, conversationState: state13({ id: untracked }) },
    13, 'owner-a', { hostId: 'remote', conversationId: untracked });
  assert.equal(f.provider.live.has(id), false);
  assert.equal(f.provider.live.has(untracked), false);
  assert.equal(f.provider.sessions.has(untracked), false);
  f.snapshot();
  f.provider.handleMessage({ method: 'client-status-changed', params: { status: 'disconnected', clientId: 'owner-b' } });
  assert.equal(f.session().status, 'running');
  f.provider.handleMessage({ method: 'client-status-changed', params: { status: 'disconnected', clientId: 'owner-a' } });
  assert.equal(f.session().status, 'unknown');
  assert.equal(f.session().evidence, 'unavailable');
});

test('a conflicting host for an existing catalog identity fails closed without mixing either stream', () => {
  const f = fixture();
  f.snapshot();
  assert.equal(f.session().status, 'running');
  f.send({ type: 'snapshot', revision: 2, conversationState: state13() },
    13, 'remote-owner', { hostId: 'remote' });
  assert.equal(f.provider.live.has(id), false);
  assert.equal(f.session().status, 'unknown');
  assert.equal(f.session().evidence, 'unavailable');
  assert.equal(f.session().openable, false);
  assert.equal(f.session().terminalResumeAllowed, false);
  assert.equal(f.provider.hostCollisions.has(id), true);
  f.snapshot(state13(), 3);
  assert.equal(f.provider.live.has(id), false);
  assert.equal(f.session().status, 'unknown', 'neither host restores a conflicted identity');
  assert.deepEqual(f.resyncs, [], 'a conflict cannot resync through an arbitrary host');
});
