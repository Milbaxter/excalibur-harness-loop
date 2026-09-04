# Excalibur

Self-improving intelligence harness loop: autonomously test DeepSeek Harness plugins against a
calibrated Terminal-Bench 2.1 subset with DeepSeek V4 Flash, keep the ones that improve pass rate
(or cut tokens per task) without benchmark hacking, and let a frontier model meta-review the whole
system every 5–10 candidates.

This repository currently contains the **technical specification** only. The implementation is
meant to be built from it by a coding agent inside Cursor.

- Spec: [`docs/EXCALIBUR_SPEC.md`](docs/EXCALIBUR_SPEC.md)
- Kickoff prompt for the building agent: [`docs/KICKOFF_PROMPT.md`](docs/KICKOFF_PROMPT.md)
- Builder notes (known weak spots + fallbacks): [`docs/BUILDER_NOTES.md`](docs/BUILDER_NOTES.md)
- Supervisor Automation (scheduled Cursor agent that reviews, unblocks, restarts): [`docs/SUPERVISOR_AUTOMATION.md`](docs/SUPERVISOR_AUTOMATION.md)
- Candidate pool (163 entries imported from dsh-intelligence-lab, 20 marked for the pilot): [`candidates/`](candidates/README.md)

## What the spec covers

1. Verified research on how DeepSeek Harness plugins and headless mode work, how Cursor Cloud
   Agents / Automations / headless CLI enable autonomous runs, and which benchmark gives a cheap
   model a 10–40% baseline with headroom.
2. Architecture: Python controller on the Cursor VM, Harbor + Daytona sandboxes for trials, DSH as
   the subject, git ledger as the only state, and a scheduled Cursor Automation as supervisor and
   meta-reviewer.
3. Benchmark protocol with calibration, dev/holdout/canary splits, and a noise model.
4. Three-stage evaluation funnel, greedy forward selection with parallel batches, statistical
   acceptance rules that weigh pass rate against tokens per task.
5. Plugin contract, anti-benchmark-hacking policy, and 20 starter plugin ideas.
6. Meta-review contract (inputs, prompt, JSON proposals, what gets auto-applied), run asynchronously
   by the supervisor with a DeepSeek V4 Pro fallback.
7. Cursor environment files, the builder + supervisor run model, budget kill-switch.
8. Milestone plan with acceptance checks, risks, and open decisions.

## Zero-touch run

1. Set the three secrets (`DEEPSEEK_API_KEY`, `DAYTONA_API_KEY`, `EXCALIBUR_BUDGET_USD=18`) in
   Cursor → Cloud Agents → Secrets.
2. Create the hourly Supervisor Automation from `docs/SUPERVISOR_AUTOMATION.md` (strongest model).
3. Start a Cloud Agent on this repo and send: *"Read AGENTS.md and act as the Builder/operator. Build
   Excalibur and run the pilot to completion, ending with results/FINAL_REPORT.md."*

What happens without you: the builder implements M0–M7 and runs the 20-candidate pilot; the
supervisor wakes hourly to write meta-reviews, repair controller crashes (bounded, with tests),
restart a stalled loop, answer the builder's questions, and make sure `results/FINAL_REPORT.md`
exists. The only things that reach you are a missing/invalid secret or an external outage, written
to `results/ANSWERS.md` under "NEEDS HUMAN". The deliverable is `results/FINAL_REPORT.md`
(spec §7.5): every candidate's verdict with Δ pass rate, Δ tokens and Δ cost, the accepted stack,
measured economics, and the recommended next campaign.
