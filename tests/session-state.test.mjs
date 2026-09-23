import { test } from 'node:test'
import assert from 'node:assert/strict'
import { foldSession } from '../src/session-state.ts'

function session(events) {
  return { snapshotEvents: () => events }
}

test('aborted last turn is not a failure lamp', () => {
  const folded = foldSession(session([
    { type: 'turn/start', time: 1 },
    { type: 'turn/end', time: 2, data: { reason: { kind: 'aborted' } } },
  ]))
  assert.equal(folded.busy, false)
  assert.equal(folded.lastTurn.kind, 'aborted')
  assert.equal(folded.lastTurn.failed, false)
})

test('interrupted last turn is not a failure lamp', () => {
  const folded = foldSession(session([
    { type: 'turn/start', time: 1 },
    { type: 'turn/end', time: 2, data: { reason: { kind: 'interrupted' } } },
  ]))
  assert.equal(folded.lastTurn.failed, false)
})

test('a new turn clears the previous abort so a running session cannot stay red', () => {
  const folded = foldSession(session([
    { type: 'turn/start', time: 1 },
    { type: 'turn/end', time: 2, data: { reason: { kind: 'aborted' } } },
    { type: 'turn/start', time: 3 },
  ]))
  assert.equal(folded.busy, true)
  assert.equal(folded.lastTurn, undefined)
})

test('a fork-seed closer is not a failure lamp', () => {
  const folded = foldSession(session([
    { type: 'turn/start', time: 1 },
    { type: 'turn/end', time: 2, data: { reason: { kind: 'forked' } } },
  ]))
  assert.equal(folded.busy, false)
  assert.equal(folded.lastTurn.kind, 'forked')
  assert.equal(folded.lastTurn.failed, false)
})

test('error still counts as failed after the turn ends', () => {
  const folded = foldSession(session([
    { type: 'turn/start', time: 1 },
    { type: 'turn/end', time: 2, data: { reason: { kind: 'error' } } },
  ]))
  assert.equal(folded.busy, false)
  assert.equal(folded.lastTurn.failed, true)
})
