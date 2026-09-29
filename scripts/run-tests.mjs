/** Node's TAP stream is the completion proof. No tests, skipped tests or missing
 * summary are failures even when an upstream runner happens to return exit 0. */
import { spawn } from 'node:child_process';
import { readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export async function runContractTests(files, { output = process.stdout } = {}) {
  if (!files.length) return 1;
  const child = spawn(process.execPath, ['--test', '--test-reporter=tap', ...files],
    { stdio: ['ignore', 'pipe', 'pipe'] });
  let tail = '';
  child.stdout.on('data', (chunk) => {
    output.write(chunk);
    tail = (tail + chunk.toString()).slice(-32768);
  });
  child.stderr.on('data', (chunk) => output.write(chunk));
  const code = await new Promise((resolveCode) => {
    child.once('error', () => resolveCode(1));
    child.once('close', (status) => resolveCode(status ?? 1));
  });
  const count = (name) => {
    const match = tail.match(new RegExp(`^# ${name} (\\d+)$`, 'm'));
    return match ? Number(match[1]) : null;
  };
  if (code !== 0) return code;
  if (!(count('tests') > 0) || !(count('suites') > 0) || count('fail') !== 0 || count('cancelled') !== 0
    || count('skipped') !== 0 || count('todo') !== 0) {
    output.write('Contract gate failed: missing, empty, cancelled or skipped test summary.\n');
    return 1;
  }
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const directory = resolve('test');
  const files = readdirSync(directory).filter((name) => name.endsWith('.test.mjs'))
    .sort().map((name) => join(directory, name));
  process.exitCode = await runContractTests(files);
}
