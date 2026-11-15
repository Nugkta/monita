import { existsSync, realpathSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const executable = realpathSync(process.argv[2] ?? process.execPath);
const prefix = dirname(dirname(executable));
const explicit = process.env.NODE_LICENSE_PATH;
const candidates = explicit ? [resolve(explicit)] : [
  resolve(prefix, 'LICENSE'),
  resolve(prefix, 'share/doc/node/LICENSE'),
  resolve(prefix, 'share/doc/node/LICENSE.md'),
  resolve(prefix, 'share/licenses/node/LICENSE'),
  ...(process.version === 'v22.19.0'
    ? [fileURLToPath(new URL('../third-party/Node-v22.19.0-LICENSE', import.meta.url))] : []),
];
const license = candidates.find(path => existsSync(path));
if (!license) {
  process.stderr.write('Node license not found. Set NODE_LICENSE_PATH to the LICENSE file for your Node.js version.\n');
  process.exit(1);
}
process.stdout.write(license + '\n');
