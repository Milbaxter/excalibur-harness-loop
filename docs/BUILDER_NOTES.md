# Builder notes: known weak spots and the fallback for each

Read this after the spec and before M0. These are the places most likely to block an autonomous
build. Each has a decided fallback so you do not need to ask.

## 1. DSH inside Terminal-Bench task containers (M1) — hardest step

Task images vary: some are minimal, some have no outbound network, a few are not Debian-based.
Do not rely on `apt`, `curl | bash`, nodesource, or `pnpm install` inside the container.

- Build **one self-contained bundle** on the controller during `install`: a static Node 22 tarball
  (official `node-v22.x-linux-x64.tar.xz`), the pinned `@deepseek-ai/dsh` package **with its
  dependencies already installed** (`npm pack` is not enough; ship a ready `node_modules` tree or a
  single-file build), and the `excalibur` profile directory with every vendored plugin's
  `node_modules` present. Target: `harness/dist/excalibur-runtime.tar.zst`, < 300 MB.
- In `install-dsh.sh.j2`: `mkdir -p /opt/excalibur && tar -I zstd -xf runtime.tar.zst -C /opt/excalibur`
  (upload the tarball with Harbor's file upload API before running the script), then export `PATH`
  and `DSH_HOME=/opt/excalibur/dsh-home`. No network needed.
- If a task image lacks glibc (Alpine): mark the task `excluded: runtime-incompatible` in
  `calibration.json` and skip it. Do not attempt musl builds.
- Verify with the Harbor `hello-world` task first; only then run a real TB task.
- If DSH's headless runner refuses to start without a `DEEPSEEK_API_KEY` present at boot, pass it
  in `ExecInput.env` — Harbor merges it into the command environment.

## 2. Community plugins that do not load on the pinned DSH

Expect a large fraction of the 44 queued community plugins to fail static check or smoke on the
pinned version (DSH is a developer preview with breaking changes).

- Exclude them with the exact error as `reason`. Do not patch third-party code.
- If fewer than 8 community plugins survive for the pilot, backfill pilot slots in this order:
  remaining queued remixes (`order` 18–21), then the DSH built-in rows from the secondary table in
  spec §8.4 (`dsh-todo-write`, `dsh-guard-loop-hygiene`, `dsh-subagent-explore`), then Tier A ideas
  #87 and #95. Keep the pilot at 20 candidates.

## 3. Seeding the hard split without a full calibration (M2 pilot path)

Preferred: per-task rewards from public Harbor Hub jobs for DeepSeek V4 Flash on
`terminal-bench@2.1` (e.g. Ante's published runs). Pick the 18 tasks with the lowest pass rate whose
median agent time is under 8 minutes; split 12 dev / 6 holdout, stratified by category.

Fallback if no usable public per-task data is found within 30 minutes of trying: run a **probe** of
36 tasks × 1 trial with the pilot caps (25 steps, 8 min, low reasoning). At ~$0.03/trial this is
~$1.10. Take the 18 with reward 0 or lowest reward, then verify with dev × 3 as the spec says.
Record which path was used in the `calibration` ledger event.

If the verified dev baseline is above 0.40 even on the hardest 12: switch `excalibur-base` to the
minimal composition (persona + bash + fs read/write only) per spec §5.4 step 4. If it is 0.00 on all
12 (nothing solvable): swap the 6 hardest for the next 6 easiest from the probe.

## 4. Meta-review model access inside the Cursor cloud VM

Try `agent --list-models` first. If the Cursor CLI is missing or unauthenticated in the VM, use
DeepSeek V4 Pro through the DeepSeek API as the meta-reviewer (`model: deepseek-v4-pro`,
`reasoningEffort: max`, JSON output enforced by the prompt + schema validation, 2 retries). Cost
~$0.20–0.40 per review; count it against the budget. Record the model actually used in the ledger.
Never use V4 Pro or any non-Flash model for evaluation trials.

## 5. Session length and interruptions

Build plus pilot is 6–10 hours of agent time. Assume you will be interrupted or the VM recycled.

- Commit after every milestone and every decided batch; `results/milestones/M<n>.md` records where
  you are.
- On resume: read the ledger and the last milestone file first, then continue. Do not redo
  completed milestones.
- If context is getting long, finish the current milestone, commit, and end the turn with a
  one-line status. The human will say "continue".

## 6. Budget enforcement

`budget.py` must exist and gate every live call before M1's first live trial. DeepSeek accounts are
prepaid, so the platform balance is the hard ceiling; `budget.py` exists to stop the run cleanly
before that. If measured $/trial after the 36-trial baseline exceeds $0.045, reduce the pilot to 12
candidates automatically and say so in the milestone file.

## 7. Things that are fine to decide yourself

- Exact pinned versions of DSH, Harbor, Node, Python.
- Daytona sandbox size (start 1 vCPU / 2 GiB; raise per task only if a task's oracle needs it).
- Which frontier model `agent --list-models` offers for meta-review.
- Internal module layout, as long as the CLI commands in spec Appendix E exist.

## 8. Things to ask the human about (end the turn with the question)

- A secret is missing or invalid.
- Daytona rejects the concurrency you need and quota cannot be raised programmatically.
- The verified dev baseline cannot be brought into 0.05–0.50 by any step in §3 above.
- Anything that would push projected spend over $16 before the pilot starts.
