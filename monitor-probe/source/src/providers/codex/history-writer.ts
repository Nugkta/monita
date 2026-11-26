import { execFile } from 'node:child_process';
import { isAbsolute } from 'node:path';
import { isAgentProcess } from '../terminal';

interface CommandResult { code: number | string | null; stdout: string; stderr: string }
export type WriterCommand = (file: string, args: string[]) => Promise<CommandResult>;
const runCommand: WriterCommand = (file, args) => new Promise(resolve => {
  execFile(file, args, {
    timeout: 2_000, maxBuffer: 2 * 1024 * 1024,
    env: { ...process.env, LC_ALL: 'C' },
  }, (error, stdout, stderr) => resolve({ code: error ? error.code ?? null : 0, stdout, stderr }));
});

/** Parse lsof's NUL-delimited fields; filenames can themselves contain newlines. */
export function parseCodexWriterFiles(output: string, paths: Set<string>): Map<string, Set<number>> {
  const writers = new Map<string, Set<number>>();
  let pid = 0, command = '', descriptor = '', access = '';
  for (const raw of output.split('\0')) {
    // lsof separates process/file records with a newline outside the NUL field.
    const field = raw.replace(/^\n/, '');
    const value = field.slice(1);
    switch (field[0]) {
      case 'p': pid = /^\d+$/.test(value) ? Number(value) : 0; command = ''; descriptor = ''; access = ''; break;
      case 'c': command = value; break;
      case 'f': descriptor = value; access = ''; break;
      case 'a': access = value; break;
      case 'n':
        if (pid > 1 && Number.isSafeInteger(pid) && isAgentProcess(command, 'codex') &&
            /^\d+$/.test(descriptor) && ['w', 'u'].includes(access) && paths.has(value)) {
          const ids = writers.get(value) ?? new Set<number>();
          ids.add(pid); writers.set(value, ids);
        }
    }
  }
  return writers;
}

export function parseCodexWriterStarts(output: string): Map<number, number> {
  const starts = new Map<number, number>();
  for (const line of output.split('\n')) {
    const match = /^\s*(\d+)\s+(\w{3}\s+\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(.+)$/.exec(line);
    if (!match || !isAgentProcess(match[3], 'codex')) continue;
    const started = Date.parse(match[2]) / 1000;
    if (Number.isFinite(started) && started > 0) starts.set(Number(match[1]), started);
  }
  return starts;
}

/** Exact candidate files with writable Codex descriptors, qualified by process age.
 * No transcript contents or process arguments are read. Errors yield no evidence.
 * The optional command dependency is used by synthetic tests only.
 */
export async function readCodexWriters(paths: string[], run: WriterCommand = runCommand): Promise<Map<string, number>> {
  const candidates = new Set(paths.filter(path => isAbsolute(path) && !path.includes('\0')));
  if (!candidates.size || candidates.size > 4096 ||
      [...candidates].reduce((size, path) => size + Buffer.byteLength(path) + 1, 0) > 128 * 1024)
    return new Map();
  try {
    const files = await run('/usr/sbin/lsof', ['-n', '-F0pcfan', '--', ...candidates]);
    // lsof returns 1 for unmatched candidates even when other files matched.
    if ((files.code !== 0 && files.code !== 1) || files.stderr.trim()) return new Map();
    const writers = parseCodexWriterFiles(files.stdout, candidates);
    const pids = [...new Set([...writers.values()].flatMap(ids => [...ids]))];
    if (!pids.length) return new Map();
    const processes = await run('/bin/ps', ['-o', 'pid=,lstart=,comm=', '-p', pids.join(',')]);
    if ((processes.code !== 0 && processes.code !== 1) || processes.stderr.trim()) return new Map();
    const starts = parseCodexWriterStarts(processes.stdout);
    const result = new Map<string, number>();
    for (const [path, ids] of writers) {
      const times = [...ids].map(pid => starts.get(pid));
      // Ambiguous writers must all be verified; newest start is conservative.
      if (times.every((time): time is number => time !== undefined)) result.set(path, Math.max(...times));
    }
    return result;
  } catch { return new Map(); }
}
