// Read only a private copy of Claude's IndexedDB. No DB handles, credentials,
// network calls or task actions. The selected persisted value is decoded only
// transiently; only allowlisted session metadata escapes this module.
import { chmodSync, copyFileSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';

export type CacheTaskState = 'running' | 'input' | 'idle' | 'unknown';
export interface ClaudeCacheSession {
  id: string; title: string; state: CacheTaskState; observedAt: number;
  /** Explicit state at the original observation; never a claim of current activity. */
  lastObservedState?: CacheTaskState;
  sessionStatus?: string; lifecycleStatus?: string; workerStatus?: string;
  connectionStatus?: string; environmentKind?: string; updatedAt?: string;
}
export interface ClaudeCacheSnapshot {
  source: 'claude-desktop-cache'; status: 'fresh' | 'stale' | 'unavailable';
  observedAt?: number; persistedAt?: number; sessions: ClaudeCacheSession[];
  reason?: 'missing' | 'unsupported' | 'stale';
}
const MAX = 32 * 1024 * 1024;
type AllocationBudget = { remaining: number };
const TTL = 20_000;
const keyName = 'react-query-cache';
const allowedFile = /^(CURRENT|MANIFEST-\d+|\d+\.(ldb|sst|log))$/;
let memo: { origin: string; generation: string; ttl: number; blob?: { path: string; mark: string }; snapshot: ClaudeCacheSnapshot } | undefined;
function fileMark(path: string): string {
  const s = lstatSync(path, { bigint: true }); if (!s.isFile() || s.isSymbolicLink() || s.size > BigInt(MAX)) fail();
  return `${s.size}:${s.mtimeNs}:${s.ctimeNs}:${s.ino}`;
}
function generationMark(origin: string): string {
  let total = 0n; const marks = [];
  const names = readdirSync(origin).filter(name => allowedFile.test(name)).sort(); if (names.length > 1_000) fail();
  for (const name of names) { const mark = fileMark(join(origin, name)); total += BigInt(mark.split(':')[0]); if (total > BigInt(MAX * 2)) fail(); marks.push(`${name}:${mark}`); }
  return marks.join('|');
}
function expireSnapshot(snapshot: ClaudeCacheSnapshot, now: number, ttl: number): ClaudeCacheSnapshot {
  const sessions = snapshot.sessions.map(s => ({ ...s, state: now - s.observedAt > ttl || s.observedAt > now + 5_000 ? 'unknown' as const : s.state }));
  if (!snapshot.observedAt) return { ...snapshot, sessions };
  const fresh = now - snapshot.observedAt <= ttl && snapshot.observedAt <= now + 5_000;
  const { reason: _reason, ...rest } = snapshot;
  return { ...rest, sessions, status: fresh ? 'fresh' : 'stale', ...(fresh ? {} : { reason: 'stale' as const }) };
}
function fail(): never { throw new Error('Unsupported cache format'); }
function num(v: unknown): number | undefined { return typeof v === 'number' && Number.isFinite(v) ? v : undefined; }
function text(v: unknown, max = 512): string | undefined { return typeof v === 'string' && v.length <= max ? v : undefined; }
function object(v: unknown): Record<string, any> | undefined { return v && typeof v === 'object' && !Array.isArray(v) ? v as Record<string, any> : undefined; }
function varint(b: Buffer, p: { n: number }): number {
  let n = 0, power = 1;
  for (let i = 0; i < 10 && p.n < b.length; i++) { const x = b[p.n++]; n += (x & 127) * power; if (!Number.isSafeInteger(n)) fail(); if (!(x & 128)) return n; power *= 128; }
  return fail();
}
function slice(b: Buffer, p: { n: number }, n: number): Buffer { if (n < 0 || n > MAX || p.n + n > b.length) fail(); const v = b.subarray(p.n, p.n + n); p.n += n; return v; }
function bytes(b: Buffer, p: { n: number }): Buffer { return slice(b, p, varint(b, p)); }
function little(b: Buffer): number { let n = 0; for (let i = b.length - 1; i >= 0; i--) n = n * 256 + b[i]; if (!Number.isSafeInteger(n)) fail(); return n; }
function utf16(b: Buffer): string { if (b.length % 2) fail(); const c = Buffer.from(b); c.swap16(); return c.toString('utf16le'); }

// Raw Snappy blocks (LevelDB compression type 1 and Blink FF 11 02).
export function decodeSnappy(b: Buffer, budget?: AllocationBudget): Buffer {
  const p = { n: 0 }, length = varint(b, p); if (length > MAX) fail();
  if (budget && (budget.remaining -= length) < 0) fail();
  const out = Buffer.alloc(length); let at = 0;
  while (p.n < b.length && at < length) {
    const tag = b[p.n++], kind = tag & 3; let len: number, offset = 0;
    if (kind === 0) {
      len = tag >>> 2;
      if (len < 60) len++;
      else { const count = len - 59; if (count > 4) fail(); len = little(slice(b, p, count)) + 1; }
      if (at + len > length) fail(); slice(b, p, len).copy(out, at); at += len;
    } else {
      if (kind === 1) { len = 4 + ((tag >>> 2) & 7); offset = ((tag & 224) << 3) | slice(b, p, 1)[0]; }
      else { len = 1 + (tag >>> 2); offset = little(slice(b, p, kind === 2 ? 2 : 4)); }
      if (!offset || offset > at || at + len > length) fail();
      for (let i = 0; i < len; i++) out[at + i] = out[at + i - offset]; at += len;
    }
  }
  if (at !== length || p.n !== b.length) fail(); return out;
}
const crcTable = Array.from({ length: 256 }, (_, i) => { let x = i; for (let j = 0; j < 8; j++) x = (x >>> 1) ^ (x & 1 ? 0x82f63b78 : 0); return x >>> 0; });
function crc(b: Buffer): number { let x = 0xffffffff; for (const v of b) x = crcTable[(x ^ v) & 255] ^ (x >>> 8); return (x ^ 0xffffffff) >>> 0; }
function maskedCRC(b: Buffer): number { const x = crc(b); return (((x >>> 15) | (x << 17)) + 0xa282ead8) >>> 0; }
function records(b: Buffer): Buffer[] {
  const out: Buffer[] = []; let parts: Buffer[] = [];
  for (let base = 0; base < b.length; base += 32768) {
    let at = base; const end = Math.min(base + 32768, b.length);
    while (at + 7 <= end) {
      const sum = b.readUInt32LE(at), len = b.readUInt16LE(at + 4), kind = b[at + 6]; at += 7;
      if (!len && !kind) break;
      if (at + len > end) { if (end === b.length) return out; fail(); }
      const data = b.subarray(at, at + len); at += len;
      if (sum !== maskedCRC(Buffer.concat([Buffer.from([kind]), data]))) fail();
      if (kind === 1) { parts = []; out.push(data); }
      else if (kind === 2) parts = [data];
      else if (kind === 3 && parts.length) parts.push(data);
      else if (kind === 4 && parts.length) { parts.push(data); out.push(Buffer.concat(parts)); parts = []; }
      else fail();
    }
  }
  return out;
}
type Entry = { key: Buffer; value: Buffer; seq: bigint; deleted: boolean };
function blockEntries(b: Buffer): { key: Buffer; value: Buffer }[] {
  if (b.length < 4) fail(); const count = b.readUInt32LE(b.length - 4), end = b.length - 4 - count * 4;
  if (end < 0 || count > 1_000_000) fail();
  const p = { n: 0 }, out = []; let key = Buffer.alloc(0);
  while (p.n < end) {
    const shared = varint(b, p), rest = varint(b, p), valueLen = varint(b, p);
    if (shared > key.length) fail(); key = Buffer.concat([key.subarray(0, shared), slice(b, p, rest)]);
    const value = slice(b, p, valueLen); if (p.n > end || out.length >= 100_000) fail(); out.push({ key, value });
  }
  return out;
}
function readBlock(file: Buffer, h: Buffer, p = { n: 0 }, budget?: AllocationBudget): Buffer {
  const start = varint(h, p), len = varint(h, p); if (start + len + 5 > file.length || len > MAX) fail();
  const data = file.subarray(start, start + len), kind = file[start + len];
  if (file.readUInt32LE(start + len + 1) !== maskedCRC(file.subarray(start, start + len + 1))) fail();
  return kind === 0 ? data : kind === 1 ? decodeSnappy(data, budget) : fail();
}
function table(file: Buffer, budget: AllocationBudget): Entry[] {
  if (file.length < 48 || file.subarray(-8).toString('hex') !== '57fb808b247547db') fail();
  const footer = file.subarray(-48), p = { n: 0 }; varint(footer, p); varint(footer, p);
  const index = readBlock(file, footer, p, budget), out: Entry[] = [];
  for (const item of blockEntries(index)) for (const e of blockEntries(readBlock(file, item.value, { n: 0 }, budget))) {
    if (out.length >= 100_000) fail();
    if (e.key.length < 8) fail(); const tag = e.key.readBigUInt64LE(e.key.length - 8), type = Number(tag & 255n);
    if (type !== 0 && type !== 1) fail(); out.push({ key: e.key.subarray(0, -8), value: e.value, seq: tag >> 8n, deleted: type === 0 });
  }
  return out;
}
function batch(b: Buffer): Entry[] {
  if (b.length < 12) fail(); const seq = b.readBigUInt64LE(), count = b.readUInt32LE(8), p = { n: 12 }, out = [];
  if (count > 100_000) fail();
  for (let i = 0; i < count; i++) { const kind = slice(b, p, 1)[0]; if (kind > 1) fail(); const key = bytes(b, p), value = kind ? bytes(b, p) : Buffer.alloc(0); out.push({ key, value, seq: seq + BigInt(i), deleted: !kind }); }
  if (p.n !== b.length) fail(); return out;
}
function manifest(b: Buffer): { tables: Set<number>; log: number; prev: number } {
  const result = { tables: new Set<number>(), log: 0, prev: 0 };
  for (const rec of records(b)) {
    const p = { n: 0 };
    while (p.n < rec.length) {
      const tag = varint(rec, p);
      if (tag === 1) { if (bytes(rec, p).toString() !== 'idb_cmp1') fail(); }
      else if (tag === 2) result.log = varint(rec, p);
      else if (tag === 9) result.prev = varint(rec, p);
      else if (tag === 3 || tag === 4) varint(rec, p);
      else if (tag === 5) { varint(rec, p); bytes(rec, p); }
      else if (tag === 6) { varint(rec, p); result.tables.delete(varint(rec, p)); }
      else if (tag === 7) { varint(rec, p); result.tables.add(varint(rec, p)); varint(rec, p); bytes(rec, p); bytes(rec, p); }
      else fail();
    }
  }
  return result;
}
function prefix(b: Buffer): { db: number; store: number; index: number; n: number } {
  if (!b.length) fail(); const p = { n: 1 }, x = b[0];
  const db = little(slice(b, p, ((x >>> 5) & 7) + 1));
  const store = little(slice(b, p, ((x >>> 2) & 7) + 1)), index = little(slice(b, p, (x & 3) + 1));
  return { db, store, index, n: p.n };
}
function primaryCacheKey(key: Buffer): { db: number; store: number; index: number; n: number } | undefined {
  const h = prefix(key); if (!h.db || !h.store || h.index !== 1 || key[h.n] !== 1) return;
  const p = { n: h.n + 1 }, count = varint(key, p);
  if (count !== keyName.length || p.n + count * 2 !== key.length) return;
  return utf16(slice(key, p, count * 2)) === keyName ? h : undefined;
}
function liveEntries(dir: string, budget: AllocationBudget): Map<string, Entry> {
  const current = readFileSync(join(dir, 'CURRENT'), 'utf8').trim(); if (!/^MANIFEST-\d+$/.test(current)) fail();
  const state = manifest(readFileSync(join(dir, current))), out = new Map<string, Entry>(), seenTables = new Set<number>(), seenLogs = new Set<number>();
  let entryCount = 0;
  function add(e: Entry) { if (++entryCount > 100_000) fail(); const key = e.key.toString('hex'), old = out.get(key); if (!old || e.seq > old.seq) out.set(key, e); }
  for (const file of readdirSync(dir)) {
    const m = /^(\d+)\.(ldb|sst|log)$/.exec(file); if (!m) continue; const id = Number(m[1]);
    if (m[2] === 'log' ? id < state.log && id !== state.prev : !state.tables.has(id)) continue;
    (m[2] === 'log' ? seenLogs : seenTables).add(id);
    const data = readFileSync(join(dir, file)); if (data.length > MAX) fail();
    if (m[2] === 'log') { for (const record of records(data)) for (const e of batch(record)) add(e); }
    else for (const e of table(data, budget)) add(e);
  }
  if ([...state.tables].some(id => !seenTables.has(id)) || (state.log && !seenLogs.has(state.log)) || (state.prev && !seenLogs.has(state.prev))) fail();
  return out;
}
function decodedValue(value: Buffer, blob?: (index: number, size: number) => Buffer, budget?: AllocationBudget): unknown {
  const p = { n: 0 }; varint(value, p); let b = value.subarray(p.n);
  if (b[0] === 255 && b[1] === 17 && b[2] === 2) b = decodeSnappy(b.subarray(3), budget);
  else if (b[0] === 255 && b[1] === 17 && b[2] === 1) {
    const q = { n: 3 }, size = varint(b, q), index = varint(b, q);
    if (q.n !== b.length || !blob) fail(); b = blob(index, size);
    if (b[0] === 255 && b[1] === 17 && b[2] === 2) b = decodeSnappy(b.subarray(3), budget);
  }
  const q = { n: 0 }; if (b[q.n++] !== 255) fail(); const version = varint(b, q);
  if (version < 16 || version > 21) fail();
  if (version >= 21) { if (b[q.n++] !== 254 || q.n + 12 > b.length) fail(); const offset = Number(b.readBigUInt64BE(q.n)), len = b.readUInt32BE(q.n + 8); q.n += 12; if ((offset || len) && (offset < q.n || offset + len > b.length)) fail(); }
  if (b[q.n] !== 255) fail(); const inner = b.subarray(q.n);
  return decodePlainV8(inner);
}
export function decodeCacheValue(value: Buffer): unknown { return decodedValue(value); }

// V8 wire16 is newer than bundled Node22. Decode only JSON-like values using
// V8's documented serialization tags. Host objects, executable values, transfer
// handles, maps/sets and unknown future formats are deliberately unsupported.
export function decodePlainV8(b: Buffer): unknown {
  const p = { n: 0 }, refs: unknown[] = []; let budget = 500_000;
  if (b[p.n++] !== 255) fail(); const wire = varint(b, p); if (wire !== 15 && wire !== 16) fail();
  function peek(): number { while (b[p.n] === 0) p.n++; if (p.n >= b.length) fail(); return b[p.n]; }
  function prop(target: any, key: unknown, value: unknown): void {
    if (typeof key !== 'string' && (typeof key !== 'number' || !Number.isInteger(key) || key < 0)) fail();
    if (Array.isArray(target)) {
      const name = String(key), index = Number(name);
      if (name === 'length' || (String(index) === name && Number.isInteger(index) && index >= 0 && index < 0xffffffff && index >= target.length)) fail();
    }
    Object.defineProperty(target, String(key), { value, configurable: true, enumerable: true, writable: true });
  }
  function value(depth = 0): any {
    if (!budget-- || depth > 100) fail(); const tag = peek(); p.n++;
    if (tag === 95) return undefined;
    if (tag === 48) return null;
    if (tag === 84) return true; if (tag === 70) return false;
    if (tag === 73) { const n = varint(b, p); if (n > 0xffffffff) fail(); return (n >>> 1) ^ -(n & 1); }
    if (tag === 85) { const n = varint(b, p); if (n > 0xffffffff) fail(); return n; }
    if (tag === 78) return slice(b, p, 8).readDoubleLE();
    if (tag === 34 || tag === 83 || tag === 99) { const raw = slice(b, p, varint(b, p)); if (tag === 99 && raw.length % 2) fail(); return raw.toString(tag === 34 ? 'latin1' : tag === 83 ? 'utf8' : 'utf16le'); }
    if (tag === 94) { const id = varint(b, p); if (id >= refs.length) fail(); return refs[id]; }
    if (tag === 111) {
      const out = Object.create(null); refs.push(out); let count = 0;
      while (peek() !== 123) { const key = value(depth + 1); prop(out, key, value(depth + 1)); count++; }
      p.n++; if (varint(b, p) !== count) fail(); return out;
    }
    if (tag === 65 || tag === 97) {
      const length = varint(b, p); if (length > 100_000) fail(); const out = new Array(length); refs.push(out); let count = 0;
      if (tag === 65) for (let i = 0; i < length; i++) { if (peek() === 45) p.n++; else out[i] = value(depth + 1); }
      const end = tag === 65 ? 36 : 64;
      while (peek() !== end) { const key = value(depth + 1); prop(out, key, value(depth + 1)); count++; }
      p.n++; if (varint(b, p) !== count || varint(b, p) !== length || out.length !== length) fail(); return out;
    }
    return fail();
  }
  const result = value(); while (b[p.n] === 0) p.n++; if (p.n !== b.length) fail(); return result;
}

export function sanitizeCacheSnapshot(value: unknown, now = Date.now(), ttl = TTL): ClaudeCacheSnapshot {
  const root = object(value), persistedAt = num(root?.timestamp), queries = root?.clientState?.queries;
  if (!persistedAt || !Array.isArray(queries) || queries.length > 500 || persistedAt > now + 5_000) fail();
  const sessions = new Map<string, ClaudeCacheSession>();
  const hiddenAt = new Map<string, number>();
  let observedAt: number | undefined;
  for (const raw of queries) {
    const query = object(raw); if (!Array.isArray(query?.queryKey) || query.queryKey[0] !== 'sessions_api_list_sessions') continue;
    const at = num(query.state?.dataUpdatedAt); if (!at || at > now + 5_000) continue;
    observedAt = Math.max(observedAt ?? 0, Math.min(at, persistedAt));
    const data = query.state?.data;
    const page = Array.isArray(data?.pages) ? data.pages[0] : undefined;
    const rows = Array.isArray(data) ? data : Array.isArray(data?.sessions) ? data.sessions : Array.isArray(page?.data) ? page.data : Array.isArray(page?.sessions) ? page.sessions : [];
    for (const rawRow of rows.slice(0, 50)) {
      const row = object(rawRow), id = text(row?.id, 180); if (!id || !/^(cse|session)_[A-Za-z0-9_-]+$/.test(id)) continue;
      const rowAt = Math.min(at, persistedAt), fresh = now - rowAt <= ttl;
      const sessionStatus = text(row?.session_status, 80), lifecycleStatus = text(row?.lifecycle_status, 80), workerStatus = text(row?.worker_status, 80), connectionStatus = text(row?.connection_status, 80);
      // Claude persists the normalized activity status separately from lifecycle
      // status (catalog C3/m3). Archived queries may share IDs with an older
      // active query; retain their observation as a tombstone before filtering.
      if (sessionStatus === 'archived' || sessionStatus === 'deleted' ||
          lifecycleStatus === 'archived' || lifecycleStatus === 'deleted') {
        hiddenAt.set(id, Math.max(hiddenAt.get(id) ?? 0, rowAt));
        if ((sessions.get(id)?.observedAt ?? Infinity) <= rowAt) sessions.delete(id);
        if (hiddenAt.size > 1_000) fail();
        continue;
      }
      if ((hiddenAt.get(id) ?? -Infinity) >= rowAt) continue;
      let lastObservedState: CacheTaskState | undefined;
      const lifecycleAllowsActivity = lifecycleStatus === undefined || lifecycleStatus === 'active' ||
        (lifecycleStatus === 'paused' && sessionStatus === 'requires_action' && workerStatus === 'requires_action');
      if (lifecycleAllowsActivity && (connectionStatus === undefined || connectionStatus === 'connected')) {
        // Keep compatibility with legacy active rows, but do not infer activity
        // from pending, failed, conflicting worker status, or disconnected idle.
        if (workerStatus === 'running' && (sessionStatus === 'running' || sessionStatus === 'active')) lastObservedState = 'running';
        else if (workerStatus === 'requires_action' && (sessionStatus === 'requires_action' || sessionStatus === 'active')) lastObservedState = 'input';
        else if (workerStatus === 'idle' && (sessionStatus === 'idle' || sessionStatus === 'active')) lastObservedState = 'idle';
      }
      const state = fresh && lastObservedState ? lastObservedState : 'unknown';
      const record: ClaudeCacheSession = { id, title: text(row?.title) ?? 'Claude Code', state, observedAt: rowAt,
        ...(lastObservedState ? { lastObservedState } : {}), sessionStatus, lifecycleStatus, workerStatus, connectionStatus,
        environmentKind: text(row?.environment_kind, 80), updatedAt: text(row?.updated_at, 80) };
      const old = sessions.get(id); if (!old || rowAt > old.observedAt) sessions.set(id, record);
      if (sessions.size > 1_000) fail();
    }
  }
  if (observedAt === undefined) return { source: 'claude-desktop-cache', status: 'unavailable', persistedAt, sessions: [], reason: 'missing' };
  const fresh = now - observedAt <= ttl;
  return { source: 'claude-desktop-cache', status: fresh ? 'fresh' : 'stale', observedAt, persistedAt, sessions: [...sessions.values()], ...(fresh ? {} : { reason: 'stale' as const }) };
}

// Explicit origin, database, store, and primary-key allowlist. All temporary raw
// data is deleted before this function returns; never touch Chrome auth stores.
export function readClaudeCache(options: { originDir?: string; now?: number; ttlMs?: number; onDiagnostic?: (phase: string) => void } = {}): ClaudeCacheSnapshot {
  const origin = options.originDir ?? join(homedir(), 'Library/Application Support/Claude/IndexedDB/https_claude.ai_0.indexeddb.leveldb');
  const now = options.now ?? Date.now(), ttl = options.ttlMs ?? TTL;
  let temp: string | undefined, phase = 'copy';
  try {
    if (!lstatSync(origin).isDirectory() || lstatSync(origin).isSymbolicLink()) fail();
    const generation = generationMark(origin);
    if (memo?.origin === origin && memo.generation === generation && memo.ttl === ttl && (!memo.blob || fileMark(memo.blob.path) === memo.blob.mark))
      return expireSnapshot(memo.snapshot, now, ttl);
    temp = mkdtempSync(join(tmpdir(), 'task-island-cache-')); chmodSync(temp, 0o700);
    let total = 0; const copied: { path: string; size: number; mtimeMs: number; ctimeMs: number; ino: number }[] = [];
    for (const name of readdirSync(origin)) {
      if (!allowedFile.test(name)) continue;
      const path = join(origin, name), info = lstatSync(path); if (!info.isFile() || info.isSymbolicLink() || info.size > MAX || (total += info.size) > MAX * 2) fail();
      copyFileSync(path, join(temp, name)); chmodSync(join(temp, name), 0o600);
      copied.push({ path, size: info.size, mtimeMs: info.mtimeMs, ctimeMs: info.ctimeMs, ino: info.ino });
    }
    for (const before of copied) { const after = lstatSync(before.path); if (after.size !== before.size || after.mtimeMs !== before.mtimeMs || after.ctimeMs !== before.ctimeMs || after.ino !== before.ino) fail(); }
    if (generationMark(origin) !== generation) fail();
    const budget = { remaining: MAX * 2 };
    phase = 'leveldb'; const entries = liveEntries(temp, budget); let selected: Entry | undefined;
    phase = 'key-selection'; let candidates = 0;
    for (const entry of entries.values()) {
      if (entry.deleted) continue; const h = primaryCacheKey(entry.key); if (!h) continue;
      if (++candidates > 10) fail();
      let dbName: string | undefined, storeName: string | undefined;
      for (const e of entries.values()) {
        if (e.deleted) continue; const m = prefix(e.key);
        if (!m.db && !m.store && !m.index && e.key[m.n] === 201) {
          const p = { n: m.n + 1 }; slice(e.key, p, varint(e.key, p) * 2);
          const name = utf16(slice(e.key, p, varint(e.key, p) * 2));
          if (p.n === e.key.length && little(e.value) === h.db) dbName = name;
        }
        if (m.db !== h.db || m.store || m.index) continue;
        if (e.key.length === m.n + 1 && e.key[m.n] === 1) dbName = utf16(e.value);
        if (e.key[m.n] === 50) { const p = { n: m.n + 1 }, sid = varint(e.key, p); if (sid === h.store && e.key[p.n++] === 0 && p.n === e.key.length) storeName = utf16(e.value); }
      }
      if (dbName !== 'keyval-store' || storeName !== 'keyval') continue;
      if (selected) fail(); selected = entry;
    }
    if (!selected) return { source: 'claude-desktop-cache', status: 'unavailable', sessions: [], reason: 'missing' };
    const h = prefix(selected.key);
    let selectedBlob: { path: string; mark: string } | undefined;
    const loadBlob = (index: number, size: number): Buffer => {
      if (size > MAX || index > 1000) fail();
      const externalKey = Buffer.from(selected!.key), indexStart = 1 + (((externalKey[0] >>> 5) & 7) + 1) + (((externalKey[0] >>> 2) & 7) + 1);
      externalKey.fill(0, indexStart, h.n); externalKey[indexStart] = 3;
      const external = entries.get(externalKey.toString('hex')); if (!external || external.deleted) fail();
      const p = { n: 0 }; let number = 0, actualSize = 0;
      for (let i = 0; i <= index; i++) { if (slice(external.value, p, 1)[0] !== 0) fail(); number = varint(external.value, p); const chars = varint(external.value, p); slice(external.value, p, chars * 2); actualSize = varint(external.value, p); }
      if (actualSize !== size) fail();
      const relative = join(h.db.toString(16), ((number & 0xff00) >>> 8).toString(16).padStart(2, '0'), number.toString(16));
      const blobRoot = origin.replace(/\.leveldb$/, '.blob');
      for (const part of [blobRoot, join(blobRoot, h.db.toString(16)), join(blobRoot, h.db.toString(16), ((number & 0xff00) >>> 8).toString(16).padStart(2, '0'))]) {
        const directory = lstatSync(part); if (!directory.isDirectory() || directory.isSymbolicLink()) fail();
      }
      const path = join(blobRoot, relative), info = lstatSync(path);
      if (!info.isFile() || info.isSymbolicLink() || info.size !== size) fail();
      const copy = join(temp!, 'target-blob'); copyFileSync(path, copy); chmodSync(copy, 0o600);
      const after = lstatSync(path); if (after.size !== info.size || after.mtimeMs !== info.mtimeMs || after.ctimeMs !== info.ctimeMs || after.ino !== info.ino) fail();
      selectedBlob = { path, mark: fileMark(path) };
      return readFileSync(copy);
    };
    phase = 'structured-clone'; const value = decodedValue(selected.value, loadBlob, budget);
    phase = 'catalog'; const snapshot = sanitizeCacheSnapshot(value, now, ttl);
    memo = { origin, generation, ttl, blob: selectedBlob, snapshot };
    return expireSnapshot(snapshot, now, ttl);
  } catch { memo = undefined; options.onDiagnostic?.(phase); return { source: 'claude-desktop-cache', status: 'unavailable', sessions: [], reason: 'unsupported' }; }
  finally { if (temp) rmSync(temp, { recursive: true, force: true }); }
}
