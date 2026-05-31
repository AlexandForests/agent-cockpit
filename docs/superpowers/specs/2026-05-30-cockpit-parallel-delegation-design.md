# Cockpit Phase 7 (Approach 1): Parallel Delegation Engine — Design

Date: 2026-05-30
Status: approved (design); pending implementation plan

## Context
The agent cockpit (Phases 1–6) lets the orchestrate Claude dispatch single tasks to free
workers via `cockpit-ask` (completions) and `cockpit-agent` (agentic edits in isolated git
worktrees). Today those run one-at-a-time and `cockpit-agent` uses a single model with no
fallback. The user's goal for Phase 7 is a **credit-saving delegation engine**: Claude routes
work that free workers can do well, runs several in **parallel**, and **merges** the results —
spending its own (paid) tokens on decomposition and review, not generation. Watching the work
is a nice-to-have, explicitly deferred to Approach 2.

## Goals
- Run N delegated agentic tasks **concurrently** (bounded) on free workers, collect results.
- Make each delegated task **reliable** (model fallback) so a throttled free tier doesn't
  silently drop work.
- Roll results up to the orchestrate Claude as one reviewable summary; Claude reviews + merges.
- Save credits: Claude decomposes + reviews; free workers generate.

## Non-goals (Approach 2, later)
- Visible per-task panes, a "work" tab, `zellij run` spawning. v1 runs in the background.
- Auto-merging. Verify-before-merge stays the orchestrate Claude's decision.
- Fan-out of `cockpit-ask` completions (Claude can already background those trivially).

## Components

### 1. `cockpit-agent` — model auto-fallback
Today: one model, 3 retries, then `exit 1`. Change: walk a **model list**, running the existing
3-retry loop per model, stopping at the first model that produces changes.
- Default list via `COCKPIT_AGENT_MODELS` (space-separated): `opencode/big-pickle opencode/deepseek-v4-flash-free` — both free, no key.
- `--model X` still pins a **single** model (no fallback) — unchanged behavior for explicit choice.
- NVIDIA models only enter the list if the user adds them (`--model nvidia/...` or via the env list); the key check stays conditional on `nvidia/*`.
- Output notes which model succeeded.
- All else (worktree isolation, `--verify`, watchdog, worktree cleanup, exit codes) unchanged.

### 2. `cockpit-agent` — machine-readable `RESULT` line
So `cockpit-fanout` can parse outcomes reliably (rather than scraping prose), `cockpit-agent`
prints one final line to stdout:
```
RESULT status=<ok|nochanges> branch=<cockpit/ts|-> model=<model|-> verify=<ok|fail|none> changed=<N|->
```
- `status=ok` ⇒ a branch with changes exists; `nochanges` ⇒ all models/retries produced nothing.
- Exit code stays 0 on `ok`, 1 on `nochanges` (already the case).

### 3. `cockpit-fanout` (the core) — Python
A bounded-concurrency runner that wraps `cockpit-agent`. Python (not bash) for clean JSON +
`concurrent.futures` + summary; Python is already a cockpit dependency, and this avoids macOS
bash 3.2's missing `wait -n`.
- **Usage:** `cockpit-fanout <batch.json>`
- **Input** `batch.json` — array of task objects:
  ```json
  [
    {"repo": "~/Desktop/claude/friendtrips", "task": "Add a zod Album schema in src/lib/schemas.ts", "verify": "npx tsc --noEmit"},
    {"repo": "~/Desktop/claude/friendtrips", "task": "Add a date-format util in src/lib/format.ts", "verify": "npx tsc --noEmit", "model": "opencode/big-pickle"}
  ]
  ```
  `repo` + `task` required; `verify`, `model` optional (passed through to `cockpit-agent`).
- **Concurrency:** `ThreadPoolExecutor(max_workers=COCKPIT_FANOUT_JOBS)`, default **3**. Each task
  runs `cockpit-agent [--model M] [--verify V] <repo> "<task>"` as a subprocess; its full stdout is
  captured to `~/cockpit/tasks/done/<batch-id>/task-<n>.out`, and the `RESULT` line is parsed.
- Same-repo concurrency is safe — each `cockpit-agent` creates its own worktree off `HEAD`.
- **Output:** `~/cockpit/tasks/done/<batch-id>/summary.md` (also printed to stdout):
  ```
  batch <id>  (3 tasks, 3 concurrent)
  # | task                     | branch        | model      | verify | changed | status
  1 | Add zod Album schema     | cockpit/…a    | big-pickle | ✓      | 1       | ok
  2 | Add date-format util     | cockpit/…b    | big-pickle | ✓      | 1       | ok
  3 | Add Leaflet map wrapper  | -             | -          | -      | -       | FAILED
  per task — review: git -C <repo> diff HEAD..<branch>   merge: git -C <repo> merge --no-ff <branch>
  ```
- Does **not** merge. The summary is the rollup the orchestrate Claude reads, then reviews each
  branch's diff and merges the good ones.

### 4. Protocol update (`cockpit-home/CLAUDE.md`)
Add the delegation pattern: *decompose into bounded, **non-overlapping-file** tasks → write the
fanout JSON → `cockpit-fanout batch.json` → read `summary.md` → review each diff → merge good
branches.* Judgment rule: delegate bounded codegen / tests / boilerplate / scaffolding (free
workers' strength); keep design, architecture, and nuanced/cross-cutting edits for yourself.
Non-overlapping files are required so parallel branches merge without conflicts.

## Data flow
```
Claude decomposes work
  → writes batch.json
  → cockpit-fanout batch.json
      → [≤JOBS concurrent] cockpit-agent (worktree + model-fallback + verify) per task
      → ~/cockpit/tasks/done/<batch-id>/{task-N.out, summary.md}
  → Claude reads summary.md → reviews diffs → git merge the good branches
```

## Acceptance / verification
1. **Fallback:** with `COCKPIT_AGENT_MODELS="<bogus-model> opencode/big-pickle"`, `cockpit-agent`
   fails the bogus model and succeeds on big-pickle (proves list iteration). `--model X` does NOT fall back.
2. **Reality check (gate):** one *realistic* delegated task via big-pickle with `--verify` yields a
   correct, review-worthy diff — concretely, e.g. "add a `parse_duration(str) -> int` util with
   unit/edge-case handling **and** its pytest" in a small Python repo (multi-concern, not a one-liner).
   If the diff isn't worth reviewing, stop and rethink what's worth delegating before relying on fan-out.
3. **Fan-out:** a 3-task `cockpit-fanout` batch on a throwaway git repo runs concurrently, produces
   `summary.md` with branches + verify status; the good branches merge cleanly (non-overlapping files);
   a deliberately-failing task is clearly flagged `FAILED`.
4. **Credit-saving in practice:** Claude decomposes + reviews + merges; the workers generate — i.e.
   the orchestrate pane spends tokens on routing/review, not code generation.

## Risks
- **Free-tier throttling under concurrency** — 3 concurrent big-pickle calls may rate-limit; `JOBS`
  default 3 is conservative and the per-task fallback to deepseek-free absorbs throttles.
- **Merge conflicts** if tasks touch the same files — mitigated by the protocol's non-overlapping rule;
  Claude owns decomposition.
- **Free-model quality on real code** (the elephant) — gated by acceptance #2 before we lean on fan-out.

## Files
- `bin/cockpit-agent` — model-list fallback + `RESULT` line.
- `bin/cockpit-fanout` — new (Python).
- `cockpit-home/CLAUDE.md` — delegation pattern + judgment rule.
- `install.sh` — symlink `cockpit-fanout`.
- `README.md`, `PLAN.md` — document the new capability.
