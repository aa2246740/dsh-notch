import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { ClaudeBoard, describeTool, hasOwnedBackground, toAskAnswers } from '../claude-code/scripts/lib/board.mjs'

function fixture() {
  let clock = 1_000
  const board = new ClaudeBoard({ now: () => clock })
  const fire = (hook_event_name, extra = {}) => board.apply({ session_id: 's1', cwd: '/work/app', claude_pid: 4242,
    hook_event_name, at: clock, ...extra })
  return { board, fire, tick: (ms = 10) => { clock += ms }, rows: () => board.snapshot('http://x').rows }
}

test('prompt → running (blue), Stop → unread completed (green), next prompt reads it', () => {
  const f = fixture()
  f.fire('SessionStart', { source: 'startup' })
  assert.deepEqual(f.rows(), [])
  f.tick(); f.fire('UserPromptSubmit', { prompt: 'Fix the flaky test\nmore detail' })
  assert.deepEqual(f.rows().map(({ id, title, busy, unread, child }) => ({ id, title, busy, unread, child })),
    [{ id: 's1', title: 'app · Fix the flaky test', busy: true, unread: false, child: false }])
  f.tick(); f.fire('Stop', { background_tasks: [] })
  const [done] = f.rows()
  assert.equal(done.busy, false); assert.equal(done.unread, true)
  assert.equal(done.lastTurn.failed, false)
  f.tick(); f.fire('UserPromptSubmit', { prompt: 'again' })
  assert.equal(f.rows()[0].busy, true)
  assert.equal(f.rows()[0].title, 'app · Fix the flaky test', 'first prompt stays the title')
})

test('StopFailure is a red result; marking seen clears it', () => {
  const f = fixture()
  f.fire('UserPromptSubmit', { prompt: 'go' })
  f.tick(); f.fire('StopFailure', { error_type: 'rate_limit' })
  const [row] = f.rows()
  assert.deepEqual(row.lastTurn, { at: 1_010, kind: 'rate_limit', failed: true })
  assert.equal(row.unread, true)
  f.tick(); f.board.markSeen('s1')
  assert.deepEqual(f.rows(), [])
})

test('a late async UserPromptSubmit cannot re-open a turn that already stopped', () => {
  const f = fixture()
  f.fire('Stop', { at: 2_000 })
  f.fire('UserPromptSubmit', { at: 1_500, prompt: 'late' })
  assert.equal(f.rows()[0].busy, false)
  f.fire('PostToolUse', { at: 1_600, tool_name: 'Bash', tool_input: {} })
  assert.equal(f.rows()[0].busy, false)
})

test('owned background work keeps the conversation running; shell tails do not', () => {
  assert.equal(hasOwnedBackground([{ type: 'shell', status: 'running' }]), false)
  assert.equal(hasOwnedBackground([{ type: 'subagent', status: 'running' }]), true)
  assert.equal(hasOwnedBackground([{ type: 'workflow', status: 'completed' }]), false)
  const f = fixture()
  f.fire('UserPromptSubmit', { prompt: 'x' })
  f.tick(); f.fire('Stop', { background_tasks: [{ type: 'subagent', status: 'running' }] })
  assert.equal(f.rows()[0].busy, true)
  f.tick(); f.fire('Stop', { background_tasks: [] })
  assert.equal(f.rows()[0].busy, false); assert.equal(f.rows()[0].unread, true)
})

test('permission request becomes a yellow approval and resolves to a Claude Code decision', async () => {
  const f = fixture()
  f.fire('UserPromptSubmit', { prompt: 'x' })
  const held = f.board.hold({ session_id: 's1', hook_event_name: 'PermissionRequest', tool_name: 'Bash',
    tool_input: { command: 'rm -rf node_modules', description: 'clean' } })
  const [row] = f.rows()
  assert.deepEqual(row.approval, { id: held.id, toolName: 'Bash', reason: 'Bash: rm -rf node_modules' })
  assert.equal(f.board.decideApproval(held.id, 'bogus'), false)
  assert.equal(f.board.decideApproval(held.id, 'allowed-once'), true)
  assert.deepEqual(await held.decision, { behavior: 'allow' })
  assert.equal(f.rows()[0].approval, undefined)

  const denied = f.board.hold({ session_id: 's1', tool_name: 'Write', tool_input: { file_path: '/a' } })
  f.board.decideApproval(denied.id, 'rejected')
  assert.equal((await denied.decision).behavior, 'deny')
})

test('AskUserQuestion is answered through updatedInput.answers keyed by question text', async () => {
  const f = fixture()
  const input = { questions: [
    { question: 'Which framework?', header: 'Framework', multiSelect: false,
      options: [{ label: 'React', description: 'UI' }, { label: 'Vue' }] },
    { question: 'Which checks?', header: 'Checks', multiSelect: true, options: [{ label: 'lint' }, { label: 'test' }] },
    { question: 'Anything else?', header: 'Other', options: [{ label: 'No' }] },
  ] }
  const held = f.board.hold({ session_id: 's1', tool_name: 'AskUserQuestion', tool_input: input })
  const ask = f.rows()[0].ask
  assert.deepEqual(ask.questions.map(q => q.id), ['0', '1', '2'])
  assert.deepEqual(ask.questions[0].options, [{ label: 'React', description: 'UI' }, { label: 'Vue' }])
  assert.equal(f.board.decideApproval(ask.id, 'allowed-once'), false, 'an ask is not an approval')
  assert.equal(f.board.answerAsk(ask.id, [
    { id: '0', selected: ['Vue'] },
    { id: '1', selected: ['lint', 'test'], custom: 'typecheck' },
    { id: '2', selected: [] },
  ]), true)
  assert.deepEqual(await held.decision, { behavior: 'allow', updatedInput: { ...input, answers: {
    'Which framework?': 'Vue', 'Which checks?': 'lint, test, typecheck', 'Anything else?': 'Skipped' } } })
})

test('a dialog answered in the terminal stops being held', async () => {
  const f = fixture()
  const bash = f.board.hold({ session_id: 's1', tool_name: 'Bash', tool_input: { command: 'ls' } })
  const edit = f.board.hold({ session_id: 's1', tool_name: 'Edit', tool_input: { file_path: '/x' } })
  f.fire('PostToolUse', { tool_name: 'Bash', tool_input: { command: 'ls' } })
  assert.equal(await bash.decision, null)
  assert.equal(f.rows()[0].approval.id, edit.id)
  f.tick(); f.fire('Stop')
  assert.equal(await edit.decision, null)
  assert.equal(f.rows()[0].approval, undefined)
})

test('dead Claude Code processes and ended sessions disappear with their holds', async () => {
  const f = fixture()
  f.fire('UserPromptSubmit', { prompt: 'x' })
  const held = f.board.hold({ session_id: 's1', tool_name: 'Bash', tool_input: {} })
  f.board.prune(pid => pid !== 4242)
  assert.equal(await held.decision, null)
  assert.deepEqual(f.rows(), [])
  f.fire('UserPromptSubmit', { prompt: 'y' })
  f.fire('SessionEnd', { end_reason: 'prompt_input_exit' })
  assert.equal(f.board.sessions.size, 0)
})

test('seen state survives in the injected map and suppresses an already-read result', () => {
  const seen = { s1: 5_000 }
  const board = new ClaudeBoard({ now: () => 6_000, seen })
  board.apply({ session_id: 's1', hook_event_name: 'Stop', at: 4_000 })
  assert.deepEqual(board.snapshot('o').rows, [])
})

test('describeTool keeps the approval card to one readable line', () => {
  assert.equal(describeTool('ExitPlanMode', { plan: '\n## Refactor auth\n1. Extract' }), 'Approve plan: Refactor auth')
  assert.equal(describeTool('mcp__srv__do', { b: 1, a: 2 }), 'mcp__srv__do: {"a":2,"b":1}')
  assert.equal(describeTool('Bash', { command: 'x'.repeat(1000) }).length, 400)
  assert.deepEqual(toAskAnswers([{ id: '0', question: 'Q' }], [{ id: '0', selected: [], custom: ' free ' }]), { Q: 'free' })
})

test('the plugin ships the same helper supervisor as the desktop shell', () => {
  assert.equal(readFileSync(new URL('../claude-code/scripts/lib/notch-lifecycle.mjs', import.meta.url), 'utf8'),
    readFileSync(new URL('../desktop/notch-lifecycle.mjs', import.meta.url), 'utf8'))
})
