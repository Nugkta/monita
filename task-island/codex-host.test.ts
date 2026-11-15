import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { createServer, type Socket } from 'node:net';
import { CodexProvider } from '../monitor-probe/source/src/providers/codex';
import { FrameDecoder, encodeFrame } from '../monitor-probe/source/src/providers/codex/transport';
import type { Session } from '../monitor-probe/source/src/shared/types';

async function observer(t: any) {
  const home = mkdtempSync('/tmp/codex-host-test-');
  mkdirSync(join(home, 'ipc'), { mode: 0o700 });
  const db = new DatabaseSync(join(home, 'state_5.sqlite'));
  db.exec(`CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,cwd TEXT,source TEXT,archived INTEGER,updated_at INTEGER);
    INSERT INTO threads VALUES('local01','Local task','/project','cli',0,10);`);
  db.close();
  let socket: Socket | undefined;
  const outbound: any[] = [];
  const server = createServer(client => {
    socket = client;
    const decoder = new FrameDecoder();
    client.on('data', bytes => {
      for (const message of decoder.push(bytes) as any[]) {
        outbound.push(message);
        if (message.method === 'initialize') client.write(encodeFrame({
          type: 'response', requestId: message.requestId,
          resultType: 'success', result: { clientId: 'observer' },
        }));
      }
    });
  });
  await new Promise<void>(resolve => server.listen(join(home, 'ipc', 'ipc.sock'), resolve));
  const provider = new CodexProvider(home, join(home, 'hooks'));
  let sessions: Session[] = [];
  provider.track(['local01']);
  await provider.start({ sessions: value => { sessions = value; }, health: () => {} });
  t.after(async () => {
    provider.stop();
    socket?.destroy();
    await new Promise<void>(resolve => server.close(() => resolve()));
    rmSync(home, { recursive: true });
  });
  async function wait(predicate: () => boolean) {
    for (let i = 0; i < 200; i++) {
      if (predicate()) return;
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    assert.fail('Timed out waiting for synthetic Codex observer');
  }
  await wait(() => outbound.some(m => m.method === 'thread-stream-following-changed'));
  const send = (method: string, params: object, version: number, owner = 'source-owner') =>
    socket!.write(encodeFrame({ type: 'broadcast', method, params, version, sourceClientId: owner }));
  const announce = (id = 'remote01', hostId = 'durable', version = 1) => send(
    'thread-stream-following-changed', { conversationId: id, hostId, following: true }, version);
  const state = (change: object, hostId = 'durable', id = 'remote01', owner = 'source-owner') => send(
    'thread-stream-state-changed', { conversationId: id, hostId, change }, 13, owner);
  const snapshot = (revision: number, runtime = 'active') => ({
    type: 'snapshot', revision, conversationState: {
      id: 'remote01', title: 'Remote task', cwd: '/remote', hasUnreadTurn: false,
      threadRuntimeStatus: { type: runtime }, requests: [],
      turns: [{ turnId: 'turn-1', status: runtime === 'active' ? 'inProgress' : 'completed' }],
      prompt: 'This transcript field must never enter provider observations',
    },
  });
  return { provider, outbound, wait, send, announce, state, snapshot,
    sessions: () => sessions, remote: () => sessions.find(s => s.externalId === 'remote01') };
}

test('loaded durable discovery survives tracking and catalog refresh, observes v13 and resyncs on its own host', async t => {
  const o = await observer(t);
  o.announce();
  await o.wait(() => o.outbound.some(m => m.params?.hostId === 'durable' && m.params?.following));
  assert.equal(o.remote()?.status, 'unknown');
  o.state(o.snapshot(1));
  await o.wait(() => o.remote()?.status === 'running');
  assert.equal(o.remote()?.title, 'Remote task');
  assert.equal(o.remote()?.hostId, 'durable');
  assert.equal(o.remote()?.terminalResumeAllowed, false);
  assert.equal(o.remote()?.resumeId, null);
  assert.equal(o.provider.sessionUrl('remote01'), 'codex://threads/remote01?hostId=durable');
  assert.equal(await o.provider.readCompletedResponse(o.remote()!), null);
  assert.ok(!JSON.stringify(o.sessions()).includes('transcript field'));
  o.provider.track(['local01', 'remote01']);
  o.provider.track(['local01']);
  await o.provider.refresh();
  assert.equal(o.remote()?.status, 'running');
  o.send('thread-stream-following-status-requested', { conversationId: 'remote01', hostId: 'durable' }, 1);
  await o.wait(() => o.outbound.filter(m => m.params?.hostId === 'durable' && m.params?.following).length >= 2);
  o.state({ type: 'patches', baseRevision: 7, revision: 8, patches: [] });
  await o.wait(() => o.remote()?.status === 'unknown');
  await o.wait(() => o.outbound.some(m => m.params?.hostId === 'durable' && m.params?.following === false));
  assert.ok(!o.outbound.some(m => m.params?.hostId === 'local' && m.params?.conversationId === 'remote01'));
  o.state(o.snapshot(9));
  await o.wait(() => o.remote()?.status === 'running');
  o.state({ type: 'patches', baseRevision: 9, revision: 10, patches: [
    { op: 'replace', path: ['threadRuntimeStatus'], value: { type: 'idle' } },
    { op: 'replace', path: ['hasUnreadTurn'], value: true },
    { op: 'replace', path: ['turns', 0, 'status'], value: 'completed' },
  ] });
  await o.wait(() => o.remote()?.status === 'review');
  assert.equal(o.remote()?.attentionKey, 'result:turn-1');
  o.send('client-status-changed', { clientId: 'source-owner', status: 'disconnected' }, 0);
  await o.wait(() => o.remote()?.status === 'unknown');
  assert.ok(o.outbound.every(m => m.method === 'initialize' ||
    m.method === 'thread-stream-following-changed' || m.type === 'client-discovery-response'));
});

test('host collisions fail closed and refuse source mixing or local terminal fallbacks', async t => {
  const o = await observer(t);
  o.announce();
  await o.wait(() => o.remote() !== undefined);
  o.state(o.snapshot(1));
  await o.wait(() => o.remote()?.status === 'running');
  o.state(o.snapshot(2), 'local');
  await o.wait(() => o.remote()?.status === 'unknown');
  assert.equal(o.remote()?.openable, false);
  assert.equal(o.remote()?.terminalResumeAllowed, false);
  assert.throws(() => o.provider.sessionUrl('remote01'), /Conflicting/);
  o.state(o.snapshot(3));
  await o.provider.refresh();
  assert.equal(o.remote()?.status, 'unknown');
  assert.equal(o.remote()?.evidence, 'unavailable');
});

test('discovery validates host, source identity and protocol and rejects local catalog collisions', async t => {
  const o = await observer(t);
  o.announce('remote01', 'bad host');
  o.announce('remote01', 'durable', 99);
  o.send('thread-stream-following-changed', { conversationId: 'remote01', hostId: 'durable', following: true }, 1, '');
  o.announce('local01', 'durable');
  await o.wait(() => o.sessions().some(s => s.externalId === 'local01' && s.openable === false));
  assert.equal(o.remote(), undefined);
  assert.ok(!o.outbound.some(m => m.params?.hostId === 'durable' && m.params?.following));
});
