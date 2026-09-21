import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

function resolveHarness() {
  const configured = process.env.DSHX_HARNESS?.trim()
  if (configured) return resolve(configured)
  const configPath = join(homedir(), '.config/dshx/harness')
  const recorded = existsSync(configPath) ? readFileSync(configPath, 'utf8').trim() : undefined
  if (!recorded) {
    throw new Error('dshx client build requires a Harness root from DSHX_HARNESS or ~/.config/dshx/harness')
  }
  return resolve(recorded)
}

const adapter = join(resolveHarness(), 'tools/dshx/src/client-build.js')
if (!existsSync(adapter)) throw new Error(`dshx client build adapter not found: ${adapter}`)
const { externalClientBundle } = await import(pathToFileURL(adapter).href)

export default externalClientBundle('dsh-notch-focus', ['lib/types/dsh-notch-focus.js'], {
  clientEntry: 'src/client/index.tsx',
})
