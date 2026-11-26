import { CodexProvider } from '../monitor-probe/source/src/providers/codex/index';
import { ClaudeProvider, claudeDesktopRunning } from '../monitor-probe/source/src/providers/claude/index';
import { HerdrProvider } from '../monitor-probe/source/src/providers/herdr/index';
import type { SessionProvider } from '../monitor-probe/source/src/providers/provider';
import { BridgeState, parseBridgeOptions } from './bridge-core';
import { readClaudeCache } from './claude-cache';

// Sole UI transport: metadata NDJSON to the native parent's private stdout pipe.
// No store, summary service, response reader, installer, app navigation or server.
let options;
try { options = parseBridgeOptions(process.argv.slice(2), process.ppid); }
catch {
  process.stdout.write('{"type":"error","version":1,"code":"bridge_failed"}\n');
  process.exit(2);
}
// Record and registry changes arrive through file watching; the one-second poll is
// the fallback. Listing every process is the costly part of a pass, and whether the
// desktop app is open changes rarely, so that answer is reused for a few seconds.
let desktopSeen: { at: number; value: Promise<boolean> } | undefined;
const desktopRunning = () => {
  const now = Date.now();
  if (!desktopSeen || now - desktopSeen.at >= 3_000 || now < desktopSeen.at)
    desktopSeen = { at: now, value: claudeDesktopRunning() };
  return desktopSeen.value;
};
const providers: SessionProvider[] = [new CodexProvider(), new ClaudeProvider({ pollMs: 1_000, desktopRunning }), new HerdrProvider()];
const state = new BridgeState(['codex', 'claude', 'herdr']);
let stopping = false;
let heartbeat: NodeJS.Timeout | undefined;
let duration: NodeJS.Timeout | undefined;
let cachePoll: NodeJS.Timeout | undefined;
let publishQueued = false;
for (const provider of providers) {
  // Ancestry and final responses are unnecessary for this surface.
  (provider as any).lineage = { read: () => undefined };
  provider.readCompletedResponse = async () => { throw new Error('Response reads disabled'); };
}
function stop(exitCode = 0) {
  if (stopping) return;
  stopping = true;
  if (heartbeat) clearInterval(heartbeat);
  if (duration) clearTimeout(duration);
  if (cachePoll) clearInterval(cachePoll);
  for (const provider of providers) { try { provider.stop(); } catch {} }
  process.exit(exitCode);
}
function fail() {
  if (stopping) return;
  try { process.stdout.write('{"type":"error","version":1,"code":"bridge_failed"}\n'); } catch {}
  stop(1);
}
function publish() {
  if (stopping || process.stdout.destroyed || !process.stdout.writable) return;
  // Backpressure is a disconnected/unresponsive parent, not a reason to buffer
  // an unbounded history of source metadata.
  if (process.stdout.writableLength > 2 * 1024 * 1024) { stop(1); return; }
  process.stdout.write(JSON.stringify(state.snapshot()) + '\n');
}
function queuePublish() {
  if (stopping || publishQueued) return;
  publishQueued = true;
  setImmediate(() => { publishQueued = false; publish(); });
}
process.once('SIGTERM', () => stop());
process.once('SIGINT', () => stop());
process.once('uncaughtException', fail);
process.once('unhandledRejection', fail);
process.stdout.on('error', () => stop());
process.stdin.on('error', () => stop());
process.stdin.once('end', () => stop());
process.stdin.resume();
heartbeat = setInterval(() => {
  if (process.ppid !== options.parentPID) { stop(); return; }
  try { process.kill(options.parentPID, 0); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'EPERM') { stop(); return; }
  }
  publish();
}, 1_000);
if (options.durationSeconds !== undefined)
  duration = setTimeout(() => stop(), Math.ceil(options.durationSeconds * 1_000));

// A stale/mistyped launch PID must not briefly start source observation.
if (process.ppid !== options.parentPID) stop();
publish();
// Let an already closed stdin stop us before opening source observers.
await new Promise(resolve => setImmediate(resolve));
if (!stopping) {
  const refreshCache = () => {
    if (stopping) return;
    try { state.setClaudeCache(readClaudeCache()); }
    catch { state.setClaudeCache({ source: 'claude-desktop-cache', status: 'unavailable', sessions: [] }); }
    queuePublish();
  };
  refreshCache();
  cachePoll = setInterval(refreshCache, 5_000);
  await Promise.all(providers.map(async provider => {
    try {
      await provider.start({
        health(value) { state.setHealth(provider.id, value); queuePublish(); },
        sessions(value) {
          state.setSessions(provider.id, value, ids => provider.track(ids));
          queuePublish();
        },
      });
      if (stopping) provider.stop();
    } catch {
      provider.stop();
      state.setHealth(provider.id, { state: 'offline' });
      queuePublish();
    }
  }));
}
