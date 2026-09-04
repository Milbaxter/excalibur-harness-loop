# Excalibur — instructions for any agent opened on this repo

If you were pointed at this repository with little or no other instruction, this file tells you
what to do. Two roles exist; pick the one that matches how you were started.

## Role A: Builder/operator (default — a Cloud Agent or local agent started by a human)

You are building and then running Excalibur, an autonomous plugin-evaluation loop for DeepSeek
Harness. Read, in this order, before doing anything else:

1. `docs/EXCALIBUR_SPEC.md` — the complete specification (read all of it).
2. `docs/BUILDER_NOTES.md` — known weak spots and the decided fallback for each, so you do not
   need to ask.
3. `candidates/README.md` — the candidate pool and the 20-entry pilot.

**Step 0 — set up supervision before M0** (see `docs/SUPERVISOR_AUTOMATION.md`):
- Call `cursor-subscriptions-list_subscriptions`. If no timer named `excalibur-supervisor` exists,
  call `cursor-subscriptions-subscribe_timer` with `name: "excalibur-supervisor"`,
  `cron: "0 * * * *"`, and `prompt` = the checklist block from that document prefixed with
  `SUPERVISOR WAKE.`. This makes you wake hourly to review, repair, restart, and finish the report.
- If `CURSOR_API_KEY` is set, additionally spawn a separate supervisor agent via the Cloud Agents
  API as described there (Tier B) and record its id in `results/SUPERVISOR_LOG.md`.
- On every wake, re-subscribe the timer if it expires within 3 hours. Unsubscribe when
  `results/FINAL_REPORT.md` exists.

Then implement the spec milestone by milestone (M0 → M7, spec §12) and execute the PILOT run
(spec §6.6). Once M6 is done, do not leave the loop running detached across idle turns (an idle VM
may hibernate); run `uv run excalibur resume --max-minutes 40` in the foreground on each wake, commit,
end the turn, and let the timer wake you again.

The full kickoff prompt with hard constraints is in `docs/KICKOFF_PROMPT.md`; treat its
"HARD CONSTRAINTS", "WORKING RULES", "CANDIDATES", "PILOT" and "FINAL REPORT" sections as
binding even if the human only sent you a link.

Non-negotiables (repeated here so they survive a short prompt):
- DeepSeek spend for the whole session < $18. `budget.py` gates every live call. No live model
  calls before `excalibur doctor` is green. First live spend is one task.
- `profile: pilot`. No full 89-task calibration.
- Pin exact versions; never upgrade mid-session.
- Sandboxes run in Daytona via Harbor. No task containers on this VM.
- Commit and push after every milestone and every decided batch. `git pull --rebase` first.
- The ledger (`results/ledger.jsonl`), plugin verdicts, benchmark splits and `LEADERBOARD.md` are
  written only by the controller code. You may hand-write `results/milestones/M<n>.md` and
  `results/incidents/*.md`.
- A supervisor (your own timer wake, an API-spawned agent, or an Automation) may commit under
  `results/meta/**`, `results/SUPERVISOR_LOG.md`, `results/ANSWERS.md`, and may fix controller
  bugs under `excalibur/` with tests. Pull before every commit and read `results/ANSWERS.md` when
  it changes.
- Finish by writing `results/FINAL_REPORT.md` per spec §7.5, committing, and summarising it.
- If a secret is missing or invalid, stop and name it. Otherwise do not ask; use the fallbacks.

Secrets available as env vars: `DEEPSEEK_API_KEY`, `DAYTONA_API_KEY`, `EXCALIBUR_BUDGET_USD`.

## Role B: Supervisor (an API-spawned agent or a scheduled Automation)

If you were started as a supervisor, or a message begins with `SUPERVISOR WAKE.`, run the
checklist block in `docs/SUPERVISOR_AUTOMATION.md` exactly; it bounds what you may edit. If you are
also the builder (Tier A), the checklist tells you when to continue building instead.
