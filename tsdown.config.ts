import { defineConfig } from 'tsdown'
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
const harness = process.env.DSHX_HARNESS || readFileSync(join(homedir(), '.config/dshx/harness'), 'utf8').trim()
const { externalClientBundle } = await import(pathToFileURL(join(harness, 'tools/dshx/src/client-build.js')).href)
export default [
  defineConfig({ entry: { index: 'src/dsh-notch.ts' }, format: 'esm', target: 'node24', outDir: 'lib', deps: { neverBundle: [/^@deepseek-ai\//] }, dts: false, sourcemap: true }),
  ...externalClientBundle('dsh-notch', [], { clientEntry: 'src/client/index.ts' }).filter(config => config.format === 'cjs'),
]
