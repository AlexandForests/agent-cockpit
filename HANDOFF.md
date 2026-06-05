# Agent Cockpit — handoff (resume here)

_Last updated: 2026-05-31_

## Where things stand
The cockpit (Phases 1–6) is built and in daily-usable shape. **Phase 7 is COMPLETE — both
approaches are merged to `main`:** Approach 1, the parallel delegation engine (merge `b5600cb`), and
Approach 2, visible task panes (merge `6c29d4f`, `--no-ff`, 2026-05-31; full suite green on the merge
+ live-validated in the cockpit). Both feature branches are deleted; their history lives under the
merge commits. Working tree is clean.

Currently checked out: **branch `main`**.

## What Phase 7 added (merged to `main`)
- **Approach 1 — `cockpit-fanout <batch.json>`**: runs N `cockpit-agent` tasks bounded-concurrent
  (default 3, `COCKPIT_FANOUT_JOBS`) into `~/cockpit/tasks/done/<batch-id>/summary.md` for
  review+merge. `cockpit-agent` gained a free-only model-fallback chain (`COCKPIT_AGENT_MODELS`,
  default `opencode/big-pickle opencode/deepseek-v4-flash-free`), a machine-readable `RESULT` line,
  and PID-suffixed branch/worktree names so concurrent runs don't collide.
  Spec/plan: `docs/superpowers/{specs,plans}/2026-05-30-cockpit-parallel-delegation*.md`.
- **Approach 2 — `cockpit-fanout --panes`**: opt-in flag runs each task in a live zellij pane in a new
  `fanout-<id>` tab (reuses the `ThreadPoolExecutor` for bounded waves + the same `summary.md`
  rollup); falls back to headless outside a zellij session. Built TDD (17 unit tests + a `zellij`
  stub-driven integration test). Live-validated: a 3-task `--panes` fan-out tiled into the new tab,
  panes streamed live + stayed open, all `status=ok verify=ok`.
  Spec/plan: `docs/superpowers/{specs,plans}/2026-05-30-cockpit-visible-task-panes*.md`.
- Delegation protocol in `cockpit-home/CLAUDE.md`; usage in `README.md`/`PLAN.md`; tests under `tests/`.

## Verify it still works
```sh
cockpit-doctor                                 # READY ✓
bash tests/test_cockpit_agent.sh               # ALL PASS
bash tests/test_fanout_integration.sh          # ALL PASS
bash tests/test_fanout_visible_integration.sh  # ALL PASS
python3 -m pytest tests/test_fanout.py -q      # 17 passed
```

## Decision waiting for you
**Phase 7 is done (both approaches merged) — pick the next build.** Nothing is blocked; candidates
are under "Next phases" below.

## Next phases (priority order)
1. **Phase 6 leftover — autostart `cockpit` on login** (launchd; the GUI-window-on-monitor-2 part is
   the fiddly bit). Status bar + session resurrection already done.
2. **Phase 5 — concurrency/roles.** Deferred until the **4080 (`gamerbox`, Windows, offline)** is set
   up as a local model server; little to tune until then.

## Not part of the cockpit
The `friendtrips` project (`~/Desktop/claude/friendtrips`, Next.js) is Alex's real app, in planning —
separate from cockpit development. The cockpit is the tooling Alex uses to build things like it.

## Orientation files
`PLAN.md` (living doc) · `README.md` (usage) · `cockpit-home/CLAUDE.md` (orchestrate routing protocol) ·
`bin/` (helpers) · the specs + plans above.
