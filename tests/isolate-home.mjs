import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// The official Home resolver respects DSH_HOME before os.homedir(). Each
// test worker must override an inherited real Home before importing the store.
const home = mkdtempSync(join(tmpdir(), 'notch-unit-home-'))
process.env.DSH_HOME = home
process.on('exit', () => rmSync(home, { recursive: true, force: true }))
