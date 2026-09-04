# Supervisor Automation: a scheduled Cursor agent that reviews, unblocks, and restarts

Cursor Automations (cursor.com/automations) start a cloud agent on a schedule with a repo and
instructions. Excalibur uses one as the **meta-reviewer and operator**: it is a frontier model with
full repo access, so it can read the ledger, audit plugin source, write `proposals.json`, restart a
stalled loop, and answer the builder's questions — without any API key plumbing inside the VM.

Two agents therefore touch the repo:

| agent | model | runs | writes |
|---|---|---|---|
| **Builder/operator** | Grok 4.6 (or your choice) | one long session, from `docs/KICKOFF_PROMPT.md` | everything under `excalibur/`, `harness/`, `plugins/`, `results/ledger.jsonl`, `results/milestones/`, `results/candidates/` |
| **Supervisor** | strongest model available (Claude/GPT/Grok top tier) | scheduled, every 60 min | only `results/meta/**`, `results/SUPERVISOR_LOG.md`, `results/ANSWERS.md`, and `git commit` of those |

## Create the Automation

1. Go to cursor.com/automations → New automation (or use the `/automate` skill from a local agent).
2. Trigger: **Schedule**, cron `0 * * * *` (hourly). During the build phase you can use `*/30 * * * *`.
3. Repository: `Milbaxter/excalibur-harness-loop`, branch `main`.
4. Model: the strongest available frontier model. This is the meta-reviewer; do not pick a cheap model.
5. Secrets: the same Cloud Agent secrets already apply (`DEEPSEEK_API_KEY`, `DAYTONA_API_KEY`,
   `EXCALIBUR_BUDGET_USD`). Optionally add `CURSOR_API_KEY` and `EXCALIBUR_BUILDER_AGENT_ID`
   (the builder's `bc-...` id) so the supervisor can send follow-ups to the builder via the Cloud
   Agents API when it is waiting on a question.
6. Instructions: paste the block below verbatim.
7. Enable the Automation's memory tool if offered; it lets the supervisor remember what it already
   reviewed across wakes.

## Instructions to paste

```
You are the Excalibur supervisor. You wake up on a schedule to review and unblock an autonomous
plugin-evaluation loop. Read docs/EXCALIBUR_SPEC.md §9 (meta-review), docs/BUILDER_NOTES.md, and
results/SUPERVISOR_LOG.md (your own log from previous wakes) before acting. Be brief and decisive.

GIT DISCIPLINE (non-negotiable)
- Run `git pull --rebase origin main` first. Work on main.
- You may create or edit ONLY: results/meta/**, results/SUPERVISOR_LOG.md, results/ANSWERS.md.
  Never edit code, config.yaml, candidates/, benchmarks/, results/ledger.jsonl, or plugin verdicts.
- Before committing: `git pull --rebase origin main` again. If it conflicts, abort the rebase,
  discard your changes, log "conflict, skipped" and exit. Commit with message "supervisor: <what>".
- Append one dated entry to results/SUPERVISOR_LOG.md every wake, even if you did nothing.

CHECKLIST, IN ORDER
1. STATE: read the latest results/milestones/M*.md, the tail of results/ledger.jsonl, git log -10,
   results/LOCK (if present) and results/incidents/*. Determine: build phase (which milestone) or
   pilot phase (how many candidates decided, spend so far vs cap).

2. PENDING META-REVIEW: if any results/meta/<n>/bundle.md exists WITHOUT a sibling proposals.json,
   do the review now. Follow spec §9.1–9.3 exactly: audit each accepted plugin's source for
   benchmark-specific behaviour (verdict general|suspicious|hack with reason), find systemic
   problems, propose up to 8 new general-intelligence plugins with benchmark-agnostic hypotheses
   and DSH extension points, propose config changes only with quantitative justification, list
   questions for the human. Write results/meta/<n>/proposals.json matching
   schemas/proposals.schema.json (if the schema file does not exist yet, use the JSON shape in spec
   §9.3). Validate it is parseable JSON. Commit.

3. STALL: if results/LOCK is older than 45 minutes, or there has been no commit for 90 minutes
   during the pilot phase, the loop is stalled. Check for a running process is impossible from
   here, so rely on the lock timestamp. If stalled AND the build is complete (M6 evidence exists):
   run `uv sync && uv run excalibur resume --max-minutes 40` yourself, then commit whatever it
   produced (it commits its own ledger updates; you only add your log entry). If the build is not
   complete, do not build; go to step 4.

4. BUILDER BLOCKED: if the latest milestone file or git log shows the builder ended with a question,
   try to answer it from the spec, builder notes, and repo state. If you can, write the answer to
   results/ANSWERS.md (dated, quoting the question) and commit. If CURSOR_API_KEY and
   EXCALIBUR_BUILDER_AGENT_ID are set, also send the answer as a follow-up run to that agent via
   POST https://api.cursor.com/v1/agents/$EXCALIBUR_BUILDER_AGENT_ID/runs (Bearer auth, JSON body
   {"prompt": {"text": "<answer>. Continue from where you stopped."}}); a 409 means the builder is
   still running — that is fine, skip. If you cannot answer, write the question into
   results/ANSWERS.md under "NEEDS HUMAN" and say so in your final message.

5. BUDGET AND SAFETY: if results/ledger.jsonl shows spend above the cap, or any plugin verdict of
   "hack" was not acted on, or a "high" severity system finding is unaddressed for two wakes, say so
   prominently in your final message and in the log. Do not modify the ledger.

6. REPORT: end with a 5-line status: phase, candidates decided/accepted, spend vs cap, what you did
   this wake, what needs the human (if anything).

Never run evaluation trials directly, never call the DeepSeek API yourself, never change acceptance
thresholds. You review and unblock; the controller decides.
```

## How the controller cooperates (already required by the builder notes)

- At meta-review time the controller writes `results/meta/<n>/bundle.md`, commits, and **continues**
  with the next batch. It ingests `proposals.json` when it appears (checked before each batch after a
  `git pull --rebase`). If none appears within 3 hours it falls back to DeepSeek V4 Pro (§4 of
  builder notes) and records `reviewer: fallback-deepseek-pro`.
- The controller refreshes `results/LOCK` every 10 minutes while running and deletes it on clean exit.
- The controller does `git pull --rebase origin main` before every commit so supervisor commits merge
  cleanly.

## Cost

Each wake is a short cloud-agent run (read a few files, maybe write one). Ten wakes overnight is
roughly one normal agent session of Cursor usage. It bills to your Cursor plan, not the $20 DeepSeek
budget. Set the schedule to every 2–3 hours once the pilot is stable if you want it cheaper.
