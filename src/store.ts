import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths'
import { join } from 'node:path'
import { randomBytes } from 'node:crypto'

export const DIR = join(resolveDshHome(), 'dsh-notch')
export const RUNTIME = join(DIR, 'runtime.json')
const SEEN = join(DIR, 'seen.json')

export interface RuntimeFile {
  origin: string
  token: string
  pid: number
  writtenAt: number
}

function ensureDir(): void {
  mkdirSync(DIR, { recursive: true, mode: 0o700 })
}

function readJson<T>(path: string): T | undefined {
  try {
    return JSON.parse(readFileSync(path, 'utf8')) as T
  } catch {
    return undefined
  }
}

export function loadOrCreateToken(): string {
  const existing = readJson<RuntimeFile>(RUNTIME)
  if (existing?.token && existing.token.length >= 16) return existing.token
  return randomBytes(24).toString('hex')
}

export function writeRuntime(file: RuntimeFile): void {
  ensureDir()
  writeFileSync(RUNTIME, `${JSON.stringify(file, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 })
}

export function loadSeen(): Record<string, number> {
  const value = readJson<Record<string, number>>(SEEN)
  if (!value || typeof value !== 'object') return {}
  return value
}

export function saveSeen(map: Record<string, number>): void {
  ensureDir()
  writeFileSync(SEEN, `${JSON.stringify(map)}\n`, { encoding: 'utf8', mode: 0o600 })
}
