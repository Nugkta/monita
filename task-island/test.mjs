import { build } from '../monitor-probe/runtime/node_modules/esbuild/lib/main.js';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
const entries=['task-island/bridge.test.ts','task-island/claude-runtime.test.ts',
  'task-island/codex-host.test.ts','task-island/claude-cache.test.ts','task-island/herdr.test.ts'];
await build({entryPoints:entries,outdir:'task-island/.test-build',
  outExtension:{'.js':'.mjs'},
  bundle:true,platform:'node',format:'esm',target:'node22',
  nodePaths:['monitor-probe/runtime/node_modules'],logLevel:'warning'});
const result=spawnSync(process.execPath,['--no-warnings','--test',...entries.map(p=>resolve(p.replace('task-island/','task-island/.test-build/').replace(/\.ts$/,'.mjs')))],{stdio:'inherit'});
process.exitCode=result.status??1;
