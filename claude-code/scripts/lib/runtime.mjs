import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, join } from 'node:path'

/**
 * Fixed, user-visible location so a manually started helper can be pointed at
 * it: DSH_NOTCH_RUNTIME_FILE="$HOME/.claude/bot-notch/runtime.json".
 */
export function notchHome(env = process.env) {
  if (env.BOT_NOTCH_HOME) return env.BOT_NOTCH_HOME
  return join(env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'bot-notch')
}

export function paths(env = process.env) {
  const dir = notchHome(env)
  return {
    dir,
    runtime: join(dir, 'runtime.json'),
    seen: join(dir, 'seen.json'),
    lock: join(dir, 'bridge.lock'),
    log: join(dir, 'bridge.log'),
    helperPid: join(dir, 'helper.pid'),
    helperLog: join(dir, 'helper.log'),
  }
}

export function ensureDir(dir) {
  mkdirSync(dir, { recursive: true, mode: 0o700 })
}

export function readJson(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')) } catch { return undefined }
}

/** Atomic private write: the runtime file carries the bridge token. */
export function writePrivateJson(path, value) {
  const stage = `${path}.${process.pid}.tmp`
  writeFileSync(stage, `${JSON.stringify(value, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 })
  renameSync(stage, path)
}

export function alive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 1) return false
  try { process.kill(pid, 0); return true } catch (error) { return error.code === 'EPERM' }
}

const SHELLS = new Set(['sh', 'bash', 'zsh', 'dash', 'fish', 'ksh'])

function parentOf(pid) {
  try {
    const text = execFileSync('ps', ['-o', 'ppid=', '-o', 'comm=', '-p', String(pid)],
      { encoding: 'utf8', env: { ...process.env, LC_ALL: 'C' }, timeout: 1000 }).trim()
    const match = /^(\d+)\s+(.+)$/.exec(text)
    return match ? { ppid: Number(match[1]), comm: basename(match[2].trim()).replace(/^-/, '') } : undefined
  } catch {
    return undefined
  }
}

/**
 * The Claude Code process that owns this hook. Exec-form hooks are its direct
 * children; a shell-form wrapper exits with the hook, so step past shells.
 */
export function claudePid(start = process.ppid) {
  let pid = start
  for (let depth = 0; depth < 3 && pid > 1; depth++) {
    const self = parentOf(pid)
    if (!self || !SHELLS.has(self.comm)) return pid
    pid = self.ppid
  }
  return pid
}

const TERM_PROGRAMS = {
  Apple_Terminal: 'com.apple.Terminal',
  'iTerm.app': 'com.googlecode.iterm2',
  vscode: 'com.microsoft.VSCode',
  WezTerm: 'com.github.wez.wezterm',
  ghostty: 'com.mitchellh.ghostty',
  WarpTerminal: 'dev.warp.Warp-Stable',
  Hyper: 'co.zeit.hyper',
  kitty: 'net.kovidgoyal.kitty',
  Alacritty: 'org.alacritty',
}

/** macOS app hosting this session (Terminal, iTerm2, VS Code, Claude Desktop…), for "open conversation". */
export function hostBundleId(env = process.env) {
  const direct = env.__CFBundleIdentifier
  if (direct && BUNDLE_ID.test(direct)) return direct
  return TERM_PROGRAMS[env.TERM_PROGRAM] ?? ''
}

export const BUNDLE_ID = /^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$/
