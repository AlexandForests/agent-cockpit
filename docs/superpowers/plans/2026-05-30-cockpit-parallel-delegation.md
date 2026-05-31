# Cockpit Parallel Delegation Engine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the orchestrate Claude delegate N bounded tasks to free workers concurrently and roll the results into one reviewable summary, saving paid Claude tokens.

**Architecture:** `cockpit-fanout` (new Python script) is a bounded-concurrency wrapper around the existing `cockpit-agent`. `cockpit-agent` gains a model-fallback chain (free-only by default) and a machine-readable `RESULT` line that `cockpit-fanout` parses. No auto-merge — `cockpit-fanout` produces branches + a `summary.md`; Claude reviews and merges.

**Tech Stack:** bash (`cockpit-agent`), Python 3 stdlib (`cockpit-fanout`, `concurrent.futures`), git worktrees, pytest for the Python unit tests. Repo: `~/Desktop/claude/agent-cockpit`.

---

## File Structure

- `bin/cockpit-agent` (modify) — wrap the retry loop in a model-fallback loop; emit a final `RESULT` line.
- `bin/cockpit-fanout` (create, Python) — parse a batch JSON, run `cockpit-agent` per task bounded-concurrent, aggregate `summary.md`. Pure helpers `parse_result()` and `build_summary()` are unit-tested.
- `tests/test_cockpit_agent.sh` (create) — stub-`opencode` integration test for fallback + RESULT.
- `tests/test_fanout.py` (create) — pytest unit tests for `parse_result`/`build_summary`.
- `tests/test_fanout_integration.sh` (create) — stub-`cockpit-agent` integration test for concurrency + summary.
- `tests/stubs/opencode`, `tests/stubs/cockpit-agent` (create) — deterministic stubs.
- `install.sh` (modify) — symlink `cockpit-fanout`.
- `cockpit-home/CLAUDE.md` (modify) — delegation pattern + judgment rule.
- `README.md`, `PLAN.md` (modify) — document the capability.

All test stubs make behavior deterministic so tests need no network/LLM. `pytest` is available (installed earlier); if missing: `python3 -m pip install --user pytest`.

---

## Task 1: `cockpit-agent` model-fallback chain + `RESULT` line

**Files:**
- Modify: `bin/cockpit-agent`
- Create: `tests/stubs/opencode`
- Create: `tests/test_cockpit_agent.sh`

- [ ] **Step 1: Write the deterministic `opencode` stub**

Create `tests/stubs/opencode` (a fake `opencode` that edits a file only for a "good" model):

```bash
#!/usr/bin/env bash
# Stub opencode for tests. Usage mirrors: opencode run "<prompt>" -m <model>
# Edits ./calc.py only when the model name contains "good"; otherwise does nothing.
model=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    if [ "${args[$i]}" = "-m" ]; then model="${args[$((i+1))]}"; fi
done
case "$model" in
    *good*) printf 'def add(a, b):\n    return a + b\n' > calc.py ;;
    *)      : ;;  # bad model: produce no change
esac
exit 0
```

Make it executable:

```bash
chmod +x tests/stubs/opencode
```

- [ ] **Step 2: Write the failing integration test**

Create `tests/test_cockpit_agent.sh`:

```bash
#!/usr/bin/env bash
# Integration test for cockpit-agent model-fallback + RESULT line, using a stub opencode.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$REPO_ROOT/bin:$REPO_ROOT/tests/stubs:$PATH"   # real cockpit-agent (bin) + stub opencode (only in stubs)
fail=0
check() { if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; fail=1; fi; }

newrepo() { d="$(mktemp -d)"; git -C "$d" init -q; git -C "$d" config user.email t@t.co; git -C "$d" config user.name t;
            printf 'def add(a, b):\n    return a - b\n' > "$d/calc.py"; git -C "$d" add -A; git -C "$d" commit -qm init; echo "$d"; }

echo "test: fallback bad-model -> good-model"
r="$(newrepo)"
out="$(COCKPIT_AGENT_MODELS='bad-model good-model' cockpit-agent "$r" 'fix calc.py' 2>/dev/null)"; rc=$?
check "exit 0 on eventual success" "[ $rc -eq 0 ]"
check "RESULT status=ok present"    "echo \"\$out\" | grep -q 'RESULT status=ok'"
check "RESULT names good-model"     "echo \"\$out\" | grep -q 'model=good-model'"
check "a cockpit/* branch was created" "[ -n \"\$(git -C \"\$r\" branch --list 'cockpit/*')\" ]"
rm -rf "$r"

echo "test: --model pins single model, no fallback"
r="$(newrepo)"
out="$(cockpit-agent --model bad-model "$r" 'fix calc.py' 2>/dev/null)"; rc=$?
check "exit 1 when the single pinned model fails" "[ $rc -eq 1 ]"
check "RESULT status=nochanges"                   "echo \"\$out\" | grep -q 'RESULT status=nochanges'"
rm -rf "$r"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
```

Make it executable: `chmod +x tests/test_cockpit_agent.sh`

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/test_cockpit_agent.sh`
Expected: FAILures — current `cockpit-agent` reads `COCKPIT_AGENT_MODEL` (singular, no chain) and prints no `RESULT` line, so `RESULT status=ok` / `model=good-model` assertions fail.

- [ ] **Step 4: Implement the model-fallback chain + RESULT line**

In `bin/cockpit-agent`, replace the model definition. Change:

```bash
MODEL="${COCKPIT_AGENT_MODEL:-opencode/big-pickle}"
VERIFY="${COCKPIT_VERIFY:-}"   # optional command run in the worktree to auto-flag broken diffs
```

to:

```bash
# Free-only fallback chain by default; tasks try each model until one produces changes.
MODELS="${COCKPIT_AGENT_MODELS:-opencode/big-pickle opencode/deepseek-v4-flash-free}"
VERIFY="${COCKPIT_VERIFY:-}"   # optional command run in the worktree to auto-flag broken diffs
```

Change the `--model` flag handler so it pins the chain to a single model. In the flag loop, change:

```bash
    --model|-m)  MODEL="${2:?--model needs a value}";  shift 2;;
```

to:

```bash
    --model|-m)  MODELS="${2:?--model needs a value}"; shift 2;;   # pins one model (or a custom chain)
```

Replace the single-model key check:

```bash
# only nvidia/* models need the key; free opencode/* models don't
case "$MODEL" in nvidia/*) [ -n "${NVIDIA_API_KEY:-}" ] || { echo "cockpit-agent: NVIDIA_API_KEY not set (needed for $MODEL)" >&2; exit 1; };; esac
```

with a chain-aware check:

```bash
# only nvidia/* models need the key; free opencode/* models don't
case " $MODELS " in *" nvidia/"*) [ -n "${NVIDIA_API_KEY:-}" ] || { echo "cockpit-agent: NVIDIA_API_KEY not set (needed for an nvidia/* model in the chain)" >&2; exit 1; };; esac
```

Now replace the retry loop. The current block is:

```bash
log="$DONE/$ts-agent-$(basename "$repo").log"   # outside the worktree, so it isn't committed
: > "$log"
tries="${COCKPIT_AGENT_TRIES:-3}"               # the agent flakes (stalls / quits early); retry
changed=0
for ((t=1; t<=tries; t++)); do
    echo "→ attempt $t/$tries → $MODEL …"
    echo "===== attempt $t =====" >> "$log"
    git -C "$wt" reset -q --hard HEAD 2>/dev/null; git -C "$wt" clean -qfd 2>/dev/null
    ( cd "$wt" && opencode run "$task" -m "$MODEL" ) >>"$log" 2>&1 &
    pid=$!
    for ((i=0; i<TIMEOUT; i+=3)); do kill -0 "$pid" 2>/dev/null || break; sleep 3; done
    if kill -0 "$pid" 2>/dev/null; then echo "  timed out after ${TIMEOUT}s — killing (NVIDIA stall)"; kill "$pid" 2>/dev/null; fi
    if [ -n "$(git -C "$wt" status --porcelain)" ]; then changed=1; break; fi
    echo "  no changes (agent flaked)$([ $t -lt $tries ] && echo ' — retrying')"
done
```

Replace it with a model-loop wrapping the retry loop:

```bash
log="$DONE/$ts-agent-$(basename "$repo").log"   # outside the worktree, so it isn't committed
: > "$log"
tries="${COCKPIT_AGENT_TRIES:-3}"               # the agent flakes (stalls / quits early); retry
changed=0; used_model="-"
for MODEL in $MODELS; do
    case "$MODEL" in nvidia/*) [ -n "${NVIDIA_API_KEY:-}" ] || { echo "  skip $MODEL (no NVIDIA_API_KEY)"; continue; };; esac
    echo "→ model $MODEL"
    echo "===== model $MODEL =====" >> "$log"
    for ((t=1; t<=tries; t++)); do
        echo "  attempt $t/$tries …"
        git -C "$wt" reset -q --hard HEAD 2>/dev/null; git -C "$wt" clean -qfd 2>/dev/null
        ( cd "$wt" && opencode run "$task" -m "$MODEL" ) >>"$log" 2>&1 &
        pid=$!
        for ((i=0; i<TIMEOUT; i+=3)); do kill -0 "$pid" 2>/dev/null || break; sleep 3; done
        if kill -0 "$pid" 2>/dev/null; then echo "    timed out after ${TIMEOUT}s — killing"; kill "$pid" 2>/dev/null; fi
        if [ -n "$(git -C "$wt" status --porcelain)" ]; then changed=1; used_model="$MODEL"; break; fi
        echo "    no changes"
    done
    [ "$changed" = 1 ] && break
    echo "  $MODEL produced nothing — trying next model in the chain"
done
```

Now update the result section. The current no-change branch is:

```bash
if [ "$changed" = 0 ]; then
    git -C "$repo" worktree remove --force "$wt" 2>/dev/null   # nothing produced — clean up fully
    git -C "$repo" branch -D "$branch" 2>/dev/null
    echo "cockpit-agent: no changes after $tries attempts. See $log" >&2
    echo "  (the agent is intermittently flaky — retry, or fall back to: cockpit-ask + apply)" >&2
    exit 1
fi
```

Replace with (adds the `RESULT` line):

```bash
if [ "$changed" = 0 ]; then
    git -C "$repo" worktree remove --force "$wt" 2>/dev/null   # nothing produced — clean up fully
    git -C "$repo" branch -D "$branch" 2>/dev/null
    echo "RESULT status=nochanges branch=- model=- verify=none changed=-"
    echo "cockpit-agent: no changes after all models/attempts. See $log" >&2
    exit 1
fi
```

The current success block computes `verify_note` then prints the result. Find:

```bash
# optional verify (run in the worktree before we drop it) — auto-flags broken diffs
verify_note="(no --verify given)"
if [ -n "$VERIFY" ]; then
    echo "===== verify: $VERIFY =====" >> "$log"
    if ( cd "$wt" && eval "$VERIFY" ) >>"$log" 2>&1; then verify_note="✓ passed: $VERIFY"; else verify_note="✗ FAILED: $VERIFY (see log)"; fi
fi
```

Replace with (also sets a `verify_state` token + a `changed_n` count for RESULT):

```bash
# optional verify (run in the worktree before we drop it) — auto-flags broken diffs
verify_note="(no --verify given)"; verify_state="none"
if [ -n "$VERIFY" ]; then
    echo "===== verify: $VERIFY =====" >> "$log"
    if ( cd "$wt" && eval "$VERIFY" ) >>"$log" 2>&1; then verify_note="✓ passed: $VERIFY"; verify_state="ok"; else verify_note="✗ FAILED: $VERIFY (see log)"; verify_state="fail"; fi
fi
changed_n="$(git -C "$repo" diff --name-only "HEAD..$branch" | wc -l | tr -d ' ')"
```

Finally, at the very end of the script (after the existing `echo "verify: $verify_note"` and the apply/discard lines), add the machine-readable line:

```bash
echo "RESULT status=ok branch=$branch model=$used_model verify=$verify_state changed=$changed_n"
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test_cockpit_agent.sh`
Expected: `ALL PASS` (all `ok:` lines).

Also confirm no syntax regressions:
Run: `bash -n bin/cockpit-agent`
Expected: no output (exit 0).

- [ ] **Step 6: Commit**

```bash
cd ~/Desktop/claude/agent-cockpit
git add bin/cockpit-agent tests/stubs/opencode tests/test_cockpit_agent.sh
git commit -m "cockpit-agent: model-fallback chain (free-only default) + machine-readable RESULT line"
```

---

## Task 2: `cockpit-fanout` — `parse_result()` (TDD)

**Files:**
- Create: `bin/cockpit-fanout`
- Create: `tests/test_fanout.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_fanout.py`:

```python
import importlib.util, os
from importlib.machinery import SourceFileLoader
# bin/cockpit-fanout has no .py extension; on Python 3.12+ spec_from_file_location returns None
# for extensionless files, so load it via an explicit SourceFileLoader.
_path = os.path.join(os.path.dirname(__file__), "..", "bin", "cockpit-fanout")
_loader = SourceFileLoader("cockpit_fanout", _path)
cf = importlib.util.module_from_spec(importlib.util.spec_from_loader("cockpit_fanout", _loader))
_loader.exec_module(cf)


def test_parse_result_ok():
    out = "noise\nRESULT status=ok branch=cockpit/123 model=opencode/big-pickle verify=ok changed=2\nmore"
    f = cf.parse_result(out)
    assert f["status"] == "ok"
    assert f["branch"] == "cockpit/123"
    assert f["model"] == "opencode/big-pickle"
    assert f["verify"] == "ok"
    assert f["changed"] == "2"


def test_parse_result_missing_defaults_to_nochanges():
    f = cf.parse_result("no result line here")
    assert f["status"] == "nochanges"
    assert f["branch"] == "-"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 -m pytest tests/test_fanout.py -v`
Expected: FAIL — `bin/cockpit-fanout` does not exist yet (import error).

- [ ] **Step 3: Create `bin/cockpit-fanout` with `parse_result`**

Create `bin/cockpit-fanout`:

```python
#!/usr/bin/env python3
"""cockpit-fanout — run N cockpit-agent tasks concurrently and roll up a summary.

Usage: cockpit-fanout <batch.json>
batch.json: [{"repo": "...", "task": "...", "verify": "...(opt)", "model": "...(opt)"}, ...]
Env: COCKPIT_FANOUT_JOBS (default 3).
"""
import sys, os, re, json, time, subprocess
from concurrent.futures import ThreadPoolExecutor

DONE = os.path.expanduser("~/cockpit/tasks/done")
JOBS = int(os.environ.get("COCKPIT_FANOUT_JOBS", "3"))
_RESULT_RE = re.compile(r"^RESULT\s+(.*)$", re.M)


def parse_result(stdout):
    """Extract the last `RESULT key=val ...` line into a dict (defaults if absent)."""
    fields = {"status": "nochanges", "branch": "-", "model": "-", "verify": "none", "changed": "-"}
    last = None
    for last in _RESULT_RE.finditer(stdout):
        pass
    if last:
        for kv in last.group(1).split():
            if "=" in kv:
                k, v = kv.split("=", 1)
                fields[k] = v
    return fields
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 -m pytest tests/test_fanout.py -v`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**

```bash
cd ~/Desktop/claude/agent-cockpit
git add bin/cockpit-fanout tests/test_fanout.py
git commit -m "cockpit-fanout: parse_result() + tests"
```

---

## Task 3: `cockpit-fanout` — `build_summary()` (TDD)

**Files:**
- Modify: `bin/cockpit-fanout`
- Modify: `tests/test_fanout.py`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_fanout.py`:

```python
def test_build_summary_has_rows_and_status():
    results = [
        (1, "Add zod Album schema", {"status": "ok", "branch": "cockpit/a", "model": "opencode/big-pickle", "verify": "ok", "changed": "1"}),
        (2, "Add Leaflet wrapper",  {"status": "nochanges", "branch": "-", "model": "-", "verify": "none", "changed": "-"}),
    ]
    s = cf.build_summary("batch-1", 3, results)
    assert "batch batch-1" in s
    assert "Add zod Album schema" in s
    assert "cockpit/a" in s
    assert "ok" in s
    assert "nochanges" in s
    assert "merge --no-ff" in s  # merge guidance present
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 -m pytest tests/test_fanout.py::test_build_summary_has_rows_and_status -v`
Expected: FAIL — `build_summary` not defined (AttributeError).

- [ ] **Step 3: Add `build_summary` to `bin/cockpit-fanout`**

Append after `parse_result` in `bin/cockpit-fanout`:

```python
def build_summary(batch_id, jobs, results):
    """results: list of (idx, task, fields-dict). Returns a markdown summary string."""
    vmap = {"ok": "✓", "fail": "✗", "none": "-"}
    lines = [f"batch {batch_id}  ({len(results)} tasks, {jobs} concurrent)", "",
             "| # | task | branch | model | verify | changed | status |",
             "|---|------|--------|-------|--------|---------|--------|"]
    for idx, task, f in results:
        t = (task[:40] + "…") if len(task) > 41 else task
        lines.append(f"| {idx} | {t} | {f['branch']} | {f['model']} | "
                     f"{vmap.get(f['verify'], f['verify'])} | {f['changed']} | {f['status']} |")
    lines += ["", "per task — review: git -C <repo> diff HEAD..<branch>   "
              "merge: git -C <repo> merge --no-ff <branch>"]
    return "\n".join(lines)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 -m pytest tests/test_fanout.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
cd ~/Desktop/claude/agent-cockpit
git add bin/cockpit-fanout tests/test_fanout.py
git commit -m "cockpit-fanout: build_summary() + tests"
```

---

## Task 4: `cockpit-fanout` — `run_task`/`main` + concurrency integration test

**Files:**
- Modify: `bin/cockpit-fanout`
- Create: `tests/stubs/cockpit-agent`
- Create: `tests/test_fanout_integration.sh`

- [ ] **Step 1: Write the deterministic `cockpit-agent` stub**

Create `tests/stubs/cockpit-agent` (fakes a branch + emits a RESULT line; a task containing `FAIL` reports nochanges):

```bash
#!/usr/bin/env bash
# Stub cockpit-agent for fanout integration tests.
# Skips --model/--verify flags, takes <repo> <task...>; behavior keyed by task text.
while [ "${1:-}" = "--model" ] || [ "${1:-}" = "-m" ] || [ "${1:-}" = "--verify" ] || [ "${1:-}" = "-v" ]; do shift 2; done
repo="$1"; shift; task="$*"
if echo "$task" | grep -q FAIL; then
    echo "RESULT status=nochanges branch=- model=- verify=none changed=-"; exit 1
fi
br="cockpit/stub-$$-$RANDOM"
git -C "$repo" branch "$br" >/dev/null 2>&1
echo "RESULT status=ok branch=$br model=stub verify=ok changed=1"; exit 0
```

Make it executable: `chmod +x tests/stubs/cockpit-agent`

- [ ] **Step 2: Write the failing integration test**

Create `tests/test_fanout_integration.sh`:

```bash
#!/usr/bin/env bash
# Integration test: cockpit-fanout runs tasks concurrently, aggregates summary, flags failures.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$REPO_ROOT/tests/stubs:$REPO_ROOT/bin:$PATH"   # stub cockpit-agent + real cockpit-fanout
fail=0
check() { if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; fi; eval "$2" || fail=1; }

repo="$(mktemp -d)"; git -C "$repo" init -q; git -C "$repo" config user.email t@t.co; git -C "$repo" config user.name t
echo x > "$repo/x"; git -C "$repo" add -A; git -C "$repo" commit -qm init
batch="$(mktemp).json"
cat > "$batch" <<JSON
[
  {"repo": "$repo", "task": "task one ok"},
  {"repo": "$repo", "task": "task two ok"},
  {"repo": "$repo", "task": "task three FAIL"}
]
JSON

out="$(cockpit-fanout "$batch" 2>/dev/null)"; rc=$?
check "exit 1 (one task failed)" "[ $rc -eq 1 ]"
check "summary mentions 3 tasks" "echo \"\$out\" | grep -q '3 tasks'"
check "two ok statuses"          "[ \$(echo \"\$out\" | grep -c '| ok |') -eq 2 ]"
check "one nochanges/FAILED"     "echo \"\$out\" | grep -q 'nochanges'"
check "two cockpit/* branches"   "[ \$(git -C \"\$repo\" branch --list 'cockpit/*' | wc -l | tr -d ' ') -eq 2 ]"
check "summary.md written"       "ls \"\$HOME\"/cockpit/tasks/done/*/summary.md >/dev/null 2>&1"
rm -rf "$repo" "$batch"
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
```

Make it executable: `chmod +x tests/test_fanout_integration.sh`

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/test_fanout_integration.sh`
Expected: FAILures — `cockpit-fanout` has no `main`/`run_task` yet, so it produces no output and writes no summary.

- [ ] **Step 4: Add `run_task` + `main` to `bin/cockpit-fanout`**

Append to `bin/cockpit-fanout`:

```python
def run_task(idx, entry, batch_dir):
    repo = os.path.expanduser(entry["repo"])
    task = entry["task"]
    cmd = ["cockpit-agent"]
    if entry.get("model"):
        cmd += ["--model", entry["model"]]
    if entry.get("verify"):
        cmd += ["--verify", entry["verify"]]
    cmd += [repo, task]
    p = subprocess.run(cmd, capture_output=True, text=True)
    with open(os.path.join(batch_dir, f"task-{idx}.out"), "w") as f:
        f.write(p.stdout + "\n----- stderr -----\n" + p.stderr)
    return (idx, task, parse_result(p.stdout))


def main():
    if len(sys.argv) != 2:
        sys.exit('usage: cockpit-fanout <batch.json>')
    with open(os.path.expanduser(sys.argv[1])) as f:
        entries = json.load(f)
    if not isinstance(entries, list) or not entries:
        sys.exit("cockpit-fanout: batch file must be a non-empty JSON array")
    for i, e in enumerate(entries):
        if "repo" not in e or "task" not in e:
            sys.exit(f"cockpit-fanout: entry {i} missing required 'repo' or 'task'")

    batch_id = time.strftime("%Y%m%d-%H%M%S")
    batch_dir = os.path.join(DONE, batch_id)
    os.makedirs(batch_dir, exist_ok=True)
    print(f"cockpit-fanout: {len(entries)} tasks, {JOBS} concurrent → batch {batch_id}")

    results = []
    with ThreadPoolExecutor(max_workers=JOBS) as ex:
        futs = [ex.submit(run_task, i + 1, e, batch_dir) for i, e in enumerate(entries)]
        for fut in futs:
            results.append(fut.result())
    results.sort(key=lambda r: r[0])

    summary = build_summary(batch_id, JOBS, results)
    with open(os.path.join(batch_dir, "summary.md"), "w") as f:
        f.write(summary + "\n")
    print("\n" + summary)
    sys.exit(0 if all(f["status"] == "ok" for _, _, f in results) else 1)


if __name__ == "__main__":
    main()
```

Make the script executable:

```bash
chmod +x bin/cockpit-fanout
```

- [ ] **Step 5: Run the integration test to verify it passes**

Run: `bash tests/test_fanout_integration.sh`
Expected: `ALL PASS`.

Also re-run the unit tests to confirm no regression:
Run: `python3 -m pytest tests/test_fanout.py -v`
Expected: PASS (3 passed).

- [ ] **Step 6: Commit**

```bash
cd ~/Desktop/claude/agent-cockpit
git add bin/cockpit-fanout tests/stubs/cockpit-agent tests/test_fanout_integration.sh
git commit -m "cockpit-fanout: run_task + main (bounded concurrency, batch summary) + integration test"
```

---

## Task 5: Install + protocol + docs

**Files:**
- Modify: `install.sh`
- Modify: `cockpit-home/CLAUDE.md`
- Modify: `README.md`, `PLAN.md`

- [ ] **Step 1: Add `cockpit-fanout` to `install.sh`**

In `install.sh`, change the helper loop:

```bash
for b in cockpit cockpit-ask cockpit-agent cockpit-doctor cockpit-clean; do
```

to:

```bash
for b in cockpit cockpit-ask cockpit-agent cockpit-doctor cockpit-clean cockpit-fanout; do
```

- [ ] **Step 2: Run install.sh and verify the symlink**

Run:
```bash
cd ~/Desktop/claude/agent-cockpit && ./install.sh && command -v cockpit-fanout
```
Expected: prints `linked cockpit-fanout` and `command -v` resolves to `~/.local/bin/cockpit-fanout`.

- [ ] **Step 3: Add the delegation pattern to `cockpit-home/CLAUDE.md`**

After the `## Running a project` section in `cockpit-home/CLAUDE.md`, add:

````markdown
## Parallel delegation (cockpit-fanout) — the credit-saver

When a job splits into several **bounded, non-overlapping-file** tasks the free workers can do
well, fan them out instead of doing them yourself:
1. Decompose into tasks that touch **different files** (so the parallel branches merge cleanly).
2. Write a batch JSON:
   ```json
   [
     {"repo": "~/Desktop/claude/myproj", "task": "Add a zod Album schema in src/lib/schemas.ts", "verify": "npx tsc --noEmit"},
     {"repo": "~/Desktop/claude/myproj", "task": "Add a date-format util in src/lib/format.ts", "verify": "npx tsc --noEmit"}
   ]
   ```
3. Run `cockpit-fanout batch.json` (≤3 concurrent by default; `COCKPIT_FANOUT_JOBS` to change).
4. Read the printed `summary.md`, review each branch's diff, and `git -C <repo> merge --no-ff <branch>` the good ones.

**Delegate** bounded codegen / tests / boilerplate / scaffolding. **Keep** design, architecture,
and nuanced or cross-cutting edits for yourself — that's where your tokens are worth spending.
Each task uses cockpit-agent's free model-fallback chain, so a throttled model won't drop work.
````

- [ ] **Step 4: Document the capability in README.md and PLAN.md**

In `README.md`, under the `## Dispatch (from the orchestrate pane)` code block, add a line:

```sh
cockpit-fanout batch.json                           # run N agent tasks concurrently -> one summary
```

In `PLAN.md`, append to the Phase 7 / finalization area a short note:

```markdown
**Phase 7 Approach 1 — parallel delegation (2026-05-30).** `cockpit-fanout batch.json` runs N
`cockpit-agent` tasks bounded-concurrent (default 3) into `~/cockpit/tasks/done/<batch-id>/summary.md`
for review+merge. `cockpit-agent` now has a free-only model-fallback chain
(`COCKPIT_AGENT_MODELS`, default big-pickle→deepseek-v4-flash-free) + a machine-readable `RESULT` line.
Visible task panes deferred to Approach 2. Spec: `docs/superpowers/specs/2026-05-30-cockpit-parallel-delegation-design.md`.
```

- [ ] **Step 5: Commit**

```bash
cd ~/Desktop/claude/agent-cockpit
git add install.sh cockpit-home/CLAUDE.md README.md PLAN.md
git commit -m "cockpit-fanout: install symlink + delegation protocol + docs"
```

---

## Task 6: Live acceptance (manual — networked, the reality-check gate)

**Files:** none (verification only). Requires razernode/opencode free tier reachable; run `cockpit-doctor` first.

- [ ] **Step 1: Reality check — one realistic delegated task**

```bash
cd /tmp && rm -rf rc && mkdir rc && cd rc && git init -q && git config user.email t@t.co && git config user.name t
echo "# duration util" > README.md && git add -A && git commit -qm init
cockpit-agent --verify "python3 -c 'import duration; assert duration.parse_duration(\"1h30m\")==5400'" \
  /tmp/rc "Create duration.py with parse_duration(s: str) -> int converting strings like '1h30m', '45m', '90s' to total seconds. Handle h/m/s units; raise ValueError on bad input."
```
Expected: a `cockpit/*` branch, `RESULT status=ok`, and `verify=ok`. Inspect the diff:
`git -C /tmp/rc diff HEAD..$(git -C /tmp/rc branch --list 'cockpit/*' | tr -d ' *')`
**Gate:** the diff should be correct and review-worthy. If it's junk, STOP — the free workers aren't
good enough for real delegation yet; report back before relying on fan-out. Clean up: `rm -rf /tmp/rc`.

- [ ] **Step 2: Real 3-task fan-out**

```bash
cd /tmp && rm -rf fo && mkdir fo && cd fo && git init -q && git config user.email t@t.co && git config user.name t
mkdir -p src && echo "# app" > README.md && git add -A && git commit -qm init
cat > /tmp/fo-batch.json <<JSON
[
  {"repo": "/tmp/fo", "task": "Create src/slug.py with slugify(s: str) -> str (lowercase, non-alphanumeric runs -> single hyphen, trim hyphens).", "verify": "python3 -c 'import sys; sys.path.insert(0,\"src\"); import slug; assert slug.slugify(\"Hi There!\")==\"hi-there\"'"},
  {"repo": "/tmp/fo", "task": "Create src/clamp.py with clamp(n, lo, hi) returning n bounded to [lo,hi].", "verify": "python3 -c 'import sys; sys.path.insert(0,\"src\"); import clamp; assert clamp.clamp(5,0,3)==3'"},
  {"repo": "/tmp/fo", "task": "Create src/initials.py with initials(name: str) -> str (uppercase first letter of each word).", "verify": "python3 -c 'import sys; sys.path.insert(0,\"src\"); import initials; assert initials.initials(\"ada lovelace\")==\"AL\"'"}
]
JSON
cockpit-fanout /tmp/fo-batch.json
```
Expected: a `summary.md` with 3 rows; the successful tasks show `verify ✓` and a `cockpit/*` branch on different files. Merge the good ones, e.g.:
`for b in $(git -C /tmp/fo branch --list 'cockpit/*' | tr -d ' *'); do git -C /tmp/fo merge --no-ff -m "merge $b" "$b"; done`
Then confirm all three modules import and pass their asserts. Clean up: `rm -rf /tmp/fo /tmp/fo-batch.json`.

- [ ] **Step 3: Final regression + doctor**

```bash
cd ~/Desktop/claude/agent-cockpit
bash tests/test_cockpit_agent.sh && bash tests/test_fanout_integration.sh && python3 -m pytest tests/test_fanout.py -q && cockpit-doctor
```
Expected: both shell tests `ALL PASS`, pytest passes, `cockpit-doctor` → `READY ✓`.

- [ ] **Step 4: Commit any doc tweaks from acceptance**

```bash
cd ~/Desktop/claude/agent-cockpit
git add -A && git commit -m "Phase 7 Approach 1: validated parallel delegation end-to-end" --allow-empty
```

---

## Self-Review

**Spec coverage:**
- Component 1 (model auto-fallback) → Task 1. ✓
- Component 2 (RESULT line) → Task 1. ✓
- Component 3 (cockpit-fanout) → Tasks 2–4. ✓
- Component 4 (protocol update) → Task 5 Step 3. ✓
- Acceptance #1 fallback → Task 1 test. ✓
- Acceptance #2 reality check → Task 6 Step 1. ✓
- Acceptance #3 fan-out → Task 6 Step 2. ✓
- Acceptance #4 credit-saving (Claude routes/reviews, workers generate) → Task 6 Step 2 (Claude decomposes the batch + merges). ✓
- Files list (bin/cockpit-agent, bin/cockpit-fanout, cockpit-home/CLAUDE.md, install.sh, README, PLAN) → all touched. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every run step shows the exact command + expected output. ✓

**Type/name consistency:** `parse_result` returns dict keys `status/branch/model/verify/changed`; `build_summary` reads exactly those; `cockpit-agent`'s `RESULT` line emits exactly those keys; the stub `cockpit-agent` emits the same keys. `COCKPIT_AGENT_MODELS` (Task 1) matches the stub-test env var and the doc. ✓
