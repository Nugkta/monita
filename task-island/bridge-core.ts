import type { ProviderId, ProviderHealth, Session } from '../monitor-probe/source/src/shared/types';
import type { ClaudeCacheSnapshot } from './claude-cache';
import { herdrAddress } from '../monitor-probe/source/src/providers/herdr/projection';

export type BridgeStateName = 'running' | 'input' | 'idle' | 'review' | 'read' | 'error' | 'unknown';
export type BridgeHealth = 'connecting' | 'live' | 'degraded' | 'offline';
export interface BridgeTask {
  id: string;
  provider: ProviderId;
  title: string;
  state: BridgeStateName;
  resultKey: string | null;
  sourceURL: string | null;
  observedAt: number;
  evidence: 'live' | 'history' | 'unavailable';
  updatedAt: number;
  observationSource?: 'claude-cache';
  lastObservedState?: 'running' | 'input' | 'idle';
  availabilityReason?: 'catalog-only' | 'source-offline' | 'runtime-unavailable' | 'stale-cache' | 'remote-disconnected' | 'metadata-only' | 'turn-record-only';
  /**
   * 'turn-record': resultKey comes from the task's own persisted turn record, so
   * it is a stable completion identity in every state, including unknown runtime,
   * and a null resultKey means no turn has completed yet.
   */
  completionTracking?: 'turn-record';
}
export interface BridgeSnapshot {
  type: 'snapshot'; version: 1; generatedAt: number;
  providers: Array<{ id: ProviderId; health: BridgeHealth }>;
  tasks: BridgeTask[];
}

const codexID = /^[A-Za-z0-9][A-Za-z0-9_-]{5,127}$/;
const claudeID = /^local_[A-Za-z0-9_-]{1,128}$/;
const claudeRemoteID = /^(?:cse|session)_[A-Za-z0-9_-]{1,128}$/;
const claudeCLI = /^cli_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const hostID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const cacheTTL = 20_000;
const resultID = /^(?:result|error):[A-Za-z0-9][A-Za-z0-9_.:-]{0,511}$/;
const healthNames = new Set<BridgeHealth>(['connecting', 'live', 'degraded', 'offline']);

export function validExternalID(provider: ProviderId, value: unknown): value is string {
  return typeof value === 'string' && (provider === 'codex' ? codexID.test(value)
    : provider === 'herdr' ? herdrAddress.test(value)
    : claudeID.test(value) || claudeCLI.test(value) || claudeRemoteID.test(value));
}

export function sourceURL(provider: ProviderId, externalID: unknown, hostId?: string): string | null {
  // Herdr desktop has no link scheme: Open only brings the app forward.
  if (provider === 'herdr' || !validExternalID(provider, externalID)) return null;
  if (provider === 'codex') {
    if (hostId !== undefined && !hostID.test(hostId)) return null;
    return `codex://threads/${encodeURIComponent(externalID)}` +
      (hostId && hostId !== 'local' ? `?hostId=${encodeURIComponent(hostId)}` : '');
  }
  if (claudeRemoteID.test(externalID)) return `claude://code/${encodeURIComponent(externalID)}`;
  return claudeID.test(externalID)
    ? `claude://code/continue?session=${encodeURIComponent(externalID)}` : null;
}

const boundedTime = (value: unknown, now: number) =>
  typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= now + 60_000
    ? Math.floor(value) : 0;
const fallbackTitle = (provider: ProviderId) =>
  provider === 'codex' ? 'Codex task' : provider === 'herdr' ? 'Herdr task' : 'Claude task';
const safeTitle = (value: unknown, provider: ProviderId) => {
  if (typeof value !== 'string') return fallbackTitle(provider);
  const clean = value.replace(/[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/g, ' ').trim();
  const title = Array.from(clean).slice(0, 500).join('');
  return title || fallbackTitle(provider);
};

/** Whitelist UI navigation/status metadata. Never serialize the source Session. */
export function toBridgeTask(session: Session, health: BridgeHealth, now = Date.now()): BridgeTask | null {
  if (!session || session.archived || !['codex', 'claude', 'herdr'].includes(session.provider) ||
      !validExternalID(session.provider, session.externalId)) return null;
  let evidence: BridgeTask['evidence'] = ['live', 'history', 'unavailable'].includes(session.evidence)
    ? session.evidence : 'unavailable';
  if (evidence === 'live' && (health === 'offline' || health === 'connecting')) evidence = 'unavailable';
  let state: BridgeStateName = 'unknown';
  if (evidence === 'live') {
    if (session.awaitingInput === true) state = 'input';
    else if (session.status === 'running') state = 'running';
    else if (session.status === 'read') state = 'read';
    else if (session.status === 'review') state = session.attentionKey?.startsWith('error:') ||
      /\b(?:error|failed|interrupted)\b/i.test(session.detail) ? 'error' : 'review';
  }
  const liveKey = session.provider !== 'herdr' && ['review', 'read', 'error'].includes(state) &&
    typeof session.attentionKey === 'string' && resultID.test(session.attentionKey)
    ? session.attentionKey : null;
  // Completion identity is independent of runtime evidence: the task's own turn
  // record names the last finished turn even when nothing says what it is doing now.
  const tracked = session.provider === 'claude' && session.recordedResultKey !== undefined;
  const recordedKey = tracked && typeof session.recordedResultKey === 'string' &&
    resultID.test(session.recordedResultKey) ? session.recordedResultKey : null;
  const resultKey = liveKey ?? recordedKey;
  return {
    id: `${session.provider}:${session.externalId}`,
    provider: session.provider,
    title: safeTitle(session.title, session.provider),
    state, resultKey, sourceURL: sourceURL(session.provider, session.externalId, session.hostId),
    observedAt: boundedTime(session.observedAt, now), evidence,
    updatedAt: boundedTime(session.updatedAt, now),
    ...(tracked ? { completionTracking: 'turn-record' as const } : {}),
    ...(state === 'unknown' ? { availabilityReason: health === 'offline' || health === 'connecting'
      ? 'source-offline' as const : evidence === 'history' ? 'catalog-only' as const
      : tracked ? 'turn-record-only' as const : 'runtime-unavailable' as const } : {}),
  };
}

const remoteSuffix = (id: string) => id.replace(/^(?:cse|session)_/, '');

/** Stores source observations in memory only; snapshots are always reduced. */
export class BridgeState {
  private records = new Map<ProviderId, { health: BridgeHealth; sessions: Session[]; tracked: string }>();
  private claudeCache?: ClaudeCacheSnapshot;
  constructor(providerIDs: ProviderId[] = ['codex', 'claude']) {
    for (const id of providerIDs) this.records.set(id, { health: 'connecting', sessions: [], tracked: '' });
  }
  setHealth(id: ProviderId, value: Pick<ProviderHealth, 'state'>) {
    const record = this.records.get(id);
    if (record) record.health = healthNames.has(value.state as BridgeHealth) ? value.state : 'offline';
  }
  setSessions(id: ProviderId, sessions: Session[], track: (ids: string[]) => void) {
    const record = this.records.get(id);
    if (!record) return;
    record.sessions = sessions.filter(session => session.provider === id);
    const ids = [...new Set(record.sessions.filter(s => !s.archived && validExternalID(id, s.externalId))
      .map(s => s.externalId))].sort();
    const signature = JSON.stringify(ids);
    if (signature !== record.tracked) {
      // Set before calling track: fixture or source callbacks can publish synchronously.
      record.tracked = signature;
      track(ids);
    }
  }
  setClaudeCache(value: ClaudeCacheSnapshot) {
    // Retain only stale navigation metadata on a failed refresh, never runtime.
    this.claudeCache = value.status === 'unavailable' && this.claudeCache
      ? { ...this.claudeCache, status: 'stale' } : value;
  }
  snapshot(now = Date.now()): BridgeSnapshot {
    const tasks: BridgeTask[] = [];
    const providers: BridgeSnapshot['providers'] = [];
    // A Claude CLI running in a local Herdr terminal is listed once, as the Herdr task.
    // Until herdr has answered, any CLI task with a live process may be one of its
    // terminals: holding it back keeps a duplicate out of the persisted review queue.
    const herdrPending = this.records.get('herdr')?.health === 'connecting';
    const inHerdr = new Set((this.records.get('herdr')?.sessions ?? [])
      .filter(s => !s.externalId.includes('/') && typeof s.terminalPid === 'number')
      .map(s => s.terminalPid));
    for (const [id, record] of this.records) {
      providers.push({ id, health: record.health });
      for (const session of record.sessions) {
        if (id === 'claude' && typeof session.terminalPid === 'number' &&
            (herdrPending || inHerdr.has(session.terminalPid))) continue;
        const task = toBridgeTask(session, record.health, now);
        if (task) tasks.push(task);
      }
    }
    if (this.claudeCache && this.records.has('claude')) {
      let freshCount = 0;
      // A local task published through Remote Control also appears in the remote
      // list. Its own record is the better source, so the task is listed once.
      const published = new Set<string>();
      for (const session of this.records.get('claude')?.sessions ?? [])
        if (!session.archived && validExternalID('claude', session.externalId))
          for (const alias of (session.remoteAliases ?? []).slice(0, 32))
            if (typeof alias === 'string' && claudeRemoteID.test(alias)) published.add(remoteSuffix(alias));
      for (const row of this.claudeCache.sessions.slice(0, 1_000)) {
        if (!claudeRemoteID.test(row.id)) continue;
        if (published.has(remoteSuffix(row.id))) continue;
        const observedAt = boundedTime(row.observedAt, now);
        const fresh = this.claudeCache.status === 'fresh' && observedAt > 0 &&
          observedAt <= now + 1_000 && now - observedAt <= cacheTTL;
        const state = fresh && ['running', 'input', 'idle'].includes(row.state) ? row.state : 'unknown';
        const task: BridgeTask = {
          id: `claude:${row.id}`, provider: 'claude', title: safeTitle(row.title, 'claude'),
          state, resultKey: null, sourceURL: sourceURL('claude', row.id), observedAt,
          evidence: fresh ? 'live' : 'history', updatedAt: observedAt,
          observationSource: 'claude-cache',
          ...(['running', 'input', 'idle'].includes(row.lastObservedState ?? '')
            ? { lastObservedState: row.lastObservedState as 'running' | 'input' | 'idle' } : {}),
          ...(state === 'unknown' ? { availabilityReason: !fresh ? 'stale-cache' as const :
            row.connectionStatus === 'disconnected' ? 'remote-disconnected' as const : 'metadata-only' as const } : {}),
        };
        const previous = tasks.findIndex(value => value.id === task.id);
        if (previous >= 0) tasks[previous] = task; else tasks.push(task);
        if (state !== 'unknown') freshCount++;
      }
      // The cache is partial and timestamped, never a complete live feed.
      const health = providers.find(value => value.id === 'claude');
      if (health && freshCount > 0) health.health = 'degraded';
    }
    tasks.sort((a, b) => b.updatedAt - a.updatedAt || a.id.localeCompare(b.id));
    return { type: 'snapshot', version: 1, generatedAt: now, providers, tasks };
  }
}

export interface BridgeOptions { parentPID: number; durationSeconds?: number }
export function parseBridgeOptions(args: string[], defaultParentPID: number): BridgeOptions {
  const options: BridgeOptions = { parentPID: defaultParentPID };
  for (let index = 0; index < args.length; index++) {
    const argument = args[index];
    if (argument !== '--parent-pid' && argument !== '--duration-seconds') throw new Error('Invalid bridge options');
    const raw = args[++index];
    if (!raw || !/^\d+(?:\.\d+)?$/.test(raw)) throw new Error('Invalid bridge options');
    const value = Number(raw);
    if (argument === '--parent-pid') {
      if (!Number.isSafeInteger(value) || value <= 1) throw new Error('Invalid bridge options');
      options.parentPID = value;
    } else {
      if (!Number.isFinite(value) || value <= 0 || value > 86_400) throw new Error('Invalid bridge options');
      options.durationSeconds = value;
    }
  }
  if (!Number.isSafeInteger(options.parentPID) || options.parentPID <= 1) throw new Error('Invalid bridge options');
  return options;
}
