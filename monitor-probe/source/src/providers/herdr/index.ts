import { execFile, spawn, type ChildProcess } from 'node:child_process';
import { connect } from 'node:net';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import type { ProviderHealth, Session } from '../../shared/types';
import type { ObserverCallbacks, SessionProvider } from '../provider';
import { projectHerdr } from './projection';

export interface HerdrProviderOptions {
  binary?: string;
  /** herdr-core's API socket; no command runs unless it accepts a connection. */
  socket?: string;
  /** Safety snapshot interval; the event stream is the primary trigger. */
  pollMs?: number;
  debounceMs?: number;
  restartMs?: number;
  timeoutMs?: number;
}

const MAX_OUTPUT = 8 * 1024 * 1024;

/**
 * Read-only observer of herdr-core. `events --json` is kept open only as a
 * "something changed" signal: its deltas are not interpreted. Each signal (and a
 * slow interval) takes a full snapshot instead. Never runs a command that writes.
 */
export class HerdrProvider implements SessionProvider {
  readonly id = 'herdr' as const;
  private readonly binary: string;
  private readonly socket: string;
  private readonly pollMs: number;
  private readonly debounceMs: number;
  private readonly restartMs: number;
  private readonly timeoutMs: number;
  private callbacks: ObserverCallbacks | null = null;
  private stopped = false;
  private timer: NodeJS.Timeout | null = null;
  private debounce: NodeJS.Timeout | null = null;
  private restart: NodeJS.Timeout | null = null;
  private stream: ChildProcess | null = null;
  private streamUp = false;
  private children = new Set<ChildProcess>();
  private inFlight: Promise<void> | null = null;
  private again = false;
  private offline: string | null = null;
  private snapshotOk = false;
  private last: Session[] = [];
  private lastObservedAt: number | null = null;
  private lastHealth = '';

  constructor(options: HerdrProviderOptions = {}) {
    this.binary =
      options.binary || process.env.MONITA_HERDR_CORE || join(homedir(), '.local', 'bin', 'herdr-core');
    this.socket = options.socket || join(homedir(), '.local', 'state', 'herdr-core', 'default', 'default.sock');
    this.pollMs = options.pollMs ?? 15_000;
    this.debounceMs = options.debounceMs ?? 250;
    this.restartMs = options.restartMs ?? 5_000;
    this.timeoutMs = options.timeoutMs ?? 5_000;
  }

  async start(callbacks: ObserverCallbacks) {
    this.callbacks = callbacks;
    callbacks.health({ provider: this.id, state: 'connecting', message: 'Reading herdr-core', lastObservedAt: null });
    await this.refresh();
    if (this.stopped) return;
    this.timer = setInterval(() => void this.refresh(), this.pollMs);
  }

  track() {}

  sessionUrl() {
    return '';
  }

  refresh(): Promise<void> {
    if (this.inFlight) {
      this.again = true;
      return this.inFlight;
    }
    this.inFlight = (async () => {
      try {
        do {
          this.again = false;
          await this.observe();
        } while (this.again && !this.stopped);
      } finally {
        this.inFlight = null;
      }
    })();
    return this.inFlight;
  }

  stop() {
    this.stopped = true;
    for (const timer of [this.timer, this.debounce, this.restart]) if (timer) clearTimeout(timer);
    this.timer = this.debounce = this.restart = null;
    this.stream?.kill();
    this.stream = null;
    for (const child of this.children) child.kill();
    this.children.clear();
  }

  private async observe() {
    // herdr-core commands may start a core that is not running. Monita only reads,
    // so it runs none of them unless the core is already up.
    if (!(await this.coreRunning())) {
      if (this.stopped) return;
      this.goOffline('herdr-core is not running');
      this.stream?.kill();
      this.report();
      return;
    }
    try {
      const [snapshot, listing] = await Promise.all([
        this.firstLine(['events', '--json']),
        this.output(['ls', '--json']),
      ]);
      if (this.stopped) return;
      const now = Date.now();
      const sessions = projectHerdr(JSON.parse(snapshot)?.terminals, JSON.parse(listing)?.machines, now);
      if (!sessions) throw new Error('Unsupported herdr-core snapshot');
      this.offline = null;
      this.snapshotOk = true;
      this.last = sessions;
      this.lastObservedAt = now;
      this.callbacks?.sessions(sessions);
      this.ensureStream();
    } catch (error) {
      if (this.stopped) return;
      this.snapshotOk = false;
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        this.goOffline('herdr-core not found');
      } else {
        // Keep navigation metadata, never the last runtime state.
        this.callbacks?.sessions(this.last.map((session) => ({ ...session, evidence: 'unavailable' as const })));
      }
    }
    this.report();
  }

  private goOffline(reason: string) {
    this.offline = reason;
    this.snapshotOk = false;
    this.last = [];
    this.callbacks?.sessions([]);
  }

  private coreRunning(): Promise<boolean> {
    return new Promise((resolve) => {
      const probe = connect(this.socket);
      const done = (up: boolean) => {
        clearTimeout(timer);
        probe.destroy();
        resolve(up);
      };
      const timer = setTimeout(() => done(false), this.timeoutMs);
      probe.once('connect', () => done(true));
      probe.once('error', () => done(false));
    });
  }

  private ensureStream() {
    if (this.stream || this.restart || this.stopped) return;
    const child = spawn(this.binary, ['events', '--json'], { stdio: ['ignore', 'pipe', 'ignore'] });
    this.stream = child;
    let first = true;
    const lines = createInterface({ input: child.stdout!, crlfDelay: Infinity });
    lines.on('line', () => {
      // The first line is the snapshot this stream starts with: the stream is now
      // connected. Take one fresh snapshot so a change made while it was
      // connecting is not missed; every later line is a change.
      if (first && this.stream === child) {
        first = false;
        this.streamUp = true;
        this.report();
      }
      this.refreshSoon();
    });
    const gone = () => {
      lines.close();
      if (this.stream !== child) return;
      this.stream = null;
      this.streamUp = false;
      if (this.stopped) return;
      this.report();
      // Reopen only through a refresh, which checks the core is still running.
      this.restart = setTimeout(() => {
        this.restart = null;
        void this.refresh();
      }, this.restartMs);
    };
    child.once('error', gone);
    child.once('close', gone);
  }

  private refreshSoon() {
    if (this.debounce || this.stopped) return;
    this.debounce = setTimeout(() => {
      this.debounce = null;
      void this.refresh();
    }, this.debounceMs);
  }

  private report() {
    if (!this.callbacks || this.stopped) return;
    const [state, message]: [ProviderHealth['state'], string] = this.offline
      ? ['offline', this.offline]
      : !this.snapshotOk
        ? ['degraded', 'Could not read herdr-core']
        : this.streamUp
          ? ['live', 'Following herdr-core']
          : ['degraded', 'Waiting for herdr-core events'];
    if (`${state}:${message}` === this.lastHealth) return;
    this.lastHealth = `${state}:${message}`;
    this.callbacks.health({ provider: this.id, state, message, lastObservedAt: this.lastObservedAt });
  }

  /** First output line of a long-running command; the command is then stopped. */
  private firstLine(args: string[]): Promise<string> {
    return new Promise((resolve, reject) => {
      const child = spawn(this.binary, args, { stdio: ['ignore', 'pipe', 'ignore'] });
      this.children.add(child);
      let buffer = '';
      let done = false;
      const finish = (error: Error | null, line = '') => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        child.kill();
        if (error) reject(error);
        else resolve(line);
      };
      const timer = setTimeout(() => finish(new Error('herdr-core timed out')), this.timeoutMs);
      child.once('error', finish);
      child.once('close', () => {
        this.children.delete(child);
        finish(new Error('herdr-core exited before a snapshot'));
      });
      child.stdout!.setEncoding('utf8');
      child.stdout!.on('data', (chunk: string) => {
        buffer += chunk;
        const end = buffer.indexOf('\n');
        if (end >= 0) finish(null, buffer.slice(0, end));
        else if (buffer.length > MAX_OUTPUT) finish(new Error('herdr-core snapshot too large'));
      });
    });
  }

  private output(args: string[]): Promise<string> {
    return new Promise((resolve, reject) => {
      const child = execFile(
        this.binary,
        args,
        { timeout: this.timeoutMs, maxBuffer: MAX_OUTPUT, encoding: 'utf8' },
        (error, stdout) => {
          this.children.delete(child);
          if (error) reject(error);
          else resolve(stdout);
        },
      );
      this.children.add(child);
    });
  }
}
