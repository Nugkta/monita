import { lstatSync, readdirSync } from 'node:fs';
import { join, resolve, sep } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import type { Session } from '../../shared/types';
import { findStateDatabase, validThreadId } from './catalog';
import { readCodexWriters } from './history-writer';

type Observation = Pick<Session, 'status' | 'detail' | 'observedAt' | 'evidence' | 'attentionKey' | 'activityAt'>;
type HistoryObservation = { snapshot: Observation; completedAt?: number };
interface Turn {
  turn_id: string;
  status: string;
  rollout_ordinal: number;
  started_at: number | null;
  completed_at: number | null;
}
interface Receipt {
  first_unread_turn: string | null;
  last_published_turn: string | null;
}
type OpenTurn = { id: string; path: string; startedAt: number };

function readOnlyDatabase(path: string): DatabaseSync {
  return new DatabaseSync(path, { readOnly: true });
}

function validTime(seconds: number | null, now: number): seconds is number {
  return typeof seconds === 'number' && Number.isSafeInteger(seconds) && seconds > 0 &&
    seconds * 1000 <= now + 1000;
}

/** Observe the same local turn IDs as desktop IPC. No transcript or item body is read. */
export async function readCodexHistory(
  home: string,
  ids: string[],
  readWriters = readCodexWriters,
  now = Date.now(),
): Promise<Map<string, HistoryObservation>> {
  const observations = new Map<string, HistoryObservation>();
  if (!ids.length) return observations;
  const openTurns: OpenTurn[] = [];
  let history: DatabaseSync | undefined;
  let state: DatabaseSync | undefined;
  try {
    const versions = readdirSync(home)
      .flatMap(name => /^thread_history_(\d+)\.sqlite$/.exec(name)?.[1] ?? [])
      .map(Number);
    if (!versions.length) return observations;
    history = readOnlyDatabase(join(home, `thread_history_${Math.max(...versions)}.sqlite`));
    state = readOnlyDatabase(findStateDatabase(home));
    const latest = history.prepare(
      'SELECT turn_id, status, rollout_ordinal, started_at, completed_at FROM thread_turns ' +
      'WHERE thread_id = ? ORDER BY rollout_ordinal DESC LIMIT 1',
    );
    const ordinal = history.prepare('SELECT rollout_ordinal FROM thread_turns WHERE thread_id = ? AND turn_id = ?');
    const receiptFor = state.prepare('SELECT first_unread_turn, last_published_turn FROM thread_read_receipts WHERE thread_id = ?');
    const rolloutFor = state.prepare('SELECT rollout_path FROM threads WHERE id = ? AND archived = 0');
    const sessionsDirectory = resolve(home, 'sessions') + sep;
    for (const id of ids) {
      const turn = latest.get(id) as Turn | undefined;
      if (!turn || !validThreadId(turn.turn_id) || !validTime(turn.started_at, now)) continue;
      const activityAt = turn.started_at * 1000;
      if (turn.status === 'inProgress' && turn.completed_at === null) {
        const path = rolloutFor.get(id)?.rollout_path;
        if (typeof path !== 'string' || path !== resolve(path) ||
            !path.startsWith(sessionsDirectory) || !path.endsWith('.jsonl')) continue;
        try {
          if (lstatSync(path, { throwIfNoEntry: false })?.isFile())
            openTurns.push({ id, path, startedAt: turn.started_at });
        } catch { /* An inaccessible rollout is not evidence of an active task. */ }
        continue;
      }
      if (!['completed', 'interrupted', 'failed'].includes(turn.status) ||
          !validTime(turn.completed_at, now) || turn.completed_at < turn.started_at) continue;
      const receipt = receiptFor.get(id) as Receipt | undefined;
      if (receipt?.last_published_turn !== turn.turn_id) continue;
      if (receipt.first_unread_turn !== null) {
        const first = ordinal.get(id, receipt.first_unread_turn)?.rollout_ordinal;
        if (typeof first !== 'number' || first > turn.rollout_ordinal) continue;
      }
      const unread = receipt.first_unread_turn !== null;
      observations.set(id, {
        completedAt: turn.completed_at * 1000,
        snapshot: {
          status: unread ? 'review' : 'read',
          detail: !unread ? 'Read in Codex' : turn.status === 'interrupted' ? 'Turn interrupted in Codex'
            : turn.status === 'failed' ? 'Turn failed in Codex' : 'New response in Codex',
          evidence: 'live',
          attentionKey: `result:${turn.turn_id}`,
          activityAt,
          observedAt: now,
        },
      });
    }
  } catch {
    // Versions without a compatible projection or receipt table cannot verify state.
    return new Map();
  } finally {
    state?.close();
    history?.close();
  }

  if (!openTurns.length) return observations;
  const writers = await readWriters(openTurns.map(turn => turn.path));
  for (const { id, path, startedAt } of openTurns) {
    const writerStartedAt = writers.get(path);
    // An open handle alone cannot make a turn from a previous process current.
    if (writerStartedAt === undefined || writerStartedAt > startedAt) continue;
    observations.set(id, {
      snapshot: {
        status: 'running',
        detail: 'Codex has an active local turn',
        evidence: 'live',
        attentionKey: null,
        activityAt: startedAt * 1000,
        observedAt: now,
      },
    });
  }
  return observations;
}
