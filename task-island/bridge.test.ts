import test from 'node:test';
import assert from 'node:assert/strict';
import { BridgeState, parseBridgeOptions, sourceURL, toBridgeTask } from './bridge-core';
import type { Session } from '../monitor-probe/source/src/shared/types';

function session(overrides: Partial<Session> = {}): Session {
  return { id: 'codex:sample-task', provider: 'codex', externalId: 'sample-task', title: 'Synthetic title',
    directory: '/PRIVATE_DIRECTORY', status: 'read', detail: 'Read in source', updatedAt: 100,
    observedAt: 200, evidence: 'live', attentionKey: 'result:turn-1', archived: false, ...overrides };
}
test('live state mapping separates input, working, unread result, source read and errors', () => {
  for (const [overrides, expected] of [
    [{ status: 'running' }, 'running'],
    [{ status: 'review', awaitingInput: true, attentionKey: 'request:1' }, 'input'],
    [{ status: 'review', detail: 'New response' }, 'review'],
    [{ status: 'review', attentionKey: 'error:1' }, 'error'],
    [{ status: 'review', detail: 'Turn interrupted in Codex' }, 'error'],
    [{ status: 'review', detail: 'Turn failed · unread' }, 'error'],
    [{ status: 'read', attentionKey: 'error:1', detail: 'Error seen' }, 'read'],
    [{ status: 'unknown' }, 'unknown'],
  ] as Array<[Partial<Session>, string]>) assert.equal(toBridgeTask(session(overrides), 'live', 1_000)?.state, expected);
});
test('only stable completion/error keys enter resultKey, never current request or stale running IDs', () => {
  for (const key of ['result:turn-1', 'result:0', 'error:123456', 'result:turn:uuid-1'])
    assert.equal(toBridgeTask(session({ attentionKey: key }), 'live', 1_000)?.resultKey, key);
  for (const key of ['request:1', 'waiting:1', 'result:', 'result:PRIVATE BODY', 'result:a\nbody', 'result:'+'a'.repeat(513)])
    assert.equal(toBridgeTask(session({ attentionKey: key }), 'live', 1_000)?.resultKey, null);
  assert.equal(toBridgeTask(session({ status: 'running' }), 'live', 1_000)?.resultKey, null);
  assert.equal(toBridgeTask(session({ awaitingInput: true }), 'live', 1_000)?.resultKey, null);
});
test('history, unavailable, offline and connecting never revive runtime or fresh completion identity', () => {
  for (const evidence of ['history', 'unavailable'] as const)
    for (const status of ['running', 'review', 'read'] as const) {
      const task=toBridgeTask(session({ evidence, status, awaitingInput: true }), 'degraded', 1_000)!;
      assert.equal(task.state, 'unknown'); assert.equal(task.evidence, evidence); assert.equal(task.resultKey, null);
    }
  for (const health of ['offline', 'connecting'] as const) {
    const task=toBridgeTask(session({ status: 'running' }), health, 1_000)!;
    assert.equal(task.state, 'unknown'); assert.equal(task.evidence, 'unavailable');
  }
  assert.equal(toBridgeTask(session({ status: 'running' }), 'degraded', 1_000)?.state, 'running');
});
test('outgoing tasks whitelist fields and never include response/request/directory/error payloads', () => {
  const raw={ ...session(), prompt:'PRIVATE_BODY', response:'PRIVATE_BODY', requests:[{params:'PRIVATE_BODY'}],
    detail:'PRIVATE_ERROR_MESSAGE', directory:'/PRIVATE_DIRECTORY', sourceURL:'https://evil.test' };
  const task=toBridgeTask(raw, 'live', 1_000)!;
  assert.deepEqual(Object.keys(task).sort(), ['id','provider','title','state','resultKey','sourceURL','observedAt','evidence','updatedAt'].sort());
  const out=JSON.stringify(task);
  for (const forbidden of ['PRIVATE_BODY','PRIVATE_ERROR_MESSAGE','PRIVATE_DIRECTORY','evil.test']) assert.ok(!out.includes(forbidden));
  assert.equal(task.sourceURL, 'codex://threads/sample-task');
});
test('navigation only builds exact safe source routes and terminal Claude has no desktop link', () => {
  assert.equal(sourceURL('codex', 'sample-task'), 'codex://threads/sample-task');
  assert.equal(sourceURL('codex', 'sample-task', 'durable'), 'codex://threads/sample-task?hostId=durable');
  assert.equal(sourceURL('codex', 'sample-task', 'local'), 'codex://threads/sample-task');
  for (const host of ['../bad', 'durable?extra=1', '', 'a'.repeat(129)])
    assert.equal(sourceURL('codex', 'sample-task', host), null);
  assert.equal(toBridgeTask(session({hostId:'durable'}), 'live', 1_000)?.sourceURL,
    'codex://threads/sample-task?hostId=durable');
  assert.equal(sourceURL('claude', 'local_example-1'), 'claude://code/continue?session=local_example-1');
  assert.equal(sourceURL('claude', 'local_ditto_12345678-1234-1234-1234-123456789abc_g2'),
    'claude://code/continue?session=local_ditto_12345678-1234-1234-1234-123456789abc_g2');
  assert.equal(sourceURL('claude', 'local_'+'x'.repeat(129)), null);
  assert.equal(sourceURL('claude', 'session_example-1'), 'claude://code/session_example-1');
  assert.equal(sourceURL('claude', 'cse_example-1'), 'claude://code/cse_example-1');
  assert.equal(sourceURL('claude', 'session_bad/escape'), null);
  const terminal='cli_12345678-1234-1234-1234-123456789abc';
  assert.equal(sourceURL('claude', terminal), null);
  assert.ok(toBridgeTask(session({ provider:'claude', externalId:terminal }), 'live', 1_000));
  for (const id of ['../escape','a?x=1','sample-task/#x','https://example.test','short','sample\n-task'])
    assert.equal(sourceURL('codex', id), null);
  assert.equal(toBridgeTask(session({externalId:'../escape'}), 'live', 1_000), null);
});
test('archives are omitted, titles are bounded Unicode and cannot inject NDJSON records', () => {
  assert.equal(toBridgeTask(session({ archived:true }), 'live', 1_000), null);
  const task=toBridgeTask(session({ title:'\u0000line\n"title"\u202e'+'好'.repeat(600) }), 'live', 1_000)!;
  assert.equal(Array.from(task.title).length, 500);
  assert.ok(!/[\u0000-\u001f\u202e]/.test(task.title));
  assert.equal((JSON.stringify(task)+'\n').split('\n').length, 2);
  assert.equal(toBridgeTask(session({ title:'\n\u0000 ' }), 'live', 1_000)?.title, 'Codex task');
  assert.equal(toBridgeTask(session({ provider:'claude', externalId:'local_english-fallback', title:'' }), 'live', 1_000)?.title, 'Claude task');
});
test('invalid/far-future times do not enter metadata; identities are reconstructed not trusted', () => {
  const task=toBridgeTask(session({ id:'malicious:other', observedAt:Infinity, updatedAt:1e20 }), 'live', 1_000)!;
  assert.equal(task.id,'codex:sample-task'); assert.equal(task.observedAt,0); assert.equal(task.updatedAt,0);
});
test('tracking follows all IDs and new discoveries without recursive or reorder-only retracking', () => {
  const state=new BridgeState(['codex']);
  const rows=Array.from({length:100},(_,i)=>session({externalId:`task-${i}`}));
  let calls=0;
  let tracked:string[]=[];
  const track=(ids:string[])=>{ calls++; tracked=ids; state.setSessions('codex',rows,track); };
  state.setSessions('codex',rows,track);
  assert.equal(calls,1); assert.equal(tracked.length,100);
  state.setSessions('codex',[...rows].reverse(),track); assert.equal(calls,1);
  state.setSessions('codex',[...rows,session({externalId:'new-task'})],ids=>{ calls++; tracked=ids; });
  assert.equal(calls,2); assert.equal(tracked.length,101);
});
test('snapshot reduction reflects source disconnects and never includes raw health messages', () => {
  const state=new BridgeState();
  state.setHealth('codex',{ state:'live' });
  state.setSessions('codex',[session({status:'running'}),session({archived:true,externalId:'archived-task'})],()=>{});
  assert.equal(state.snapshot(1_000).tasks.length,1);
  assert.equal(state.snapshot(1_000).tasks[0].state,'running');
  state.setHealth('codex',{state:'offline',message:'PRIVATE_ERROR'} as any);
  const snapshot=state.snapshot(2_000);
  assert.equal(snapshot.tasks[0].state,'unknown');
  assert.equal(snapshot.tasks[0].availabilityReason,'source-offline');
  assert.equal(snapshot.generatedAt,2_000);
  assert.ok(!JSON.stringify(snapshot).includes('PRIVATE_ERROR'));
  assert.equal(toBridgeTask(session({status:'unknown',evidence:'history'}),'degraded',2_000)?.availabilityReason,'catalog-only');
});
test('Claude cache observations expire independently of fresh bridge heartbeats and never fabricate results', () => {
  const state = new BridgeState(['claude']);
  state.setHealth('claude', {state:'degraded'});
  state.setClaudeCache({source:'claude-desktop-cache',status:'fresh',observedAt:100_000,
    sessions:[{id:'session_example-1',title:'Example',state:'running',lastObservedState:'running',observedAt:100_000,
      workerStatus:'PRIVATE_WORKER_DETAIL',environmentKind:'PRIVATE_ENVIRONMENT'}]});
  const fresh = state.snapshot(110_000).tasks[0];
  assert.equal(fresh.state,'running'); assert.equal(fresh.resultKey,null);
  assert.equal(fresh.observationSource,'claude-cache'); assert.equal(fresh.observedAt,100_000);
  assert.ok(!JSON.stringify(fresh).includes('PRIVATE_'));
  const expired = state.snapshot(120_001).tasks[0];
  assert.equal(expired.state,'unknown'); assert.equal(expired.observedAt,100_000);
  assert.equal(expired.evidence,'history');
  assert.equal(expired.lastObservedState,'running');
  assert.equal(expired.availabilityReason,'stale-cache');
  state.setClaudeCache({source:'claude-desktop-cache',status:'fresh',sessions:[
    {id:'session_example-1',title:'Example',state:'idle',observedAt:130_000}]});
  assert.equal(state.snapshot(130_001).tasks[0].state,'idle');
  assert.equal(state.snapshot(130_001).tasks[0].resultKey,null);
  state.setClaudeCache({source:'claude-desktop-cache',status:'unavailable',sessions:[]});
  assert.equal(state.snapshot(130_002).tasks[0].state,'unknown');
});
test('explicit invalid lifetime/PID arguments fail closed rather than become unbounded observers', () => {
  assert.deepEqual(parseBridgeOptions([],123),{parentPID:123});
  assert.deepEqual(parseBridgeOptions(['--duration-seconds','0.2','--parent-pid','456'],123),{parentPID:456,durationSeconds:0.2});
  for (const args of [['--duration-seconds'],['--duration-seconds','0'],['--duration-seconds','NaN'],['--duration-seconds','999999'],
    ['--parent-pid','1'],['--parent-pid','1.5'],['--parent-pid','oops'],['--unexpected','1']])
    assert.throws(()=>parseBridgeOptions(args,123));
  assert.throws(()=>parseBridgeOptions([],1));
});

function claudeSession(overrides: Partial<Session> = {}): Session {
  return session({ id: 'claude:local_example-1', provider: 'claude', externalId: 'local_example-1',
    status: 'unknown', evidence: 'unavailable', attentionKey: null, ...overrides });
}
test('a recorded turn is a completion identity even when runtime state is unavailable', () => {
  const task = toBridgeTask(claudeSession({ recordedResultKey: 'result:4' }), 'degraded', 1_000)!;
  assert.equal(task.state, 'unknown'); assert.equal(task.evidence, 'unavailable');
  assert.equal(task.resultKey, 'result:4'); assert.equal(task.completionTracking, 'turn-record');
  assert.equal(task.availabilityReason, 'turn-record-only');
  // The record is on disk whether or not the desktop app is running.
  const offline = toBridgeTask(claudeSession({ recordedResultKey: 'error:1700000000000' }), 'offline', 1_000)!;
  assert.equal(offline.state, 'unknown'); assert.equal(offline.resultKey, 'error:1700000000000');
  assert.equal(offline.availabilityReason, 'source-offline');
  // No finished turn yet is itself tracked, so the first completion is not mistaken for a baseline.
  const none = toBridgeTask(claudeSession({ recordedResultKey: null }), 'live', 1_000)!;
  assert.equal(none.resultKey, null); assert.equal(none.completionTracking, 'turn-record');
});
test('a recorded turn never invents runtime state and never applies to sources without a record', () => {
  const running = toBridgeTask(claudeSession({ status: 'running', evidence: 'live', recordedResultKey: 'result:4' }), 'live', 1_000)!;
  assert.equal(running.state, 'running'); assert.equal(running.resultKey, 'result:4');
  assert.equal(running.availabilityReason, undefined);
  // A current source result wins over the record; both name the same turn in practice.
  const review = toBridgeTask(claudeSession({ status: 'review', evidence: 'live', attentionKey: 'result:5', recordedResultKey: 'result:4' }), 'live', 1_000)!;
  assert.equal(review.state, 'review'); assert.equal(review.resultKey, 'result:5');
  for (const bad of ['request:1', 'waiting:1', 'result:', 'result:PRIVATE BODY', 7, {}] as unknown[])
    assert.equal(toBridgeTask(claudeSession({ recordedResultKey: bad as string }), 'live', 1_000)?.resultKey, null);
  const untracked = toBridgeTask(claudeSession(), 'degraded', 1_000)!;
  assert.equal(untracked.completionTracking, undefined); assert.equal(untracked.availabilityReason, 'runtime-unavailable');
  const codex = toBridgeTask(session({ status: 'unknown', evidence: 'unavailable', attentionKey: null,
    recordedResultKey: 'result:4' }), 'live', 1_000)!;
  assert.equal(codex.resultKey, null); assert.equal(codex.completionTracking, undefined);
});
test('a local task published through Remote Control is listed once, from its own record', () => {
  const state = new BridgeState(['claude']);
  state.setHealth('claude', { state: 'live' });
  const now = Date.now();
  state.setSessions('claude', [claudeSession({ recordedResultKey: 'result:2', remoteAliases: ['session_shared-1'] }),
    claudeSession({ id: 'claude:local_example-2', externalId: 'local_example-2', archived: true, remoteAliases: ['session_archived-1'] })], () => {});
  state.setClaudeCache({ source: 'claude-desktop-cache', status: 'fresh', observedAt: now, sessions: [
    { id: 'cse_shared-1', title: 'Same task, remote spelling', state: 'running', observedAt: now, lastObservedState: 'running' },
    { id: 'session_other-1', title: 'Unrelated remote task', state: 'idle', observedAt: now, lastObservedState: 'idle' },
    { id: 'session_archived-1', title: 'Archived local twin', state: 'idle', observedAt: now, lastObservedState: 'idle' },
  ] });
  const ids = state.snapshot(now).tasks.map(task => task.id).sort();
  assert.deepEqual(ids, ['claude:local_example-1', 'claude:session_archived-1', 'claude:session_other-1']);
});
