import { after } from 'node:test'
import os from 'node:os'
import { mkdtempSync, rmSync } from 'node:fs'
import { syncBuiltinESMExports } from 'node:module'
const home = mkdtempSync(os.tmpdir() + '/notch-isolated-')
const original = os.homedir
os.homedir = () => home
syncBuiltinESMExports()
const { Board } = await import('../src/board.ts')
os.homedir = original
syncBuiltinESMExports()
after(() => rmSync(home, { recursive: true, force: true }))
export { Board }
