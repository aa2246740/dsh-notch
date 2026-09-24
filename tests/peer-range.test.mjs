import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const RANGE = '>=0.1.7-rc.1 <0.1.8'
const PEERS = [
  '@deepseek-ai/dsh',
  '@deepseek-ai/dsh-host-webserver',
  '@deepseek-ai/dsh-session',
  '@deepseek-ai/dsh-user-approval',
  '@deepseek-ai/dsh-user-questions',
]

test('Harness peer range includes the 0.1.7-rc.2 desk pin', () => {
  const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'))
  assert.equal(pkg.version, '0.3.2')
  for (const name of PEERS) {
    assert.equal(pkg.peerDependencies[name], RANGE)
    assert.equal(pkg.peerDependenciesMeta[name].optional, true)
  }
})
