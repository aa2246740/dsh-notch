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
 * Behaviour: check → spawn → forget. The capsule is a detached GUI process
 * with its own single-instance mutex (`Program.cs`), it waits for the Host's
 * `~/.dsh/dsh-notch/runtime.json` and reconnects by itself, so nothing here
 * needs to be kept alive, retried or torn down with DSH.
 *
 * Environment overrides:
 *   DSH_NOTCH_WIN_EXE      capsule binary to launch (default: this repo's build)
 *   DSH_NOTCH_WIN_LAUNCH=0 do not launch (e.g. when debugging the Host alone)
 */

import { execFile, spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { basename, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'dsh-notch-win-launcher'

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
 * so "unknown" must not swallow the launch.
 */
function isRunning(exeName: string): Promise<boolean> {
  return new Promise((done) => {
    execFile(
      'tasklist',
      ['/FI', `IMAGENAME eq ${exeName}`, '/FO', 'CSV', '/NH'],
      { windowsHide: true, timeout: 10_000 },
      (error, stdout) => {
        done(!error && stdout.toLowerCase().includes(`"${exeName.toLowerCase()}"`))
      },
    )
  })
}

async function launch(): Promise<void> {
  const exe = resolveExe()

  if (!existsSync(exe)) {
    console.warn(`[dsh-notch-win] no capsule binary at ${exe} — not launching`)
    return
  }

  const exeName = basename(exe)
  if (await isRunning(exeName)) {
    console.log(`[dsh-notch-win] capsule already running (${exeName})`)
    return
  }

  // detached + stdio ignored: the capsule must outlive nothing and keep nothing
  // alive — DSH can exit (or be killed) without taking it down or waiting for it.
  const child = spawn(exe, [], { detached: true, stdio: 'ignore', windowsHide: true })
  child.on('error', (error) => {
    console.warn(`[dsh-notch-win] could not start the capsule: ${String(error)}`)
  })
  child.unref()
  console.log(`[dsh-notch-win] capsule started (pid ${String(child.pid ?? '?')}) from ${exe}`)
}

export function apply(): void {
  if (process.platform !== 'win32') return

  if (isDisabled()) {
    console.log('[dsh-notch-win] launcher disabled (DSH_NOTCH_WIN_LAUNCH=0)')
    return
  }

  void launch().catch((error: unknown) => {
    console.warn(`[dsh-notch-win] launcher failed: ${String(error)}`)
  })
}
