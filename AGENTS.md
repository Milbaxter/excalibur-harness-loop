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

Then implement the spec milestone by milestone (M0 → M7, spec §12) and execute the PILOT run
(spec §6.6). The full kickoff prompt with hard constraints is in `docs/KICKOFF_PROMPT.md`; treat
its "HARD CONSTRAINTS", "WORKING RULES", "CANDIDATES", "PILOT" and "FINAL REPORT" sections as
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
- A Supervisor Automation may commit under `results/meta/**`, `results/SUPERVISOR_LOG.md`,
  `results/ANSWERS.md`, and may fix controller bugs under `excalibur/` with tests. Pull before
  every commit and read `results/ANSWERS.md` when it changes.
- Finish by writing `results/FINAL_REPORT.md` per spec §7.5, committing, and summarising it.
- If a secret is missing or invalid, stop and name it. Otherwise do not ask; use the fallbacks.

Secrets available as env vars: `DEEPSEEK_API_KEY`, `DAYTONA_API_KEY`, `EXCALIBUR_BUDGET_USD`.

## Role B: Supervisor (a scheduled Cursor Automation)

If you were started by an Automation on a schedule, your instructions are the block in
`docs/SUPERVISOR_AUTOMATION.md` ("Instructions to paste"). Follow them exactly; they bound what you
may edit.
