import { EventEmitter } from 'node:events';
import { lstatSync } from 'node:fs';
import { dirname } from 'node:path';
import { createConnection, type Socket } from 'node:net';
import { randomUUID } from 'node:crypto';

const MAX_FRAME = 64 * 1024 * 1024;
export interface CodexThreadRef { id: string; hostId: string }
export const validHostId = (value: unknown): value is string =>
  typeof value === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,255}$/.test(value);
const threadKey = ({ id, hostId }: CodexThreadRef) => JSON.stringify([hostId, id]);
export class FrameDecoder {
  private buffer: Buffer = Buffer.alloc(0);
  push(chunk: Buffer): unknown[] {
    this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : chunk;
    const messages: unknown[] = [];
    while (this.buffer.length >= 4) {
      const size = this.buffer.readUInt32LE();
      if (!size || size > MAX_FRAME) throw new Error('Unsupported Codex frame size.');
      if (this.buffer.length < size + 4) break;
      messages.push(JSON.parse(this.buffer.subarray(4, size + 4).toString('utf8')));
      this.buffer = this.buffer.subarray(size + 4);
    }
    return messages;
  }
}
export function encodeFrame(value: unknown): Buffer {
  const body = Buffer.from(JSON.stringify(value));
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length);
  return Buffer.concat([header, body]);
}

/** Private desktop observer protocol, validated against desktop 26.903.61454.
 * The only outbound operations are registration, following/unfollowing and
 * declining discovery requests. No execution, approval or ownership methods.
 */
export class CodexTransport extends EventEmitter {
  private socket: Socket | null = null;
  private retry: NodeJS.Timeout | null = null;
  private deadline: NodeJS.Timeout | null = null;
  private stopped = true;
  private ready = false;
  private tracked = new Map<string, CodexThreadRef>();
  private attempt = 0;
  private initializeId = '';
  constructor(private readonly socketPath: string) {
    super();
  }
  start() {
    this.stopped = false;
    this.connect();
  }
  private connect() {
    if (this.stopped) return;
    try {
      const sock = lstatSync(this.socketPath),
        dir = lstatSync(dirname(this.socketPath)),
        uid = process.getuid?.();
      if (
        !sock.isSocket() ||
        sock.uid !== uid ||
        !dir.isDirectory() ||
        dir.uid !== uid ||
        dir.mode & 0o022
      )
        throw new Error('Codex socket must be owned by the current user in a private directory.');
    } catch (error) {
      this.emit('offline', error instanceof Error ? error.message : String(error));
      this.reconnect();
      return;
    }
    const socket = createConnection(this.socketPath);
    this.socket = socket;
    const decoder = new FrameDecoder();
    this.deadline = setTimeout(
      () => socket.destroy(new Error('Codex observer registration timed out.')),
      8000,
    );
    socket.on('connect', () => {
      this.initializeId = randomUUID();
      this.send({
        type: 'request',
        requestId: this.initializeId,
        method: 'initialize',
        version: 0,
        params: { clientType: 'monitor-observer' },
      });
    });
    socket.on('data', (chunk) => {
      try {
        for (const message of decoder.push(chunk)) this.receive(message);
      } catch (error) {
        socket.destroy(error instanceof Error ? error : new Error(String(error)));
      }
    });
    socket.on('error', (error) => this.emit('offline', error.message));
    socket.on('close', () => {
      if (this.deadline) clearTimeout(this.deadline);
      this.deadline = null;
      this.ready = false;
      this.socket = null;
      if (!this.stopped) {
        this.emit('offline', 'Codex desktop is disconnected.');
        this.reconnect();
      }
    });
  }
  private receive(value: unknown) {
    if (!value || typeof value !== 'object') return;
    const message = value as Record<string, any>;
    if (message.type === 'client-discovery-request') {
      this.send({
        type: 'client-discovery-response',
        requestId: message.requestId,
        response: { canHandle: false },
      });
      return;
    }
    if (message.type === 'response' && message.requestId === this.initializeId) {
      if (message.resultType !== 'success')
        throw new Error('Codex refused the observer connection.');
      if (this.deadline) clearTimeout(this.deadline);
      this.deadline = null;
      this.ready = true;
      this.attempt = 0;
      for (const ref of this.tracked.values()) this.follow(ref, true);
      this.emit('ready');
      return;
    }
    if (message.type !== 'broadcast' || !this.ready) return;
    if (
      message.method === 'thread-stream-following-status-requested' &&
      message.version === 1 &&
      validHostId(message.params?.hostId) &&
      this.tracked.has(threadKey({ id: message.params.conversationId, hostId: message.params.hostId }))
    )
      this.follow({ id: message.params.conversationId, hostId: message.params.hostId }, true);
    this.emit('message', message);
  }
  private send(message: unknown) {
    if (this.socket && !this.socket.destroyed && this.socket.writable)
      this.socket.write(encodeFrame(message));
  }
  private follow({ id, hostId }: CodexThreadRef, following: boolean) {
    this.send({
      type: 'broadcast',
      method: 'thread-stream-following-changed',
      version: 1,
      params: { conversationId: id, hostId, following },
    });
  }
  track(ids: string[]) {
    this.trackThreads(ids.map(id => ({ id, hostId: 'local' })));
  }
  trackThreads(refs: CodexThreadRef[]) {
    const next = new Map(refs.filter(ref => validHostId(ref.hostId) &&
      typeof ref.id === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9_-]{5,127}$/.test(ref.id))
      .map(ref => [threadKey(ref), { id: ref.id, hostId: ref.hostId }]));
    if (this.ready) {
      for (const [key, ref] of this.tracked) if (!next.has(key)) this.follow(ref, false);
      for (const [key, ref] of next) if (!this.tracked.has(key)) this.follow(ref, true);
    }
    this.tracked = next;
  }
  resync(id: string, hostId = 'local') {
    const ref = this.tracked.get(threadKey({ id, hostId }));
    if (this.ready && ref) {
      this.follow(ref, false);
      this.follow(ref, true);
    }
  }
  private reconnect() {
    if (this.stopped || this.retry) return;
    this.retry = setTimeout(
      () => {
        this.retry = null;
        this.connect();
      },
      Math.min(1000 * 2 ** this.attempt++, 15000),
    );
  }
  stop() {
    this.stopped = true;
    if (this.ready) for (const ref of this.tracked.values()) this.follow(ref, false);
    if (this.retry) clearTimeout(this.retry);
    if (this.deadline) clearTimeout(this.deadline);
    this.retry = null;
    this.deadline = null;
    this.ready = false;
    this.socket?.end();
    this.socket?.destroy();
    this.socket = null;
  }
}
