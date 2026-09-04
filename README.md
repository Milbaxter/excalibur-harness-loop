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
- Candidate pool (163 entries imported from dsh-intelligence-lab, 20 marked for the pilot): [`candidates/`](candidates/README.md)

## What the spec covers

1. Verified research on how DeepSeek Harness plugins and headless mode work, how Cursor Cloud
   Agents / Automations / headless CLI enable autonomous runs, and which benchmark gives a cheap
   model a 10–40% baseline with headroom.
2. Architecture: Python controller on the Cursor VM, Harbor + Daytona sandboxes for trials, DSH as
   the subject, git ledger as the only state, Cursor headless CLI for meta-review.
3. Benchmark protocol with calibration, dev/holdout/canary splits, and a noise model.
4. Three-stage evaluation funnel, greedy forward selection with parallel batches, statistical
   acceptance rules that weigh pass rate against tokens per task.
5. Plugin contract, anti-benchmark-hacking policy, and 20 starter plugin ideas.
6. Meta-review contract (inputs, prompt, JSON proposals, what gets auto-applied).
7. Cursor environment files, run modes (long-running agent or cron Automation), budget kill-switch.
8. Milestone plan with acceptance checks, risks, and open decisions.

## How to use this repo next

Open a Cursor agent on this repo with a prompt like:

> Implement `docs/EXCALIBUR_SPEC.md` milestone by milestone (M0 → M7). Start with M0 and stop after
> each milestone's acceptance check passes. Secrets `DEEPSEEK_API_KEY` and `DAYTONA_API_KEY` are
> available as environment variables.
