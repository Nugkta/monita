import type { Session } from '../../shared/types';

/** `t7` on this Mac, or `machine/t7` on a connected herdr-core machine. */
export const herdrAddress = /^(?:[A-Za-z0-9][A-Za-z0-9._-]{0,63}\/)?t[0-9]{1,9}$/;

const record = (value: unknown): Record<string, any> | null =>
  value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, any>) : null;
const text = (value: unknown) => (typeof value === 'string' ? value.trim() : '');
const time = (value: unknown) =>
  typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null;

/**
 * Project a herdr-core snapshot (`terminals` from `events --json`, `machines` from
 * `ls --json`) into sessions. Read-only: "unread" is Herdr desktop's own
 * `herdr.seen` label, so there is no result identity for Monita to acknowledge.
 * Returns null when the snapshot itself is not understood.
 */
export function projectHerdr(terminals: unknown, machines: unknown, now: number): Session[] | null {
  if (!Array.isArray(terminals)) return null;
  const connected = new Set(
    (Array.isArray(machines) ? machines : [])
      .map(record)
      .filter((m) => m?.state === 'connected' && typeof m.name === 'string')
      .map((m) => m!.name as string),
  );
  const sessions: Session[] = [];
  for (const raw of terminals) {
    const row = record(raw);
    const status = record(row?.status);
    if (!row || !status || row.state !== 'live' || typeof status.app !== 'string') continue;
    const address = row.address;
    if (typeof address !== 'string' || !herdrAddress.test(address)) continue;
    if (!Number.isSafeInteger(row.turn) || row.turn < 0) continue;
    const labels = record(row.labels) ?? {};
    const seenLabel = Number.parseInt(text(labels['herdr.seen']), 10);
    const seen = Number.isSafeInteger(seenLabel) && seenLabel >= 0 ? seenLabel : 0;
    const unread = row.turn > seen;
    const machine = address.includes('/') ? address.slice(0, address.indexOf('/')) : null;
    const state = status.state;
    let sessionStatus: Session['status'] = 'read';
    let detail = 'Viewed in Herdr';
    if (state === 'working' || state === 'blocked') {
      sessionStatus = 'running';
      detail = state === 'blocked' ? 'Waiting for input in Herdr' : 'Working in Herdr';
    } else if (state === 'error' && unread) {
      sessionStatus = 'review';
      detail = 'Agent reported an error';
    } else if (state === 'done' && unread) {
      sessionStatus = 'review';
      detail = 'New result in Herdr';
    }
    const title = text(row.title) || text(labels.where) || 'Herdr task';
    const pid = record(row.foreground)?.pid;
    const at = time(row.status_ms) ?? time(row.created_ms) ?? now;
    sessions.push({
      id: `herdr:${address}`,
      provider: 'herdr',
      externalId: address,
      hostId: machine ?? 'local',
      title: machine ? `${machine} · ${title}` : title,
      directory: typeof row.cwd === 'string' ? row.cwd : null,
      status: sessionStatus,
      detail,
      updatedAt: at,
      activityAt: at,
      observedAt: now,
      evidence: machine === null || connected.has(machine) ? 'live' : 'unavailable',
      attentionKey: null,
      ...(state === 'blocked' ? { awaitingInput: true } : {}),
      archived: false,
      openable: false,
      terminalPid: machine === null && Number.isSafeInteger(pid) && pid > 1 ? pid : null,
    });
  }
  return sessions;
}
