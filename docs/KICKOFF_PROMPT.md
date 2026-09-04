# Kickoff: build and run the Excalibur pilot

## Human pre-flight (do this first)

1. DeepSeek: top up ~$20 at platform.deepseek.com and create an API key.
2. Daytona: sign up at daytona.io (free $200 credit, no card) and create an API key.
3. Cursor Dashboard → Cloud Agents → Secrets, add:
   - `DEEPSEEK_API_KEY`
   - `DAYTONA_API_KEY`
   - `EXCALIBUR_BUDGET_USD` = `18`
4. Supervision needs **no setup**: the builder subscribes its own hourly timer (Tier A in
   `docs/SUPERVISOR_AUTOMATION.md`). Optional upgrades: add a `CURSOR_API_KEY` secret so the
   builder spawns an independent frontier-model supervisor (Tier B), or create a manual
   Automation (Tier C).
5. Start a Cloud Agent on this repo (branch `main`) with the building model and paste the prompt below.
   If long-running agents are not available on your plan, run the same prompt from a local Cursor
   agent on your machine instead; the pilot takes roughly 2–4 hours. Optionally copy the builder
   agent's `bc-...` id into the `EXCALIBUR_BUILDER_AGENT_ID` secret so the supervisor can send it
   follow-ups.

## Prompt to paste

Shortest version (the repo's `AGENTS.md` carries the binding constraints, so this is enough):

```
Read AGENTS.md in this repo and act as the Builder/operator. Set up supervision (Step 0), then build
Excalibur milestone by milestone and run the pilot to completion, ending with results/FINAL_REPORT.md.
Do not stop to ask unless a secret is missing.
```

Full version (identical intent, useful if you want every constraint in the conversation):

```
You are building and then running Excalibur, an autonomous plugin-evaluation loop for DeepSeek Harness.
The complete technical specification is in docs/EXCALIBUR_SPEC.md. Read it fully before doing anything,
then read docs/BUILDER_NOTES.md: it lists the known weak spots and the decided fallback for each, so you
do not need to ask about them.
Your job is to implement it milestone by milestone (M0 → M7, §12) and then execute the PILOT run (§6.6).

HARD CONSTRAINTS
- Budget: total DeepSeek spend for this whole session must stay under $18. Implement budget.py early
  (M0) and make every live-model call go through it. No live model calls before `excalibur doctor` is
  green. First live spend (M1) is a single task, ≤ $1. Before starting M7, project the pilot cost from
  measured $/trial and abort if projected > $16.
- Use profile: pilot for everything (config.yaml). Do NOT run the full 89-task calibration (§5.4); use
  the seeded hard split procedure in §6.6.
- Pin exact versions: @deepseek-ai/dsh (write to harness/dsh.version), harbor, the terminal-bench
  dataset version, Node 22, Python 3.12. Never upgrade mid-session.
- Never hand-edit results/ledger.jsonl, results/LEADERBOARD.md, benchmarks/*.txt, or plugin verdicts;
  those are written only by controller code. results/milestones/ and results/incidents/ are yours.
- Sandboxes run in Daytona via Harbor (--env daytona). Do not try to run task containers on this VM.
- Secrets are available as env vars: DEEPSEEK_API_KEY, DAYTONA_API_KEY, EXCALIBUR_BUDGET_USD. If any is
  missing, stop and say exactly which one; do not work around it.

WORKING RULES
- Commit and push after every milestone (and after every decided batch during M7) with clear messages.
- Each milestone has a "Done when" check in §12. Run it, paste the evidence into
  results/milestones/M<n>.md, commit, then continue. Do not skip ahead if a check fails; fix it.
- Write unit tests for metrics.py, acceptance.py (including the A/A false-accept case with synthetic
  data) and ledger.py replay. Mock Harbor in loop.py tests. Only M1, M2-verify, and M7 spend money.
- Prefer the simplest implementation that satisfies the spec. No web UI, no database, no extra services.
- If the DSH version you pin differs from the spec's assumptions (CLI flags, patch format, session log
  fields), adapt the adapter and document the deltas in docs/DSH_NOTES.md; do not change the protocol.
- On any uncaught exception the controller must write results/incidents/<ts>.md (traceback, command,
  ledger tail) and commit it before exiting; the supervisor wake uses it to repair and restart.
- Set up supervision first (AGENTS.md Step 0: hourly timer named excalibur-supervisor). A supervisor
  may commit under results/meta/**, results/SUPERVISOR_LOG.md, results/ANSWERS.md and may fix
  controller bugs under excalibur/ with tests. `git pull --rebase`
  before every commit and read results/ANSWERS.md when it changes.
- If you are blocked on something only a human can decide, finish everything that doesn't depend on
  it, commit, and end your turn with the question stated in one paragraph.

CANDIDATES
- The candidate pool is candidates/seed_queue.yaml (read candidates/README.md first). It was imported
  from https://github.com/Milbaxter/dsh-intelligence-lab at the pinned commit; clone that repo
  read-only for the remix sources and plugin-ideas/README.md.
- In M3 implement `excalibur queue import`: vendor each queued community plugin at a pinned commit
  into harness/vendor/<id> (resolve RESOLVE_AT_IMPORT and write the commit back), copy remixes into
  plugins/<id>/, generate plugin.yaml from the catalog fields, run the static check. Third-party
  plugins that fail the static check or do not load under the pinned DSH become status: excluded
  with the reason — do not patch third-party code. Adapt remixes only where the DSH API shape
  differs, and record adaptations in docs/DSH_NOTES.md.
- Ideas (source.kind: idea) are implemented by the coder step only when they reach the front of
  the queue. The three Tier A ideas in the pilot need real implementations; keep each under 300 LOC.

PILOT (M7) SPECIFICS
- Queue: exactly the 20 entries with pilot: true, in their `order`. Do not add others.
- Trigger one meta-review after 8 decided candidates: write results/meta/1/bundle.md, commit, push,
  and keep going; the supervisor wake writes proposals.json (builder notes §4 has the fallback).
  Ingest proposals per §9.4 but do NOT auto-implement new candidates in the pilot (queue them only).
- Stop when the queue is empty, the budget cap fires, or 20 candidates are decided.

FINAL REPORT
Write results/FINAL_REPORT.md with all nine sections of spec §7.5 (`uv run excalibur report --final`),
commit and push it, then end with a summary containing:
1. Measured $/trial, tokens/trial (billed), wall/trial, and pass rate of the baseline on the dev split.
2. results/LEADERBOARD.md summary: accepted / rejected / accepted_dev_only with Δpass and Δtokens.
3. Whether the positive controls behaved as expected, and if not, your diagnosis.
4. Re-projected cost for a 100-candidate campaign under the lean profile using measured numbers.
5. Anything in the spec that turned out wrong or underspecified, with your recommended change.
Start with M0 now.
```

## While it runs

- Watch `results/ledger.jsonl` and `results/milestones/` in the repo; every decision is committed.
- Check DeepSeek spend in the DeepSeek dashboard once or twice; the in-repo `budget.py` estimate is
  derived from token counts and can drift a few percent from the invoice.
- If the agent stops with a question, its hourly wake will try to answer it from the repo (see
  results/ANSWERS.md); only "NEEDS HUMAN" entries need you. It resumes from the ledger.

## After the pilot

Read the final report's measured $/trial and the positive-control results. If the built-in rows show up
as improvements and $/trial is ≤ $0.04, fund the lean campaign (§6.5) from the measured projection; if
not, fix what the report flags before spending more.
