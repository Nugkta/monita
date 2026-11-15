import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { ClaudeProvider } from '../monitor-probe/source/src/providers/claude/index';
import { readDesktopRecords, readLiveProcesses, validSessionId } from '../monitor-probe/source/src/providers/claude/catalog';
import { sessionFromRecord } from '../monitor-probe/source/src/providers/claude/projection';
import { toBridgeTask } from './bridge-core';
import type { Session, ProviderHealth } from '../monitor-probe/source/src/shared/types';

const A = 'local_aaaaaaaa-0000-4000-8000-000000000001';
const B = 'local_bbbbbbbb-0000-4000-8000-000000000002';
const DITTO = 'local_ditto_aaaaaaaa-0000-4000-8000-000000000003_g2';
const CLI = 'aaaaaaaa-0000-4000-8000-000000000001';
function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'task-island-claude-runtime-'));
  const desktop = join(root, 'desktop'), org = join(desktop, 'account', 'org');
  const config = join(root, 'config'), registry = join(config, 'sessions'), hooks = join(root, 'hooks');
  mkdirSync(org, { recursive: true }); mkdirSync(registry, { recursive: true }); mkdirSync(hooks);
  function record(id: string, extra: Record<string, unknown> = {}) {
    writeFileSync(join(org, id + '.json'), JSON.stringify({ sessionId: id, cliSessionId: CLI,
      title: 'Synthetic Claude task', cwd: '/synthetic/project', isArchived: false,
      createdAt: 1_000, lastActivityAt: 2_000, lastFocusedAt: 2_500,
      completedTurns: 1, lastAssistantUuid: CLI,
      initialMessage: 'PRIVATE_BODY', postTurnSummary: 'PRIVATE_BODY', ...extra }));
  }
  function process(pid: number, status: string, extra: Record<string, unknown> = {}) {
    writeFileSync(join(registry, pid + '.json'), JSON.stringify({ pid, entrypoint: 'claude-desktop',
      kind: 'interactive', hostSessionId: A, status, statusUpdatedAt: 3_000,
      unusedPayload: 'PRIVATE_BODY', ...extra }));
  }
  return { root, desktop, org, config, registry, hooks, record, process };
}

async function observer(t: test.TestContext, desktopRunning = true) {
  const f = fixture();
  let sessions: Session[] = [], health: ProviderHealth | undefined;
  const provider = new ClaudeProvider({ desktopDir: f.desktop, configDir: f.config,
    hooksDir: f.hooks, desktopRunning: async () => desktopRunning,
    processAlive: () => true, pollMs: 60_000 });
  t.after(() => { provider.stop(); rmSync(f.root, { recursive: true, force: true }); });
  const callbacks = { sessions: (value: Session[]) => { sessions = value; }, health: (value: ProviderHealth) => { health = value; } };
  return { f, provider, callbacks, sessions: () => sessions, health: () => health };
}

test('historical focus and results without current runtime cannot become live Read', async t => {
  const o = await observer(t);
  o.f.record(A);
  const before = readFileSync(join(o.f.org, A + '.json'));
  await o.provider.start(o.callbacks);
  assert.equal(o.sessions()[0].status, 'unknown');
  assert.equal(o.sessions()[0].evidence, 'unavailable');
  assert.equal(o.sessions()[0].attentionKey, null);
  assert.equal(o.health()?.state, 'degraded');
  assert.deepEqual(o.health()?.disconnectedSessionIds, ['claude:' + A]);
  assert.equal(toBridgeTask(o.sessions()[0], 'degraded')?.state, 'unknown');
  assert.ok(!JSON.stringify(o.sessions()).includes('PRIVATE_BODY'));
  assert.deepEqual(readFileSync(join(o.f.org, A + '.json')), before);
});

test('a matching observed idle runtime can establish source Read; busy and waiting take precedence', async t => {
  const o = await observer(t);
  o.f.record(A); o.f.process(42, 'idle');
  await o.provider.start(o.callbacks);
  assert.equal(o.sessions()[0].status, 'read');
  assert.equal(o.sessions()[0].evidence, 'live');
  assert.equal(o.sessions()[0].attentionKey, 'result:1');
  assert.equal(o.health()?.state, 'live');
  o.f.process(42, 'busy'); await o.provider.refresh();
  assert.equal(o.sessions()[0].status, 'running');
  assert.equal(o.sessions()[0].attentionKey, null);
  o.f.process(42, 'waiting', { waitingFor: 'permission prompt' }); await o.provider.refresh();
  assert.equal(o.sessions()[0].awaitingInput, true);
  assert.equal(toBridgeTask(o.sessions()[0], 'live')?.state, 'input');
});

test('unrecognized runtime status does not fall back to an old Read result', async t => {
  const o = await observer(t);
  o.f.record(A); o.f.process(42, 'new-unsupported-status');
  await o.provider.start(o.callbacks);
  assert.equal(o.sessions()[0].status, 'unknown');
  assert.equal(o.sessions()[0].attentionKey, null);
  assert.equal(o.health()?.state, 'degraded');
});

test('a missing or unreadable registry does not imply idle or completion', async t => {
  const o = await observer(t);
  o.f.record(A); o.f.process(42, 'idle');
  await o.provider.start(o.callbacks);
  assert.equal(o.sessions()[0].status, 'read');
  writeFileSync(join(o.f.registry, '42.json'), '{partial'); await o.provider.refresh();
  assert.equal(o.sessions()[0].status, 'unknown');
  assert.equal(o.sessions()[0].evidence, 'unavailable');
  rmSync(o.f.registry, { recursive: true }); await o.provider.refresh();
  assert.equal(o.sessions()[0].status, 'unknown');
  assert.equal(o.health()?.state, 'degraded');
});

test('covered and uncovered visible records produce partial health without discarding valid running state', async t => {
  const o = await observer(t);
  o.f.record(A); o.f.record(B); o.f.process(42, 'busy');
  await o.provider.start(o.callbacks);
  assert.equal(o.sessions().find(s => s.externalId === A)?.status, 'running');
  assert.equal(o.sessions().find(s => s.externalId === B)?.status, 'unknown');
  assert.equal(o.health()?.state, 'degraded');
  assert.deepEqual(o.health()?.disconnectedSessionIds, ['claude:' + B]);
});

test('desktop absence still invalidates otherwise idle observations', async t => {
  const o = await observer(t, false);
  o.f.record(A); o.f.process(42, 'idle');
  await o.provider.start(o.callbacks);
  assert.equal(o.sessions()[0].status, 'unknown');
  assert.equal(o.health()?.state, 'offline');
});

test('archived cached records do not degrade visible coverage', async t => {
  const o = await observer(t);
  o.f.record(A); o.f.record(B, { isArchived: true }); o.f.process(42, 'idle');
  o.provider.track([A, B]);
  await o.provider.start(o.callbacks);
  assert.equal(o.sessions().find(s => s.externalId === B)?.status, 'unknown');
  assert.equal(o.health()?.state, 'live');
  assert.equal(toBridgeTask(o.sessions().find(s => s.externalId === B)!, 'live'), null);
});

test('current ditto generation IDs survive record discovery and runtime association', t => {
  const f = fixture(); t.after(() => rmSync(f.root, { recursive: true, force: true }));
  f.record(DITTO); f.process(42, 'busy', { hostSessionId: DITTO });
  assert.equal(validSessionId(DITTO), true);
  for (const bad of ['local_../escape', 'local_a?x=1', 'local_a/b', 'local_', 'local_' + 'x'.repeat(129)])
    assert.equal(validSessionId(bad), false);
  const record = readDesktopRecords(f.desktop)[0];
  const live = readLiveProcesses(f.registry, () => true);
  assert.equal(record.sessionId, DITTO);
  assert.equal(live.desktop.get(DITTO)?.status, 'busy');
  assert.equal(sessionFromRecord(record, live.desktop.get(DITTO), true).status, 'running');
});

test('SSH PID, turn edges and wrap-up summaries alone cannot prove a running or finished task', async t => {
  const o = await observer(t);
  o.f.record(A, { sshConfig: { hostname: 'synthetic-host' }, sshRemoteProcessId: 12345,
    lastUserFrameAt: Date.now(), lastTurnEdgeAt: Date.now(), turnWrapUp: { description: 'PRIVATE_BODY' } });
  await o.provider.start(o.callbacks);
  assert.equal(o.sessions()[0].status, 'unknown');
  assert.equal(o.sessions()[0].attentionKey, null);
  assert.ok(!JSON.stringify(o.sessions()).includes('PRIVATE_BODY'));
});

test('an SSH task with no local runtime entry still reports each finished turn from its own record', async t => {
  const o = await observer(t);
  o.f.record(A, { sshConfig: { hostname: 'synthetic-host' }, sshRemoteProcessId: 12345, completedTurns: 3 });
  await o.provider.start(o.callbacks);
  const first = toBridgeTask(o.sessions()[0], 'degraded')!;
  assert.equal(o.sessions()[0].status, 'unknown');
  assert.equal(o.sessions()[0].attentionKey, null);
  assert.equal(first.state, 'unknown'); assert.equal(first.resultKey, 'result:3');
  assert.equal(first.completionTracking, 'turn-record'); assert.equal(first.availabilityReason, 'turn-record-only');
  o.f.record(A, { sshConfig: { hostname: 'synthetic-host' }, completedTurns: 4, lastActivityAt: 9_000 });
  await o.provider.refresh();
  const next = toBridgeTask(o.sessions()[0], 'degraded')!;
  assert.equal(next.state, 'unknown'); assert.equal(next.resultKey, 'result:4');
  o.f.record(A, { completedTurns: 4, error: 'PRIVATE_BODY', errorAt: 9_500 });
  await o.provider.refresh();
  assert.equal(toBridgeTask(o.sessions()[0], 'degraded')?.resultKey, 'error:9500');
  assert.ok(!JSON.stringify(o.sessions()).includes('PRIVATE_BODY'));
  assert.ok(!JSON.stringify(o.sessions()).includes('synthetic-host'));
});

test('a task with no finished turn is tracked, and an interrupted turn adds no result', async t => {
  const o = await observer(t);
  o.f.record(A, { completedTurns: 0, lastAssistantUuid: undefined });
  await o.provider.start(o.callbacks);
  const none = toBridgeTask(o.sessions()[0], 'degraded')!;
  assert.equal(none.resultKey, null); assert.equal(none.completionTracking, 'turn-record');
  // Activity and a new assistant message without a completed-turn increment is not a result.
  o.f.record(A, { completedTurns: 0, lastActivityAt: 8_000, lastTurnCutShort: true });
  await o.provider.refresh();
  assert.equal(toBridgeTask(o.sessions()[0], 'degraded')?.resultKey, null);
});

test('a record that disappears or is unreadable stops vouching for a turn', async t => {
  const o = await observer(t);
  o.f.record(A, { completedTurns: 2 });
  o.provider.track([A]);
  await o.provider.start(o.callbacks);
  assert.equal(o.sessions()[0].recordedResultKey, 'result:2');
  writeFileSync(join(o.f.org, A + '.json'), '{partial'); await o.provider.refresh();
  assert.equal(o.sessions()[0].recordedResultKey, undefined);
  assert.equal(toBridgeTask(o.sessions()[0], 'degraded')?.completionTracking, undefined);
  rmSync(join(o.f.org, A + '.json')); await o.provider.refresh();
  assert.equal(o.sessions()[0].recordedResultKey, undefined);
  o.f.record(A, { completedTurns: 3 }); await o.provider.refresh();
  assert.equal(o.sessions()[0].recordedResultKey, 'result:3');
});

test('with the desktop closed the record still names the last finished turn but no runtime state', async t => {
  const o = await observer(t, false);
  o.f.record(A, { completedTurns: 5 }); o.f.process(42, 'busy');
  await o.provider.start(o.callbacks);
  const task = toBridgeTask(o.sessions()[0], 'offline')!;
  assert.equal(task.state, 'unknown'); assert.equal(task.resultKey, 'result:5');
  assert.equal(task.availabilityReason, 'source-offline');
});

test('a live local runtime and the record agree on one identity per turn', async t => {
  const o = await observer(t);
  o.f.record(A, { completedTurns: 2 }); o.f.process(42, 'busy');
  await o.provider.start(o.callbacks);
  const running = toBridgeTask(o.sessions()[0], 'live')!;
  assert.equal(running.state, 'running'); assert.equal(running.resultKey, 'result:2');
  o.f.record(A, { completedTurns: 3, lastActivityAt: 9_000 }); o.f.process(42, 'idle');
  await o.provider.refresh();
  const done = toBridgeTask(o.sessions()[0], 'live')!;
  assert.equal(done.state, 'review'); assert.equal(done.resultKey, 'result:3');
  assert.equal(o.sessions()[0].attentionKey, o.sessions()[0].recordedResultKey);
});

test('unchanged records are not parsed again, changed ones are, and only ids leave the bridge list', t => {
  const f = fixture(); t.after(() => rmSync(f.root, { recursive: true, force: true }));
  f.record(A, { completedTurns: 1, bridgeSessionIds: ['session_shared-1', 'cse_shared-2', 'PRIVATE_BODY', 7, 'session_bad/../x'] });
  const first = readDesktopRecords(f.desktop)[0];
  assert.deepEqual(first.bridgeSessionIds, ['session_shared-1', 'cse_shared-2']);
  assert.equal(readDesktopRecords(f.desktop)[0], first, 'same parsed object while the file is unchanged');
  f.record(A, { completedTurns: 22 });
  const second = readDesktopRecords(f.desktop)[0];
  assert.notEqual(second, first); assert.equal(second.completedTurns, 22);
  assert.deepEqual(second.bridgeSessionIds, []);
  rmSync(join(f.org, A + '.json'));
  assert.equal(readDesktopRecords(f.desktop).length, 0);
  assert.equal(sessionFromRecord(first, undefined, true).remoteAliases?.length, 2);
});
