import { homedir } from 'node:os';
import { join } from 'node:path';
import type { SessionProvider, ObserverCallbacks } from '../provider';
import type { Session } from '../../shared/types';
import {
  isAgentProcess,
  readTerminalProcesses,
  sameTerminal,
  type TerminalProcess,
} from '../terminal';
import { readCatalog, validThreadId } from './catalog';
import { CodexTransport, validHostId, type CodexThreadRef } from './transport';
import { LineageReader } from '../lineage';
import { readCodexResponse } from './response';
import { defaultHooksDirectory, readHookRecords, sessionFromHooks, type HookRecord } from './hooks';
import { readCodexHistory } from './history';
import {
  projectConversation,
  patchProjection,
  sessionFromProjection,
  latestTurn,
  validateConversation,
  type Projection,
} from './projection';

type StreamVersion = 11 | 13;
type LiveState = { revision: number; owner: string; version: StreamVersion; state: Projection };

export class CodexProvider implements SessionProvider {
  readonly id = 'codex' as const;
  readCompletedResponse(session: Session) {
    if (session.hostId && session.hostId !== 'local') return Promise.resolve(null);
    return readCodexResponse(this.home, session);
  }
  private callbacks: ObserverCallbacks | null = null;
  private transport: CodexTransport;
  private sessions = new Map<string, Session>();
  private live = new Map<string, LiveState>();
  private tracked: string[] = [];
  private hosts = new Map<string, string>();
  private discovered = new Map<string, CodexThreadRef>();
  private hostCollisions = new Set<string>();
  private timer: NodeJS.Timeout | null = null;
  private connected = false;
  private lastObservedAt: number | null = null;
  private resyncTimes = new Map<string, number>();
  private protocolError: string | null = null;
  private hookRecords = new Map<string, HookRecord>();
  private historyObserved = new Set<string>();
  private startedAt = Date.now();
  private terminalProcesses: Map<number, TerminalProcess> | null = new Map();
  private terminalOwners = new Map<number, string>();
  private refreshPromise: Promise<void> | null = null;
  private catalogCurrent = false;
  private lineage = new LineageReader();
  constructor(
    readonly home = process.env.CODEX_HOME || join(homedir(), '.codex'),
    readonly hooksDirectory = defaultHooksDirectory(),
    private readProcesses = readTerminalProcesses,
  ) {
    this.transport = new CodexTransport(join(home, 'ipc', 'ipc.sock'));
  }
  async start(callbacks: ObserverCallbacks) {
    this.callbacks = callbacks;
    this.startedAt = Date.now();
    callbacks.health({
      provider: this.id,
      state: 'connecting',
      message: 'Connecting to local Codex',
      lastObservedAt: null,
    });
    await this.refresh();
    this.transport.on('ready', () => {
      this.connected = true;
      this.reportHealth();
    });
    this.transport.on('offline', (message: string) => {
      this.connected = false;
      const disconnected = [...this.live.keys()];
      this.live.clear();
      for (const id of disconnected)
        this.markUnavailable(id, 'Codex desktop disconnected; last known state is not current');
      this.publish();
      this.reportHealth(message);
    });
    this.transport.on('message', (message) => this.handleMessage(message));
    this.transport.start();
    this.timer = setInterval(() => void this.refresh(), 1000);
  }
  private health(state: 'live' | 'offline' | 'degraded', message: string) {
    this.callbacks?.health({
      provider: this.id,
      state,
      message,
      lastObservedAt: this.lastObservedAt,
    });
  }
  private publish() {
    this.callbacks?.sessions([...this.sessions.values()]);
  }
  private withHooks(session: Session, projection?: Projection, historyCompletedAt?: number) {
    if (this.hostCollisions.has(session.externalId)) return {
      ...session, status: 'unknown' as const, evidence: 'unavailable' as const,
      attentionKey: null, awaitingInput: false, openable: false,
      resumeId: null, terminalPid: null, terminalIdentity: null, terminalResumeAllowed: false,
    };
    if (session.hostId && session.hostId !== 'local') return {
      ...session, resumeId: null, terminalPid: null, terminalIdentity: null,
      terminalResumeAllowed: false,
    };
    const record = this.hookRecords.get(session.externalId);
    const terminal = record?.terminal;
    const process = terminal && this.terminalProcesses?.get(terminal.pid);
    const alive =
      terminal &&
      !terminal.ended &&
      process &&
      isAgentProcess(process.command, 'codex') &&
      sameTerminal(terminal, process) &&
      this.terminalOwners.get(terminal.pid) === session.externalId;
    const desktopBusy = session.status === 'running' ||
      (projection &&
      (projection.threadRuntimeStatus?.type === 'active' ||
        projection.requests?.length ||
        projection.threadRuntimeStatus?.activeFlags?.length ||
        latestTurn(projection)?.status === 'inProgress'));
    session = {
      ...session,
      resumeId: terminal ? session.externalId : null,
      terminalPid: alive ? terminal.pid : null,
      terminalIdentity: alive
        ? { pid: terminal.pid, tty: terminal.tty, startedAt: terminal.startedAt }
        : null,
      terminalResumeAllowed:
        this.catalogCurrent &&
        !!terminal &&
        this.terminalProcesses !== null &&
        !alive &&
        !desktopBusy,
    };
    const event = record?.activity?.turnId ? record.activity : record?.completion;
    const turn = projection && latestTurn(projection);
    const turnStartedAt = Number(turn?.turnStartedAtMs);
    const oldIdleTurn =
      projection &&
      turn && Number.isFinite(turnStartedAt) && turnStartedAt > 0 &&
      ['idle', 'notLoaded'].includes(projection.threadRuntimeStatus?.type || '') &&
      !projection.requests?.length &&
      !projection.threadRuntimeStatus?.activeFlags?.length &&
      event?.turnId &&
      event.turnId !== (turn?.turnId || turn?.id) &&
      event.at > turnStartedAt;
    // History timestamps have second precision. Only supersede a receipt when
    // a different hook turn was observed in a later second.
    const oldHistoryTurn = historyCompletedAt !== undefined && event?.turnId &&
      session.attentionKey !== `result:${event.turnId}` && event.at >= historyCompletedAt + 1000;
    return session.status === 'unknown' || oldIdleTurn || oldHistoryTurn
      ? sessionFromHooks(
          { ...session, status: 'unknown', evidence: 'unavailable', attentionKey: null },
          record,
          this.startedAt,
        )
      : session;
  }
  private reportHealth(offlineMessage = 'Codex desktop disconnected') {
    const hasHooks = [...this.sessions.values()].some((s) => {
      const record = this.hookRecords.get(s.externalId);
      return record?.activity || record?.completion;
    });
    if (this.connected && !this.protocolError) {
      const known = [...this.sessions.values()].filter(s => s.status !== 'unknown').length;
      this.health(
        known === this.sessions.size ? 'live' : 'degraded',
        `Connected to Codex desktop · ${known}/${this.sessions.size} statuses observed · local catalog and loaded desktop sessions only${hasHooks ? ' · companion observations available' : ''}`,
      );
    } else {
      const hasHistory = this.historyObserved.size > 0;
      this.health(
        this.connected || hasHooks || hasHistory ? 'degraded' : 'offline',
        `${this.protocolError || offlineMessage}${hasHistory ? ' · using local turn history' : ''}${hasHooks ? ' · using companion observations' : ''}`,
      );
    }
  }
  refresh(): Promise<void> {
    if (!this.refreshPromise)
      this.refreshPromise = this.refreshNow().finally(() => {
        this.refreshPromise = null;
      });
    return this.refreshPromise;
  }
  private async refreshNow() {
    try {
      this.hookRecords = readHookRecords(this.hooksDirectory);
      this.terminalProcesses = await this.readProcesses(
        [...this.hookRecords.values()].flatMap((record) =>
          record.terminal ? [record.terminal.pid] : [],
        ),
      );
      this.terminalOwners.clear();
      // /new can keep the CLI process alive. Only its most recent task owns its tab.
      for (const [id, record] of [...this.hookRecords].sort(
        (a, b) => (a[1].terminal?.at || 0) - (b[1].terminal?.at || 0),
      )) {
        if (record.terminal) this.terminalOwners.set(record.terminal.pid, id);
      }
      const rows = readCatalog(this.home, this.tracked, this.lineage);
      const history = await readCodexHistory(
        this.home,
        rows.filter(row => !row.archived && !this.live.has(row.externalId) &&
          !this.hostCollisions.has(row.externalId)).map(row => row.externalId),
      );
      const previousHistory = this.historyObserved;
      this.historyObserved = new Set();
      this.catalogCurrent = true;
      for (const row of rows) {
        previousHistory.delete(row.externalId);
        if (!this.acceptHost(row.externalId, 'local')) continue;
        row.hostId = 'local';
        const live = this.live.get(row.externalId);
        const observed = live ? undefined : history.get(row.externalId);
        if (observed) this.historyObserved.add(row.externalId);
        this.sessions.set(
          row.externalId,
          live
            ? this.withHooks(sessionFromProjection(row, live.state), live.state)
            : this.withHooks({ ...row, ...observed?.snapshot }, undefined, observed?.completedAt),
        );
      }
      for (const id of previousHistory) this.sessions.delete(id);
      this.publish();
      this.reportHealth();
    } catch (error) {
      this.catalogCurrent = false;
      for (const id of this.historyObserved)
        this.markUnavailable(id, 'Codex local turn history is unavailable');
      this.historyObserved.clear();
      for (const [id, session] of this.sessions)
        this.sessions.set(id, { ...session, terminalResumeAllowed: false });
      this.publish();
      this.health('degraded', error instanceof Error ? error.message : String(error));
    }
  }
  track(externalIds: string[]) {
    this.tracked = externalIds.filter(validThreadId);
    for (const id of this.live.keys())
      if (!this.tracked.includes(id) && !this.discovered.has(id)) this.live.delete(id);
    this.syncTracked();
  }
  private syncTracked() {
    const refs = new Map(this.discovered);
    for (const id of this.tracked)
      refs.set(id, { id, hostId: this.hosts.get(id) ?? 'local' });
    this.transport.trackThreads([...refs.values()].filter(ref => !this.hostCollisions.has(ref.id)));
  }
  private acceptHost(id: string, hostId: string): boolean {
    if (this.hostCollisions.has(id)) return false;
    const previous = this.hosts.get(id);
    if (previous && previous !== hostId) {
      this.hostCollisions.add(id);
      this.discovered.delete(id);
      this.invalidate(id, 'Conflicting Codex execution hosts; task status is unavailable.');
      this.syncTracked();
      this.protocolError = 'Conflicting Codex execution hosts; refusing to mix task states.';
      this.reportHealth();
      return false;
    }
    this.hosts.set(id, hostId);
    return true;
  }
  private discoverThread(message: Record<string, any>): boolean {
    const params = message.params;
    if (message.method !== 'thread-stream-following-changed' || message.version !== 1 ||
        params?.following !== true || params?.hostId === 'local' ||
        !validHostId(params?.hostId) || typeof params?.conversationId !== 'string' ||
        !validThreadId(params.conversationId) ||
        typeof message.sourceClientId !== 'string' || !message.sourceClientId) return false;
    const id = params.conversationId, hostId = params.hostId;
    if (!this.acceptHost(id, hostId)) return true;
    if (!this.discovered.has(id)) {
      if (this.discovered.size >= 5000) return true;
      this.discovered.set(id, { id, hostId });
      this.sessions.set(id, {
        id: `codex:${id}`, provider: 'codex', externalId: id, hostId,
        title: 'Codex task', directory: null, status: 'unknown',
        detail: 'Waiting for a live state from the loaded Codex session',
        updatedAt: 0, observedAt: Date.now(), evidence: 'unavailable',
        attentionKey: null, archived: false, openable: true,
        terminalResumeAllowed: false,
      });
      // Discovery comes from an existing desktop observer. Subscribing only asks
      // an existing owner for its state; it never resumes or acquires a stream.
      this.syncTracked();
      this.publish();
      this.reportHealth();
    }
    return true;
  }
  private invalidate(id: string, message: string) {
    this.live.delete(id);
    this.markUnavailable(id, message);
    this.publish();
  }
  private markUnavailable(id: string, message: string) {
    const session = this.sessions.get(id);
    if (session) {
      this.sessions.set(
        id,
        this.withHooks({
          ...session,
          status: 'unknown',
          evidence: 'unavailable',
          attentionKey: null,
          activityAt: undefined,
          awaitingInput: false,
          detail: message,
        }),
      );
    }
  }
  private requestResync(id: string) {
    if (Date.now() - (this.resyncTimes.get(id) || 0) > 2000) {
      this.resyncTimes.set(id, Date.now());
      this.transport.resync(id, this.hosts.get(id) ?? 'local');
    }
  }
  private handleMessage(message: Record<string, any>) {
    const params = message.params || {};
    if (this.discoverThread(message)) return;
    if (message.method === 'client-status-changed' && params.status === 'disconnected') {
      for (const [id, live] of this.live)
        if (live.owner === params.clientId)
          this.invalidate(id, 'The Codex window observing this task disconnected.');
      return;
    }
    if (message.method === 'ipc-connection-reset') {
      for (const id of new Set([...this.tracked, ...this.discovered.keys()])) {
        this.invalidate(id, 'Reconnecting to Codex');
        this.transport.resync(id, this.hosts.get(id) ?? 'local');
      }
      return;
    }
    const id = params.conversationId || params.threadId;
    if (typeof id !== 'string' || !validThreadId(id) || !validHostId(params.hostId) ||
        this.hostCollisions.has(id) ||
        (!this.tracked.includes(id) && !this.discovered.has(id))) return;
    if (!this.acceptHost(id, params.hostId)) return;
    if (message.method === 'thread-read-state-changed') {
      const live = this.live.get(id);
      if (!live) return;
      if (message.version !== 3 || typeof params.hasUnreadTurn !== 'boolean') {
        this.invalidate(id, 'Unsupported Codex read receipt; waiting for a current snapshot.');
        this.requestResync(id);
        return;
      }
      // Receipts are global and may legitimately come from another window. With
      // no matching owner/revision evidence, reacquire the authoritative snapshot
      // instead of letting a delayed old-window receipt clear a newer result.
      if (
        message.sourceClientId !== live.owner &&
        (live.version === 13 || message.sourceClientId !== undefined)
      ) {
        this.invalidate(id, 'Confirming Codex read receipt from the current source window.');
        this.requestResync(id);
      } else {
        live.state = { ...live.state, hasUnreadTurn: params.hasUnreadTurn };
        this.publishLive(id, live);
      }
      return;
    }
    if (message.method !== 'thread-stream-state-changed') return;
    if (message.version !== 11 && message.version !== 13) {
      this.protocolError = 'Unsupported Codex stream version; expected 11 or 13.';
      this.invalidate(id, 'This Codex desktop protocol version is not supported.');
      this.health('degraded', this.protocolError);
      return;
    }
    const change = params.change;
    try {
      const old = this.live.get(id);
      if (
        !change || Array.isArray(change) || !Number.isSafeInteger(change.revision) ||
        change.revision < 0
      )
        throw new Error('Missing Codex state revision.');
      if (typeof message.sourceClientId !== 'string' || !message.sourceClientId.length)
        throw new Error('Missing Codex state owner.');
      if (change.type === 'snapshot') {
        if (
          old && old.owner === message.sourceClientId && old.version === message.version &&
          change.revision < old.revision
        ) return;
        if (change.conversationState?.id !== id)
          throw new Error('Codex snapshot identity mismatch.');
        validateConversation(change.conversationState, message.version);
        this.protocolError = null;
        const live: LiveState = {
          revision: change.revision,
          owner: message.sourceClientId,
          version: message.version,
          state: projectConversation(change.conversationState, message.version),
        };
        this.live.set(id, live);
        this.publishLive(id, live);
      } else if (change.type === 'patches') {
        if (
          old && old.owner === message.sourceClientId && old.version === message.version &&
          change.revision <= old.revision
        ) return;
        if (
          !old || old.owner !== message.sourceClientId || old.version !== message.version ||
          change.baseRevision !== old.revision || change.revision <= change.baseRevision
        )
          throw new Error('Missed a Codex state update; resynchronizing.');
        const state = patchProjection(old.state, change.patches);
        if (state.id !== id) throw new Error('Codex patched snapshot identity mismatch.');
        validateConversation(state, message.version);
        const live = {
          ...old,
          revision: change.revision,
          state,
        };
        this.live.set(id, live);
        this.publishLive(id, live);
      } else throw new Error('Unknown Codex state message.');
    } catch {
      this.invalidate(id, 'Unsupported or out-of-order Codex state; resynchronizing.');
      this.requestResync(id);
    }
  }
  private publishLive(id: string, live: { state: Projection }) {
    const base = this.sessions.get(id);
    if (!base) return;
    this.historyObserved.delete(id);
    this.lastObservedAt = Date.now();
    this.sessions.set(
      id,
      this.withHooks(sessionFromProjection(base, live.state, this.lastObservedAt), live.state),
    );
    this.publish();
    this.reportHealth();
  }
  sessionUrl(externalId: string) {
    if (!validThreadId(externalId)) throw new Error('Invalid Codex task id.');
    if (this.hostCollisions.has(externalId)) throw new Error('Conflicting Codex task hosts.');
    const hostId = this.hosts.get(externalId) ?? 'local';
    const url = `codex://threads/${encodeURIComponent(externalId)}`;
    return hostId === 'local' ? url : `${url}?hostId=${encodeURIComponent(hostId)}`;
  }
  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.callbacks = null;
    this.transport.stop();
  }
}
