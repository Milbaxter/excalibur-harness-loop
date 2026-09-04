# Candidate seed queue

`seed_queue.yaml` is the ordered candidate pool for Excalibur, imported from
[Milbaxter/dsh-intelligence-lab](https://github.com/Milbaxter/dsh-intelligence-lab) at commit
`5ff2d2c` and mapped onto the Excalibur plugin contract (spec §8). The controller reads this file
with `excalibur queue import candidates/seed_queue.yaml`.

## What is in the pool

| bucket | count | how it becomes a candidate |
|---|---:|---|
| Positive controls (DSH built-in rows) | 2 | mount the existing DSH row via a patch; no code |
| Community plugins (GitHub, from the lab's `catalog.json`) | 44 queued / 19 excluded | vendored at a pinned commit into `harness/vendor/<id>` at import time; installed into the sandbox from the cached tarball; manifest generated from the catalog entry |
| Local remixes (lab's `remixes/`) | 9 queued / 2 excluded | copied into `plugins/<id>/`; adapted to the pinned DSH API if their `ctx.tools.register` shape differs; static-checked |
| Ideas (lab's `plugin-ideas/README.md`, 100 items) | 86 backlog / 14 deferred | implemented on demand by the coder step (spec §9.4) in Tier A → B → C order; deferred items are architecture-scale and only get built if a meta-review asks for them |

## Pilot (20 candidates, `pilot: true`)

Chosen to maximise the chance of seeing a clear effect on a 12-task hard split for the least
implementation effort: things that already exist and act on verification/planning/context first,
three Tier A ideas last.

| order | id | kind |
|---:|---|---|
| 1 | dsh-plan-mode | control |
| 2 | dsh-compaction-basic | control |
| 3–12 | dsh-doublecheck, dsh-proof, dsh-pain-point-check, dsh-specflow, dsh-task-planner, dsh-plan-and-solve, dsh-premise-guard, dsh-context-proxy, dsh-tool-search, dsh-fail-logger | community |
| 13–17 | remix-test-first-gate, remix-verify-loop, remix-failure-notebook, remix-smallest-patch, remix-compact-then-act | remix |
| 18–20 | idea #100 Failure Signal Parser, #63 Action Precondition Checker, #65 Observation Completeness Detector | idea (Tier A) |

After the pilot, the queue continues in `order`: remaining remixes, remaining community plugins by
category (verification → planning → context → tools → memory → workflow), then ideas Tier A → B → C.

## Exclusions and why

Excluded entries stay in the file with `status: excluded` and a `reason`, so the decision is
auditable and reversible:

- **Model/provider changes** (`dsh-model-router`, `llm-adaptive`, `dsh-subagent-claude`): the
  benchmark measures the harness around one fixed cheap model; swapping models is out of scope.
- **Whole-harness replacement** (`mstar-harness`): not composable with greedy stacking.
- **External services or network** (`dsh-mcp-bridge`, `dsh-deep-research`, `modsearch`,
  `nowledge-mem`, `dsh-docker`, probably `dsh-workspace-rag`): Harbor task sandboxes are
  network-restricted and Excalibur forbids other services (§8.2).
- **Cross-session self-modification** (`dsh-continual-evolve`, `dsh-evolve`): every trial is a
  fresh sandbox, so these cannot work as designed and would blur what is being measured.
- **Interactive/UI-only** (`dsh-prompt-studio`, `dsh-prompt-profile`, `dsh-turn-rewind`,
  `forkprobe`, `dsh-sidechain`): no effect in headless mode.
- **Generality rule** (`remix-mneme-swe-notes`): SWE-bench-specific notes. `remix-no-web` is an
  ablation of a capability the baseline lacks.

Memory plugins (`dsh-mneme`, `dsh-memento`, `dsh-file-memory`, `dsh-memory*`, `distill`,
`dsh-mnemon`, `dsh-knowledge*`) are kept but ordered late: with per-trial sandboxes they can only
help *within* a task, which is a weaker version of their intended effect.

## Import rules the controller applies

1. Resolve `pin: RESOLVE_AT_IMPORT` to the current default-branch commit of each repo and write it
   back; never float.
2. Run the static check (§8.2) on every vendored plugin. Failures become `status: excluded` with
   the scanner's reason — do not patch third-party code.
3. Generate `plugins/<id>/plugin.yaml` from the catalog fields (`category`, `hypothesis`, `risk`);
   drop the lab's `whyForSweBench` and `priorBoostPp` fields, which are benchmark-specific.
4. For remixes, verify the `ctx.tools.register` / `inject` shapes against the pinned DSH types
   and record any adaptation in `docs/DSH_NOTES.md`.
5. Ideas are scaffolded only when they reach the front of the queue, not at import.
