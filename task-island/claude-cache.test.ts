import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { serialize } from 'node:v8';
import { decodeCacheValue, decodePlainV8, decodeSnappy, readClaudeCache, sanitizeCacheSnapshot } from './claude-cache';

const now = 1_800_000_000_000;
const row = (extra: object = {}) => ({ id: 'session_synthetic', title: 'Synthetic task', session_status: 'active', worker_status: 'running', connection_status: 'connected', ...extra });
const cache = (rows = [row()], at = now, extra: object = {}) => ({ timestamp: at, clientState: { queries: [
  { queryKey: ['private_other_query'], state: { dataUpdatedAt: at, data: { body: 'PRIVATE_BODY' } } },
  { queryKey: ['sessions_api_list_sessions', 'synthetic'], state: { dataUpdatedAt: at, data: { pages: [{ data: rows }] } } },
] }, ...extra });

test('only allowlisted catalog scalars escape; live status requires explicit worker and connection evidence', () => {
  const r = sanitizeCacheSnapshot(cache([
    row({ id: 'cse_run', body: 'PRIVATE_BODY', resume_token: 'PRIVATE_TOKEN', metadata: { openedInAppAt: now } }),
    row({ id: 'session_input', worker_status: 'requires_action' }),
    row({ id: 'session_disconnected', connection_status: 'disconnected' }),
    row({ id: 'session_idle', worker_status: 'idle', unread: false }),
    row({ id: 'session_no_worker', worker_status: undefined }),
    row({ id: 'session_inactive', session_status: 'completed' }),
  ]), now);
  assert.equal(r.status, 'fresh');
  assert.deepEqual(r.sessions.map(s => s.state), ['running', 'input', 'unknown', 'idle', 'unknown', 'unknown']);
  assert.ok(!JSON.stringify(r).includes('PRIVATE_'));
  assert.ok(!JSON.stringify(r).includes('openedInAppAt'));
});

test('cached observations expire without becoming fresh through a new read or persistence timestamp', () => {
  const value = cache([row()], now - 21_000);
  value.timestamp = now;
  const first = sanitizeCacheSnapshot(value, now), later = sanitizeCacheSnapshot(value, now + 10_000);
  assert.equal(first.status, 'stale'); assert.equal(first.sessions[0].state, 'unknown');
  assert.equal(later.observedAt, first.observedAt); assert.equal(later.sessions[0].state, 'unknown');
  assert.equal(first.observedAt, now - 21_000);
  assert.equal(first.sessions[0].lastObservedState, 'running');
  assert.equal(later.sessions[0].lastObservedState, 'running');
});

test('last observed activity is retained without renewing stale runtime or asserting disconnected/conflicting state', () => {
  const r = sanitizeCacheSnapshot(cache([
    row({ id:'session_last_run',session_status:'running',lifecycle_status:'active' }),
    row({ id:'session_last_input',session_status:'requires_action',lifecycle_status:'active',worker_status:'requires_action' }),
    row({ id:'session_last_idle',session_status:'idle',lifecycle_status:'active',worker_status:'idle' }),
    row({ id:'session_offline',session_status:'running',connection_status:'disconnected' }),
    row({ id:'session_conflicting',session_status:'idle',worker_status:'running' }),
    row({ id:'session_failed',session_status:'running',lifecycle_status:'failed' }),
  ],now-60_000),now);
  assert.equal(r.status,'stale');
  assert.deepEqual(r.sessions.map(s=>s.state),Array(6).fill('unknown'));
  assert.deepEqual(r.sessions.map(s=>s.lastObservedState),['running','input','idle',undefined,undefined,undefined]);
  assert.ok(r.sessions.every(s=>s.observedAt===now-60_000));
});

test('normalized persisted activity status is separate from lifecycle status', () => {
  const r = sanitizeCacheSnapshot(cache([
    row({ id: 'session_running', session_status: 'running', lifecycle_status: 'active', worker_status: 'running' }),
    row({ id: 'session_input', session_status: 'requires_action', lifecycle_status: 'active', worker_status: 'requires_action' }),
    row({ id: 'session_idle', session_status: 'idle', lifecycle_status: 'active', worker_status: 'idle' }),
    row({ id: 'session_paused_input', session_status: 'requires_action', lifecycle_status: 'paused', worker_status: 'requires_action' }),
    row({ id: 'session_pending', session_status: 'pending', lifecycle_status: 'active', worker_status: undefined }),
  ]), now);
  assert.deepEqual(r.sessions.map(s => s.state), ['running', 'input', 'idle', 'input', 'unknown']);
});

test('normalized idle cannot conceal a disconnected running worker or failed lifecycle', () => {
  const r = sanitizeCacheSnapshot(cache([
    row({ id: 'session_offline_busy', session_status: 'idle', lifecycle_status: 'active', worker_status: 'running', connection_status: 'disconnected' }),
    row({ id: 'session_offline_idle', session_status: 'idle', lifecycle_status: 'active', worker_status: 'idle', connection_status: 'disconnected' }),
    row({ id: 'session_failed', session_status: 'idle', lifecycle_status: 'failed', worker_status: 'idle' }),
    row({ id: 'session_conflict', session_status: 'running', lifecycle_status: 'active', worker_status: 'idle' }),
    row({ id: 'session_paused', session_status: 'paused', lifecycle_status: 'paused', worker_status: 'idle' }),
  ]), now);
  assert.deepEqual(r.sessions.map(s => s.state), ['unknown', 'unknown', 'unknown', 'unknown', 'unknown']);
});

test('archived and deleted catalog records do not appear as unknown tasks', () => {
  const r = sanitizeCacheSnapshot(cache([
    row({ id: 'session_archived', session_status: 'archived' }),
    row({ id: 'session_deleted', session_status: 'deleted' }),
    row({ id: 'session_lifecycle_archive', session_status: 'idle', lifecycle_status: 'archived', worker_status: 'idle' }),
    row({ id: 'session_lifecycle_delete', session_status: 'idle', lifecycle_status: 'deleted', worker_status: 'idle' }),
    row({ id: 'session_visible', session_status: 'idle', lifecycle_status: 'active', worker_status: 'idle' }),
  ]), now);
  assert.equal(r.sessions.length, 1); assert.equal(r.sessions[0].id, 'session_visible');
  assert.equal(r.sessions[0].state, 'idle');
});

test('new archived observations suppress stale active-query duplicates in either query order', () => {
  const value = cache([row({ session_status: 'idle', lifecycle_status: 'active', worker_status: 'idle' })], now - 10_000);
  value.timestamp = now;
  value.clientState.queries.push({ queryKey: ['sessions_api_list_sessions'], state: { dataUpdatedAt: now, data: { pages: [{ data: [row({ session_status: 'archived', lifecycle_status: 'archived', worker_status: 'idle' })] }] } } } as any);
  assert.equal(sanitizeCacheSnapshot(value, now).sessions.length, 0);
  value.clientState.queries.reverse();
  assert.equal(sanitizeCacheSnapshot(value, now).sessions.length, 0);
  value.clientState.queries[0].state.dataUpdatedAt = now - 20_000;
  assert.equal(sanitizeCacheSnapshot(value, now).sessions[0].state, 'idle');
});

test('per-query freshness and newest duplicate observation are preserved', () => {
  const value = cache([row()], now - 30_000);
  value.timestamp = now;
  value.clientState.queries.push({ queryKey: ['sessions_api_list_sessions'], state: { dataUpdatedAt: now, data: { pages: [{ data: [row({ worker_status: 'requires_action' }), row({ id: 'cse_second' })] }] } } } as any);
  const r = sanitizeCacheSnapshot(value, now);
  assert.equal(r.status, 'fresh'); assert.equal(r.sessions.length, 2);
  assert.equal(r.sessions[0].state, 'input'); assert.equal(r.sessions[0].observedAt, now);
});

test('unsupported snapshots fail closed and cache coverage remains limited to first fifty rows per query', () => {
  assert.throws(() => sanitizeCacheSnapshot({ timestamp: now }, now));
  assert.throws(() => sanitizeCacheSnapshot(cache([], now + 6_000), now));
  assert.equal(sanitizeCacheSnapshot({ timestamp: now, clientState: { queries: [] } }, now).status, 'unavailable');
  assert.equal(sanitizeCacheSnapshot(cache(Array.from({ length: 60 }, (_, i) => row({ id: `cse_${i}` }))), now).sessions.length, 50);
});

test('canonical V8 wire16 JSON-like fixtures decode without rewriting their header', () => {
  assert.equal((decodePlainV8(Buffer.from('ff106f22017849027b01', 'hex')) as any).x, 1);
  const dense = decodePlainV8(Buffer.from('ff10410349025f2d240003', 'hex')) as any[];
  assert.equal(dense[0], 1); assert.equal(1 in dense, true); assert.equal(2 in dense, false);
  const sparse = decodePlainV8(Buffer.from('ff1061054908220178400105', 'hex')) as any[];
  assert.equal(sparse.length, 5); assert.equal(sparse[4], 'x');
  assert.equal(decodePlainV8(Buffer.from('ff106304604f7d59', 'hex')), '你好');
  const cycle = decodePlainV8(Buffer.from('ff106f220473656c665e007b01', 'hex')) as any;
  assert.equal(cycle.self, cycle);
  assert.throws(() => decodePlainV8(Buffer.from('ff104200', 'hex'))); // ArrayBuffer unsupported.
  assert.throws(() => decodePlainV8(Buffer.from('ff106f22017849027b02', 'hex'))); // Incorrect property count.
  assert.throws(() => decodePlainV8(Buffer.from('ff1061004908220178400100', 'hex'))); // Index beyond sparse array length.
  assert.throws(() => decodePlainV8(Buffer.from('ff115f', 'hex'))); // Future wire version.
});

test('Snappy literals, overlapping copies, malformed offsets and Blink envelopes', () => {
  assert.equal(decodeSnappy(Buffer.from([5, 16, 104, 101, 108, 108, 111])).toString(), 'hello');
  assert.equal(decodeSnappy(Buffer.from([5, 0, 97, 1, 1])).toString(), 'aaaaa');
  assert.throws(() => decodeSnappy(Buffer.from([5, 1, 1])));
  const plain = serialize({ scalar: 4 });
  assert.equal((decodeCacheValue(Buffer.concat([Buffer.from([1, 255, 17]), plain])) as any).scalar, 4);
  const header = Buffer.alloc(15); header[0] = 255; header[1] = 21; header[2] = 254;
  assert.equal((decodeCacheValue(Buffer.concat([Buffer.from([1]), header, plain])) as any).scalar, 4);
  header.writeUInt32BE(0xffffffff, 11);
  assert.throws(() => decodeCacheValue(Buffer.concat([Buffer.from([1]), header, plain])));
  assert.throws(() => decodeCacheValue(Buffer.from([1, 255, 17, 1, 0, 0]))); // No blob resolver.
  assert.throws(() => decodeSnappy(Buffer.from([5, 0, 97, 1, 1]), { remaining: 4 }));
});

function vint(n: number): Buffer { const out = []; do { let b = n % 128; n = Math.floor(n / 128); if (n) b += 128; out.push(b); } while (n); return Buffer.from(out); }
function str(s: string): Buffer { const b = Buffer.from(s, 'utf16le'); b.swap16(); return b; }
function sized(b: Buffer): Buffer { return Buffer.concat([vint(b.length), b]); }
function idbString(s: string): Buffer { return Buffer.concat([vint(s.length), str(s)]); }
function logRecord(data: Buffer): Buffer {
  let crc = 0xffffffff;
  for (const byte of Buffer.concat([Buffer.from([1]), data])) { crc ^= byte; for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ ((crc & 1) ? 0x82f63b78 : 0); }
  crc = (crc ^ 0xffffffff) >>> 0; const header = Buffer.alloc(7);
  header.writeUInt32LE((((crc >>> 15) | (crc << 17)) + 0xa282ead8) >>> 0); header.writeUInt16LE(data.length, 4); header[6] = 1;
  return Buffer.concat([header, data]);
}
function fixture(t: test.TestContext, blob = false, databaseName = 'keyval-store') {
  const base = mkdtempSync(join(tmpdir(), 'task-island-fixture-')), dir = join(base, 'origin.leveldb'); mkdirSync(dir);
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const dbKey = Buffer.concat([Buffer.from([0, 0, 0, 0, 201]), idbString('https://claude.ai'), idbString(databaseName)]);
  const storeKey = Buffer.from([0, 1, 0, 0, 50, 1, 0]);
  const primary = Buffer.concat([Buffer.from([0, 1, 1, 1, 1]), idbString('react-query-cache')]);
  const payload = Buffer.concat([Buffer.from([255, 17]), serialize(cache())]);
  const pairs = [[dbKey, Buffer.from([1])], [storeKey, str('keyval')]];
  if (blob) {
    // A selected offloaded value may itself be Snappy compressed.
    const lenBytes = payload.length < 256 ? 1 : 2;
    const encodedLen = Buffer.alloc(lenBytes); encodedLen.writeUIntLE(payload.length - 1, 0, lenBytes);
    const compressed = Buffer.concat([Buffer.from([255, 17, 2]), vint(payload.length), Buffer.from([(59 + lenBytes) << 2]), encodedLen, payload]);
    const blobDir = join(base, 'origin.blob', '1', '00'); mkdirSync(blobDir, { recursive: true }); writeFileSync(join(blobDir, '1'), compressed);
    const external = Buffer.from(primary); external[3] = 3;
    pairs.push([external, Buffer.concat([Buffer.from([0, 1, 0]), vint(compressed.length)])]);
    pairs.push([primary, Buffer.concat([Buffer.from([1, 255, 17, 1]), vint(compressed.length), Buffer.from([0])])]);
  } else pairs.push([primary, Buffer.concat([Buffer.from([1]), payload])]);
  const batchHeader = Buffer.alloc(12); batchHeader.writeBigUInt64LE(1n); batchHeader.writeUInt32LE(pairs.length, 8);
  const batch = Buffer.concat([batchHeader, ...pairs.map(([key, value]) => Buffer.concat([Buffer.from([1]), sized(key), sized(value)]))]);
  const manifest = Buffer.concat([Buffer.from([1]), sized(Buffer.from('idb_cmp1')), Buffer.from([2, 2, 3, 3, 4]), vint(pairs.length)]);
  writeFileSync(join(dir, 'CURRENT'), 'MANIFEST-000001\n'); writeFileSync(join(dir, 'MANIFEST-000001'), logRecord(manifest)); writeFileSync(join(dir, '000002.log'), logRecord(batch));
  writeFileSync(join(dir, 'Cookies'), 'IGNORED_AUTH_STORE');
  return dir;
}

for (const blob of [false, true]) test(`copied LevelDB catalog${blob ? ' with compressed blob' : ''} yields sanitized metadata and leaves source untouched`, t => {
  const dir = fixture(t, blob), before = readFileSync(join(dir, '000002.log'));
  const tempBefore = readdirSync(tmpdir()).filter(n => n.startsWith('task-island-cache-')).sort();
  const r = readClaudeCache({ originDir: dir, now });
  assert.equal(r.status, 'fresh'); assert.equal(r.sessions.length, 1); assert.equal(r.sessions[0].state, 'running');
  assert.deepEqual(readFileSync(join(dir, '000002.log')), before);
  assert.deepEqual(readdirSync(tmpdir()).filter(n => n.startsWith('task-island-cache-')).sort(), tempBefore);
  assert.equal(readFileSync(join(dir, 'Cookies'), 'utf8'), 'IGNORED_AUTH_STORE');
});

test('damaged source and unexpected database names do not produce live tasks', t => {
  const dir = fixture(t); const log = readFileSync(join(dir, '000002.log')); log[0] ^= 1; writeFileSync(join(dir, '000002.log'), log);
  assert.equal(readClaudeCache({ originDir: dir, now }).status, 'unavailable');
  assert.deepEqual(readClaudeCache({ originDir: join(dir, 'missing'), now }).sessions, []);
  const differentDB = fixture(t, false, 'different-database');
  assert.deepEqual(readClaudeCache({ originDir: differentDB, now }).sessions, []);
});

test('unchanged-generation memo expires original observations and a changed generation is reparsed', t => {
  const dir = fixture(t);
  const first = readClaudeCache({ originDir: dir, now });
  const later = readClaudeCache({ originDir: dir, now: now + 21_000 });
  assert.equal(first.sessions[0].state, 'running'); assert.equal(later.sessions[0].state, 'unknown');
  assert.equal(later.sessions[0].lastObservedState,'running');
  assert.equal(later.observedAt, first.observedAt); assert.equal(later.status, 'stale');
  const log = readFileSync(join(dir, '000002.log')); log[0] ^= 1; writeFileSync(join(dir, '000002.log'), log);
  assert.equal(readClaudeCache({ originDir: dir, now }).status, 'unavailable');
});

test('query iteration is bounded before traversal and only the first persisted page is read', () => {
  const value = cache(); value.clientState.queries = new Array(501);
  assert.throws(() => sanitizeCacheSnapshot(value, now));
  const firstPage = cache([]); (firstPage.clientState.queries[1].state.data as any).pages.push({ data: [row()] });
  assert.equal(sanitizeCacheSnapshot(firstPage, now).sessions.length, 0);
});

test('the diagnostic hook sees a decoded value once per cache generation and cannot change the result', t => {
  const dir = fixture(t); let calls = 0, sawQueries = false;
  const inspect = (value: unknown) => { calls++; sawQueries = Array.isArray((value as any)?.clientState?.queries); throw new Error('ignored'); };
  const first = readClaudeCache({ originDir: dir, now, inspect });
  assert.equal(first.status, 'fresh'); assert.equal(calls, 1); assert.equal(sawQueries, true);
  const again = readClaudeCache({ originDir: dir, now, inspect });
  assert.equal(again.sessions.length, first.sessions.length); assert.equal(calls, 1, 'an unchanged cache is not decoded again');
});
