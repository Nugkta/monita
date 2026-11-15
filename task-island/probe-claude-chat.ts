// Read-only probe: what, on this Mac, changes while a Claude *chat* task runs?
// Task Island reads only Claude's Code sources. This looks for a source it could
// read for chat tasks, and prints STRUCTURE ONLY: list names, field names,
// status-style values, counts, and which files change. It never prints titles,
// prompts, replies, paths chosen by the user, or log text. Nothing is written
// except this report to stdout; no task is opened or changed; no network use.
//
//   node task-island/probe-claude-chat.mjs [seconds] [--find <session id fragment>]
import { createHash } from 'node:crypto';
import { closeSync, openSync, readdirSync, readFileSync, readSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, extname } from 'node:path';
import { readClaudeCache } from './claude-cache';

const uuid = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;
const token = /^[a-z][a-z0-9_]{0,31}$/;
const fieldName = /^[A-Za-z_][A-Za-z0-9_]{0,40}$/;
const stateField = /(status|state|kind|type|mode|phase|^is_|^has_|^is[A-Z]|running|active|archiv|connect|pending|complete|unread|stream)/i;
const idField = /(^id$|_id$|Id$|uuid$)/;
const genericNames = new Set(['sessions', 'session', 'metadata', 'config', 'state', 'index', 'manifest', 'transcript', 'messages',
  'events', 'outputs', 'uploads', 'audit', 'logs', 'log', 'cache', 'tmp', 'data', 'db', 'settings', 'registry', 'current', 'lock',
  'history', 'tasks', 'task', 'status', 'meta', 'info', 'main', 'window', 'renderer', 'mcp', 'agent', 'plugins', 'skills']);

export function typeOf(value: unknown): string {
  if (value === null) return 'null';
  if (Array.isArray(value)) return `array(${value.length})`;
  if (typeof value === 'string') return value.length > 200 ? 'long-string' : 'string';
  return typeof value;
}
/** The prefix of an id such as session_…, or its general form. Never the id itself. */
export function idClass(value: unknown): string {
  if (typeof value !== 'string') return typeOf(value);
  const prefix = /^([a-z]{2,12})_[A-Za-z0-9_-]{4,}$/.exec(value);
  if (prefix) return prefix[1] + '_…';
  uuid.lastIndex = 0;
  return uuid.test(value) ? 'uuid' : 'string';
}
function bump(map: Map<string, number>, key: string) { map.set(key, (map.get(key) ?? 0) + 1); }
const show = (map: Map<string, number>) => [...map].sort((a, b) => b[1] - a[1]).slice(0, 12).map(([k, n]) => `${k}×${n}`).join(' ');

export interface RowSummary { fields: Map<string, Set<string>>; states: Map<string, Map<string, number>>; ids: Map<string, Map<string, number>>; rows: number }
/** Field names, value types, and the values of status-style fields when they are short code tokens. */
export function summarizeRows(rows: unknown[]): RowSummary {
  const out: RowSummary = { fields: new Map(), states: new Map(), ids: new Map(), rows: 0 };
  for (const row of rows.slice(0, 500)) {
    if (!row || typeof row !== 'object' || Array.isArray(row)) continue;
    out.rows++;
    for (const [key, value] of Object.entries(row as Record<string, unknown>)) {
      if (!fieldName.test(key)) { (out.fields.get('<other keys>') ?? out.fields.set('<other keys>', new Set()).get('<other keys>')!).add('…'); continue; }
      (out.fields.get(key) ?? out.fields.set(key, new Set()).get(key)!).add(typeOf(value).replace(/\(\d+\)/, ''));
      if (stateField.test(key) && (typeof value === 'boolean' || value === null || (typeof value === 'string' && token.test(value))))
        bump(out.states.get(key) ?? out.states.set(key, new Map()).get(key)!, String(value));
      if (idField.test(key)) bump(out.ids.get(key) ?? out.ids.set(key, new Map()).get(key)!, idClass(value));
    }
  }
  return out;
}
/** Arrays of objects up to four levels inside a query's data, by structural path. */
export function findRowArrays(data: unknown, path = 'data', depth = 0, out: { path: string; rows: unknown[] }[] = []) {
  if (depth > 4 || !data || typeof data !== 'object') return out;
  if (Array.isArray(data)) {
    if (data.length && data.every(v => v && typeof v === 'object' && !Array.isArray(v))) {
      out.push({ path, rows: data });
      for (const row of data.slice(0, 3)) findRowArrays(row, path + '[]', depth + 1, out);
    }
    return out;
  }
  for (const [key, value] of Object.entries(data as Record<string, unknown>))
    if (fieldName.test(key)) findRowArrays(value, `${path}.${key}`, depth + 1, out);
  return out;
}
export function keyShape(queryKey: unknown): { name: string; rest: string } {
  const parts = Array.isArray(queryKey) ? queryKey : [queryKey];
  const first = parts[0];
  // A list's own name is written by the app and is letters only; anything with digits or spaces could be an id or typed text.
  const name = typeof first === 'string' && /^[A-Za-z][A-Za-z_.:\/-]{1,80}$/.test(first) ? first : `<${idClass(first)}>`;
  const rest = parts.slice(1).map(part => part && typeof part === 'object' && !Array.isArray(part)
    ? '{' + Object.keys(part as object).filter(k => fieldName.test(k)).slice(0, 8).join(',') + '}'
    : typeof part === 'string' ? idClass(part) : typeOf(part)).join(', ');
  return { name, rest };
}
/** Objects anywhere in the cache that carry the wanted id, with their status-style fields. */
export function findById(root: unknown, fragment: string): { where: string; states: string }[] {
  const hits: { where: string; states: string }[] = [], wanted = fragment.toLowerCase();
  const walk = (node: unknown, path: string, depth: number) => {
    if (depth > 9 || !node || typeof node !== 'object' || hits.length >= 20) return;
    if (Array.isArray(node)) { node.slice(0, 2000).forEach(child => walk(child, path + '[]', depth + 1)); return; }
    const entries = Object.entries(node as Record<string, unknown>);
    const own = entries.filter(([key, value]) => typeof value === 'string' && value.toLowerCase().includes(wanted) && fieldName.test(key));
    if (own.length) {
      const states = entries.filter(([key, value]) => fieldName.test(key) && stateField.test(key) &&
        (typeof value === 'boolean' || value === null || (typeof value === 'string' && token.test(value))))
        .map(([key, value]) => `${key}=${value}`).join(' ');
      const times = entries.filter(([key, value]) => fieldName.test(key) && /(_at$|At$|time)/.test(key) && (typeof value === 'string' || typeof value === 'number'))
        .map(([key, value]) => `${key}#${createHash('sha256').update(String(value)).digest('hex').slice(0, 4)}`).join(' ');
      hits.push({ where: `${path} (matched in ${own.map(([key]) => key).join(',')})`, states: [states, times].filter(Boolean).join(' | ') });
    }
    for (const [key, value] of entries) if (fieldName.test(key)) walk(value, `${path}.${key}`, depth + 1);
  };
  walk(root, '', 0);
  return hits;
}
export function describeCache(root: unknown, now: number, find?: string): string[] {
  const lines: string[] = [];
  const queries = (root as any)?.clientState?.queries;
  if (!Array.isArray(queries)) return ['cache: no query list found'];
  const byName = new Map<string, { count: number; newest: number; rest: Set<string>; arrays: Map<string, RowSummary> }>();
  for (const query of queries.slice(0, 500)) {
    const shape = keyShape(query?.queryKey), at = typeof query?.state?.dataUpdatedAt === 'number' ? query.state.dataUpdatedAt : 0;
    const entry = byName.get(shape.name) ?? byName.set(shape.name, { count: 0, newest: 0, rest: new Set(), arrays: new Map() }).get(shape.name)!;
    entry.count++; entry.newest = Math.max(entry.newest, at); if (shape.rest) entry.rest.add(shape.rest);
    for (const found of findRowArrays(query?.state?.data)) if (!entry.arrays.has(found.path)) entry.arrays.set(found.path, summarizeRows(found.rows));
  }
  lines.push(`cache: ${queries.length} queries under ${byName.size} names`);
  for (const [name, entry] of [...byName].sort((a, b) => b[1].newest - a[1].newest)) {
    lines.push(`  ${name} ×${entry.count}, refreshed ${entry.newest ? Math.round((now - entry.newest) / 1000) + 's ago' : 'never'}` +
      (entry.rest.size ? `, key: [${[...entry.rest].slice(0, 3).join(' | ')}]` : ''));
    for (const [path, summary] of [...entry.arrays].slice(0, 6)) {
      if (!summary.rows) continue;
      lines.push(`    ${path}: ${summary.rows} rows, fields: ${[...summary.fields.keys()].slice(0, 40).join(', ')}`);
      for (const [field, values] of summary.states) lines.push(`      ${field}: ${show(values)}`);
      for (const [field, values] of summary.ids) lines.push(`      ${field} ids: ${show(values)}`);
    }
  }
  if (find) {
    const hits = findById(root, find);
    lines.push(hits.length ? `this conversation appears in the cache ${hits.length} time(s):` : 'this conversation does NOT appear anywhere in the cache');
    for (const hit of hits) lines.push(`  ${hit.where}${hit.states ? ' → ' + hit.states : ''}`);
  }
  return lines;
}

/** A path with every user-specific part replaced by its general form. */
export function maskPath(relative: string): string {
  return relative.split('/').map((segment, depth) => {
    const ext = extname(segment), stem = ext ? segment.slice(0, -ext.length) : segment;
    uuid.lastIndex = 0;
    if (uuid.test(stem)) return stem.replace(uuid, '<uuid>').replace(/[^<>a-z_-]+/gi, m => /^[A-Za-z_-]+$/.test(m) ? m : '…') + ext;
    if (/^[a-z]{2,12}_[A-Za-z0-9_-]{6,}$/.test(stem)) return stem.split('_')[0] + '_<id>' + ext;
    if (/^\d+$/.test(stem)) return '<n>' + ext;
    if (depth === 0 || genericNames.has(stem.toLowerCase())) return segment;
    return '<name>' + (/^\.[A-Za-z0-9]{1,8}$/.test(ext) ? ext : '');
  }).join('/');
}
type Marks = Map<string, { size: number; mtime: number }>;
export function scan(root: string, maxDepth = 5, limit = 40_000): Marks {
  const out: Marks = new Map(); const skip = /^(Cache|Code Cache|GPUCache|DawnCache|DawnGraphiteCache|DawnWebGPUCache|blob_storage|Crashpad|ShaderCache|GrShaderCache|vm_bundles|node_modules|\.git)$/;
  const walk = (dir: string, relative: string, depth: number) => {
    if (depth > maxDepth || out.size >= limit) return;
    let entries; try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      if (entry.isSymbolicLink()) continue;
      const path = join(dir, entry.name), rel = relative ? `${relative}/${entry.name}` : entry.name;
      if (entry.isDirectory()) { if (!skip.test(entry.name)) walk(path, rel, depth + 1); }
      else if (entry.isFile()) { try { const s = statSync(path); out.set(rel, { size: s.size, mtime: s.mtimeMs }); } catch {} }
      if (out.size >= limit) return;
    }
  };
  walk(root, '', 0);
  return out;
}
export function changes(before: Marks, after: Marks): Map<string, { files: number; grew: number }> {
  const out = new Map<string, { files: number; grew: number }>();
  for (const [path, mark] of after) {
    const old = before.get(path);
    if (old && old.size === mark.size && old.mtime === mark.mtime) continue;
    const key = maskPath(path) + (old ? '' : ' (new)'), entry = out.get(key) ?? out.set(key, { files: 0, grew: 0 }).get(key)!;
    entry.files++; entry.grew += mark.size - (old?.size ?? 0);
  }
  return out;
}
/** Shape of the JSON records in a store: field names, types and status-style values only. */
export function describeJsonStore(root: string, find?: string): string[] {
  const lines: string[] = [], rows: unknown[] = [], matches: string[] = [];
  const marks = scan(root, 6, 5_000);
  for (const [relative, mark] of marks) {
    if (!relative.endsWith('.json') || mark.size > 2 * 1024 * 1024 || rows.length >= 400) continue;
    try {
      const textValue = readFileSync(join(root, relative), 'utf8'), value = JSON.parse(textValue);
      if (value && typeof value === 'object' && !Array.isArray(value)) {
        rows.push(value);
        if (find && (relative.toLowerCase().includes(find.toLowerCase()) || textValue.toLowerCase().includes(find.toLowerCase()))) matches.push(relative);
      }
    } catch {}
  }
  const shapes = new Map<string, number>();
  for (const relative of marks.keys()) bump(shapes, maskPath(relative));
  lines.push(`  ${marks.size} files; layouts: ${show(shapes)}`);
  if (rows.length) {
    const summary = summarizeRows(rows);
    lines.push(`  ${summary.rows} JSON records, fields: ${[...summary.fields.keys()].slice(0, 80).join(', ')}`);
    for (const [field, values] of summary.states) lines.push(`    ${field}: ${show(values)}`);
    for (const [field, values] of summary.ids) lines.push(`    ${field} ids: ${show(values)}`);
  }
  if (find) lines.push(matches.length ? `  this conversation is in ${matches.length} record(s): ${[...new Set(matches.map(maskPath))].join(', ')}`
    : '  this conversation is not in these records');
  return lines;
}
/** The record(s) for one conversation, reduced to status-style values and which timestamps moved. */
export function recordState(root: string, find: string): string {
  const parts: string[] = [];
  for (const [relative, mark] of scan(root, 6, 5_000)) {
    if (!relative.endsWith('.json') || mark.size > 2 * 1024 * 1024) continue;
    try {
      const textValue = readFileSync(join(root, relative), 'utf8');
      if (!relative.toLowerCase().includes(find.toLowerCase()) && !textValue.toLowerCase().includes(find.toLowerCase())) continue;
      const value = JSON.parse(textValue);
      const bits = Object.entries(value as Record<string, unknown>).filter(([key]) => fieldName.test(key)).flatMap(([key, v]) =>
        stateField.test(key) && (typeof v === 'boolean' || v === null || (typeof v === 'string' && token.test(v))) ? [`${key}=${v}`]
          : typeof v === 'number' && /(At$|_at$|Turns$|count$|Count$)/.test(key) ? [`${key}=${v > 1e11 ? '#' + (v % 100000) : v}`] : []);
      parts.push(`${maskPath(relative)}: ${bits.join(' ')}`);
    } catch {}
  }
  return parts.join(' ;; ');
}
const logWords = ['session', 'turn', 'status', 'running', 'idle', 'complete', 'stop', 'requires_action', 'stream', 'sse', 'message_stop', 'error'];
/** For newly appended log lines: how many, their bracketed tags, and counts of fixed keywords. No log text. */
export function describeAppended(textValue: string): string {
  const tags = new Map<string, number>(), words = new Map<string, number>();
  const lines = textValue.split('\n').filter(Boolean);
  for (const line of lines) {
    for (const match of line.slice(0, 200).matchAll(/\[([A-Za-z][A-Za-z0-9_.:-]{0,39})\]/g)) bump(tags, match[1]);
    const lower = line.toLowerCase();
    for (const word of logWords) if (lower.includes(word)) bump(words, word);
  }
  return `${lines.length} lines; tags: ${show(tags) || 'none'}; keywords: ${show(words) || 'none'}`;
}
function readTail(path: string, from: number, to: number): string {
  const length = Math.min(512 * 1024, Math.max(0, to - from)); if (!length) return '';
  const buffer = Buffer.alloc(length); let fd: number | undefined;
  try { fd = openSync(path, 'r'); readSync(fd, buffer, 0, length, to - length); return buffer.toString('utf8'); }
  catch { return ''; } finally { if (fd !== undefined) closeSync(fd); }
}

function main() {
  const args = process.argv.slice(2);
  const seconds = Math.min(3_600, Math.max(4, Number(args.find(a => /^\d+$/.test(a)) ?? 180)));
  const findIndex = args.indexOf('--find');
  const find = findIndex >= 0 && /^[A-Za-z0-9_-]{6,64}$/.test(args[findIndex + 1] ?? '') ? args[findIndex + 1] : undefined;
  const support = join(homedir(), 'Library', 'Application Support', 'Claude');
  const logs = join(homedir(), 'Library', 'Logs', 'Claude');
  const registry = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'sessions');
  const clock = () => new Date().toTimeString().slice(0, 8);
  const print = (line: string) => process.stdout.write(line + '\n');

  print(`Claude chat probe, ${seconds}s, structure only. ${find ? 'Looking for one conversation by id.' : ''}`);
  let top: string[] = []; try { top = readdirSync(support, { withFileTypes: true }).filter(e => e.isDirectory()).map(e => e.name).sort(); } catch {}
  print(`stores under the app's data folder: ${top.map(name => maskPath(name)).join(', ') || 'none readable'}`);
  for (const store of ['local-agent-mode-sessions', 'claude-code-sessions']) { print(`${store}:`); for (const line of describeJsonStore(join(support, store), find)) print(line); }
  const registryRows: unknown[] = [];
  try { for (const name of readdirSync(registry)) if (/^\d+\.json$/.test(name)) try { registryRows.push(JSON.parse(readFileSync(join(registry, name), 'utf8'))); } catch {} } catch {}
  const registrySummary = summarizeRows(registryRows);
  print(`process registry: ${registrySummary.rows} entries; fields: ${[...registrySummary.fields.keys()].join(', ')}`);
  for (const [field, values] of registrySummary.states) print(`  ${field}: ${show(values)}`);
  print(`  entrypoints: ${show(registryRows.reduce<Map<string, number>>((map, row: any) => (bump(map, token.test(String(row?.entrypoint ?? '').replace(/-/g, '_')) ? String(row.entrypoint) : 'other'), map), new Map()))}`);

  let cacheLines: string[] = [], cacheChanged = false;
  const readCache = () => { cacheChanged = false; const result = readClaudeCache({ inspect: value => { cacheChanged = true; cacheLines = describeCache(value, Date.now(), find); } }); return result.status; };
  print(`cache status: ${readCache()}`); for (const line of cacheLines) print(line);
  let findLine = cacheLines.filter(line => line.includes('matched in')).join(' ;; ');
  let recordLine = find ? ['local-agent-mode-sessions', 'claude-code-sessions'].map(store => recordState(join(support, store), find)).filter(Boolean).join(' ;; ') : '';
  if (recordLine) print(`record now: ${recordLine}`);

  let disk = scan(support), logMarks = scan(logs, 2, 500);
  const totals = new Map<string, { files: number; grew: number; times: number }>();
  print(`\nwatching ${disk.size} files and ${logMarks.size} logs. Lines below are changes only.`);
  const started = Date.now();
  const timer = setInterval(() => {
    const status = readCache();
    if (cacheChanged) {
      const nowFind = cacheLines.filter(line => line.includes('matched in')).join(' ;; ');
      const fresh = cacheLines.filter(line => /refreshed [0-5]s ago/.test(line)).map(line => line.trim().split(' ')[0]).join(', ');
      print(`${clock()} cache rewritten (${status}); just refreshed: ${fresh || 'nothing in the last 5s'}`);
      if (find && nowFind !== findLine) { print(`${clock()}   this conversation in cache: ${nowFind || 'gone'}`); findLine = nowFind; }
    }
    const nextDisk = scan(support);
    for (const [path, change] of changes(disk, nextDisk)) {
      const total = totals.get(path) ?? totals.set(path, { files: 0, grew: 0, times: 0 }).get(path)!;
      if (total.times < 3) print(`${clock()} file changed: ${path} (${change.files} file(s), ${change.grew >= 0 ? '+' : ''}${change.grew} bytes)`);
      total.files += change.files; total.grew += change.grew; total.times++;
    }
    disk = nextDisk;
    if (find) {
      const next = ['local-agent-mode-sessions', 'claude-code-sessions'].map(store => recordState(join(support, store), find)).filter(Boolean).join(' ;; ');
      if (next !== recordLine) { print(`${clock()} record changed: ${next}`); recordLine = next; }
    }
    const nextLogs = scan(logs, 2, 500);
    for (const [name, mark] of nextLogs) {
      const old = logMarks.get(name);
      if (old && mark.size > old.size) print(`${clock()} log ${maskPath(name)} grew: ${describeAppended(readTail(join(logs, name), old.size, mark.size))}`);
    }
    logMarks = nextLogs;
    if (Date.now() - started >= seconds * 1000) {
      clearInterval(timer);
      print(`\ntotals over ${seconds}s:`);
      for (const [path, total] of [...totals].sort((a, b) => b[1].times - a[1].times).slice(0, 40)) print(`  ${path}: changed ${total.times}×, ${total.grew >= 0 ? '+' : ''}${total.grew} bytes`);
      print('probe finished');
    }
  }, 2_000);
}
if (process.argv[1] && /probe-claude-chat\.(mjs|ts)$/.test(process.argv[1])) main();
