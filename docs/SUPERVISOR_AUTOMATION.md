# Supervision: how the loop gets reviewed, repaired, and restarted without a human

Excalibur needs an agent that periodically wakes, reads the ledger, writes meta-reviews, repairs a
crashed controller, restarts a stalled loop, answers the builder's questions, and makes sure the
final report exists. There are three ways to get one. **The builder picks automatically** (see
`AGENTS.md`): Tier B if `CURSOR_API_KEY` is set, otherwise Tier A. Tier C is manual.

| tier | what | human setup | independence |
|---|---|---|---|
| **A — self-scheduled (default)** | The builder agent subscribes an hourly timer (`cursor-subscriptions` `subscribe_timer`, cron `0 * * * *`, name `excalibur-supervisor`) whose prompt is the checklist below. Each wake it runs the checklist in its own session. | none | reviewer = builder model; still catches crashes, stalls, missing report |
| **B — API-spawned supervisor** | The builder creates a *separate* cloud agent via the Cloud Agents API with a frontier model and the checklist as its prompt; that agent subscribes its own hourly timer. | one secret: `CURSOR_API_KEY` (Dashboard → API Keys), optional `EXCALIBUR_SUPERVISOR_MODEL` | independent frontier reviewer |
| **C — Cursor Automation** | A scheduled Automation at cursor.com/automations with the checklist as instructions. | create the Automation by hand (steps at the end) | independent frontier reviewer |

All three run the **same checklist** and obey the **same write boundaries**, so the controller does
not care which one is active.

## Tier A — self-scheduled timer (what happens with no extra setup)

At the start of the session (before M0) the builder calls
`cursor-subscriptions-list_subscriptions`; if no timer named `excalibur-supervisor` exists, it
calls `cursor-subscriptions-subscribe_timer` with `name: "excalibur-supervisor"`, `cron: "0 * * * *"`,
and `prompt` = the checklist block below prefixed with `SUPERVISOR WAKE.`. Timers dedupe by name.
The subscription has a server-assigned expiry; on every wake the builder checks `expiresAt` and
re-subscribes if fewer than 3 hours remain.

Operating pattern once M6 is done: the builder does **not** leave the loop running in a detached
tmux session across idle turns (an idle cloud VM may be hibernated, freezing the process). Instead,
each wake runs `uv run excalibur resume --max-minutes 40` in the foreground, waits for it, commits,
and ends the turn. Pilot batches are sized (2 candidates, `-n 24`) to fit inside that window. This
is the Automation-chain pattern executed by one agent.

If the builder ends its turn with a question for the human, the hourly wake still fires; the
checklist's step 5 makes it re-read the repo and answer its own question when the answer is in the
spec or builder notes.

## Tier B — API-spawned supervisor (when `CURSOR_API_KEY` is present)

Before M0 the builder spawns the supervisor once:

```bash
curl -sS -X POST https://api.cursor.com/v1/agents \
  -H "Authorization: Bearer $CURSOR_API_KEY" -H "Content-Type: application/json" \
  -d @- <<JSON
{
  "prompt": { "text": "<the checklist block below, verbatim, prefixed with: You are the Excalibur supervisor for repo https://github.com/Milbaxter/excalibur-harness-loop. First, subscribe an hourly timer named excalibur-supervisor (cron 0 * * * *) whose prompt is this same checklist, then run the checklist once now.>" },
  "source": { "repository": "https://github.com/Milbaxter/excalibur-harness-loop", "ref": "main" },
  "model": "${EXCALIBUR_SUPERVISOR_MODEL:-<strongest model listed by the API>}",
  "name": "excalibur-supervisor"
}
JSON
```

The builder records the returned agent id in `results/SUPERVISOR_LOG.md` (first entry) and still
subscribes its own Tier A timer as a backstop (the two coordinate through the lock and disjoint
write sets, so both being alive is safe). Exact field names follow the Cloud Agents API v1
reference (`https://cursor.com/docs/cloud-agent/api/endpoints`); adapt if the schema differs.

## The checklist (identical for all tiers)

```
SUPERVISOR WAKE. You are supervising Excalibur, an autonomous plugin-evaluation loop. Read
docs/EXCALIBUR_SPEC.md §9 and §7.5, docs/BUILDER_NOTES.md, and results/SUPERVISOR_LOG.md before
acting. Be brief and decisive. Never ask the human a question you can answer from the repo.

GIT DISCIPLINE (non-negotiable)
- `git pull --rebase origin main` first. Work on main.
- Always allowed to create/edit: results/meta/**, results/SUPERVISOR_LOG.md, results/ANSWERS.md.
- Bounded repairs (step 4 only): files under excalibur/, tests/, scripts/, .cursor/install.sh.
- Never edit: config.yaml acceptance thresholds or splits, candidates/, benchmarks/,
  results/ledger.jsonl, results/LEADERBOARD.md, results/candidates/, plugins/ or harness/vendor/
  (plugin code under test), harness/excalibur-base/ (the baseline), docs/EXCALIBUR_SPEC.md.
- Before committing: `git pull --rebase origin main` again. On conflict: abort the rebase, discard
  your changes, log "conflict, skipped", exit. Commit messages start with "supervisor:".
- Append one dated entry to results/SUPERVISOR_LOG.md every wake, even if you did nothing.
- If the timer subscription named excalibur-supervisor expires within 3 hours, re-subscribe it.

CHECKLIST, IN ORDER
0. NOT STARTED: if results/ does not exist and there is no results/milestones/, the build has not
   begun. If you ARE the builder, continue building instead. Otherwise log "waiting" and exit.

1. STATE: read the latest results/milestones/M*.md, tail -50 results/ledger.jsonl (if present),
   git log -15, results/LOCK (if present), results/incidents/*, results/ANSWERS.md. Determine:
   build phase (which milestone) or pilot phase (candidates decided, accepted, spend vs cap), or
   complete (results/FINAL_REPORT.md exists).

2. COMPLETE: if results/FINAL_REPORT.md exists, sanity-check it against spec §7.5 (all sections,
   numbers consistent with the ledger). Append a verdict to results/SUPERVISOR_LOG.md, unsubscribe
   the excalibur-supervisor timer, end your message with "CAMPAIGN COMPLETE", and stop.

3. PENDING META-REVIEW: for any results/meta/<n>/bundle.md without a sibling proposals.json, do
   the review now per spec §9.1–9.3: audit each accepted plugin's source for benchmark-specific
   behaviour (verdict general|suspicious|hack + reason); find systemic problems; propose up to 8
   new general-intelligence plugins (benchmark-agnostic hypothesis + DSH extension points);
   config changes only with quantitative justification; questions for the human. Write
   results/meta/<n>/proposals.json valid against schemas/proposals.schema.json (set
   "reviewer": "supervisor:<your model>"). Validate with python/jq before committing.

4. CRASH OR STALL → REPAIR: signals: a new file in results/incidents/, a traceback in the last
   milestone file, or results/LOCK older than 45 minutes while the pilot is not complete.
   a) Diagnose from the incident and the code. Reproduce with `uv run pytest -q` and, if relevant,
      `uv run excalibur doctor` (no live spend).
   b) If the cause is a CONTROLLER bug (excalibur/, scripts/, install), fix it minimally, add or
      adjust a unit test that would have caught it, run `uv run pytest -q` until green, commit as
      "supervisor: fix <what> (incident <file>)". Do not change acceptance thresholds, splits,
      budget caps, plugin code, or the baseline to make a failure go away — those are not bugs.
   c) If the cause is external (Daytona quota, DeepSeek outage, missing secret), do not "fix" it:
      write it to results/ANSWERS.md under "NEEDS HUMAN" and stop after logging.
   d) After a successful fix, or if the lock is stale and M6 evidence exists: run
      `uv sync && uv run excalibur resume --max-minutes 40` in the foreground and wait for it. It
      commits its own ledger updates. If the build is not complete: if you are the builder,
      continue the build; otherwise go to 5.

5. BLOCKED ON A QUESTION: if the last milestone file or git log shows the builder ended with a
   question, answer it from the spec, builder notes, and repo state in results/ANSWERS.md (dated,
   quoting the question) and act on it if you are the builder. If you are a separate supervisor and
   CURSOR_API_KEY plus EXCALIBUR_BUILDER_AGENT_ID are set, also send the answer as a follow-up run:
   POST https://api.cursor.com/v1/agents/$EXCALIBUR_BUILDER_AGENT_ID/runs with Bearer auth and
   JSON {"prompt": {"text": "<answer>. Continue from where you stopped."}}; a 409 means the builder
   is running — skip. If you cannot answer, write it under "NEEDS HUMAN".

6. FINAL REPORT SAFETY NET: if the pilot finished (20 candidates decided, budget cap fired, or
   queue empty) but results/FINAL_REPORT.md does not exist, run `uv run excalibur report --final`;
   if that fails, write results/FINAL_REPORT.md yourself per spec §7.5 using only numbers from the
   ledger and LEADERBOARD.md. Commit.

7. BUDGET AND SAFETY: if spend exceeds the cap, a "hack" verdict was not acted on, or a "high"
   severity finding is unaddressed for two wakes, say so prominently in the log and your message.

8. REPORT: end with a 5-line status: phase, candidates decided/accepted, spend vs cap, what you did
   this wake, what needs the human (if anything).

Never run evaluation trials outside `excalibur resume`, never call the DeepSeek API yourself, never
change acceptance thresholds. You review, repair, and unblock; the controller decides.
```

## How the controller cooperates (required by the builder notes)

- At meta-review time the controller writes `results/meta/<n>/bundle.md`, commits, and continues.
  It ingests `proposals.json` when it appears (checked before each batch after `git pull --rebase`).
  If none appears within 3 hours it falls back to DeepSeek V4 Pro and records
  `reviewer: fallback-deepseek-pro`.
- The controller refreshes `results/LOCK` every 10 minutes while running and deletes it on clean exit.
- On any uncaught exception the controller writes `results/incidents/<ts>.md` with the traceback,
  the command, the ledger tail, and commits it before exiting non-zero.
- `excalibur resume --max-minutes N` is time-boxed, lock-aware, idempotent, and works from a clean
  checkout with only the secrets — it is the unit of work every wake runs.

## Tier C — manual Cursor Automation (optional)

1. cursor.com/automations → New automation. Trigger: Schedule, cron `0 * * * *`.
2. Repository `Milbaxter/excalibur-harness-loop`, branch `main`. Model: the strongest available.
3. Instructions: paste the checklist block above verbatim.
4. Secrets already apply. Optionally add `CURSOR_API_KEY` and `EXCALIBUR_BUILDER_AGENT_ID`.
5. Disable it when a wake reports "CAMPAIGN COMPLETE".

## Cost

One wake per hour; most wakes are a few file reads. Wakes that run `resume --max-minutes 40` are
long-running turns. Overnight this is roughly one normal agent session of Cursor usage, billed to
your Cursor plan, not the $20 DeepSeek budget.
