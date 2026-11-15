import { applyPatches, enablePatches, type Patch } from 'immer';
import type { Session } from '../../shared/types';

enablePatches();
type ObjectValue = Record<string, any>;
type StreamVersion = 11 | 13;
export interface Projection extends ObjectValue {
  /** Locally selected, never accepted from the source snapshot or its patches. */
  streamVersion?: StreamVersion;
  threadRuntimeStatus?: { type: string; activeFlags?: string[] };
  requests?: Array<{ id?: string | number | null; requestId?: string | number | null; method?: string }>;
  turns?: ObjectValue[];
  turnHistory?: { kind?: string; history?: {
    entitiesByKey?: Record<string, ObjectValue>;
    islands?: Array<{ entries?: Array<{ value?: string }>; newerBoundary?: { status?: string } }>;
    isComplete?: boolean;
  } };
}

type Schema = { kind: 'scalar'; types: string[] } |
  { kind: 'object'; fields: Record<string, Schema> } |
  { kind: 'array'; item: Schema } | { kind: 'dictionary'; item: Schema };
const scalar = (...types: string[]): Schema => ({ kind: 'scalar', types });
const objectSchema = (fields: Record<string, Schema>): Schema => ({ kind: 'object', fields });
const array = (item: Schema): Schema => ({ kind: 'array', item });
const text = scalar('string');
const identity = scalar('string', 'number', 'null');
const turnSchema = objectSchema({ turnId: identity, id: identity,
  status: text, turnStartedAtMs: scalar('number', 'null') });
const boundarySchema = objectSchema({ status: text });
const historySchema = objectSchema({
  entitiesByKey: { kind: 'dictionary', item: turnSchema },
  islands: array(objectSchema({ entries: array(objectSchema({ value: text })),
    newerBoundary: boundarySchema, olderBoundary: boundarySchema })),
  isComplete: scalar('boolean'),
});
const rootSchema = objectSchema({
  id: text, title: scalar('string', 'null'), cwd: scalar('string', 'null'), updatedAt: scalar('number'),
  hasUnreadTurn: scalar('boolean'),
  threadRuntimeStatus: objectSchema({ type: text, activeFlags: array(text) }),
  requests: array(objectSchema({ id: identity, requestId: identity, method: text })),
  turns: array(turnSchema),
  turnHistory: objectSchema({ kind: text, history: historySchema }),
});
const forbidden = new Set(['__proto__', 'prototype', 'constructor']);
const isObject = (v: unknown): v is ObjectValue =>
  v !== null && typeof v === 'object' && !Array.isArray(v);
const own = (o: object, key: PropertyKey) => Object.prototype.hasOwnProperty.call(o, key);

function reduce(value: unknown, schema: Schema): any {
  if (schema.kind === 'scalar') {
    const type = value === null ? 'null' : typeof value;
    if (!schema.types.includes(type) || (type === 'number' && !Number.isFinite(value)))
      throw new Error('Unsupported Codex metadata field type.');
    return value;
  }
  if (schema.kind === 'array') {
    if (!Array.isArray(value)) throw new Error('Unsupported Codex metadata array.');
    // Keep every index. Dropping a malformed element would misapply later patches.
    return Array.from(value, item => reduce(item, schema.item));
  }
  if (!isObject(value)) throw new Error('Unsupported Codex metadata object.');
  const entries: Array<[string, unknown]> = [];
  for (const [key, item] of Object.entries(value)) {
    if (schema.kind === 'dictionary') {
      if (forbidden.has(key)) throw new Error('Unsafe Codex entity key.');
      entries.push([key, reduce(item, schema.item)]);
    } else if (own(schema.fields, key)) {
      entries.push([key, reduce(item, schema.fields[key])]);
    }
  }
  return Object.fromEntries(entries);
}

/** Validate wire metadata without retaining prompts, tools, text or request arguments. */
export function validateConversation(value: unknown, version: number): void {
  if (version !== 11 && version !== 13) throw new Error('Unsupported Codex stream version.');
  if (!isObject(value) || typeof value.id !== 'string' || !value.id)
    throw new Error('Missing Codex snapshot identity.');
  // Reducing validates the types of every field we will use; other fields are ignored.
  const state = reduce(value, rootSchema) as Projection;
  const runtime = state.threadRuntimeStatus;
  if (version === 13 && (!runtime || !Array.isArray(value.requests) || !Array.isArray(value.turns)))
    throw new Error('Missing Codex runtime metadata.');
  if (runtime && !['active', 'idle', 'notLoaded', 'systemError'].includes(runtime.type))
    throw new Error('Unsupported Codex runtime state.');
  if (state.turnHistory?.kind === 'canonical') {
    const history = state.turnHistory.history;
    if (!history || !isObject(history.entitiesByKey) || !Array.isArray(history.islands) ||
        history.islands.some(island => !Array.isArray(island.entries)))
      throw new Error('Unsupported Codex canonical history metadata.');
  }
}

/** Keep only status, navigation metadata and ordered turn identities. */
export function projectConversation(value: unknown, version: StreamVersion = 11): Projection {
  const out = reduce(value, rootSchema) as Projection;
  out.requests ??= [];
  out.turns ??= [];
  out.streamVersion = version;
  return out;
}

function patchSchema(path: Array<string | number>): { schema?: Schema; path: Array<string | number> } {
  let schema: Schema = rootSchema;
  const normalized: Array<string | number> = [];
  for (const part of path) {
    if ((typeof part !== 'string' && typeof part !== 'number') || forbidden.has(String(part)))
      throw new Error('Unsafe Codex patch path.');
    if (schema.kind === 'object') {
      if (typeof part !== 'string') throw new Error('Unsupported Codex object patch path.');
      if (!own(schema.fields, part)) return { path: normalized };
      schema = schema.fields[part];
      normalized.push(part);
    } else if (schema.kind === 'dictionary') {
      if (typeof part !== 'string') throw new Error('Unsupported Codex entity patch path.');
      schema = schema.item;
      normalized.push(part);
    } else if (schema.kind === 'array') {
      if (part === 'length') {
        schema = scalar('number');
        normalized.push(part);
      } else {
        const index = typeof part === 'string' && /^(0|[1-9]\d*)$/.test(part) ? Number(part) : part;
        if (typeof index !== 'number' || !Number.isSafeInteger(index) || index < 0 || index > 100_000)
          throw new Error('Unsupported Codex array patch path.');
        schema = schema.item;
        normalized.push(index);
      }
    } else return { path: normalized };
  }
  return { schema, path: normalized };
}

export function patchProjection(state: Projection, raw: unknown): Projection {
  if (!Array.isArray(raw)) throw new Error('Unsupported Codex patch format.');
  const version = state.streamVersion === 13 ? 13 : 11;
  const patches: Patch[] = [];
  for (const p of raw) {
    if (!p || !Array.isArray(p.path) || !['add', 'remove', 'replace'].includes(p.op))
      throw new Error('Unsupported Codex patch.');
    // Check all segments before deciding that an unobserved field can be ignored.
    if (p.path.some((part: unknown) => (typeof part !== 'string' && typeof part !== 'number') ||
        forbidden.has(String(part)))) throw new Error('Unsafe Codex patch path.');
    if (!p.path.length) {
      if (p.op === 'remove') throw new Error('Codex projection root cannot be removed.');
      if (version === 13) validateConversation(p.value, version);
      patches.push({ op: p.op, path: [], value: projectConversation(p.value, version) });
      continue;
    }
    const resolved = patchSchema(p.path);
    if (!resolved.schema) continue;
    if (resolved.path.at(-1) === 'length' && p.op !== 'replace')
      throw new Error('Unsupported Codex array length operation.');
    if (p.op === 'remove') patches.push({ op: p.op, path: resolved.path });
    else {
      const value = reduce(p.value, resolved.schema);
      if (resolved.path.at(-1) === 'length' &&
          (!Number.isSafeInteger(value) || value < 0 || value > 100_000))
        throw new Error('Unsupported Codex array length.');
      patches.push({ op: p.op, path: resolved.path, value });
    }
  }
  const changed = applyPatches(projectConversation(state, version), patches);
  if (version === 13) {
    // Validate before defaults could hide missing required fields.
    validateConversation(changed, version);
    const replacesRoot = raw.length === 1 && raw[0]?.path?.length === 0 && raw[0].op !== 'remove';
    if (state.turnHistory?.kind === 'canonical' && changed.turnHistory?.kind !== 'canonical' && !replacesRoot)
      throw new Error('Missing or changed Codex canonical history mode after a patch.');
  }
  return projectConversation(changed, version);
}

export function latestTurn(state: Projection): ObjectValue | undefined {
  if (state.turnHistory?.kind === 'canonical') {
    const history = state.turnHistory.history;
    const island = history?.islands?.at(-1);
    // Loaded older pages or stale entities cannot establish the current head.
    if (island?.newerBoundary?.status !== 'exhausted') return undefined;
    const key = island.entries?.at(-1)?.value;
    if (typeof key !== 'string' || forbidden.has(key) || !history?.entitiesByKey ||
        !own(history.entitiesByKey, key)) return undefined;
    return history.entitiesByKey[key];
  }
  if (state.streamVersion === 13) {
    // v13 noncanonical history uses source order too; unknown history modes fail closed.
    if (state.turnHistory && state.turnHistory.kind !== 'legacy') return undefined;
    return state.turns?.at(-1);
  }
  // Retain the previously supported v11 noncanonical fallback.
  return [...(state.turns || []), ...Object.values(state.turnHistory?.history?.entitiesByKey || {})]
    .sort((a, b) => (Number(a.turnStartedAtMs) || 0) - (Number(b.turnStartedAtMs) || 0)).at(-1);
}

export function sessionFromProjection(base: Session, state: Projection, now = Date.now()): Session {
  const runtime = state.threadRuntimeStatus;
  const flags = runtime?.activeFlags || [];
  const request = state.requests?.[0];
  const latest = latestTurn(state);
  const turnId = state.streamVersion === 13 ? latest?.turnId : latest?.turnId || latest?.id;
  const stableTurnId = typeof turnId === 'string' && turnId ? turnId : null;
  const terminal = latest && ['completed', 'interrupted', 'failed'].includes(latest.status);
  let status: Session['status'] = 'unknown',
    detail = 'Codex has not reported a supported runtime state.', attentionKey: string | null = null;
  if (request || flags.includes('waitingOnApproval') || flags.includes('waitingOnUserInput')) {
    status = 'review';
    detail = flags.includes('waitingOnApproval') || /approval/i.test(request?.method || '')
      ? 'Waiting for approval in Codex' : 'Waiting for your input in Codex';
    const requestId = request?.id ?? request?.requestId;
    attentionKey = requestId !== undefined && requestId !== null ? `request:${requestId}`
      : stableTurnId ? `waiting:${stableTurnId}:${flags.join(',')}` : null;
  } else if (runtime?.type === 'active') {
    status = 'running'; detail = 'Codex is working';
  } else if (runtime?.type === 'systemError') {
    status = 'review'; detail = 'Codex reported an error';
    attentionKey = stableTurnId ? `error:${stableTurnId}` : null;
  } else if (runtime?.type === 'idle' || runtime?.type === 'notLoaded') {
    if (typeof state.hasUnreadTurn === 'boolean') {
      status = state.hasUnreadTurn ? 'review' : 'read';
      detail = state.hasUnreadTurn ? latest?.status === 'interrupted' ? 'Turn interrupted · unread in Codex'
        : latest?.status === 'failed' ? 'Turn failed · unread in Codex' : 'New response in Codex'
        : 'Read in Codex';
      if (stableTurnId && (state.streamVersion !== 13 || terminal)) attentionKey = `result:${stableTurnId}`;
    } else detail = 'Codex has not supplied a read receipt.';
  }
  return { ...base,
    title: typeof state.title === 'string' && state.title.trim() ? state.title : base.title,
    directory: typeof state.cwd === 'string' ? state.cwd : base.directory,
    updatedAt: typeof state.updatedAt === 'number' ? state.updatedAt : base.updatedAt,
    status, detail, attentionKey, activityAt: Number(latest?.turnStartedAtMs) || undefined,
    awaitingInput: Boolean(request || flags.includes('waitingOnApproval') || flags.includes('waitingOnUserInput')),
    observedAt: now, evidence: 'live' };
}
