# Cloud / private-worker model policy

This repository is verified on Cola's Windows private worker (Home-Windows). Agents that run here must stay on the parent Grok session.

## Hard rules

- Never launch subagents (`Task`, `explore`, `browser`, `computerUse`) with other models.
- Only use **Grok 4.6**. Never Claude, Sonnet, Opus, GPT, or Gemini.
- Stay on the parent Grok model for the whole run.
- Prefer **Grok** or **Composer** only.
- Do not spawn `Task`, computerUse, or browser unless the user explicitly requires that tool.
- Child agents must omit `model` so they inherit the parent.

## Enforcement

- `.cursor/hooks.json` runs `.cursor/hooks/block-other-models.sh` on `subagentStart` with `failClosed: true`.
- The hook denies Claude/Sonnet/Opus (and GPT/Gemini) model names and `computerUse` / `browser` subagent types.
- `.cursor/agents/worker.md` sets `model: inherit` and `force-default-model: true`.

## If a tool offers another model

Refuse it. Continue on the parent Grok 4.6 agent instead of starting a sibling with a different model.
