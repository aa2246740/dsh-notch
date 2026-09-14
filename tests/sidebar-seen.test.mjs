/**
 * Regression test for the sidebar-mirror unread rule (Windows port fork
 * difference #2).
 *
 * While any DSH page is open and syncing, `unread` used to come straight from the
 * sidebar's `completed` flag, with no regard for `seen`. That made an explicit
 * "mark all seen" a permanent no-op: the lamps were cleared in `seen` and
 * re-armed by the very next sync. The rule now honours `dismissed` first, exactly
 * like the non-mirror branch always did.
 *
 * Run: node tests/sidebar-seen.test.mjs
 *
 * No tsx needed: Node 24 strips the types in src/*.ts itself, which is also how
 * the running DSH host loads this plugin.
 */
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// Redirect the plugin's data files (homedir()/.dsh/dsh-notch) into a scratch
// directory BEFORE importing the store, so the user's real seen.json is never
// touched. os.homedir() reads HOME on POSIX and USERPROFILE on Windows.
const scratch = mkdtempSync(join(tmpdir(), 'dsh-notch-test-'))
process.env.HOME = scratch
process.env.USERPROFILE = scratch
const dataDir = join(scratch, '.dsh', 'dsh-notch')
mkdirSync(dataDir, { recursive: true })

const { Board } = await import('../src/board.ts')

const SESSION = 'session-00000000-0000-0000-0000-000000000001'
const TURN_AT = 1_700_000_000_000

function makeSession(agentStatus) {
  const events = [
    { type: 'turn/start', time: TURN_AT - 1000 },
    { type: 'turn/end', time: TURN_AT, data: { reason: { kind: 'completed' } } },
  ]
  return {
    id: SESSION,
    header: {},
    snapshotEvents: () => events,
    agentStatus,
  }
}

/** Minimal Context: only the services Board touches. */
function makeCtx(agentStatus) {
  const session = makeSession(agentStatus)
  return {
    sessions: { list: () => [session] },
    agents: { get: () => ({ status: agentStatus }) },
    get: () => undefined,
    logger: { warn: () => {} },
  }
}

const sidebarRow = { id: SESSION, title: 'scratch session', completed: true, running: false }
const sync = (board) => board.syncSidebar({ clientId: 'c1', focused: true, rows: [sidebarRow] })
const rowOf = (board) => board.snapshot('x').rows.find(row => row.id === SESSION)

/** Every case gets its own seen.json, so cases cannot leak into each other. */
function freshBoard(seen = {}, agentStatus = 'idle') {
  writeFileSync(join(dataDir, 'seen.json'), JSON.stringify(seen), 'utf8')
  return new Board(makeCtx(agentStatus))
}

let failures = 0
function check(name, ok, detail) {
  if (!ok) failures++
  console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${name.padEnd(44)} ${detail}`)
}

// 1. A fresh sidebar sync reports the finished session as unread.
{
  const board = freshBoard()
  sync(board)
  const row = rowOf(board)
  check('sidebar completion shows as unread', row?.unread === true, `unread=${row?.unread}`)
}

// 2. "mark all seen" must STICK even though the mirror keeps saying completed.
//    (Before the fix this failed: unread came straight from the mirror.)
{
  const board = freshBoard()
  sync(board)
  const before = rowOf(board)?.unread === true
  board.markAllSeen()
  sync(board)
  const row = rowOf(board)
  check('seen all sticks despite the mirror',
    before && row?.unread !== true,
    `before=${before} after=${row === undefined ? 'row omitted' : 'unread=' + row.unread}`)
}

// 3. The same for a single session.
{
  const board = freshBoard()
  sync(board)
  const before = rowOf(board)?.unread === true
  board.markSeen(SESSION)
  sync(board)
  const row = rowOf(board)
  check('markSeen sticks despite the mirror',
    before && row?.unread !== true,
    `before=${before} after=${row === undefined ? 'row omitted' : 'unread=' + row.unread}`)
}

// 4. A NEWER turn than the seen mark is still unread (seen must not over-mute).
{
  const board = freshBoard({ [SESSION]: TURN_AT - 5000 })
  sync(board)
  const row = rowOf(board)
  check('turn newer than seen stays unread', row?.unread === true, `unread=${row?.unread}`)
}

// 5. Busy wins: nothing is "unread" while the session is running.
{
  const board = freshBoard({}, 'running')
  sync(board)
  const row = rowOf(board)
  check('busy row is not unread', row?.busy === true && row?.unread === false,
    `busy=${row?.busy} unread=${row?.unread}`)
}

try { rmSync(scratch, { recursive: true, force: true }) } catch { /* best effort */ }

console.log(failures === 0 ? '\nRESULT: PASS' : `\nRESULT: FAIL (${failures})`)
process.exit(failures === 0 ? 0 : 1)
