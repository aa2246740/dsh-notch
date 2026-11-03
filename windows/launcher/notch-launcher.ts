/**
 * dsh-notch-win launcher — starts the Windows capsule when DSH boots.
 *
 * The capsule used to be started by Windows at logon
 * (`HKCU\...\CurrentVersion\Run\DshNotchWin`). That is the wrong lifetime for
 * it: the capsule is the *UI half* of a program whose other half is this DSH
 * Host plugin, and a logon-start begins it even when no DSH ever runs, for a
 * whole session. Starting it from the Host's own boot keeps the two halves
 * together — and it needs nothing outside DSH, so the registry is not touched
 * at all any more.
 *
 * Why a plugin of its own instead of three lines inside `src/dsh-notch.ts`:
 * `src/` is upstream code (this port keeps exactly 3 deliberate fork
 * differences there, in board.ts) while `windows/` is the Windows port. A
 * separate entry keeps the Windows-only behaviour in the Windows subproject.
 *
 * Loaded through the profile's `cordis.patch.yml` (install.ps1 appends this
 * insert; the profile directory reaches this file through the `dsh-notch`
 * junction):
 *
 *     - insert:
 *         - id: dsh-notch-win-launcher
 *           name: './dsh-notch/windows/launcher/notch-launcher.ts'
 *
 * Behaviour: check → spawn, and bind that work to the plugin scope. Disposal
 * aborts an in-flight `tasklist` and refuses to spawn afterwards. A helper
 * this call actually started is stopped on disposal only after its live image
 * path still matches the executable we launched, so a recycled pid is left
 * alone. A capsule that was already running is not owned and is not signalled.
 *
 * Environment overrides:
 *   DSH_NOTCH_WIN_EXE      capsule binary to launch (default: this repo's build)
 *   DSH_NOTCH_WIN_LAUNCH=0 do not launch (e.g. when debugging the Host alone)
 */

import { execFile, execFileSync, spawn, type ChildProcess } from 'node:child_process'
import { existsSync } from 'node:fs'
import { basename, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'dsh-notch-win-launcher'

interface LauncherScope {
  /** Cordis registers the returned function and calls it when the scope ends. */
  effect?: (register: () => (() => void) | void) => unknown
  signal?: AbortSignal
}

interface OwnedHelper {
  child: ChildProcess
  exe: string
}

/**
 * The binary is always the repository's own build output — the same tree the
 * Host plugin is loaded from — so there is no second copy to drift.
 * `<repo>/windows/launcher/notch-launcher.ts` → `<repo>/windows/DshNotchWin/bin/...`
 */
function resolveExe(): string {
  const override = process.env.DSH_NOTCH_WIN_EXE
  if (override && override.trim().length > 0) return override.trim()

  const here = dirname(fileURLToPath(import.meta.url))
  return resolve(here, '..', 'DshNotchWin', 'bin', 'Release', 'net8.0-windows', 'win-x64', 'dsh-notch-win.exe')
}

function isDisabled(): boolean {
  const flag = process.env.DSH_NOTCH_WIN_LAUNCH
  if (!flag) return false
  return ['0', 'false', 'no', 'off'].includes(flag.trim().toLowerCase())
}

/**
 * True when a process with that image name exists. `tasklist` is used because
 * it is the only process listing Windows ships; CSV output keeps the check
 * locale-independent (the "no tasks match" message never quotes a name).
 * A failing tasklist returns false — the capsule's own mutex is the real guard,
 * so "unknown" must not swallow the launch. Disposal settles the probe as
 * "not running" so the await cannot still spawn afterwards.
 */
function isRunning(exeName: string, signal: AbortSignal): Promise<boolean> {
  return new Promise((done) => {
    let settled = false
    const finish = (running: boolean) => {
      if (settled) return
      settled = true
      signal.removeEventListener('abort', onAbort)
      done(running)
    }
    const onAbort = () => finish(false)
    if (signal.aborted) {
      done(false)
      return
    }
    signal.addEventListener('abort', onAbort, { once: true })
    execFile(
      'tasklist',
      ['/FI', `IMAGENAME eq ${exeName}`, '/FO', 'CSV', '/NH'],
      { windowsHide: true, timeout: 10_000, signal },
      (error, stdout) => {
        const text = typeof stdout === 'string' ? stdout : String(stdout ?? '')
        finish(!signal.aborted && !error && text.toLowerCase().includes(`"${exeName.toLowerCase()}"`))
      },
    )
  })
}

/** Extended-length and quoted paths still have to compare equal to the exe we spawned. */
function normalizeImagePath(value: string): string {
  let text = value.trim().replace(/^"(.*)"$/, '$1')
  if (text.startsWith('\\\\?\\')) text = text.slice(4)
  return resolve(text).replace(/[\\/]+$/, '').toLowerCase()
}

function pathsEqual(left: string, right: string): boolean {
  return normalizeImagePath(left) === normalizeImagePath(right)
}

/**
 * Live image path for a pid, or null when it cannot be verified. A missing
 * answer is not a match: signalling then could hit a pid that was reused.
 */
function imagePath(pid: number): string | null {
  if (!Number.isSafeInteger(pid) || pid <= 1) return null
  try {
    const output = execFileSync(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        `$p = Get-CimInstance Win32_Process -Filter 'ProcessId=${pid}'; if ($null -ne $p) { $p.ExecutablePath }`,
      ],
      { encoding: 'utf8', timeout: 3000, windowsHide: true },
    )
    const text = String(output).trim()
    return text.length > 0 ? text : null
  } catch {
    return null
  }
}

function signalOwned(child: ChildProcess, exe: string): void {
  const pid = child.pid
  if (pid == null || child.exitCode != null) return
  const image = imagePath(pid)
  if (image == null || !pathsEqual(image, exe)) return
  try {
    child.kill()
  } catch {
    // already gone
  }
}

async function launch(
  signal: AbortSignal,
  onSpawn: (child: ChildProcess, exe: string) => void,
): Promise<void> {
  const exe = resolveExe()

  if (!existsSync(exe)) {
    console.warn(`[dsh-notch-win] no capsule binary at ${exe} — not launching`)
    return
  }
  if (signal.aborted) return

  const exeName = basename(exe)
  if (await isRunning(exeName, signal)) return
  if (signal.aborted) return

  // detached + stdio ignored: a crash of DSH must not strand the Host on the
  // capsule. Plugin disposal still owns the child and stops it when the image
  // path is still the one we started.
  const child = spawn(exe, [], { detached: true, stdio: 'ignore', windowsHide: true })
  child.on('error', (error) => {
    console.warn(`[dsh-notch-win] could not start the capsule: ${String(error)}`)
  })
  onSpawn(child, exe)
  if (signal.aborted) return
  child.unref()
  console.log(`[dsh-notch-win] capsule started (pid ${String(child.pid ?? '?')}) from ${exe}`)
}

export function apply(ctx: LauncherScope = {}): void {
  if (process.platform !== 'win32') return

  if (isDisabled()) {
    console.log('[dsh-notch-win] launcher disabled (DSH_NOTCH_WIN_LAUNCH=0)')
    return
  }

  const controller = new AbortController()
  if (ctx.signal?.aborted) controller.abort()
  else ctx.signal?.addEventListener('abort', () => controller.abort(), { once: true })

  let owned: OwnedHelper | null = null
  const stopOwned = () => {
    if (!controller.signal.aborted) controller.abort()
    const current = owned
    owned = null
    if (!current) return
    signalOwned(current.child, current.exe)
    current.child.unref()
  }

  // Called immediately by Cordis. The returned function runs on disposal,
  // which is also what a scope double-call (`effect()?.()`) does.
  ctx.effect?.(() => stopOwned)

  void launch(controller.signal, (child, exe) => {
    owned = { child, exe }
    if (controller.signal.aborted) stopOwned()
  }).catch((error: unknown) => {
    console.warn(`[dsh-notch-win] launcher failed: ${String(error)}`)
  })
}
