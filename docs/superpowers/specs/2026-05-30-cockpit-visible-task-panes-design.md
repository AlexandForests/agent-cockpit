# Phase 7 Approach 2 — Visible Task Panes (`cockpit-fanout --panes`)

_Design spec · 2026-05-30_

## Context

Phase 7 Approach 1 shipped `cockpit-fanout` (merged to `main`, commit `b5600cb`): it runs N
`cockpit-agent` tasks bounded-concurrent (`ThreadPoolExecutor`, `COCKPIT_FANOUT_JOBS`, default 3) as
**headless captured subprocesses**, parses each `RESULT` line, and rolls up
`~/cockpit/tasks/done/<batch-id>/summary.md` for review + merge.

Because tasks run headless, you see nothing until the batch finishes. Approach 2 closes that gap:
**watch the fan-out run live**, each task in its own zellij pane, without changing the engine or the
review/merge flow.

## Goal / scope

A **thin observability layer** over the existing fan-out:

- Each task runs in a live, labeled zellij pane in a new tab, so progress is visible in real time.
- The engine, bounded concurrency, `RESULT` parsing, and `summary.md` rollup are **unchanged**.
- Opt-in and additive — default behavior and existing callers/tests are untouched.

## Non-goals (YAGNI)

- **No in-pane interactivity** (approve/merge/kill from a pane) — review/merge stays via `summary.md`
  + git, as today.
- **Not the default** — headless remains the default; visible mode is opt-in via `--panes`.
- No new worker panes, no changes to the 4-pane cockpit layout, no changes to `cockpit-agent`.

## Design

### CLI / behavior

- New opt-in flag: `cockpit-fanout --panes <batch.json>`.
- Visible mode is active only when **all** hold: `--panes` given, `$ZELLIJ` set (we are inside the
  cockpit session), and `zellij` is on PATH.
- Otherwise → print a one-line stderr notice and run the **existing headless path** (graceful
  degradation; covers scripts / CI).
- In visible mode:
  - A new tab `fanout-<batch-id>` is created.
  - Each task spawns a live pane named `task-N <short label>`; output streams into the pane via `tee`.
  - Panes **stay open** after the agent exits (read the diff / RESULT).
  - The same `summary.md` is written to the batch dir and printed to the invoking (orchestrate) pane.
  - Exit-code semantics unchanged (0 iff all tasks `status=ok`).

### Files touched

- `bin/cockpit-fanout` — only file with logic changes (arg parse, visible `run_task` path, tab setup,
  fallback).
- `cockpit-home/CLAUDE.md` — one protocol line: orchestrator may pass `--panes` to watch a fan-out.
- `tests/` — new `stubs/zellij` + tests (see Testing).
- Unchanged: `bin/cockpit-agent`, `zellij/cockpit.kdl`, `bin/cockpit`, `parse_result`,
  `build_summary`, `install.sh`.

### Data flow — visible `run_task(idx, entry, batch_dir)`

1. **Generate a wrapper script** `<batch_dir>/task-<idx>.sh` (`#!/usr/bin/env bash`, `chmod +x`; args
   embedded with `shlex.quote` — task text is never interpolated into a shell `-c`, avoiding
   quoting / injection). It runs:

   ```sh
   cockpit-agent [--model M] [--verify V] <repo> <task> 2>&1 | tee <batch_dir>/task-<idx>.out
   echo "${PIPESTATUS[0]}" > <batch_dir>/task-<idx>.done
   ```

   `tee` → live in the pane + saved for parsing. `.done` sentinel carries cockpit-agent's exit code
   (via bash `PIPESTATUS`, hence the pinned bash shebang) and signals completion.

2. **Focus + spawn**: `zellij action go-to-tab-name fanout-<batch-id>`, then
   `zellij run --name "task-<idx>: <label>" --cwd <repo> -- <batch_dir>/task-<idx>.sh`
   (`<label>` = the task text truncated to ~30 chars; no `--close-on-exit`, so the pane persists).

3. **Poll** for `task-<idx>.done` (e.g. 0.5 s interval) up to a **per-task** safety timeout (~12 min,
   comfortably above cockpit-agent's 5-min watchdog).

4. On completion → `parse_result(task-<idx>.out)`; return `(idx, task, fields)` as today.

### Concurrency

Unchanged mechanism: the existing `ThreadPoolExecutor(max_workers=JOBS)` still wraps `run_task`.
Because each visible `run_task` blocks on its sentinel poll, only `JOBS` task panes are live at once;
the rest spawn in waves as pollers return. `COCKPIT_FANOUT_JOBS` high ⇒ effectively all-at-once.
Rollup after all futures resolve is identical to headless.

### zellij wrinkles — decisions

- **Stray default pane**: `new-tab` opens with one empty shell pane. v1 **leaves it** (the tab is a
  throwaway you close after merge); not worth fragile close-timing logic.
- **Active-tab placement**: `zellij run` spawns into the *active* tab, so each spawn is preceded by
  `go-to-tab-name fanout-<id>` to guarantee panes land in the fan-out tab. Accepted side effect: a
  new wave pulls focus back to that tab (desirable for a watch feature).

### Error handling

- `cockpit-agent`'s 5-min watchdog still fires inside the pane; a killed task still emits its
  `RESULT` + sentinel and is parsed normally (`status=nochanges` / `FAILED`).
- **Fan-out safety timeout** (~12 min > agent watchdog + buffer): if `.done` never appears (pane
  killed, zellij crash), record synthetic `status=timeout` and continue — no hung fan-out.
- If `zellij run` returns nonzero → record `status=spawn-failed`, continue the rest.

## Testing

- **`tests/stubs/zellij`** — records `new-tab` / `run` / `go-to-tab-name` invocations; for `run`,
  executes the wrapped script synchronously so `.out` / `.done` are produced. Lets an integration
  test drive the visible path with no real terminal.
- **Integration test** (`--panes` with stubbed zellij + stubbed cockpit-agent): assert tab named
  `fanout-<id>`, one `run` per task, sentinels consumed, `summary.md` **byte-identical** to the
  headless run for the same batch.
- **Unit tests**: wrapper-script generation (quoting of model / verify / repo / task), poll + parse
  against a pre-seeded fake batch dir, and fallback (`--panes` without `$ZELLIJ` ⇒ headless path).
- Existing headless tests stay green (no engine change).
- **Live validation** (manual, as in Approach 1): real 3-task `cockpit-fanout --panes` inside the
  cockpit — watch the `fanout-<id>` tab populate in waves, panes stay open with diffs, `summary.md`
  matches.

## Risks

- `zellij run` / `zellij action` flag names vary by zellij version — verify against the installed
  0.44.3 during implementation (`--cwd`, `--name`, `go-to-tab-name`).
- Wrapper exit-code capture is shell-sensitive; the generated script pins bash (`PIPESTATUS`) via
  shebang and is spawned directly (`zellij run -- <script>`), not through `zsh -c`.
