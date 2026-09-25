import { spawn, execFileSync } from 'node:child_process'
import { readFileSync, mkdirSync, writeFileSync, renameSync, unlinkSync, statSync } from 'node:fs'
import { dirname, resolve } from 'node:path'

/** PID alone is not ownership: require both executable and process start time. */
export function processIdentity(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 1) return { state: 'dead' }
  try {
    const text = execFileSync('/bin/ps', ['-p', String(pid), '-o', 'lstart=', '-o', 'comm='],
      { encoding: 'utf8', env: { ...process.env, LC_ALL: 'C' }, timeout: 1000 }).trim()
    const match = /^(.{24})\s+(.+)$/.exec(text)
    if (match) return { state: 'alive', stamp: match[1], command: match[2] }
  } catch {}
  try { process.kill(pid, 0) } catch (error) {
    if (error.code === 'ESRCH') return { state: 'dead' }
  }
  return { state: 'unknown' }
}

export function processLiveness(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 1) return 'dead'
  try { process.kill(pid, 0); return 'alive' } catch (error) {
    return error.code === 'ESRCH' ? 'dead' : 'unknown'
  }
}

/** The desktop owns an adopted helper too. If it exits during adoption, retry. */
export function superviseNotch({ bin, pidPath, log, interval = 250, env = process.env,
  probe = processIdentity, alive = processLiveness, launch = spawn, signal = process.kill.bind(process) }) {
  let current, pending, timer, stopped = false
  const starts = []
  const note = text => log.write(`[notch] ${text}\n`)
  const storedPID = () => {
    try { return Number(readFileSync(pidPath, 'utf8').trim()) } catch { return 0 }
  }
  const owned = pid => {
    const identity = probe(pid)
    return identity.state === 'alive' && resolve(identity.command) === resolve(bin)
      ? { pid, ...identity, checkedAt: Date.now() } : undefined
  }
  const schedule = () => {
    clearTimeout(timer)
    if (!stopped) { timer = setTimeout(reconcile, interval); timer.unref?.() }
  }
  function reconcile() {
    if (stopped) return
    if (pending) { schedule(); return }
    // External installers hold this short lease while replacing executable + PID.
    // A crashed installer cannot disable recovery indefinitely.
    try {
      if (Date.now() - statSync(`${pidPath}.updating`).mtimeMs < 60000) { schedule(); return }
    } catch {}
    if (current) {
      const state = alive(current.pid)
      if (state === 'unknown' || (state === 'alive' && Date.now() - current.checkedAt < 5000)) {
        schedule(); return
      }
      const live = probe(current.pid)
      if (live.state === 'unknown' || (live.state === 'alive' && live.stamp === current.stamp && live.command === current.command)) {
        current.checkedAt = Date.now()
        schedule(); return
      }
      current = undefined
    }
    const pid = storedPID()
    const identity = probe(pid)
    if (identity.state === 'unknown') { schedule(); return }
    current = owned(pid)
    if (current) { note(`adopt ${current.pid}`); schedule(); return }
    while (starts.length && Date.now() - starts[0] > 10000) starts.shift()
    if (starts.length >= 3) { note('helper repeatedly exited; retry paused'); stopped = true; return }
    starts.push(Date.now())
    const child = launch(bin, [], { stdio: ['ignore', 'pipe', 'pipe'], detached: false, env })
    pending = child
    child.stdout?.pipe(log, { end: false })
    child.stderr?.pipe(log, { end: false })
    child.once('spawn', () => {
      if (pending !== child) return
      pending = undefined
      if (stopped) { child.kill('SIGTERM'); return }
      current = owned(child.pid)
      // A successful spawn still must be attributable before touching its PID file.
      if (!current) { child.kill('SIGTERM'); schedule(); return }
      mkdirSync(dirname(pidPath), { recursive: true })
      const stage = `${pidPath}.${process.pid}.tmp`
      writeFileSync(stage, `${child.pid}\n`)
      renameSync(stage, pidPath)
      note(`spawn ${child.pid}`)
      schedule()
    })
    child.once('error', error => { if (pending === child) pending = undefined; note(`spawn error: ${error.message}`); schedule() })
    child.once('exit', () => {
      if (pending === child) pending = undefined
      if (current?.pid === child.pid) current = undefined
      schedule()
    })
    schedule()
  }
  const stop = () => {
    stopped = true
    clearTimeout(timer)
    pending?.kill('SIGTERM')
    // A native hot replacement may have updated the file since the last check.
    const candidates = [current, owned(storedPID())].filter(Boolean)
    const seen = new Set()
    for (const item of candidates) {
      if (seen.has(item.pid)) continue
      seen.add(item.pid)
      const live = owned(item.pid)
      if (!live || live.stamp !== item.stamp) continue
      try { signal(item.pid, 'SIGTERM'); note(`stop ${item.pid}`) } catch (error) {
        if (error.code !== 'ESRCH') note(`stop failed: ${error.message}`)
      }
      if (storedPID() === item.pid) { try { unlinkSync(pidPath) } catch {} }
    }
    current = undefined
  }
  reconcile()
  return { get pid() { return current?.pid ?? pending?.pid }, stop, kill: stop }
}
