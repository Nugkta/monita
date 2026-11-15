import { build } from './runtime/node_modules/esbuild/lib/main.js';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
const entries = [
  'monitor-probe/source/tests/adapter.test.ts',
  'monitor-probe/source/tests/projection.test.ts',
  'monitor-probe/tests/projection-v13.test.ts',
  'monitor-probe/tests/provider-v13.test.ts',
];
await build({entryPoints:entries,outdir:'monitor-probe/.test-build',outbase:'monitor-probe',
  outExtension:{'.js':'.mjs'},bundle:true,platform:'node',format:'esm',target:'node22',
  nodePaths:['monitor-probe/runtime/node_modules'],logLevel:'warning'});
const files = entries.map(p=>resolve(p.replace('monitor-probe/','monitor-probe/.test-build/').replace(/\.ts$/,'.mjs')));
const result=spawnSync(process.execPath,['--no-warnings','--test',...files],{stdio:'inherit'});
process.exitCode=result.status??1;
