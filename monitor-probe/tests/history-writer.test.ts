import test from 'node:test';
import assert from 'node:assert/strict';
import { parseCodexWriterFiles, readCodexWriters, type WriterCommand } from '../source/src/providers/codex/history-writer';

const path = '/home/test/rollout with spaces\nand newline.jsonl';
const frame = (pid: number, access: string, name = path, command = 'codex') =>
  `p${pid}\0c${command}\0\nf12\0a${access}\0n${name}\0\n`;
const started = 'Thu Nov 26 11:22:33 2026';
const ps = (pid: number, command = '/Applications/ChatGPT.app/Contents/Resources/codex') =>
  ` ${pid} ${started} ${command}\n`;

test('NUL fields match exact paths including whitespace and only writable numeric descriptors', () => {
  const result = parseCodexWriterFiles(frame(42, 'u') + frame(43, 'w') + frame(44, 'r') +
    frame(45, 'u', path + '.old') + frame(46, 'u', path, 'node') +
    `p47\0ccodex\0\nfcwd\0au\0n${path}\0\n`, new Set([path]));
  assert.deepEqual([...result.get(path)!], [42, 43]);
});

test('partial lsof matches still qualify via ps executable and start time in one batch each', async () => {
  const calls: Array<[string, string[]]> = [];
  const run: WriterCommand = async (file, args) => {
    calls.push([file, args]);
    return file.endsWith('lsof') ? { code: 1, stdout: frame(42, 'u'), stderr: '' } :
      { code: 0, stdout: ps(42), stderr: '' };
  };
  assert.deepEqual(await readCodexWriters([path, path, '/missing'], run),
    new Map([[path, Date.parse(started) / 1000]]));
  assert.equal(calls.length, 2);
  assert.deepEqual(calls[0][1], ['-n', '-F0pcfan', '--', path, '/missing']);
  assert.deepEqual(calls[1][1], ['-o', 'pid=,lstart=,comm=', '-p', '42']);
});

test('missing, non-Codex and malformed process metadata provide no writer evidence', async () => {
  for (const output of ['', ps(42, '/usr/bin/node'), '42 invalid date codex\n', ps(99)]) {
    const run: WriterCommand = async file => file.endsWith('lsof') ?
      { code: 0, stdout: frame(42, 'w'), stderr: '' } : { code: 1, stdout: output, stderr: '' };
    assert.equal((await readCodexWriters([path], run)).size, 0);
  }
});

test('command errors, warnings and thrown failures fail closed', async () => {
  for (const bad of [{ code: 'ENOENT', stdout: '', stderr: '' },
    { code: 0, stdout: frame(42, 'u'), stderr: 'warning' },
    { code: 2, stdout: frame(42, 'u'), stderr: '' }]) {
    assert.equal((await readCodexWriters([path], async () => bad)).size, 0);
  }
  assert.equal((await readCodexWriters([path], async () => { throw Error('unavailable'); })).size, 0);
});

test('empty and oversized candidate sets avoid process queries', async () => {
  const run: WriterCommand = async () => { throw Error('must not execute'); };
  assert.equal((await readCodexWriters([], run)).size, 0);
  assert.equal((await readCodexWriters(['/a'.repeat(70000)], run)).size, 0);
});

test('multiple writers use the newest start and fail closed if any writer is unverified', async () => {
  for (const includeSecond of [false, true]) {
    const run: WriterCommand = async file => file.endsWith('lsof') ?
      { code: 0, stdout: frame(42, 'u') + frame(43, 'w'), stderr: '' } :
      { code: 0, stdout: ps(42) + (includeSecond ? ps(43).replace('11:22:33', '11:23:33') : ''), stderr: '' };
    const result = await readCodexWriters([path], run);
    assert.equal(result.size, includeSecond ? 1 : 0);
    if (includeSecond) assert.equal(result.get(path), Date.parse(started) / 1000 + 60);
  }
});
