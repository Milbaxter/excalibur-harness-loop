# Excalibur — Self-Improving Harness Loop

**Technical specification for an autonomous plugin-evaluation loop built on DeepSeek Harness, Harbor/Terminal-Bench, and Cursor Cloud Agents.**

Status: v1 spec, ready to implement. Written for an implementing model (e.g. Grok 4.6 inside Cursor). Every design decision below is grounded in the sources listed in §2; numbers marked *(est.)* are estimates the implementer must confirm during calibration (§5.4).

---

## 0. One-page summary

| | |
|---|---|
| **Subject under test** | DeepSeek Harness (`dsh`) running **DeepSeek V4 Flash** in headless one-shot mode, composed as `base stack + candidate plugin`. |
| **Benchmark** | **Terminal-Bench 2.1** (89 Docker tasks) run through **Harbor**, restricted to a calibrated **hard "dev" subset (~30 tasks)** on which the baseline scores 10–40%, plus a **held-out subset (~15 tasks)** used only to confirm accepted plugins. |
| **Sandboxes** | **Daytona** cloud sandboxes via Harbor `--env daytona` (trials are I/O-bound, so 60–120 concurrent trials). The Cursor VM never runs task containers. |
| **Controller** | A Python CLI (`excalibur`) in this repo, driven by a **Cursor Cloud Agent** (long-running run, or a cron **Automation** that resumes from the git-committed ledger every 30 min). |
| **Meta-reviewer** | Every N=8 (configurable 5–10) candidates, a frontier model is invoked through Cursor's headless CLI (`agent -p --model <smart>`) with the ledger, failure clusters, and sample trajectories; it emits structured proposals (new plugins, harness/evaluator fixes, hack flags). |
| **Metrics** | Pass rate (mean reward), **billed tokens/task**, USD/task, wall time/task. Acceptance requires a paired improvement on the dev set, confirmation on hold-out, and a token budget constraint (§7). |
| **Anti-hacking** | Static scan of plugin source, sealed hold-out, cross-distribution canary tasks, meta-review audit, and the rule that a plugin must be describable without reference to any task (§8). |
| **Budget (overnight)** | ~100 candidates in ~8–10 h. Cost is driven by trial volume (~4.5–7k agentic rollouts × ~1.5M mostly-cached prompt tokens each), not the per-token price: **≈ $300–550 lean, $450–750 standard** *(est., §6.5)*. DeepSeek tokens ≈ 60%, Daytona ≈ 20%, meta-review ≈ 10%. Achieved via three-stage funnel (smoke → screen → confirm) and evaluating 4 candidates in parallel. |
| **Output** | `results/LEADERBOARD.md` + `results/ledger.jsonl`: which plugins were accepted, Δ pass-rate, Δ tokens/task, Δ cost, with confidence intervals; final accepted stack as a reproducible `dsh` profile. |

---

## 1. Goals, non-goals, success criteria

### 1.1 Goals
1. Input: a list of candidate plugins (or plugin ideas). Output: an ordered, evidence-backed list of plugins that **generally** improve the agent, each with measured Δ score and Δ tokens/task.
2. The accepted set accumulates: candidate *k* is tested on top of all previously accepted plugins (greedy forward selection).
3. Runs unattended overnight inside Cursor, survives VM recycling, and resumes from committed state.
4. Cheap enough that 100+ candidates per night is realistic with a cheap model (DeepSeek V4 Flash: $0.14 in / $0.003 cached in / $0.28 out per 1M tokens).
5. Periodic meta-review by a high-intelligence model that can improve *the system itself*, not just propose plugins.

### 1.2 Non-goals
- Leaderboard submission or official Terminal-Bench numbers (we use subsets and fewer trials).
- Fine-tuning or changing the model. Only harness plugins change.
- A web UI. Reporting is Markdown/JSON in git, plus `harbor view` locally when a human wants to dig.

### 1.3 Success criteria for the implementation
- `excalibur run` on a fresh Cursor Cloud Agent VM reaches steady state and processes candidates with zero human input for 8+ hours.
- Baseline calibrated into the 10–40% band on the dev split; noise characterised (§5.4).
- Accept/reject decisions are reproducible from `ledger.jsonl` alone.
- At least one meta-review cycle produces a structured proposal file that is turned into queued candidates.
- Hard budget kill-switch works (§10.5).

---

## 2. Research findings this spec relies on

### 2.1 DeepSeek Harness (DSH) — how plugins work
Sources: [GitHub repo](https://github.com/deepseek-ai/DeepSeek-Harness), [architecture.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md), [headless bundle README](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/bundle/headless/README.md), [Cordis-in-DSH deep dive](https://vanducng.dev/2026/08/15/what-cordis-does-inside-deepseek-harness/), [plugin anatomy docs](https://deepseekdocs.com/en/docs/learn/core/plugin-anatomy), [SDK guide](https://deepseekdocs.com/en/docs/guides/drive-harness-from-program).

- **Everything is a plugin.** Model adapters, tool registry, session log, system prompt assembly, and the agent loop itself are Cordis plugins mounted into a shared `Context`. There is no privileged core.
- **Plugin shape.** A TS module exporting `apply(ctx, config)` (or a class extending `Service`), optional `name`, `inject: string[]` (services it needs; Cordis delays start until they exist), and `Config` (Zod/Schemastery schema). Every registration goes through `ctx.effect()` and is undone automatically on unload — plugins never write cleanup code.
- **Extension points that matter for us** (from `architecture.md` "Where new behavior goes"):
  - `ctx.systemPrompt.section({name, order, text})` — add/replace prompt sections.
  - `ctx.tools` — register model-facing tools (schema joins prompt assembly).
  - Waterfall events: `agent/pre-step` (rewrite/reject what the model sees), `agent/request`, `llm/stream`, `tools/pre-execute` → `tools/execute` → `tools/post-execute`; serial `agent/turn-stopping`.
  - `agent.inject()` — add model-visible context for the next request.
  - `ctx.shell`, `ctx.fs`, `ctx.subprocess`, `ctx.sandbox` providers (exclusive service names).
  - Compaction (`packages/compaction`), guard plugins (`packages/guard`: loop-hygiene, tool-timeout), todo, plan mode, subagents, skills, workflows — all already exist as swappable rows.
- **Composition is configuration.** The running tree = ordered layers applied to an empty list: each bundle's `cordis.patch.yml` (profile order) → profile's own patch → `$DSH_HOME/cordis.patch.yml` → `--patch <file>` overlays → agent presets. A patch either **replaces a row's `config` by `id`** or **inserts rows**. `dsh --profile <p> --dump-config` prints the effective tree. This is the mechanism Excalibur uses to add a candidate: one `--patch` file per candidate, no code changes to `dsh`.
- **Installing out-of-tree plugins.** `dsh plugin --profile <p> add <npm-spec | github:... | link:/abs/path>` (thin pnpm forwarder into `$DSH_HOME/profiles/<p>`). A package declares `dsh.bundle.patch` in `package.json` to contribute a patch layer automatically.
- **Headless mode.** `dsh --profile headless "<task>"`: fresh persisted session, streams reasoning to stderr, prints final assistant text to stdout, exit 0 iff `turn/end` reason is `completed`. No ports. Designed for CI. Profiles `headless`, `sdk`, `sdk-minimal`, `acp` apply layers once at startup (no hot reload) — correct for benchmarking.
- **Token accounting.** `assistant/message` events carry `TokenUsage { inputTokens (uncached), outputTokens, cacheReadTokens?, cacheWriteTokens?, reasoningTokens? }` in the session JSONL at `$DSH_HOME/sessions/**/session.jsonl[.zstd]`. Billed input = input + cacheRead + cacheWrite. This is the source for tokens/task.
- **Replay adapter.** `dsh-llm-replay` runs a composition against recorded session logs with no network or model cost — used here for zero-cost plugin load/smoke checks.
- **Caveats.** Developer preview with breaking changes; pin an exact `@deepseek-ai/dsh` version. `BENCHMARK.md` in the repo is a stub — DSH ships no eval harness, so Excalibur must own evaluation.

### 2.2 Cursor — running this autonomously
Sources: [Cloud Agents API](https://cursor.com/docs/cloud-agent/api/endpoints), [TypeScript SDK](https://cursor.com/docs/sdk/typescript), [Automations](https://cursor.com/docs/cloud-agent/automations), [Environment setup](https://cursor.com/docs/cloud-agent/setup), [Headless CLI](https://cursor.com/docs/cli/headless), [CLI parameters](https://cursor.com/docs/cli/reference/parameters), [Long-running agents](https://cursor.com/blog/long-running-agents).

- **Cloud Agents** run in isolated Ubuntu VMs with the repo cloned, booted from a **Build** (snapshot produced by `.cursor/environment.json` `install`). `start` runs on every boot; `terminals` start tmux-hosted long-lived processes. Default VM profile has **capped, unpublished CPU/RAM**; raising it is an Enterprise support request. Docker is available only by installing it yourself (DinD with `fuse-overlayfs`/`iptables-legacy` or `vfs` storage driver) and is slow. **Conclusion: do not run benchmark containers on the Cursor VM; use Harbor's cloud sandbox providers.**
- **Long-running agents** (Ultra/Teams/Enterprise): multi-hour runs (Cursor cites 25–52 h examples). No user-configurable max runtime; runs can be recycled. Plan for **resume-from-git** regardless.
- **Automations**: schedule (cron) or event (webhook/GitHub/Slack/Linear) triggers that start a cloud agent with instructions and a repo. This is the fallback/heartbeat mechanism: "every 30 min, run `excalibur resume`".
- **Cloud Agents API v1 / SDK**: `POST /v1/agents` creates agent + first run; `POST /v1/agents/{id}/runs` sends follow-ups (409 if a run is active); SSE streaming; `Agent.create({cloud:{repos}})`. Useful for a controller that fans out, but not required for v1 of Excalibur.
- **Headless CLI**: `agent -p --force --model <model> --output-format json "<prompt>"` runs a full Cursor agent (tools, repo access) non-interactively. `agent --list-models` enumerates models. This is how the meta-reviewer is invoked with a frontier model without a separate API key — it bills to the Cursor account.
- **Secrets**: Cloud Agents > Secrets in the dashboard inject env vars into VMs (`DEEPSEEK_API_KEY`, `DAYTONA_API_KEY`, optional `CURSOR_API_KEY`). Values are redacted in transcripts.
- **Concurrency**: Pro ≈ 8 simultaneous cloud agents; higher tiers more. Excalibur needs exactly one controller agent at a time (the ledger lock enforces this).

### 2.3 Benchmark landscape and choice
Sources: [Terminal-Bench 2.1 leaderboard/notes](https://snorkel.ai/leaderboard/terminal-bench-2-1/), [Harbor docs](https://www.harborframework.com/docs/getting-started), [Harbor agents](https://www.harborframework.com/docs/agents), [Harbor cloud execution](https://harbor-framework-harbor.mintlify.app/guides/cloud-execution), [ATIF trajectory RFC](https://github.com/harbor-framework/harbor/blob/main/rfcs/0001-trajectory-format.md), [Ante TB2.1 results with DeepSeek Flash](https://antigma.ai/eval), [DeepSeek V4 Flash 0731 pricing/benchmarks](https://felloai.com/deepseek-v4/), [Agents' Last Exam](https://github.com/rdi-berkeley/agents-last-exam/).

Requirements: sandboxed tool use (so harness plugins matter), short tasks, cheap, runnable from a script, credible, and a baseline in 10–40%.

| Candidate | Verdict |
|---|---|
| **Terminal-Bench 2.1** (89 tasks, Docker, Harbor) | **Chosen.** Canonical harness benchmark; Harbor supports custom installed agents, cloud sandboxes, `--n-concurrent`, per-trial `result.json` and ATIF `trajectory.json` with token/cost fields. Problem: V4 Flash 0731 already scores 66–83% with strong harnesses (Ante: 66.4% preview / 82.7% 0731). **Fix: calibrated hard subset** (§5). |
| SWE-bench Verified / Pro | Flash ≈ 79% / 52.6%; huge per-task images, long runs, expensive. Rejected. |
| Agents' Last Exam (near-term tier) | Flash ≈ 25% — right band, but requires GCP/AWS/QEMU desktop VMs and GUI; too heavy. Rejected for v1; noted as a future canary source. |
| Automation Bench (public), NL2Repo, DeepSWE | Right band for some, but tooling maturity/cost unclear. Rejected for v1. |
| Text-only QA (HLE, ARC-AGI-2, AIME) | No tool use → harness plugins barely matter. Rejected. |

Terminal-Bench full-run economics (Ante, 89 tasks × 5 trials, Flash 0731): ~$68 and ~39 min wall at high concurrency → **≈ $0.15/trial and heavy tail from long tasks**. Excalibur's subset + timeout policy brings this to ≈ $0.04–0.08/trial *(est.)*.

---

## 3. Architecture

```
┌──────────────────────────── Cursor Cloud Agent VM (controller) ────────────────────────────┐
│  git repo (this)                                                                            │
│  ├─ excalibur/  (Python CLI)  ──► harbor run -d terminal-bench@2.1 --env daytona -n 60      │
│  │     loop.py  · evaluator.py · metrics.py · acceptance.py · meta_review.py · ledger.py    │
│  ├─ plugins/    (candidate + accepted DSH plugins, one dir each)                             │
│  ├─ harness/    (excalibur-base dsh profile, patches, install template)                      │
│  ├─ results/    (ledger.jsonl, leaderboard, per-candidate reports; committed after each step)│
│  └─ .cursor/    (environment.json, Dockerfile, agents/, automation instructions)             │
│                                                                                             │
│  meta-review: `agent -p --model <frontier> --output-format json -f "$(cat prompt.md)"`      │
└───────────────┬───────────────────────────────────────────────────────┬─────────────────────┘
                │ Harbor spawns one sandbox per trial                   │ git push after every
                ▼                                                       ▼ candidate decision
┌────────── Daytona sandboxes (60–120 concurrent) ──────────┐    ┌─────────────────────┐
│  task image (TB 2.1 task)                                 │    │ origin (GitHub)     │
│   + node 22 + pinned @deepseek-ai/dsh (tarball, cached)   │    │ ledger = source of  │
│   + excalibur-base profile + candidate --patch            │    │ truth for resume    │
│   dsh --profile excalibur "<instruction>"                 │    └─────────────────────┘
│   └─► DeepSeek API (V4 Flash)                             │
│  session.jsonl copied out as artifact → tokens/task        │
└────────────────────────────────────────────────────────────┘
```

Components:

1. **Controller (`excalibur` CLI, Python 3.12, `uv`)** — owns the loop, the ledger, acceptance statistics, reporting, and meta-review invocation. Runs on the Cursor VM. Stateless between steps except for `results/` in git.
2. **Evaluator** — Harbor (`uv tool install harbor`) with a custom `BaseInstalledAgent` subclass `DshAgent` that installs DSH into each task container and runs the headless profile. Trials run in Daytona sandboxes.
3. **Subject** — DSH pinned version, profile `excalibur` = `excalibur-base` bundle + accepted plugins + candidate under test, model `deepseek-v4-flash`.
4. **Registry** — `plugins/<id>/` directories with `plugin.yaml` manifest + TS source or npm spec. `results/ledger.jsonl` append-only event log.
5. **Meta-reviewer** — Cursor headless CLI invocation with a frontier model; reads a review bundle, writes `results/meta/<n>/proposals.json`; controller turns proposals into queued candidates/issues.

Design rules:
- **Everything is resumable from git.** The controller must be killable at any instant; on restart it re-reads the ledger, reconciles any in-flight Harbor job directory (`jobs/<name>/result.json` present → ingest; absent → re-run), and continues.
- **One writer.** A `results/LOCK` file with agent id + heartbeat timestamp; a second controller exits if the lock is <20 min old.
- **No task containers on the controller VM.** Local Docker is only for `excalibur doctor` smoke runs of 1–2 tasks, and optional.

---

## 4. Repository layout

```
excalibur/
  README.md
  pyproject.toml                 # uv project; deps: harbor, pyyaml, pydantic, numpy, scipy, rich, typer
  excalibur/
    __init__.py
    cli.py                       # typer app: doctor, calibrate, run, resume, eval, review, report, budget
    config.py                    # loads config.yaml, env, validates
    ledger.py                    # append-only JSONL events + derived state
    catalog.py                   # plugin manifests, queue ordering, static checks
    harness.py                   # builds dsh profile/patch for a stack; packs plugin tarballs
    evaluator.py                 # runs harbor jobs, ingests result.json + trajectories + dsh session logs
    metrics.py                   # pass rate, tokens/task, cost, wall time; paired deltas + bootstrap
    acceptance.py                # decision rules (§7)
    loop.py                      # funnel + greedy selection + batching (§6, §9)
    meta_review.py               # bundle builder + `agent -p` invocation + proposal ingestion (§9)
    report.py                    # LEADERBOARD.md, per-candidate reports, final summary JSON
    budget.py                    # cost tracking + kill switch
    harbor_agent/
      dsh_agent.py               # Harbor BaseInstalledAgent subclass
      install-dsh.sh.j2          # installs node + dsh tarball + profile inside the task container
  harness/
    dsh.version                  # pinned @deepseek-ai/dsh version (exact)
    excalibur-base/              # the baseline profile as a bundle package
      package.json               # dsh.bundle.patch -> cordis.patch.yml
      cordis.patch.yml           # rows: llm-deepseek (flash), persona, tools, sandbox off, telemetry off
    patches/                     # generated per-stack patch files (gitignored except accepted-stack.yml)
    accepted-stack.yml           # ordered list of accepted plugin ids (also derivable from ledger)
  plugins/
    _template/                   # copy to create a plugin
      plugin.yaml
      package.json
      src/index.ts
      cordis.patch.yml
    <plugin-id>/ ...
  benchmarks/
    tb21/
      dev.txt                    # task names in dev split (written by `calibrate`)
      holdout.txt                # task names in hold-out split (sealed; see §8)
      canary.txt                 # 3–5 non-TB tasks (different distribution)
      calibration.json           # baseline per-task pass rates, durations, tokens
  results/
    ledger.jsonl
    LEADERBOARD.md
    candidates/<plugin-id>/report.md
    meta/<n>/bundle.md, proposals.json
    LOCK                         # gitignored
  jobs/                          # harbor job dirs (gitignored; artifacts summarised into results/)
  config.yaml
  .cursor/
    environment.json
    Dockerfile
    agents/meta-reviewer.md      # optional: Cursor subagent definition for reviews
    AUTOMATION.md                # instructions text to paste into the Automation
```

---

## 5. Benchmark protocol

### 5.1 Dataset
- Harbor registry dataset `terminal-bench@2.1` (89 tasks). Pin the dataset version and the Harbor version in `config.yaml`.
- Trials execute with `--env daytona`. Harbor's docs put Daytona at 100+ concurrency with fast startup; DeepSeek Flash allows 2,500 concurrent requests, so `-n 60` is the default and `-n 120` is allowed for batch mode.

### 5.2 Splits
- **dev** (~30 tasks): used for screening and confirmation of each candidate. Selected by calibration (§5.4) so the baseline lands in 10–40%.
- **holdout** (~15 tasks): same difficulty band, disjoint from dev, **never** used for selection; only run once per *accepted* candidate to confirm generalisation. Task names are stored, but the controller refuses to run holdout for rejected candidates or more than once per candidate.
- **canary** (3–5 tasks): from a *different* Harbor dataset (e.g. a few `swe-bench-lite` or custom small repo tasks) to detect TB-specific overfitting. Cheap, run on accepted candidates only.
- Excluded from all splits: tasks whose oracle runtime or resource needs exceed the per-trial cap below (recorded in `calibration.json` with reason).

### 5.3 Per-trial limits (cost control)
- Agent wall time cap: **15 min** (Harbor `--agent-timeout` / task.toml override). Tasks that need more are excluded at calibration.
- DSH per-run caps via the excalibur-base patch: `maxTokens` 48k output per request, max steps 60 per turn, tool-timeout guard 120 s, shell output cap 64 KB. Hitting a cap = trial fails (reward 0) — this is intentional; efficiency plugins should learn to avoid it.
- Verifier runs as usual after the agent finishes.

### 5.4 Calibration (`excalibur calibrate`) — one-time, ~1 h, ~$40 *(est.)*
1. Run the **default DSH stack** (user requirement: first run is default DSH settings) on all 89 tasks × 3 trials with V4 Flash: `harbor run -d terminal-bench@2.1 -a excalibur.harbor_agent.dsh_agent:DshAgent --env daytona -n 90 -k 3`.
2. Record per task: pass rate, median wall time, median billed tokens, timeouts.
3. Choose splits with this procedure:
   - Drop tasks with median agent time > 12 min or any oracle failure.
   - Sort remaining by pass rate ascending. Take the tasks with pass rate ≤ 0.34 (hard band). If fewer than 45 such tasks exist, include the next-hardest until you have 45.
   - Randomly (seeded) split into dev (30) and holdout (15), stratified by category (software eng / sysadmin / data / ML / security) so both splits look alike.
   - Compute baseline dev pass rate. **Target: 0.10–0.40.**
4. **If the default stack is still above 0.40 on the hard band** (plausible: strong harness + strong model), switch the baseline to `excalibur-base = sdk-minimal-like` composition (persona + bash + fs read/write + no plan/todo/subagents/skills/compaction) and repeat step 1 on the hard band only. Rationale: this is still "default DSH plugins", just fewer of them, and it makes the first plugins to test the *general* capabilities DSH already ships (plan mode, todo, compaction, subagents) — an excellent sanity check for the whole pipeline because they should show up as improvements.
5. **If below 0.10**, relax the band (include tasks up to 0.50 pass rate).
6. Write `benchmarks/tb21/{dev,holdout}.txt`, `calibration.json`, and a `calibration` event to the ledger. The dev/holdout lists are frozen for the campaign.

### 5.5 Noise model (must be understood by the implementer)
Pass rate over 30 tasks × 1 trial has SE ≈ √(p(1−p)/30) ≈ 8 pp at p=0.25. A single screening run therefore only detects large effects. That is why §6 uses a funnel: cheap screening to *rank* candidates, then confirmation with 3 trials/task (90 paired trials → SE ≈ 4.6 pp for the mean; the paired delta is tighter because task difficulty cancels). Acceptance thresholds in §7 are set with this in mind; calibrate them with two baseline-vs-baseline A/A runs during `calibrate` (record the observed |Δ| distribution — it is the null).

---

## 6. Evaluation funnel and loop

### 6.1 Candidate lifecycle

```
queued → static_check → smoke → screen → confirm → holdout+canary → accepted
                │          │        │         │            │
                └──rejected┴────────┴─────────┴────────────┘   (with reason code)
```

| Stage | What runs | Cost/time *(est.)* | Pass condition |
|---|---|---|---|
| **static_check** | Manifest validation; TS compiles; forbidden-pattern scan (§8); size limits | 0 | No violations |
| **smoke** | `dsh` loads the stack with the candidate under `dsh-llm-replay` (no model) on 1 recorded session; then 2 live dev tasks × 1 trial | ~$0.15, 3 min | Plugin mounts, no crash, ≥1 completed turn |
| **screen** | dev 30 tasks × 1 trial vs. current baseline stack (baseline numbers reused from its own confirm run) | ~$1.5–2.5, ~12 min | Δpass ≥ −2 pp (not clearly worse) **or** Δbilled-tokens ≤ −15% |
| **confirm** | dev 30 × 3 trials paired against baseline's 30 × 3 | ~$5–7, ~15 min | Acceptance rule §7.2 |
| **holdout+canary** | holdout 15 × 2 + canary 4 × 2 | ~$2–3, ~12 min | §7.3 |

Expected funnel: ~70% of candidates die at screen, ~50% of the rest at confirm → ~10–20 accepted per 100 *(est.)*.

### 6.2 Greedy forward selection with parallel batches
- The **baseline stack** `S` starts as `excalibur-base` (+ whatever calibration chose). Its confirm-level numbers (30×3) are always on file.
- The controller pulls **B = 4** candidates at a time (configurable), runs their screens **concurrently** (4 Harbor jobs, 120 sandboxes), then runs confirms for those that passed screen, concurrently.
- Among candidates that pass confirm in the batch, **accept the one with the highest composite score** (§7.1). Re-queue the other passers at the front of the queue with `retest_against=S'` (they must be re-confirmed against the new stack — interactions are real). Rejected candidates are not retried unless a meta-review explicitly re-queues them.
- After acceptance: `S' = S + p`. Run holdout+canary for `p`. If holdout fails (§7.3), mark `accepted_dev_only`, **revert** `S' → S`, and continue. Otherwise **reuse `p`'s confirm run (30×3) as the baseline numbers for `S'`** — it is exactly the new stack measured at confirm depth, so no separate re-baseline run is needed. This also yields the cumulative-gain curve for free.
- **Re-baseline sanity** every 10 acceptances: run `S` at 30×5 and check it is not drifting downward; if two consecutive re-baselines drop >3 pp, trigger an out-of-band meta-review.

### 6.3 Pseudocode

```python
def run(config):
    state = Ledger.load(config.results_dir)          # replays ledger.jsonl into state
    acquire_lock_or_exit(state)
    ensure_calibrated(state)                          # §5.4 if missing
    baseline = state.baseline_stack()                 # Stack(ids=[...], confirm=Metrics)
    while state.queue and budget.ok(state):
        batch = state.queue.pop_front(config.batch_size)
        for cand in batch:
            if not static_check(cand): state.reject(cand, "static"); continue
            if not smoke(cand, baseline): state.reject(cand, "smoke"); continue
        screened = parallel(screen(c, baseline) for c in batch if c.alive)
        passers  = [c for c in screened if screen_pass(c, baseline)]
        confirmed = parallel(confirm(c, baseline) for c in passers)
        winners = [c for c in confirmed if accept_rule(c, baseline)]
        for c in confirmed: state.record(c)           # every trial ingested, committed
        if winners:
            best = max(winners, key=composite)
            others = [c for c in winners if c is not best]
            new_stack = baseline + best
            hold = holdout_and_canary(best, new_stack, baseline)
            if hold.ok:
                state.accept(best, hold)
                baseline = Stack(new_stack, confirm=best.confirm_metrics)  # reuse, no re-run
                state.requeue_front(others, retest_against=baseline.id)
            else:
                state.mark(best, "accepted_dev_only"); state.reject(best, "holdout")
        git_commit_push(state, f"excalibur: batch {state.batch_no} decided")
        if state.candidates_since_review >= config.meta_review_every:
            proposals = meta_review(state)            # §9
            state.ingest(proposals); git_commit_push(...)
    write_final_report(state)
```

### 6.4 Time budget for 100 candidates overnight *(est.)*
- Per batch of 4: smoke 3 min (parallel) + screen 12 min + confirm 15 min (only for passers) + holdout 12 min (only if a winner) → **~30–40 min per batch** when a winner exists, ~15–20 min when none.
- 25 batches → **8–12 h**, i.e. overnight. To make it tighter: raise `batch_size` to 6 (Daytona 180 concurrent — check quota), or shrink dev to 24 tasks (noisier).
### 6.5 Cost model — why "extremely cheap per token" still adds up

**Per trial.** A trial is an agentic rollout of 30–50 model steps; every step resends the whole conversation, so a 40-step trial whose context grows to ~80k tokens moves ~1.5M prompt tokens. With DeepSeek's prefix cache:

| component | tokens | price | cost |
|---|---|---|---|
| uncached input (~10%) | ~150k | $0.14/M | $0.021 |
| cached input (~90%) | ~1.35M | $0.003/M | $0.004 |
| output incl. reasoning | ~60k | $0.28/M | $0.017 |
| **DeepSeek per trial** | | | **≈ $0.04** *(est.)* |
| Daytona per trial (2 vCPU / 4 GiB × ~8 min) | | $0.0504/vCPU-h, $0.0162/GiB-h | ≈ $0.02 |

Reference point: Ante's TB 2.1 run with Flash 0731 (max reasoning, no time cap) cost $68 / 445 trials = **$0.15/trial**. Excalibur's 15-min cap and medium reasoning effort should land nearer $0.04–0.08; calibration measures the real number and `budget.py` uses it.

**Trial volume is the driver.** Two campaign profiles for 100 candidates:

| stage | **standard** trials | **lean** trials |
|---|---|---|
| calibration (89×3 + A/A) / seeded verification (45×2) | 450 | 90 |
| screening (100 × dev × 1) | 3,000 (dev=30) | 2,000 (dev=20) |
| confirms (~30 candidates × dev × k) | 2,700 (k=3) | 1,800 (k=3 capability, 2 efficiency) |
| holdout + canary (~15 accepted × 38) | 570 | 570 |
| re-baselines | 0 (reused, §6.2) | 0 |
| meta-review + coder calls (Cursor, frontier model) | 12 reviews | 12 reviews |
| **total trials** | **~6,700** | **~4,500** |
| DeepSeek tokens @ $0.04–0.08/trial | $270–540 | $180–360 |
| Daytona @ ~$0.02/trial | ~$130 | ~$90 |
| meta-review (12 × $3–8) | $40–100 | $40–100 |
| **all-in** *(est.)* | **≈ $450–750** | **≈ $300–550** |

Levers, in order of impact: (1) tokens/trial — cache-friendly prompt ordering and a lower step cap are worth more than any other knob, and efficiency plugins that get accepted lower the cost of every later evaluation; (2) dev-split size at screening; (3) confirm trials `k`; (4) reasoning effort (`medium` vs `max`); (5) DeepSeek off-peak discount window if it applies to V4 Flash at run time; (6) Daytona sandbox size (1 vCPU / 2 GiB is enough for most TB tasks; calibration records which tasks need more).

For perspective, the same campaign with a frontier model at $15–75 per 1M output tokens would cost $10k–40k. The cheap model is what makes the loop feasible; it does not make ~5–7k agentic rollouts free. `budget.py` (§10.5) enforces the cap regardless of which estimate turns out right.

### 6.6 `pilot` profile — the first run, ≤ $20 of DeepSeek credit

**Build and run this profile first.** It validates the pipeline end to end, measures the real $/trial (replacing every *(est.)* above), and tests 15–20 candidates with enough power to detect large effects. Only after a successful pilot should the `lean`/`standard` campaign be funded.

Cost assumptions: Daytona's **$200 sign-up credit (no card)** covers all sandbox compute; meta-review runs through the Cursor CLI on the Cursor plan (or DeepSeek V4 Pro at ~$0.20 per review); therefore the $20 is DeepSeek Flash tokens only.

| knob | pilot value | why |
|---|---|---|
| per-trial step cap / agent time cap | 25 steps / 8 min | halves tokens per trial; hard tasks needing 50+ steps are not winnable by a cheap model anyway |
| `max_output_tokens` per request | 8,192 | bounds reasoning blow-ups |
| `reasoningEffort` | `low` | 2–3× fewer output tokens; the plugins under test should not depend on max reasoning |
| context cap / compaction | compact at 48k tokens | bounds prompt size per step |
| calibration | **skipped**; seed the hard split from public per-task rewards on Harbor Hub (e.g. Ante's Flash 0731 runs), then verify with dev × 3 | saves ~270 trials (~$10) |
| dev / holdout / canary | 12 / 6 / 2 tasks | SE ≈ 12 pp — detects effects ≥ ~15 pp, which is what the first (built-in) candidates should show if the pipeline works |
| screen / confirm / holdout trials | 1 / 2 / 2 | |
| candidates | the 20 entries marked `pilot: true` in `candidates/seed_queue.yaml`: 2 DSH built-in positive controls, 10 community plugins, 5 remixes, 3 Tier A ideas (see `candidates/README.md`) | already-implemented plugins first so the $20 buys measurements, not coding |
| batch size / `-n` | 2 / 24 | keeps concurrent spend visible |
| controller | laptop or one Cursor agent polling every 15 min | an idle cloud agent polling tmux all night spends Cursor usage for nothing |
| `budget.cap_usd` | **18** | kill-switch with margin |
| acceptance thresholds | `min_delta_pp: 10` capability, `min_cost_decrease_pct: 25` efficiency | matched to the pilot's noise floor |

Pilot trial budget: baseline 12×3 (36) + screen 20×12×1 (240) + confirm ~6×12×2 (144) + holdout ~3×6×2 (36) ≈ **456 trials ≈ $9–14 at $0.02–0.03/trial** (est.; the pilot's first 36 trials measure the real figure and `budget.py` re-projects the run from it). If measured $/trial exceeds $0.045, the controller automatically drops to 12 candidates.

Exit criteria for the pilot: (1) `doctor` + baseline verify + one full candidate lifecycle completed unattended; (2) measured $/trial, tokens/trial, and wall/trial recorded in the ledger; (3) at least one positive-control plugin accepted or a documented reason why not; (4) one meta-review produced valid `proposals.json`. With those in hand, the full campaign is re-costed from measured numbers (expected: ~$150–250 for 100 candidates with pilot-level token caps and the lean profile).

Cheaper-still options considered: OpenRouter `:free` model variants (DSH honours `DEEPSEEK_BASE_URL`, so an OpenAI-compatible endpoint may work) are rate-limited and unreliable for 24-way concurrency — acceptable for `smoke` only, not for measured stages; running a local model is not viable (V4 Flash is a 284B MoE).

---

## 7. Metrics and acceptance rules

### 7.1 Metrics per trial → per candidate
From Harbor `result.json` (reward, timings) + DSH `session.jsonl` copied out via Harbor artifact collection (`$DSH_HOME/sessions/**`) and parsed with the same de-dup rule as `dsh-token-meter` (`assistant/message.usage` is final per `(turn, step)`, `assistant/chunk{type:'usage'}` is fallback):

| Metric | Definition |
|---|---|
| `pass` | mean reward over trials (0–1) |
| `billed_tokens` | Σ (inputTokens + cacheReadTokens + cacheWriteTokens + outputTokens) per trial, median and mean over trials |
| `cost_usd` | priced with DeepSeek list price table in `config.yaml` (input miss $0.14, cache hit $0.003, output $0.28 per 1M); ATIF `total_cost_usd` also written so `harbor view` shows it |
| `wall_s` | agent phase seconds |
| `steps` | model requests per trial |
| `timeout_rate`, `error_rate` | fraction of trials hitting caps / crashing |

**Composite score** (used only to rank winners within a batch, never as the sole accept criterion):
`composite = Δpass_pp − λ · max(0, Δcost_pct) / 10`, with λ = 1 (i.e. +10% cost costs 1 pp of credit). Configurable.

### 7.2 Confirm acceptance rule (dev, paired 30×3 vs 30×3)
Let per-task mean reward be `r_c[t]`, `r_b[t]`; `Δ[t] = r_c[t] − r_b[t]`; `Δpass = mean(Δ)`; `Δcost = cost_c/cost_b − 1`.

Accept if **either**:
- **Capability path:** `Δpass ≥ +3 pp` **and** one-sided paired bootstrap `P(Δpass ≤ 0) ≤ 0.10` (10,000 resamples over tasks) **and** `Δcost ≤ +20%` **and** `timeout_rate_c ≤ timeout_rate_b + 5 pp`.
- **Efficiency path:** `Δpass ≥ −1 pp` (non-inferiority, bootstrap `P(Δpass ≤ −3pp) ≤ 0.10`) **and** `Δcost ≤ −15%`.

Otherwise reject with reason `confirm_no_gain`, `confirm_too_expensive`, or `confirm_noisy`. Thresholds live in `config.yaml`; calibration's A/A runs must show that baseline-vs-baseline is accepted < 10% of the time under these rules — if not, raise `+3 pp` or add trials.

### 7.3 Holdout + canary rule
- Holdout (15×2): `Δpass_holdout ≥ 0 pp` for capability plugins, `≥ −3 pp` for efficiency plugins; **and** `Δcost_holdout` consistent in sign with dev (efficiency plugins must still be cheaper).
- Canary (4×2): `Δpass_canary ≥ −25 pp` (a crude guard: the plugin must not wreck off-distribution behaviour) and no crash/incompatibility.
- Fail → `accepted_dev_only` (reported, excluded from stack). This label is the main signal of benchmark-specific overfitting.

### 7.4 Reporting
`results/LEADERBOARD.md` (regenerated every commit):

```
| # | Plugin | Status | Δpass dev (95% CI) | Δtokens/task | Δcost/task | Δwall | Holdout Δ | Stack pass after |
```
plus a cumulative-gain chart as an ASCII/Markdown table of stack pass rate and cost after each acceptance, and a "rejected" table with reason codes. Per-candidate `report.md` contains: manifest, effective `--dump-config` diff, per-task table, 3 worst regressions and 3 best gains with links to `jobs/<job>/<trial>/agent/trajectory.json`.

---

## 8. Plugin contract and anti-benchmark-hacking policy

### 8.1 Manifest `plugins/<id>/plugin.yaml`
```yaml
id: reflect-on-failure            # kebab-case, unique
title: Reflect on tool failure before retrying
category: reasoning               # reasoning | context | tools | efficiency | verification | planning | safety
hypothesis: >
  After a failed tool call the model repeats near-identical commands. Injecting a short
  structured "what failed / why / what to change" prompt before the next step should reduce
  wasted steps and increase completion on multi-stage tasks.
mechanism: agent/pre-step listener + systemPrompt section   # extension points used
source:
  kind: local                     # local | npm | github
  path: ./                        # or spec: "@org/dsh-plugin-x@1.2.3" / "github:org/repo#sha"
patch: ./cordis.patch.yml         # rows to insert/replace when the plugin is in the stack
expected_effect: capability       # capability | efficiency | both
risk_notes: none
author: meta-review-3 | human
```

### 8.2 Plugin source rules (enforced by `static_check`)
- Must be a standard DSH plugin (exports `apply` or a `Service` class; declares `inject`; config via schema). Must compile with the pinned DSH types.
- **Generality rule:** the hypothesis must be statable without reference to any benchmark, dataset, task name, file path under `/tests`, or expected output. The static scanner rejects source or prompts containing: task names from TB 2.1 (list generated from the dataset), the strings `terminal-bench`, `tbench`, `/tests/`, `test.sh`, `reward`, `solution/`, `oracle`; hard-coded shell one-liners longer than 200 chars; or embedded data files > 20 KB.
- No network access other than through DSH's own `ctx.llm` (plugins may not call other model APIs; Daytona sandboxes are additionally restricted by Harbor task network policy).
- May not read or modify the verifier directory, may not change the model id or provider (the `llm-deepseek` row is locked by the excalibur-base patch and diffed after `--dump-config`).
- Size cap 1,500 LOC; must load in < 3 s under replay.

### 8.3 Dynamic safeguards
- Sealed **holdout** (§5.2) and **canary** tasks from another distribution.
- `accepted_dev_only` labelling and automatic exclusion.
- **Meta-review audit** (§9): the reviewer receives each accepted plugin's source and must answer `general | suspicious | hack` with reasoning; `hack` → quarantine + revert.
- Prompt-injection check: the reviewer also confirms that no plugin adds instructions that tell the model to game verifiers (e.g. "edit tests").

### 8.4 Candidate sources and queue order
The primary candidate pool is imported from [Milbaxter/dsh-intelligence-lab](https://github.com/Milbaxter/dsh-intelligence-lab) (pinned commit in `candidates/seed_queue.yaml`): 52 community DSH plugins with GitHub sources, 11 local remixes, and a 100-item catalogue of plugin *ideas* with an implementation priority list. The mapping, exclusions (model swaps, external services, network, whole-harness replacements, interactive-only, cross-session self-modification, SWE-bench-specific), and the 20-candidate pilot selection are documented in `candidates/README.md`. The controller loads it with `excalibur queue import candidates/seed_queue.yaml`.

Import rules: community plugins are **vendored at a pinned commit** into `harness/vendor/<id>` at import time and shipped inside the cached tarball (no per-trial network fetch); remixes are copied into `plugins/<id>/` and adapted to the pinned DSH API if needed; ideas are scaffolded and implemented by the coder step (§9.4) only when they reach the front of the queue, in the lab's Tier A → B → C order, with architecture-scale ideas deferred unless a meta-review requests them. Every imported plugin passes the static check in §8.2 unchanged — third-party code is excluded, not patched, if it fails.

Queue order after the pilot: remaining remixes → remaining community plugins by category (verification → planning → context → tools → memory → workflow) → ideas Tier A → B → C. Meta-review proposals are inserted by priority. The table below is a *secondary* backlog of general ideas the implementer may add after the imported pool; its first six entries are DSH built-in rows that double as positive controls.

| id | category | mechanism |
|---|---|---|
| `dsh-plan-mode` | planning | mount DSH plan-mode row |
| `dsh-todo-write` | planning | mount `todo_write` tool |
| `dsh-compaction-basic` | context | mount compaction provider with conservative thresholds |
| `dsh-subagent-explore` | reasoning | mount subagent delegation for read-only exploration |
| `dsh-guard-loop-hygiene` | safety | detect repeated identical tool calls, inject a nudge |
| `dsh-skill-filesystem` | tools | mount skills loader with basic skills |
| `env-recon-preamble` | context | first step runs `uname/ls/cat README` summary via a pre-step injected context |
| `read-before-write` | verification | tools/pre-execute: block edits to files never read this session (with override) |
| `verify-before-done` | verification | agent/turn-stopping: if no test/verification command ran, inject "verify then finish" once |
| `reflect-on-failure` | reasoning | after non-zero exit, inject structured reflection prompt |
| `tool-output-summarizer` | efficiency | tools/post-execute: truncate + head/tail + grep-hint for outputs > N KB |
| `cache-friendly-prompt-order` | efficiency | stable section ordering + move volatile context to the end to maximise prefix-cache hits |
| `step-budget-awareness` | efficiency | inject remaining step/token budget every k steps |
| `error-pattern-hints` | reasoning | map common stderr patterns (missing dep, permission, port in use) to short generic hints |
| `scratchpad-notes` | context | `notes_write/notes_read` tools with the notes kept in the system prompt tail |
| `command-timeout-adaptive` | tools | raise/lower shell timeout based on the command class |
| `double-check-diff` | verification | before finishing, show `git diff --stat`/file list to the model for a final review |
| `parallel-tool-calls` | efficiency | allow batching independent read-only tool calls per step |
| `reasoning-effort-adaptive` | efficiency | lower reasoning effort for trivial steps, raise on failure streaks |
| `long-output-to-file` | tools | redirect huge command outputs to a file and return a pointer + head |

---

## 9. Meta-review

### 9.1 Trigger and inputs
Every `meta_review_every` (default 8; allowed 5–10) *decided* candidates, or on drift alarm (§6.2). The controller builds `results/meta/<n>/bundle.md` (< 60k tokens) containing:
- Config, current stack, cumulative-gain table, budget spent/remaining.
- Ledger summary for the window: each candidate's manifest, stage reached, Δ metrics, reason codes.
- Failure clustering: for the current stack's last confirm run, per-task failure categories (timeout, wrong answer, crash, verifier error) and 3 representative trajectory excerpts (last 40 steps) chosen by the controller.
- Source of every plugin accepted in the window (for the hack audit).
- The open questions list from the previous review and what happened to them.

### 9.2 Invocation
Inside the Cursor VM (the repo is present, so the reviewer can read any file):

```bash
agent -p --force --model "$META_MODEL" --output-format json \
  --workspace /workspace \
  "$(cat excalibur/prompts/meta_review.md) $(cat results/meta/$N/bundle.md)"
```

`META_MODEL` defaults to the strongest model available from `agent --list-models` at run time (the builder should pick a frontier model such as the latest Claude/GPT/Grok tier and record it in the ledger). The reviewer may run read-only commands (`harbor view` API, `jq` over trajectories) but the prompt forbids edits; the controller applies changes.

### 9.3 Required output (`proposals.json`, schema-validated)
```json
{
  "review_id": 3,
  "system_findings": [{"area":"evaluator|acceptance|harness|budget","finding":"...","severity":"low|med|high"}],
  "plugin_audits": [{"id":"...","verdict":"general|suspicious|hack","reason":"..."}],
  "new_candidates": [{"id":"...","title":"...","category":"...","hypothesis":"...","mechanism":"...","sketch":"<TS outline>","priority":1}],
  "requeue": [{"id":"...","reason":"..."}],
  "config_changes": [{"path":"acceptance.min_delta_pp","from":3,"to":2.5,"justification":"..."}],
  "questions_for_human": ["..."]
}
```

### 9.4 What the controller does with it
- `new_candidates`: scaffold `plugins/<id>` from `_template` with the sketch as `src/index.ts` and manifest filled in; run `static_check`; queue by priority. (Implementation of the sketch into working code is done by a **second headless Cursor call** with a cheaper model: `agent -p --force --model <coder> "implement plugins/<id> per plugin.yaml and sketch; run pnpm typecheck"`, capped at 2 attempts.)
- `plugin_audits` with `hack`: quarantine (remove from stack, mark ledger, revert to previous stack numbers).
- `config_changes`: applied automatically **only** for keys whitelisted in `config.yaml: meta_review.auto_apply_keys` (e.g. batch size, bootstrap resamples, timeouts). Anything else is written to `results/meta/<n>/PROPOSED_CHANGES.md` and surfaces in the final report for the human.
- `system_findings` with severity `high`: controller pauses new batches, commits, and (if `CURSOR_API_KEY` is present) posts a follow-up to the owning Cursor agent run so the human sees it; otherwise continues in "conservative mode" (batch size 1).
- Everything is committed under `results/meta/<n>/`.

---

## 10. Running it inside Cursor

### 10.1 Environment
`.cursor/environment.json`:
```json
{
  "build": { "dockerfile": ".cursor/Dockerfile", "context": ".." },
  "install": "uv sync && uv tool install harbor && uv tool install daytona && pnpm --dir harness install && bash scripts/cache-dsh-tarball.sh",
  "start": "mkdir -p /tmp/excalibur && echo started > /tmp/excalibur/start.ok",
  "terminals": []
}
```
`.cursor/Dockerfile` (Ubuntu 24.04 base): Node 22 + pnpm, Python 3.12 + `uv`, `jq`, `zstd`, `git`. No Docker daemon required (Daytona does sandboxing). Optional DinD only if `EXCALIBUR_LOCAL_DOCKER=1`.

`scripts/cache-dsh-tarball.sh` runs `npm pack @deepseek-ai/dsh@$(cat harness/dsh.version)` and stores the tarball + the `excalibur-base` bundle in `harness/dist/` so each sandbox install is a single `npm i -g ./dsh.tgz` (~20–40 s) instead of a registry fetch. Also pre-generate the per-stack patch files.

Secrets (Dashboard → Cloud Agents → Secrets): `DEEPSEEK_API_KEY`, `DAYTONA_API_KEY`, optional `DAYTONA_API_URL`, optional `CURSOR_API_KEY` (only for API follow-ups), `EXCALIBUR_BUDGET_USD`.

### 10.2 Harbor agent adapter (core of the evaluator)
`excalibur/harbor_agent/dsh_agent.py` extends `BaseInstalledAgent`:
- `_install_agent_template_path` → `install-dsh.sh.j2`: installs Node 22 if missing (nodesource or prebuilt tarball), `npm i -g /tmp/dsh.tgz`, writes `$DSH_HOME` (e.g. `/tmp/dsh-home`) with profile `excalibur` = `excalibur-base` bundle + accepted plugins + candidate (copied in via Harbor `upload`), sets `DSH_TELEMETRY=off`.
- `create_run_agent_commands(instruction)` → one `ExecInput`: `cd /app && dsh --profile excalibur --patch /tmp/stack.patch.yml "<instruction>"` with `env={DEEPSEEK_API_KEY, DSH_HOME}` and a hard `timeout 900`.
- After run: copy `$DSH_HOME/sessions` to the agent output dir (Harbor artifact collection) and convert the DSH session log to **ATIF** `trajectory.json` (steps = user/assistant/tool events; `final_metrics.total_prompt_tokens/total_completion_tokens/total_cached_tokens/total_cost_usd`). Set `SUPPORTS_ATIF = True` so `harbor view` shows tokens.
- Prompt template: pass the instruction verbatim; do **not** add benchmark-specific hints (generality rule applies to the adapter too). The only allowed wrapper is the neutral "You are working in `/app`; finish by ensuring the task is complete" line, kept identical for all candidates.

Alternative considered: run DSH on the controller and point its `fs`/`subprocess` providers at the remote sandbox (DSH's `e2b.cordis.yml` shows this composition). Rejected for v1 — the installed-agent pattern is how every agent on the TB leaderboard is run, keeps the controller light, and isolates candidate bugs inside the sandbox.

### 10.3 Run modes
1. **Primary — single long-running Cloud Agent (Ultra/Teams/Enterprise).** Start from cursor.com/agents with the prompt in `.cursor/AUTOMATION.md` ("run `uv run excalibur run` in a tmux session `excalibur-loop`; poll every 10 min; on completion write the final report; never edit results by hand"). The controller commits and pushes after every batch, so a mid-run VM recycle loses ≤ one batch.
2. **Fallback / heartbeat — Automation on a 30-min cron** with the same repo and instructions: `uv run excalibur resume --max-minutes 25`. `resume` exits immediately if `results/LOCK` is fresh (another controller alive), otherwise reconciles and runs batches until its time box expires, committing as it goes. This turns the overnight run into a chain of short agents if long-running agents are unavailable.
3. **Self-hosted worker (optional).** Point a Cursor self-hosted worker pool at a beefier machine if Daytona is not wanted; then `--env docker` with `-n 16` becomes viable. Not needed for the default design.

### 10.4 Agent instructions (`.cursor/AUTOMATION.md`, also used as the run prompt)
- You are the operator, not the experimenter: never hand-edit `results/`, `benchmarks/`, or plugin verdicts.
- Start/resume the loop (`uv run excalibur resume --max-minutes <N>`), watch `results/ledger.jsonl` tail and `jobs/*/job.log`.
- If the controller crashes: capture the traceback into `results/incidents/<ts>.md`, fix **controller** bugs only if obvious and covered by tests, otherwise commit the incident and exit.
- On finish: run `uv run excalibur report`, commit, push, and summarise `results/LEADERBOARD.md` in your final message.

### 10.5 Budget and kill-switch
- `budget.py` tracks spend from ATIF costs + Daytona usage (sandbox-seconds × vCPU/GiB prices) and refuses to start a new batch if projected spend > `EXCALIBUR_BUDGET_USD`. Default $500.
- Hard caps: per-trial 15 min; per-Harbor-job 45 min; per-batch 75 min; DeepSeek 429/5xx → exponential backoff with `-n` halved for the next job.
- `excalibur budget` prints spend so far; the Automation prompt tells the agent to stop the loop if it exceeds the cap.

---

## 11. Data model

### 11.1 Ledger events (`results/ledger.jsonl`, one JSON per line)
```
{"ts":..., "type":"calibration", "dev":[...], "holdout":[...], "baseline":{...}, "aa_null": {...}}
{"ts":..., "type":"candidate_queued", "id":"...", "manifest":{...}, "source":"seed|meta-review-3"}
{"ts":..., "type":"stage", "id":"...", "stage":"static|smoke|screen|confirm|holdout|canary", "job":"jobs/<name>", "metrics":{...}, "vs_stack":"stack-0007", "passed":true}
{"ts":..., "type":"decision", "id":"...", "decision":"accepted|rejected|accepted_dev_only|quarantined", "reason":"...", "composite":1.8}
{"ts":..., "type":"stack", "stack_id":"stack-0008", "plugins":[...], "confirm_metrics":{...}}
{"ts":..., "type":"meta_review", "n":3, "model":"...", "proposals":"results/meta/3/proposals.json"}
{"ts":..., "type":"budget", "spent_usd":123.4, "cap_usd":500}
```
`Ledger.load()` folds events into: queue, per-candidate status, current stack + metrics, spend, review counter. No other state file is authoritative.

### 11.2 Stack patch generation
`harness.py` composes `patches/<stack-id>.yml` = concatenation of each plugin's `cordis.patch.yml` (in acceptance order) with the candidate's rows appended; row ids are namespaced `x-<plugin-id>-<row>` to avoid collisions. Verified by `dsh --profile excalibur --patch <file> --dump-config` inside the smoke sandbox; the dump is stored with the trial for audit.

---

## 12. Implementation plan (milestones with acceptance checks)

| # | Milestone | Done when |
|---|---|---|
| M0 | Environment: Dockerfile, `environment.json`, `uv` project, pinned DSH version and cached tarball, `excalibur doctor` (checks keys, `harbor --version`, Daytona auth, `dsh --version` in a throwaway sandbox) | `doctor` green on a fresh Cloud Agent VM |
| M1 | `DshAgent` Harbor adapter + ATIF conversion + token parsing | `harbor run -d terminal-bench@2.1 -a excalibur.harbor_agent.dsh_agent:DshAgent --env daytona --include-task-name hello-world -n 1` yields reward + non-zero token counts in `trajectory.json` |
| M2 | `calibrate` (full 89×3 default-stack run, split selection, A/A null runs) **or, under `profile: pilot`, `calibrate --seeded`**: hard split seeded from public per-task rewards, verified with dev×3 (§6.6) | dev baseline in 0.10–0.40; A/A false-accept rate < 10% under §7.2 (pilot: verified baseline recorded, thresholds from §6.6) |
| M3 | Ledger, catalog, static checks, `_template` plugin, **`queue import` of `candidates/seed_queue.yaml`** (vendor community plugins at pinned commits, copy remixes, generate manifests, run static checks) | `excalibur eval --candidate dsh-plan-mode --stage screen` runs and appends events; import report lists queued/excluded counts with reasons |
| M4 | Funnel + greedy batch loop + rebaseline + commit/push | `excalibur run --max-candidates 8` completes unattended; `resume` after `kill -9` continues correctly |
| M5 | Meta-review bundle, `agent -p` invocation, proposal ingestion, scaffold + coder call | A review produces ≥1 queued candidate that passes static_check |
| M6 | Reports, budget kill-switch, Automation instructions, incident capture | LEADERBOARD regenerates; budget cap halts run; Automation resumes a killed run |
| M7 | **Pilot run (§6.6)** with the 20 `pilot: true` candidates under `profile: pilot`, cap $18 | Report with accepted/rejected tables, cumulative-gain curve, and measured $/trial, tokens/trial, wall/trial written to the ledger; full-campaign cost re-projected from measured numbers |

Testing guidance for the implementer: unit-test `metrics.py`/`acceptance.py` with synthetic per-task arrays (including the A/A case); test `ledger.py` replay with fixture logs; mock Harbor in `loop.py` tests; only M1/M2/M7 need real spend.

---

## 13. Risks and mitigations

| Risk | Mitigation |
|---|---|
| DSH preview breaks APIs | Pin exact version + tarball; smoke stage catches load failures; upgrade only between campaigns |
| Baseline too strong (no headroom) | Calibration ladder §5.4 (hard band → minimal composition → relax band) |
| Noise produces false accepts | Paired design, 3-trial confirm, bootstrap gate, A/A-calibrated thresholds, holdout confirmation, periodic 5-trial re-baseline |
| Benchmark hacking by generated plugins | §8: static scan, sealed holdout, canary, meta audit, generality rule |
| Cost runaway | Budget kill-switch, per-trial/job/batch caps, funnel, `-n` backoff on 429 |
| Cursor VM recycled mid-run | Ledger in git after every batch; `resume` reconciles Harbor job dirs; Automation heartbeat |
| Daytona quota/concurrency | Configurable `-n`; controller halves `-n` on provisioning errors; `--env modal`/`e2b` are drop-in alternatives |
| DeepSeek rate limits / peak pricing | Backoff; schedule runs in off-peak window; cache-friendly prompt ordering |
| Meta-reviewer proposes harmful config changes | Whitelisted auto-apply keys only; rest goes to human report |
| Task network drift (TB 2.0 lesson) | Use 2.1; exclude tasks that fail oracle at calibration; re-check oracle monthly |

---

## 14. Assumptions and open decisions (for the human)
1. Sandboxes: Daytona is assumed (Harbor-supported, $0.05/vCPU-h, $200 free credit). Swap to Modal/E2B by changing `evaluator.env` — nothing else depends on it.
2. Meta-review model: chosen at runtime from `agent --list-models`; record the choice. If the account lacks a frontier model, the loop still runs; reviews degrade.
3. Long-running agents require Ultra/Teams/Enterprise; on Pro use the 30-min Automation chain (§10.3.2).
4. Terminal-Bench 2.1 is the v1 benchmark. Adding a second benchmark (e.g. an Agents' Last Exam near-term subset) as a *canary* is the recommended next step once the loop is stable.
5. Acceptance thresholds (+3 pp / −15% cost / p ≤ 0.10) are starting points to be validated by the A/A runs; the meta-reviewer may propose changes but cannot auto-apply them.

---

## Appendix A — `config.yaml` (initial)
```yaml
model:
  provider: deepseek-official
  id: deepseek-v4-flash
  prices_per_million_usd: {input_miss: 0.14, input_cache_hit: 0.003, output: 0.28}
  max_output_tokens: 49152
benchmark:
  dataset: terminal-bench@2.1
  dev_size: 30
  holdout_size: 15
  hard_band_max_pass: 0.34
  target_baseline_band: [0.10, 0.40]
  per_trial_agent_timeout_s: 900
evaluator:
  env: daytona
  n_concurrent: 60
  n_concurrent_batch_max: 120
  job_timeout_s: 2700
funnel:
  smoke_tasks: 2
  screen_trials: 1
  confirm_trials: 3
  holdout_trials: 2
  canary_trials: 2
  screen_pass: {max_pass_drop_pp: 2, or_min_cost_drop_pct: 15}
acceptance:
  capability: {min_delta_pp: 3, max_p_null: 0.10, max_cost_increase_pct: 20, max_timeout_increase_pp: 5}
  efficiency: {min_delta_pp: -1, noninferiority_margin_pp: 3, max_p_null: 0.10, min_cost_decrease_pct: 15}
  holdout: {capability_min_delta_pp: 0, efficiency_min_delta_pp: -3}
  canary: {min_delta_pp: -25}
  composite_lambda: 1.0
  bootstrap_resamples: 10000
loop:
  batch_size: 4
  sanity_rebaseline_every_accepts: 10   # 30×5 drift check only; normal baselines reuse the winner's confirm run
  profile: pilot                         # pilot | lean | standard (see §6.5–6.6); pilot first, always
  meta_review_every: 8
meta_review:
  model: auto            # resolved from `agent --list-models`
  coder_model: auto-cheap
  auto_apply_keys: [loop.batch_size, evaluator.n_concurrent, acceptance.bootstrap_resamples]
budget:
  cap_usd: 500
  daytona_prices: {vcpu_hour: 0.0504, gib_hour: 0.0162}
```

## Appendix B — `excalibur-base/cordis.patch.yml` (sketch)
```yaml
# Locked rows (diffed after --dump-config; a candidate may not change these)
- id: llm-deepseek
  config:
    thinking: enabled
    reasoningEffort: medium
    models: [{ id: deepseek-v4-flash, contextWindow: 256000 }]
- id: agent-default-model
  config: { provider: deepseek-official, model: deepseek-v4-flash }
- id: system-prompt
  config:
    persona: "You are a careful software engineer working in a Linux shell. Complete the task fully, verify your work, then stop."
- id: telemetry
  disabled: true
- id: hmr
  disabled: true
# Baseline capability rows are decided by calibration (§5.4): either the default headless set,
# or the minimal set below (bash + fs read/write only).
```

## Appendix C — Harbor adapter skeleton
```python
# excalibur/harbor_agent/dsh_agent.py
import os, shlex
from pathlib import Path
from harbor.agents.installed.base import BaseInstalledAgent, ExecInput

class DshAgent(BaseInstalledAgent):
    SUPPORTS_ATIF = True

    @staticmethod
    def name() -> str:
        return "excalibur-dsh"

    @property
    def _install_agent_template_path(self) -> Path:
        return Path(__file__).parent / "install-dsh.sh.j2"   # node22 + /tmp/dsh.tgz + profile + patch

    def create_run_agent_commands(self, instruction: str) -> list[ExecInput]:
        return [ExecInput(
            command=(
                "cd /app && timeout 900 dsh --profile excalibur "
                "--patch /tmp/excalibur/stack.patch.yml " + shlex.quote(instruction) +
                " > /tmp/excalibur/final.txt 2> /tmp/excalibur/stderr.txt; "
                "echo $? > /tmp/excalibur/exit_code"
            ),
            env={"DEEPSEEK_API_KEY": os.environ["DEEPSEEK_API_KEY"],
                 "DSH_HOME": "/tmp/dsh-home", "DSH_TELEMETRY": "off"},
        )]

    def populate_context_post_run(self, context) -> None:
        # copy /tmp/dsh-home/sessions/** into the trial's agent dir (Harbor artifact collection),
        # parse session.jsonl(.zstd) -> ATIF trajectory.json with final_metrics token/cost fields,
        # set context.n_input_tokens / n_output_tokens / n_cache_tokens / cost_usd.
        ...
```

## Appendix D — Meta-review prompt (`excalibur/prompts/meta_review.md`, abridged)
```
You are the meta-reviewer for Excalibur, an autonomous loop that tests DeepSeek Harness plugins
on a Terminal-Bench 2.1 subset with DeepSeek V4 Flash. You may read any file in this repo and run
read-only commands. Do NOT edit files. Return ONLY a JSON object matching schemas/proposals.schema.json.

Your jobs, in priority order:
1. Audit each accepted plugin's source for benchmark-specific behaviour (task names, test paths,
   verifier gaming, hard-coded solutions, instructions to modify tests). Verdict per plugin.
2. Find systemic problems: noisy acceptance, bad task selection, evaluator bugs (timeouts, install
   failures counted as model failures), cost leaks, cache-unfriendly prompt assembly.
3. From the failure clusters and trajectories, propose up to 8 NEW plugins that would improve
   general agent competence (reasoning, verification, context management, efficiency). Each needs a
   benchmark-agnostic hypothesis and the DSH extension point(s) it uses.
4. Propose config changes only with quantitative justification from the ledger.
5. List questions only a human can answer.
Bundle follows.
```

## Appendix E — Commands cheat-sheet
```bash
uv run excalibur doctor                       # env, keys, harbor, daytona, dsh tarball, 1-task smoke
uv run excalibur calibrate                    # §5.4 (one-time, ~1h)
uv run excalibur queue add plugins/*/         # validate manifests, enqueue
uv run excalibur run                          # full loop until queue empty or budget cap
uv run excalibur resume --max-minutes 25      # time-boxed, lock-aware (Automation mode)
uv run excalibur eval --candidate <id> --stage confirm --against stack-0003
uv run excalibur review --now                 # force a meta-review
uv run excalibur report                       # regenerate LEADERBOARD.md and final JSON
uv run excalibur budget                       # spend so far vs cap
harbor view jobs                              # human inspection of trajectories (local)
```
