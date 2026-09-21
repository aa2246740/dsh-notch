# Harness subagent compatibility audit

Audited on 2026-09-21 against the installed Harness source at `fb2c4b9e698e30edb738bca4cf0618587db7d203` (`dsh-v0.1.5-rc.2`, local changes present). This is an audit of the named checkout and public service interfaces, not a guarantee about arbitrary third-party providers.

| Entry path | Harness source | Notch behavior |
| --- | --- | --- |
| Foreground spawn and agent fork | `packages/subagent/tool-subagent/src/index.ts`; `subagent-in-process-driver/src/index.ts`; `subagent/src/child-agent.ts` | Both use `childSessionMeta`, setting `origin: subagent` and `parentSession`. Fold into the owning conversation. An inherited prefix does not turn a delegated fork into an independent user task. |
| Workflow parallel, nested, and integration phases | `packages/workflow/workflow-worker-thread/src/host.ts` | Workers call `subagents.start` with the initiating parent. Count the owner once, including nested descendants. Worker outcomes do not become independent result indicators. |
| Ralph fresh-agent iterations | `packages/workflow/tool-ralph/src/index.ts` | Uses the workflow engine with its calling parent. Replacing each round's worker must not pulse the task count or result lamps. |
| Continuable children, messages, and cold resume | `packages/subagent/subagent/src/continuation.ts`; `continuation-activation.ts`; `control.ts` | Initial creation uses the same metadata; resume preserves the durable child header. Idle resident children add no blue count; active ones keep the owner active. |
| Experimental Agent Team | `packages/experimental/agent-team/src/roster.ts`; `mailbox.ts` | Teammates use `startContinuable` with the lead as parent. The same grouping applies. |
| Background one-shot subagents | `packages/subagent/tool-subagent/src/index.ts`; `packages/jobs/jobs-local/src/index.ts` | Official jobs have `kind: subagent` and `ownerSession`. Read active jobs for each live agent, then fold the owner into the conversation. `stopping` remains active until terminal settlement. |
| External Codex, Claude Code, ACP, DSH SDK | `packages/subagent/subagent-*/src/run.ts`; `subagent/src/out-of-process.ts` | `subprocessRunHandle` explicitly exposes no local Agent. Foreground work is represented by its busy parent; official background jobs supply the otherwise missing running signal. Remote process ids are not local sessions. |
| User-created conversation forks | `packages/api/session-controller/src/commands.ts`; `list.ts` | Have `parentSession`/`parentId` but no subagent origin. Keep separate both in Host grouping and the browser mirror, including cold completed sessions. |
| Goal continuation and scheduled reminders | `packages/goal/goal-round-driver/src/index.ts`; `packages/schedule/schedule/src/runtime.ts` | Use the original agent's `followup`; do not create another countable session. Later tool calls may of course delegate through the paths above. |
| Automatic title and compaction summary | `packages/session/session-title-llm/src/index.ts`; `packages/compaction/compaction-basic/src/summarizer.ts` | Call `llm.stream` directly; do not manufacture a subagent task for these calls. |
| New Webhook, SDK, or ACP user sessions | Corresponding `session.ts` / `server.ts` creation paths | Independent roots unless an actual delegation relationship is stamped. Do not group by title, model, provider, workspace, or process name. |

## Confirmed defects and fixes

1. Running local children were emitted as independent rows; stale browser rows could reintroduce filtered children. The Host now resolves conversation ownership before emitting rows.
2. External background children have no local Agent. The Host now observes `jobs.list(agent)` and considers only owned subagent records in `running` or `stopping`. It does not call `read`, `wait`, `kill`, or mark notices reported. Unowned jobs and shell servers do not hold all conversations active.
3. The browser mirror filtered every `parentId`, hiding ordinary forks and allowing an orphan marked `origin: subagent` through. The companion now follows the same origin discriminator as the official workspace sidebar. Its source is included under `companions/dsh-notch-focus`.

Questions retain their original request ids and resolvers after projection onto the owner. Cancelling a child removes its yellow action. Missing or cyclic lineage does not invent a running task; an actionable question remains visible rather than being discarded.

## Verification and limits

`npm test` covers 59 cases, including sequential workers, resumed children with reversed load order, cancellation, nested questions, remote background jobs, stopping/terminal states, job ownership, the real browser companion's mirror submission, heartbeat interruptions, conflicting browser clients, and delayed reading acknowledgements. Reading an idle parent while its child or remote job still runs cannot prematurely acknowledge the eventual result. The original local-worker fix failed 7 of its 10 new regression cases. Before the follow-up fixes, background cases failed 5 of 6 and the browser fork/origin regression failed.

The opt-in probe uses the selected Harness's actual built Cordis, SessionStore, AgentRegistry, LocalJobRegistry, `childSessionMeta`, and `subprocessRunHandle`. It verifies metadata, idle-parent job activity, discovery after a late load, non-consuming observation, cancellation settlement, and ordinary versus delegated forks:

```sh
DSHX_HARNESS=/absolute/path/to/deepseek-harness node --import tsx tools/check-harness-subagents.mjs
```

The probe creates only an isolated in-memory registry and temporary Notch storage. It starts no model, provider process, second Host, or real user session. The real installed SkillHub workflow was separately observed without sending messages. External providers' actual CLI execution and their own approval UIs were not launched or certified. A third-party plugin that bypasses both official session metadata and the owned-job interface cannot be reliably attributed from its title alone.

## Browser heartbeat stability

A browser heartbeat previously acted as both a five-second running lease and an unread-state lease. Expiration switched loaded sessions back to a different unread calculation and removed cold completed sessions; the next heartbeat reversed that decision. A background or throttled page could therefore animate a completed lamp repeatedly without any new result.

Unread decisions now survive heartbeat interruptions. Only running claims from an unloaded session expire. A retained completion remains openable. The regression checks repeat expiry/recovery, cold and loaded completions, stale running claims, and a newer completion arriving while an old browser snapshot is still fresh.

That expiry fix alone did not reconcile two pages: Harness's `completedNotifications` is local to each browser. Another page's missing reminder must not cancel a completion. Projection version 3 reports explicit reading acknowledgements only for the focused page's selected, inactive conversation. It captures the time of that observation before sending; the list's `updatedAt` is the user prompt time and is not a completion timestamp. The Host retains positive completion facts and a monotonic read-through timestamp. A delayed acknowledgement cannot clear a later turn, and an old positive browser flag cannot resurrect a read result. Host `turn/end` records short and failed root turns even when no polling request saw them running. A cold Host load no longer replays historical results based solely on an old read timestamp.

## Native presentation interruption

A reversed robot entry could finish with a tiny positive visibility residue while still marked as entering. Its canvas then painted a solid origin-color disk over the status number. `IdlePresence` now commits exact endpoints, clears the departure direction, and invalidates queued timer ticks. Polling is serialized and rejects older snapshots so delayed HTTP responses cannot reverse a newer result.

`npm run test:presentation` verifies reversed entries, exact endpoints, late snapshots, and a 40-state interruption replay without a model or live session. It also renders before/after native PNGs (set `NOTCH_PRESENTATION_OUTPUT` to an output directory). `npm run test:outcome` separately exercises the existing outcome motion and layout. Authenticated `GET /dsh-notch/diagnostics` exposes a bounded, content-free trace of state sources and reading acknowledgements for future incident diagnosis; it contains no titles, message content, or credentials.
