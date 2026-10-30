import { execFileSync } from 'node:child_process';
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { VENDORED_SRT_WIN_EXE } from '@anthropic-ai/sandbox-runtime';

const root = fileURLToPath(new URL('..', import.meta.url));
const output = resolve(root, 'dist');
const args = process.argv.slice(2);
const esbuildCli = args[0] ? resolve(args[0]) : resolve(root, 'node_modules/esbuild/bin/esbuild');
const postjectCli = args[1] ? resolve(args[1]) : resolve(root, 'node_modules/postject/dist/cli.js');
const bundle = resolve(output, 'bundle.cjs');
const configPath = resolve(output, 'sea-config.json');
const blob = resolve(output, 'sea-prep.blob');
const exe = resolve(output, 'windows-sandbox-cli.exe');

await mkdir(output, { recursive: true });
execFileSync(process.execPath, [
  esbuildCli, resolve(root, 'src/cli.mjs'), '--bundle', '--platform=node', '--format=cjs',
  '--target=node24', '--outfile=' + bundle,
  '--define:import.meta.url="file:///C:/__sea__/dist/sandbox/windows-sandbox-utils.js"',
], { stdio: 'inherit' });

// SRT 0.0.81 retries EADDRINUSE but stops on EACCES. Windows may reserve
// an individual port inside the installed WFP range (as it does for 60080
// on this host). Keep the installed range unchanged and try the next port.
const originalRetry = 'if (range && err?.code === "EADDRINUSE" && port < hi) {';
const patchedRetry = 'if (range && (err?.code === "EADDRINUSE" || err?.code === "EACCES") && port < hi) {';
const bundledSource = await readFile(bundle, 'utf8');
if (bundledSource.split(originalRetry).length !== 2) {
  throw new Error('Pinned SRT 0.0.81 proxy retry signature changed; review the upstream code before packaging');
}
await writeFile(bundle, bundledSource.replace(originalRetry, patchedRetry));

await writeFile(configPath, JSON.stringify({
  main: bundle,
  output: blob,
  disableExperimentalSEAWarning: true,
  useSnapshot: false,
  useCodeCache: false,
  assets: { 'srt-win.exe': VENDORED_SRT_WIN_EXE },
}, null, 2));
execFileSync(process.execPath, ['--experimental-sea-config', configPath], { stdio: 'inherit' });
await copyFile(process.execPath, exe);
execFileSync(process.execPath, [
  postjectCli, exe, 'NODE_SEA_BLOB', blob,
  '--sentinel-fuse', 'NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2',
], { stdio: 'inherit' });
console.log(exe);
