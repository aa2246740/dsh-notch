import type { Context } from '@deepseek-ai/cordis'

export const name = 'dsh-notch-focus'
export const inject = []

export function apply(ctx: Context) {
  // Headless follower: the browser half does the work; the Host half only
  // marks load. Keeping ctx referenced so the signature stays honest.
  void ctx
  console.log('[my-plugins/dsh-notch-focus] loaded')
}
