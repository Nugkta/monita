import test from 'node:test';
import assert from 'node:assert/strict';
import { projectHerdr } from '../monitor-probe/source/src/providers/herdr/projection';

// Shaped like a real `herdr-core events --json` snapshot row (synthetic values).
function term(overrides: Record<string, unknown> = {}) {
  return { address: 'build-box/t16', state: 'live', status: { app: 'claude-code', state: 'done' }, turn: 3,
    labels: { 'herdr.seen': '3', where: 'project / 2' }, title: 'T', cwd: '/w', foreground: { pid: 4242 },
    status_ms: 500, created_ms: 100, ...overrides };
}
const connected = [{ name: 'build-box', state: 'connected' }];
const one = (row: Record<string, unknown>, machines: unknown = connected) => {
  const sessions = projectHerdr([row], machines, 1_000);
  assert.ok(sessions);
  assert.equal(sessions.length, 1);
  return sessions[0];
};
const status = (state: string, turn = 3, seen: string | null = '3') =>
  term({ status: { app: 'claude-code', state }, turn, labels: seen === null ? { where: 'x' } : { 'herdr.seen': seen, where: 'x' } });

test('maps each herdr status', () => {
  assert.equal(one(status('working')).status, 'running');
  const blocked = one(status('blocked'));
  assert.equal(blocked.status, 'running');
  assert.equal(blocked.awaitingInput, true);
  const done = one(status('done', 4, '3'));
  assert.equal(done.status, 'review');
  assert.equal(done.detail, 'New result in Herdr');
  const error = one(status('error', 4, '3'));
  assert.equal(error.status, 'review');
  assert.equal(error.detail, 'Agent reported an error');
  assert.equal(one(status('done', 3, '3')).status, 'read');
  assert.equal(one(status('error', 3, '3')).status, 'read');
  assert.equal(one(status('idle', 5, '0')).status, 'read');
  assert.equal(one(status('weird', 5, '0')).status, 'read');
  assert.equal(one(status('done', 2, null)).status, 'review');
  assert.equal(one(status('done', 3, '3')).detail, 'Viewed in Herdr');
  for (const s of ['working', 'done', 'idle']) {
    assert.equal(one(status(s, 4, '3')).attentionKey, null);
    assert.notEqual(one(status(s)).awaitingInput, true);
  }
});

test('excludes shells and finished terminals', () => {
  assert.deepEqual(projectHerdr([term({ status: null }), term({ state: 'finished' }),
    term({ status: { state: 'done' } })], connected, 1_000), []);
});

test('titles and identity', () => {
  const remote = one(term());
  assert.equal(remote.id, 'herdr:build-box/t16');
  assert.equal(remote.provider, 'herdr');
  assert.equal(remote.externalId, 'build-box/t16');
  assert.equal(remote.title, 'build-box · T');
  assert.equal(remote.hostId, 'build-box');
  assert.equal(remote.terminalPid, null);
  assert.equal(remote.directory, '/w');
  assert.equal(remote.updatedAt, 500);
  assert.equal(remote.observedAt, 1_000);
  assert.equal(remote.evidence, 'live');
  assert.equal(remote.archived, false);
  const local = one(term({ address: 't3' }), []);
  assert.equal(local.id, 'herdr:t3');
  assert.equal(local.title, 'T');
  assert.equal(local.hostId, 'local');
  assert.equal(local.terminalPid, 4242);
  assert.equal(local.evidence, 'live');
  assert.equal(one(term({ title: '' })).title, 'build-box · project / 2');
  assert.equal(one(term({ address: 't3', title: null, labels: {} }), []).title, 'Herdr task');
  assert.equal(one(term({ address: 't3', foreground: null }), []).terminalPid, null);
  assert.equal(one(term({ status_ms: null }), connected).updatedAt, 100);
});

test('disconnected machine is unavailable', () => {
  assert.equal(one(term(), [{ name: 'build-box', state: 'disconnected' }]).evidence, 'unavailable');
  assert.equal(one(term(), []).evidence, 'unavailable');
  assert.equal(one(term(), 'not-an-array').evidence, 'unavailable');
});

test('malformed input fails closed', () => {
  assert.equal(projectHerdr({}, [], 1), null);
  assert.equal(projectHerdr(undefined, [], 1), null);
  const rows = [null, 7, 'x', term({ address: '../x' }), term({ address: 't' }), term({ address: 'a/b/t1' }),
    term({ address: 42 }), term({ turn: 'three' }), term({ labels: null }), term({ address: 't9' })];
  const sessions = projectHerdr(rows, connected, 1);
  assert.ok(sessions);
  assert.deepEqual(sessions.map(s => s.externalId).sort(), ['build-box/t16', 't9']);
});

// ---- HerdrProvider against a fake herdr-core binary ----
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync, appendFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HerdrProvider } from '../monitor-probe/source/src/providers/herdr/index';
import { createServer, type Server } from 'node:net';
import type { ProviderHealth, Session } from '../monitor-probe/source/src/shared/types';

const FAKE = `#!/bin/sh
D="$(dirname "$0")"
case "$1" in
  ls) cat "$D/ls.json" ;;
  events)
    echo $$ >> "$D/pids"
    cat "$D/snapshot.json"
    exec tail -n 0 -F "$D/stream" 2>/dev/null ;;
  *) exit 2 ;;
esac
`;
function fake() {
  const dir = mkdtempSync(join(tmpdir(), 'monita-herdr-'));
  const binary = join(dir, 'herdr-core');
  writeFileSync(binary, FAKE); chmodSync(binary, 0o700);
  writeFileSync(join(dir, 'stream'), '');
  writeFileSync(join(dir, 'ls.json'), JSON.stringify({ machines: connected }));
  const snapshot = (state: string) => writeFileSync(join(dir, 'snapshot.json'),
    JSON.stringify({ channel: null, seq: 1, terminals: [term({ status: { app: 'claude-code', state }, turn: 4 })] }) + '\n');
  snapshot('done');
  const pids = () => existsSync(join(dir, 'pids'))
    ? readFileSync(join(dir, 'pids'), 'utf8').trim().split('\n').map(Number) : [];
  const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };
  const socket = join(dir, 'core.sock');
  let server: Server | null = null;
  const core = (up: boolean) => new Promise<void>(resolve => {
    if (up && !server) { server = createServer(c => c.end()); server.listen(socket, () => resolve()); }
    else if (!up && server) { server.close(() => resolve()); server = null; }
    else resolve();
  });
  return { dir, binary, socket, core, snapshot, pids, alive,
    emit: (lines: number) => appendFileSync(join(dir, 'stream'), '{"method":"event"}\n'.repeat(lines)),
    cleanup: () => { server?.close(); rmSync(dir, { recursive: true, force: true }); } };
}
function observe(provider: HerdrProvider) {
  const seen = { health: [] as ProviderHealth['state'][], sessions: null as Session[] | null };
  const started = provider.start({
    health: h => { seen.health.push(h.state); },
    sessions: s => { seen.sessions = s; },
  });
  return { seen, started };
}
async function until(check: () => boolean, ms = 2_000) {
  const end = Date.now() + ms;
  while (!check()) {
    if (Date.now() > end) throw new Error('timed out waiting for condition');
    await new Promise(r => setTimeout(r, 10));
  }
}
const pause = (ms: number) => new Promise(r => setTimeout(r, ms));
const options = (f: { binary: string; socket: string }, extra = {}) =>
  ({ binary: f.binary, socket: f.socket, pollMs: 200, debounceMs: 20, restartMs: 100, ...extra });

test('reports live sessions from snapshot', async () => {
  const f = fake(); await f.core(true); const provider = new HerdrProvider(options(f));
  try {
    const { seen, started } = observe(provider); await started;
    await until(() => seen.health.at(-1) === 'live');
    assert.equal(seen.sessions?.length, 1);
    assert.equal(seen.sessions?.[0].status, 'review');
    assert.equal(provider.id, 'herdr');
  } finally { provider.stop(); f.cleanup(); }
});

test('stream lines trigger refresh', async () => {
  const f = fake(); await f.core(true); const provider = new HerdrProvider(options(f, { pollMs: 60_000 }));
  try {
    const { seen, started } = observe(provider); await started;
    await until(() => seen.health.at(-1) === 'live');
    await pause(100); // let the fake's `tail -n 0` open the file before appending
    f.snapshot('working'); f.emit(1);
    await until(() => seen.sessions?.[0]?.status === 'running', 1_000);
  } finally { provider.stop(); f.cleanup(); }
});

test('bursts coalesce', async () => {
  const f = fake(); await f.core(true); const provider = new HerdrProvider(options(f, { pollMs: 60_000 }));
  try {
    const { seen, started } = observe(provider); await started;
    await until(() => seen.health.at(-1) === 'live');
    await pause(100);
    const before = f.pids().length;
    f.emit(20);
    await pause(400);
    const after = f.pids().length;
    assert.ok(after - before >= 1, 'a burst still refreshes');
    assert.ok(after - before <= 2, `expected at most 2 snapshots, got ${after - before}`);
  } finally { provider.stop(); f.cleanup(); }
});

test('stream exit degrades and restarts', async () => {
  const f = fake(); await f.core(true); const provider = new HerdrProvider(options(f, { pollMs: 60_000, restartMs: 300 }));
  try {
    const { seen, started } = observe(provider); await started;
    await until(() => seen.health.at(-1) === 'live');
    await pause(100);
    const stream = f.pids().filter(f.alive);
    assert.equal(stream.length, 1, 'only the trigger stream stays running');
    process.kill(stream[0], 'SIGTERM');
    await until(() => seen.health.at(-1) === 'degraded');
    await until(() => seen.health.at(-1) === 'live', 2_000);
    assert.equal(f.pids().filter(f.alive).length, 1);
  } finally { provider.stop(); f.cleanup(); }
});

test('missing binary reports offline', async () => {
  const f = fake(); await f.core(true);
  const provider = new HerdrProvider(options({ binary: '/nonexistent/herdr-core', socket: f.socket }));
  try {
    const { seen, started } = observe(provider); await started;
    await until(() => seen.health.at(-1) === 'offline');
    assert.deepEqual(seen.sessions, []);
  } finally { provider.stop(); f.cleanup(); }
});

test('unreadable snapshot degrades and keeps last sessions as unavailable', async () => {
  const f = fake(); await f.core(true); const provider = new HerdrProvider(options(f));
  try {
    const { seen, started } = observe(provider); await started;
    await until(() => seen.health.at(-1) === 'live');
    writeFileSync(join(f.dir, 'snapshot.json'), '{"terminals":"nope"}\n');
    await until(() => seen.health.at(-1) === 'degraded', 1_000);
    assert.equal(seen.sessions?.length, 1);
    assert.equal(seen.sessions?.[0].evidence, 'unavailable', 'stale rows never read as live');
  } finally { provider.stop(); f.cleanup(); }
});

test('stop leaves no herdr-core processes behind', async () => {
  const f = fake(); await f.core(true); const provider = new HerdrProvider(options(f));
  try {
    const { seen, started } = observe(provider); await started;
    await until(() => seen.health.at(-1) === 'live');
    provider.stop();
    await until(() => f.pids().every(pid => !f.alive(pid)), 1_000);
    const count = f.pids().length;
    await pause(300);
    assert.equal(f.pids().length, count, 'no snapshots after stop');
  } finally { provider.stop(); f.cleanup(); }
});

// ---- Bridge ----
import { BridgeState, toBridgeTask } from './bridge-core';

const herdrSession = (overrides: Partial<Session> = {}) => ({ ...one(term()), ...overrides });

test('herdr tasks are whitelisted without url or result', () => {
  const review = toBridgeTask(herdrSession({ status: 'review', detail: 'New result in Herdr' }), 'live', 1_000)!;
  assert.equal(review.id, 'herdr:build-box/t16');
  assert.equal(review.provider, 'herdr');
  assert.equal(review.state, 'review');
  assert.equal(review.resultKey, null);
  assert.equal(review.sourceURL, null);
  assert.equal(review.title, 'build-box · T');
  assert.equal(toBridgeTask(herdrSession({ status: 'review', detail: 'Agent reported an error' }), 'live', 1_000)?.state, 'error');
  assert.equal(toBridgeTask(herdrSession({ status: 'running', awaitingInput: true }), 'live', 1_000)?.state, 'input');
  assert.equal(toBridgeTask(herdrSession({ status: 'running' }), 'live', 1_000)?.state, 'running');
  assert.equal(toBridgeTask(herdrSession({ status: 'read' }), 'live', 1_000)?.state, 'read');
  assert.equal(toBridgeTask(herdrSession({ evidence: 'unavailable' }), 'live', 1_000)?.state, 'unknown');
  assert.equal(toBridgeTask(herdrSession({ externalId: '../t1' }), 'live', 1_000), null);
  assert.equal(toBridgeTask(herdrSession({ attentionKey: 'result:1', status: 'review' }), 'live', 1_000)?.resultKey, null);
});

const cliSession = (pid: number): Session => ({ id: 'claude:cli', provider: 'claude',
  externalId: 'cli_0b658f2a-4487-43f8-b6a4-292dc87388bc', title: 'Claude CLI', directory: null, status: 'running',
  detail: '', updatedAt: 1, observedAt: 1, evidence: 'live', attentionKey: null, archived: false, terminalPid: pid });

test('local herdr terminal hides the matching claude cli task', () => {
  const ids = (herdrPid: number, address = 't3') => {
    const state = new BridgeState(['claude', 'herdr']);
    state.setHealth('claude', { state: 'live' }); state.setHealth('herdr', { state: 'live' });
    state.setSessions('claude', [cliSession(4242)], () => {});
    state.setSessions('herdr', [herdrSession({ externalId: address, id: `herdr:${address}`, terminalPid: herdrPid })], () => {});
    return state.snapshot(1_000).tasks.map(t => t.id).sort();
  };
  assert.deepEqual(ids(4242), ['herdr:t3']);
  assert.deepEqual(ids(9999), ['claude:cli_0b658f2a-4487-43f8-b6a4-292dc87388bc', 'herdr:t3']);
  assert.deepEqual(ids(4242, 'build-box/t3'), ['claude:cli_0b658f2a-4487-43f8-b6a4-292dc87388bc', 'herdr:build-box/t3']);
});

test('a stopped herdr-core is never started by Monita', async () => {
  const f = fake(); const provider = new HerdrProvider(options(f));
  try {
    const { seen, started } = observe(provider); await started;
    await until(() => seen.health.at(-1) === 'offline');
    assert.deepEqual(seen.sessions, []);
    await pause(400);
    assert.equal(f.pids().length, 0, 'no herdr-core command may run while its core is down');
  } finally { provider.stop(); f.cleanup(); }
});

test('a core that stops is not restarted through the stream', async () => {
  const f = fake(); await f.core(true);
  const provider = new HerdrProvider(options(f, { pollMs: 150, restartMs: 100 }));
  try {
    const { seen, started } = observe(provider); await started;
    await until(() => seen.health.at(-1) === 'live');
    await pause(100);
    await f.core(false);
    for (const pid of f.pids().filter(f.alive)) process.kill(pid, 'SIGTERM');
    await until(() => seen.health.at(-1) === 'offline', 1_000);
    const count = f.pids().length;
    await pause(500);
    assert.equal(f.pids().length, count, 'no stream restart or snapshot while the core is down');
    await f.core(true);
    await until(() => seen.health.at(-1) === 'live', 2_000);
  } finally { provider.stop(); f.cleanup(); }
});

test('claude terminal sessions wait for herdr to answer before they are listed', () => {
  const state = new BridgeState(['claude', 'herdr']);
  state.setHealth('claude', { state: 'live' });
  state.setSessions('claude', [cliSession(4242), { ...cliSession(0), externalId: 'local_desktop', terminalPid: null }], () => {});
  assert.deepEqual(state.snapshot(1_000).tasks.map(t => t.id), ['claude:local_desktop'],
    'a CLI task that may be a Herdr terminal is held while herdr is connecting');
  state.setHealth('herdr', { state: 'live' });
  state.setSessions('herdr', [], () => {});
  assert.deepEqual(state.snapshot(1_000).tasks.map(t => t.id).sort(),
    ['claude:cli_0b658f2a-4487-43f8-b6a4-292dc87388bc', 'claude:local_desktop']);
  const offline = new BridgeState(['claude', 'herdr']);
  offline.setHealth('herdr', { state: 'offline' });
  offline.setSessions('claude', [cliSession(4242)], () => {});
  assert.equal(offline.snapshot(1_000).tasks.length, 1, 'an offline herdr holds nothing back');
});
