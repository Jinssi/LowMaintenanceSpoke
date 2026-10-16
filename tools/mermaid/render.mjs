// Renders every docs/*.mmd to SVG (and PNG) using the local Azure icon pack.
// Usage: node render.mjs [file.mmd ...]   (default: all of ../../docs/*.mmd)
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = fileURLToPath(new URL('.', import.meta.url));
const docs = resolve(here, '../../docs');
const pack = join(here, 'azure-icons.json');
const config = join(here, 'mermaid.config.json');
const mmdc = join(here, 'node_modules', '.bin', process.platform === 'win32' ? 'mmdc.cmd' : 'mmdc');

if (!existsSync(pack)) throw new Error('azure-icons.json missing: run `npm run build-icons` first.');
if (!existsSync(mmdc)) throw new Error('mermaid-cli missing: run `npm install` in tools/mermaid first.');

const inputs = process.argv.slice(2).length
  ? process.argv.slice(2).map((f) => resolve(f))
  : readdirSync(docs).filter((f) => f.endsWith('.mmd')).map((f) => join(docs, f));

for (const input of inputs) {
  for (const ext of ['svg', 'png']) {
    const output = input.replace(/\.mmd$/, `.${ext}`);
    const args = ['-i', input, '-o', output, '-c', config, '-b', 'white', '--iconPacksNamesAndUrls', `azure#${pathToFileURL(pack).href}`];
    if (ext === 'png') args.push('-s', '2');
    execFileSync(mmdc, args, { stdio: 'inherit', shell: process.platform === 'win32' });
    console.log(`Rendered ${output}`);
  }
}
