import { build } from '../monitor-probe/runtime/node_modules/esbuild/lib/main.js';
await build({entryPoints:['task-island/bridge.ts'],outfile:'task-island/bridge.mjs',
  bundle:true,platform:'node',format:'esm',target:'node22',
  nodePaths:['monitor-probe/runtime/node_modules'],logLevel:'warning'});
