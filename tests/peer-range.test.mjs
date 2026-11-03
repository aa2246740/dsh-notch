import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import semver from 'semver'

const RANGE = '>=0.2.1-rc.1 <0.2.2'
const ACCEPT = ['0.2.1-rc.5', '0.2.1']
const REJECT = ['0.2.0-alpha.1', '0.2.0-alpha.9', '0.2.0-rc.2', '0.2.0', '0.1.7-rc.2', '0.2.1-alpha.1', '0.2.2']
const HOST_PEERS = [
  '@deepseek-ai/dsh',
  '@deepseek-ai/dsh-home-paths',
  '@deepseek-ai/dsh-host-webserver',
  '@deepseek-ai/dsh-session',
  '@deepseek-ai/dsh-user-approval',
  '@deepseek-ai/dsh-user-questions',
]
const OPTIONAL = [
  '@deepseek-ai/dsh',
  '@deepseek-ai/dsh-host-webserver',
  '@deepseek-ai/dsh-session',
  '@deepseek-ai/dsh-user-approval',
  '@deepseek-ai/dsh-user-questions',
]
const FOCUS_PEERS = [
  '@deepseek-ai/dsh-client-ui-workspace',
  '@deepseek-ai/dsh-client-ui-session',
  '@deepseek-ai/dsh-api-session-controller',
]

test('Harness peer range accepts 0.2.1-rc.5', () => {
  const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'))
  assert.equal(pkg.version, '0.3.7')
  assert.equal(pkg.devDependencies['@deepseek-ai/dsh-home-paths'], RANGE)
  for (const name of HOST_PEERS) assert.equal(pkg.peerDependencies[name], RANGE)
  for (const name of OPTIONAL) assert.equal(pkg.peerDependenciesMeta[name].optional, true)
  for (const version of ACCEPT) assert.equal(semver.satisfies(version, RANGE), true, version)
  for (const version of REJECT) assert.equal(semver.satisfies(version, RANGE), false, version)
})

test('focus companion uses the same Harness peer range', () => {
  const pkg = JSON.parse(readFileSync(new URL('../companions/dsh-notch-focus/package.json', import.meta.url), 'utf8'))
  assert.equal(pkg.version, '0.1.4')
  for (const name of FOCUS_PEERS) {
    assert.equal(pkg.peerDependencies[name], RANGE)
    assert.equal(pkg.devDependencies[name], RANGE)
  }
  for (const version of ACCEPT) assert.equal(semver.satisfies(version, RANGE), true, version)
  for (const version of REJECT) assert.equal(semver.satisfies(version, RANGE), false, version)
})
