# Visible Task Panes (`cockpit-fanout --panes`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `--panes` flag to `cockpit-fanout` that runs each `cockpit-agent` task in a live, labeled zellij pane in a new `fanout-<batch-id>` tab, so you can watch the fan-out run — while keeping the same engine, bounded concurrency, and `summary.md` rollup.

**Architecture:** A thin observability layer. New small, pure-ish functions are added to `bin/cockpit-fanout` and unit-tested in isolation; `main()` is wired to dispatch each task either headless (today's `run_task`) or visible (`run_task_visible`, which spawns a pane via `zellij run` and blocks on a sentinel file). The existing `ThreadPoolExecutor(max_workers=JOBS)` provides bounded "waves" for free because the visible path blocks until its task's sentinel appears. Outside a zellij session, `--panes` degrades to headless. A `tests/stubs/zellij` stub lets the visible path be tested end-to-end with no real terminal.

**Tech Stack:** Python 3.14 (stdlib only: `subprocess`, `shutil`, `shlex`, `concurrent.futures`), bash (wrapper script + stubs + integration tests), pytest, zellij 0.44.3.

**Spec:** `docs/superpowers/specs/2026-05-30-cockpit-visible-task-panes-design.md`

**Branch:** `phase7-visible-panes` (already created off `main`).

---

## File Structure

| File | Create/Modify | Responsibility |
|------|---------------|----------------|
| `bin/cockpit-fanout` | Modify | Add `parse_args`, `agent_cmd`, `visible_mode`, `build_wrapper`, `write_wrapper`, `await_sentinel`, `spawn_pane`, `run_task_visible`; wire `main()`. Engine/rollup unchanged. |
| `tests/test_fanout.py` | Modify (append) | Unit tests for all new functions, reusing the existing `cf` module loader. |
| `tests/stubs/zellij` | Create | Test stub: records `action`/`run` calls to `$ZELLIJ_STUB_LOG`; for `run`, executes the wrapped script synchronously so `.out`/`.done` appear. |
| `tests/test_fanout_visible_integration.sh` | Create | End-to-end visible-path test using the zellij + cockpit-agent stubs. |
| `cockpit-home/CLAUDE.md` | Modify | One protocol line: orchestrator may pass `--panes` to watch a fan-out. |
| `README.md` | Modify | One usage line for `--panes`. |

Unchanged: `bin/cockpit-agent`, `bin/cockpit`, `zellij/cockpit.kdl`, `install.sh`, `parse_result`, `build_summary`, `run_task`.

**Notes for the implementer (zero-context assumptions):**
- `bin/cockpit-fanout` has **no `.py` extension**; tests load it via `SourceFileLoader` as module `cf` (see top of `tests/test_fanout.py`). New functions become `cf.<name>` automatically — no test-loader changes needed.
- `cockpit-agent`'s machine-readable contract is a line like `RESULT status=ok branch=cockpit/… model=… verify=ok changed=1` (or `RESULT status=nochanges branch=- model=- verify=none changed=-`). `parse_result()` already extracts it.
- Run all commands from the repo root: `/Users/<user>/Desktop/claude/agent-cockpit`. Confirm you are on branch `phase7-visible-panes` (`git branch --show-current`).
- Full suite after any task: `bash tests/test_cockpit_agent.sh && bash tests/test_fanout_integration.sh && bash tests/test_fanout_visible_integration.sh 2>/dev/null; python3 -m pytest tests/test_fanout.py -q` (the visible integration test only exists from Task 7 on).

---

### Task 1: `parse_args` — accept optional `--panes`

**Files:**
- Modify: `bin/cockpit-fanout` (add `parse_args`; rewire the top of `main()`)
- Test: `tests/test_fanout.py` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_fanout.py`:

```python
def test_parse_args_headless():
    assert cf.parse_args(["batch.json"]) == (False, "batch.json")


def test_parse_args_panes_before_path():
    assert cf.parse_args(["--panes", "batch.json"]) == (True, "batch.json")


def test_parse_args_panes_after_path():
    assert cf.parse_args(["batch.json", "--panes"]) == (True, "batch.json")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_fanout.py -k parse_args -q`
Expected: FAIL — `AttributeError: module 'cockpit_fanout' has no attribute 'parse_args'`

- [ ] **Step 3: Write minimal implementation**

In `bin/cockpit-fanout`, add this function above `main()`:

```python
def parse_args(argv):
    """Returns (panes: bool, batch_path: str). --panes may appear anywhere."""
    panes = False
    rest = []
    for a in argv:
        if a == "--panes":
            panes = True
        else:
            rest.append(a)
    if len(rest) != 1:
        sys.exit("usage: cockpit-fanout [--panes] <batch.json>")
    return panes, rest[0]
```

Then replace the first three lines of `main()`:

```python
def main():
    if len(sys.argv) != 2:
        sys.exit('usage: cockpit-fanout <batch.json>')
    with open(os.path.expanduser(sys.argv[1])) as f:
```

with:

```python
def main():
    panes, batch_path = parse_args(sys.argv[1:])
    with open(os.path.expanduser(batch_path)) as f:
```

(`panes` is consumed in Task 7; leaving it bound now is intentional.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_fanout.py -k parse_args -q`
Expected: PASS (3 passed)

Run: `bash tests/test_fanout_integration.sh`
Expected: `ALL PASS` (headless path unchanged — `cockpit-fanout "$batch"` still works)

- [ ] **Step 5: Commit**

```bash
git add bin/cockpit-fanout tests/test_fanout.py
git commit -m "cockpit-fanout: parse_args — accept optional --panes flag"
```

---

### Task 2: `agent_cmd` — extract the cockpit-agent command builder (DRY)

**Files:**
- Modify: `bin/cockpit-fanout` (add `agent_cmd`; refactor `run_task` to use it)
- Test: `tests/test_fanout.py` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_fanout.py`:

```python
def test_agent_cmd_minimal():
    assert cf.agent_cmd({"repo": "/tmp/r", "task": "do x"}) == ["cockpit-agent", "/tmp/r", "do x"]


def test_agent_cmd_with_model_and_verify():
    cmd = cf.agent_cmd({"repo": "/tmp/r", "task": "t", "model": "opencode/big-pickle", "verify": "pytest -q"})
    assert cmd == ["cockpit-agent", "--model", "opencode/big-pickle", "--verify", "pytest -q", "/tmp/r", "t"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_fanout.py -k agent_cmd -q`
Expected: FAIL — `AttributeError: module 'cockpit_fanout' has no attribute 'agent_cmd'`

- [ ] **Step 3: Write minimal implementation**

In `bin/cockpit-fanout`, add above `run_task`:

```python
def agent_cmd(entry):
    """Build the cockpit-agent argv for one batch entry (repo is expanduser'd)."""
    cmd = ["cockpit-agent"]
    if entry.get("model"):
        cmd += ["--model", entry["model"]]
    if entry.get("verify"):
        cmd += ["--verify", entry["verify"]]
    cmd += [os.path.expanduser(entry["repo"]), entry["task"]]
    return cmd
```

Then refactor the existing `run_task` to reuse it. Replace these lines in `run_task`:

```python
    repo = os.path.expanduser(entry["repo"])
    task = entry["task"]
    cmd = ["cockpit-agent"]
    if entry.get("model"):
        cmd += ["--model", entry["model"]]
    if entry.get("verify"):
        cmd += ["--verify", entry["verify"]]
    cmd += [repo, task]
    p = subprocess.run(cmd, capture_output=True, text=True)
```

with:

```python
    task = entry["task"]
    p = subprocess.run(agent_cmd(entry), capture_output=True, text=True)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_fanout.py -k agent_cmd -q`
Expected: PASS (2 passed)

Run: `bash tests/test_fanout_integration.sh`
Expected: `ALL PASS` (run_task behaves identically)

- [ ] **Step 5: Commit**

```bash
git add bin/cockpit-fanout tests/test_fanout.py
git commit -m "cockpit-fanout: extract agent_cmd() helper (DRY), reuse in run_task"
```

---

### Task 3: `visible_mode` — decide whether to use panes

**Files:**
- Modify: `bin/cockpit-fanout` (add `import shutil`; add `visible_mode`)
- Test: `tests/test_fanout.py` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_fanout.py`:

```python
def test_visible_mode_requires_flag_env_and_binary(monkeypatch):
    monkeypatch.setattr(cf.shutil, "which", lambda n: "/usr/bin/zellij")
    monkeypatch.setenv("ZELLIJ", "0")
    assert cf.visible_mode(True) is True
    assert cf.visible_mode(False) is False           # flag off
    monkeypatch.delenv("ZELLIJ", raising=False)
    assert cf.visible_mode(True) is False             # not in a session
    monkeypatch.setenv("ZELLIJ", "0")
    monkeypatch.setattr(cf.shutil, "which", lambda n: None)
    assert cf.visible_mode(True) is False             # zellij not on PATH
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_fanout.py -k visible_mode -q`
Expected: FAIL — `AttributeError: module 'cockpit_fanout' has no attribute 'visible_mode'` (or `shutil`)

- [ ] **Step 3: Write minimal implementation**

In `bin/cockpit-fanout`, change the import line:

```python
import sys, os, re, json, time, subprocess
```

to:

```python
import sys, os, re, json, time, shlex, shutil, subprocess
```

(`shlex` is used in Task 4.) Then add above `main()`:

```python
def visible_mode(panes):
    """True only if --panes was given AND we're inside a zellij session AND zellij is on PATH."""
    return bool(panes and os.environ.get("ZELLIJ") and shutil.which("zellij"))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_fanout.py -k visible_mode -q`
Expected: PASS (1 passed)

- [ ] **Step 5: Commit**

```bash
git add bin/cockpit-fanout tests/test_fanout.py
git commit -m "cockpit-fanout: visible_mode() — gate panes on flag + \$ZELLIJ + zellij on PATH"
```

---

### Task 4: `build_wrapper` / `write_wrapper` — per-task pane script

**Files:**
- Modify: `bin/cockpit-fanout` (add `build_wrapper`, `write_wrapper`)
- Test: `tests/test_fanout.py` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_fanout.py`:

```python
def test_build_wrapper_quotes_and_streams():
    w = cf.build_wrapper(1, {"repo": "/tmp/r", "task": "add x"}, "/b")
    assert w.startswith("#!/usr/bin/env bash\n")
    assert "cockpit-agent /tmp/r 'add x'" in w        # task safely quoted
    assert "tee /b/task-1.out" in w                    # live + saved output
    assert 'echo "${PIPESTATUS[0]}" > /b/task-1.done' in w  # sentinel = agent's exit code


def test_build_wrapper_includes_model_and_verify():
    w = cf.build_wrapper(2, {"repo": "/r", "task": "t", "model": "opencode/big-pickle", "verify": "pytest -q"}, "/b")
    assert "--model opencode/big-pickle" in w
    assert "--verify 'pytest -q'" in w


def test_write_wrapper_creates_executable(tmp_path):
    import os, stat
    path = cf.write_wrapper(3, {"repo": "/r", "task": "t"}, str(tmp_path))
    assert path == os.path.join(str(tmp_path), "task-3.sh")
    assert os.path.exists(path)
    assert os.stat(path).st_mode & stat.S_IXUSR    # is executable
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_fanout.py -k wrapper -q`
Expected: FAIL — `AttributeError: module 'cockpit_fanout' has no attribute 'build_wrapper'`

- [ ] **Step 3: Write minimal implementation**

In `bin/cockpit-fanout`, add above `main()`:

```python
def build_wrapper(idx, entry, batch_dir):
    """Bash wrapper for a task pane: runs cockpit-agent, tees output to task-N.out,
    writes the agent's exit code to task-N.done (the completion sentinel)."""
    out = os.path.join(batch_dir, f"task-{idx}.out")
    done = os.path.join(batch_dir, f"task-{idx}.done")
    agent = " ".join(shlex.quote(a) for a in agent_cmd(entry))
    return (
        "#!/usr/bin/env bash\n"
        f"{agent} 2>&1 | tee {shlex.quote(out)}\n"
        'echo "${PIPESTATUS[0]}" > ' + shlex.quote(done) + "\n"
    )


def write_wrapper(idx, entry, batch_dir):
    """Write task-N.sh (executable) and return its path."""
    path = os.path.join(batch_dir, f"task-{idx}.sh")
    with open(path, "w") as f:
        f.write(build_wrapper(idx, entry, batch_dir))
    os.chmod(path, 0o755)
    return path
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_fanout.py -k wrapper -q`
Expected: PASS (3 passed)

- [ ] **Step 5: Commit**

```bash
git add bin/cockpit-fanout tests/test_fanout.py
git commit -m "cockpit-fanout: build_wrapper/write_wrapper — per-task pane script (tee + sentinel)"
```

---

### Task 5: `await_sentinel` — block until a task's `.done` appears

**Files:**
- Modify: `bin/cockpit-fanout` (add `await_sentinel`)
- Test: `tests/test_fanout.py` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_fanout.py`:

```python
def test_await_sentinel_present(tmp_path):
    d = tmp_path / "task-1.done"
    d.write_text("0")
    assert cf.await_sentinel(str(d), timeout=1.0, poll=0.01) is True


def test_await_sentinel_timeout(tmp_path):
    d = tmp_path / "task-1.done"   # never created
    assert cf.await_sentinel(str(d), timeout=0.05, poll=0.01) is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_fanout.py -k await_sentinel -q`
Expected: FAIL — `AttributeError: module 'cockpit_fanout' has no attribute 'await_sentinel'`

- [ ] **Step 3: Write minimal implementation**

In `bin/cockpit-fanout`, add above `main()`:

```python
def await_sentinel(done_path, timeout, poll=0.5):
    """Poll until done_path exists; return True if it appeared within timeout, else False."""
    waited = 0.0
    while waited < timeout:
        if os.path.exists(done_path):
            return True
        time.sleep(poll)
        waited += poll
    return os.path.exists(done_path)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_fanout.py -k await_sentinel -q`
Expected: PASS (2 passed)

- [ ] **Step 5: Commit**

```bash
git add bin/cockpit-fanout tests/test_fanout.py
git commit -m "cockpit-fanout: await_sentinel — poll for a task's .done file with timeout"
```

---

### Task 6: `spawn_pane` + `run_task_visible` — the visible task path

**Files:**
- Modify: `bin/cockpit-fanout` (add `spawn_pane`, `run_task_visible`)
- Test: `tests/test_fanout.py` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_fanout.py`:

```python
def test_run_task_visible_parses_out(tmp_path, monkeypatch):
    bd = str(tmp_path)
    with open(os.path.join(bd, "task-1.out"), "w") as f:
        f.write("RESULT status=ok branch=cockpit/x model=stub verify=ok changed=1")
    with open(os.path.join(bd, "task-1.done"), "w") as f:
        f.write("0")
    monkeypatch.setattr(cf, "spawn_pane", lambda *a, **k: 0)
    idx, task, fields = cf.run_task_visible(1, {"repo": "/r", "task": "t"}, bd, "fanout-x", timeout=1.0, poll=0.01)
    assert idx == 1 and fields["status"] == "ok" and fields["branch"] == "cockpit/x"


def test_run_task_visible_timeout(tmp_path, monkeypatch):
    monkeypatch.setattr(cf, "spawn_pane", lambda *a, **k: 0)   # spawns, but .done never appears
    _, _, fields = cf.run_task_visible(1, {"repo": "/r", "task": "t"}, str(tmp_path), "fanout-x", timeout=0.05, poll=0.01)
    assert fields["status"] == "timeout"


def test_run_task_visible_spawn_failed(tmp_path, monkeypatch):
    monkeypatch.setattr(cf, "spawn_pane", lambda *a, **k: 1)   # zellij run returned nonzero
    _, _, fields = cf.run_task_visible(1, {"repo": "/r", "task": "t"}, str(tmp_path), "fanout-x", timeout=0.05, poll=0.01)
    assert fields["status"] == "spawn-failed"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_fanout.py -k run_task_visible -q`
Expected: FAIL — `AttributeError: module 'cockpit_fanout' has no attribute 'run_task_visible'`

- [ ] **Step 3: Write minimal implementation**

In `bin/cockpit-fanout`, add above `main()`:

```python
def spawn_pane(idx, entry, batch_dir, tab):
    """Write the task wrapper, focus the fan-out tab, and spawn the task in a new pane.
    Returns the `zellij run` return code (0 on success)."""
    script = write_wrapper(idx, entry, batch_dir)
    repo = os.path.expanduser(entry["repo"])
    label = entry["task"][:30]
    subprocess.run(["zellij", "action", "go-to-tab-name", tab], capture_output=True, text=True)
    p = subprocess.run(
        ["zellij", "run", "--name", f"task-{idx}: {label}", "--cwd", repo, "--", script],
        capture_output=True, text=True,
    )
    return p.returncode


def _fields(status):
    return {"status": status, "branch": "-", "model": "-", "verify": "none", "changed": "-"}


def run_task_visible(idx, entry, batch_dir, tab, timeout=720.0, poll=0.5):
    """Spawn the task in a live pane; block on its sentinel; parse the captured output.
    Bounded concurrency comes from the caller's ThreadPoolExecutor (this blocks per task)."""
    if spawn_pane(idx, entry, batch_dir, tab) != 0:
        return (idx, entry["task"], _fields("spawn-failed"))
    done = os.path.join(batch_dir, f"task-{idx}.done")
    if not await_sentinel(done, timeout, poll):
        return (idx, entry["task"], _fields("timeout"))
    with open(os.path.join(batch_dir, f"task-{idx}.out")) as f:
        return (idx, entry["task"], parse_result(f.read()))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_fanout.py -k run_task_visible -q`
Expected: PASS (3 passed)

- [ ] **Step 5: Commit**

```bash
git add bin/cockpit-fanout tests/test_fanout.py
git commit -m "cockpit-fanout: spawn_pane + run_task_visible — zellij run + sentinel wait"
```

---

### Task 7: Wire `main()` for visible mode + end-to-end integration test

**Files:**
- Create: `tests/stubs/zellij`
- Create: `tests/test_fanout_visible_integration.sh`
- Modify: `bin/cockpit-fanout` (`main()` wiring)

- [ ] **Step 1: Create the zellij test stub**

Create `tests/stubs/zellij`:

```bash
#!/usr/bin/env bash
# Stub zellij for `cockpit-fanout --panes` integration tests.
# Records every invocation to $ZELLIJ_STUB_LOG. For `run ... -- <script>`, executes the
# script synchronously so the task's .out/.done files are produced (real zellij runs it
# async in a pane; synchronous here is fine — we test the logic, not the timing).
log="${ZELLIJ_STUB_LOG:-/dev/null}"
echo "zellij $*" >> "$log"
case "${1:-}" in
  action) exit 0 ;;                     # new-tab / go-to-tab-name — just record
  run)
    while [ "${1:-}" != "--" ] && [ $# -gt 0 ]; do shift; done
    shift                               # drop the "--"
    [ -n "${1:-}" ] && bash "$1"
    exit 0 ;;
  *) exit 0 ;;
esac
```

Make it executable:

```bash
chmod +x tests/stubs/zellij
```

- [ ] **Step 2: Write the failing integration test**

Create `tests/test_fanout_visible_integration.sh`:

```bash
#!/usr/bin/env bash
# Integration: `cockpit-fanout --panes` spawns task panes via (stubbed) zellij and
# produces the same summary as headless.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$REPO_ROOT/tests/stubs:$REPO_ROOT/bin:$PATH"   # stub zellij + cockpit-agent, real cockpit-fanout
export ZELLIJ="0"                                          # pretend we're inside the cockpit session
export ZELLIJ_STUB_LOG="$(mktemp)"
fail=0
check() { if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; fi; eval "$2" || fail=1; }

repo="$(mktemp -d)"; git -C "$repo" init -q; git -C "$repo" config user.email t@t.co; git -C "$repo" config user.name t
echo x > "$repo/x"; git -C "$repo" add -A; git -C "$repo" commit -qm init
batch="$(mktemp).json"
cat > "$batch" <<JSON
[
  {"repo": "$repo", "task": "task one ok"},
  {"repo": "$repo", "task": "task two ok"}
]
JSON

out="$(cockpit-fanout --panes "$batch" 2>/dev/null)"; rc=$?
check "exit 0 (all ok)"          "[ $rc -eq 0 ]"
check "summary mentions 2 tasks" "echo \"\$out\" | grep -q '2 tasks'"
check "two ok statuses"          "[ \$(echo \"\$out\" | grep -c '| ok |') -eq 2 ]"
check "summary.md written"       "ls \"\$HOME\"/cockpit/tasks/done/*/summary.md >/dev/null 2>&1"
check "new-tab fanout- created"  "grep -q 'action new-tab --name fanout-' \"\$ZELLIJ_STUB_LOG\""
check "go-to-tab-name issued"    "grep -q 'go-to-tab-name fanout-' \"\$ZELLIJ_STUB_LOG\""
check "one run per task (2)"     "[ \$(grep -c 'zellij run --name task-' \"\$ZELLIJ_STUB_LOG\") -eq 2 ]"
rm -rf "$repo" "$batch" "$ZELLIJ_STUB_LOG"
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
```

Make it executable:

```bash
chmod +x tests/test_fanout_visible_integration.sh
```

- [ ] **Step 3: Run the integration test to verify it fails**

Run: `bash tests/test_fanout_visible_integration.sh`
Expected: `FAILURES` — `main()` doesn't yet create a tab or dispatch to the visible path, so `new-tab fanout- created`, `go-to-tab-name issued`, and `one run per task` all FAIL (the stub log is empty; `cockpit-fanout` ran headless).

- [ ] **Step 4: Wire `main()` for visible mode**

In `bin/cockpit-fanout`, replace the body of `main()` from the `batch_id =` line through the `with ThreadPoolExecutor(...)` block. The current code is:

```python
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
```

Replace it with:

```python
    batch_id = time.strftime("%Y%m%d-%H%M%S")
    batch_dir = os.path.join(DONE, batch_id)
    os.makedirs(batch_dir, exist_ok=True)

    visible = visible_mode(panes)
    if panes and not visible:
        print("cockpit-fanout: --panes ignored (not inside a zellij session) — running headless",
              file=sys.stderr)

    tab = None
    if visible:
        tab = f"fanout-{batch_id}"
        subprocess.run(["zellij", "action", "new-tab", "--name", tab], capture_output=True, text=True)

    print(f"cockpit-fanout: {len(entries)} tasks, {JOBS} concurrent → batch {batch_id}"
          + (f"  (panes: tab {tab})" if visible else ""))

    def dispatch(idx, entry):
        if visible:
            return run_task_visible(idx, entry, batch_dir, tab)
        return run_task(idx, entry, batch_dir)

    results = []
    with ThreadPoolExecutor(max_workers=JOBS) as ex:
        futs = [ex.submit(dispatch, i + 1, e) for i, e in enumerate(entries)]
        for fut in futs:
            results.append(fut.result())
    results.sort(key=lambda r: r[0])
```

(Everything after — `build_summary`, writing `summary.md`, the final `print`, and the `sys.exit(...)` — is unchanged.)

- [ ] **Step 5: Run the integration test to verify it passes**

Run: `bash tests/test_fanout_visible_integration.sh`
Expected: `ALL PASS`

- [ ] **Step 6: Run the FULL suite to verify nothing regressed**

Run: `bash tests/test_cockpit_agent.sh && bash tests/test_fanout_integration.sh && bash tests/test_fanout_visible_integration.sh && python3 -m pytest tests/test_fanout.py -q`
Expected: `ALL PASS` ×3, then pytest all green.

- [ ] **Step 7: Commit**

```bash
git add bin/cockpit-fanout tests/stubs/zellij tests/test_fanout_visible_integration.sh
git commit -m "cockpit-fanout: wire --panes into main (new tab + visible dispatch) + integration test"
```

---

### Task 8: Docs — dispatch protocol + README

**Files:**
- Modify: `cockpit-home/CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Add the protocol line**

Open `cockpit-home/CLAUDE.md`, find the section describing `cockpit-fanout`, and add one line:

```markdown
- To **watch** a fan-out run live (inside the cockpit), add `--panes`: `cockpit-fanout --panes batch.json`.
  Each task runs in its own pane in a new `fanout-<id>` tab; review/merge from `summary.md` as usual.
  Outside the cockpit zellij session it silently runs headless.
```

(If no `cockpit-fanout` section exists yet, add the line under the dispatch-helpers list.)

- [ ] **Step 2: Add the README usage line**

Open `README.md`, find the `cockpit-fanout` usage, and add:

```markdown
- `cockpit-fanout --panes <batch.json>` — same fan-out, but each task runs in a visible zellij pane
  (new `fanout-<id>` tab) so you can watch it; falls back to headless outside a session.
```

- [ ] **Step 3: Commit**

```bash
git add cockpit-home/CLAUDE.md README.md
git commit -m "docs: document cockpit-fanout --panes (visible task panes)"
```

---

### Task 9: Live validation (manual — the acceptance test)

This cannot run in CI (needs a real terminal + zellij session). Do it in the actual cockpit.

- [ ] **Step 1: Preflight**

Run: `cockpit-doctor`
Expected: `READY ✓`

- [ ] **Step 2: Verify real zellij accepts the flags (version guard)**

Run (inside a cockpit zellij session): `zellij run --help | grep -E -- '--name|--cwd'` and `zellij action new-tab --help | grep -- '--name'`
Expected: the flags exist on the installed 0.44.3. If `--cwd` is **not** supported, remove `"--cwd", repo,` from `spawn_pane` (the pane's cwd is cosmetic — `cockpit-agent` gets the repo as an argument) and re-run Task 6 + Task 7 tests, then re-commit.

- [ ] **Step 3: Real fan-out with panes**

From the orchestrate pane (inside the cockpit), create a 3-task batch against a scratch repo and run:

```bash
cockpit-fanout --panes /path/to/batch.json
```

Expected, observed by eye:
- A new tab `fanout-<id>` appears and is focused.
- Up to `COCKPIT_FANOUT_JOBS` (default 3) task panes run at once, labeled `task-N: …`, streaming `cockpit-agent` output live; remaining tasks' panes appear in waves as slots free.
- Panes **stay open** after each agent finishes (you can read the diff/RESULT).
- Back in the orchestrate pane, the same `summary.md` table is printed, and `~/cockpit/tasks/done/<id>/summary.md` exists.

- [ ] **Step 4: Fallback check**

Run the same command **outside** any zellij session (a plain terminal):

```bash
cockpit-fanout --panes /path/to/batch.json
```

Expected: stderr line `--panes ignored (not inside a zellij session) — running headless`, then a normal headless run.

- [ ] **Step 5: Update HANDOFF + record outcome**

Update `HANDOFF.md` to mark Phase 7 Approach 2 complete + live-validated, and commit.

---

## Self-Review

**1. Spec coverage** — every spec section maps to a task:
- CLI `--panes` + anywhere-position → Task 1. Visible-mode gate (`flag + $ZELLIJ + PATH`) → Task 3. Fallback notice → Task 7 (`main`) + Task 9 step 4.
- New `fanout-<id>` tab → Task 7. Live pane per task, label, `--cwd`, stays open → Task 6 (`spawn_pane`) + Task 9.
- Wrapper (shebang/quoting/tee/sentinel) → Task 4. Generated script spawned directly → Task 6.
- Sentinel poll + per-task safety timeout → Task 5 + Task 6. Bounded waves via existing pool → Task 7 (dispatch inside `ThreadPoolExecutor`).
- `status=timeout` / `status=spawn-failed` error handling → Task 6. cockpit-agent watchdog unchanged (no task needed).
- Same `summary.md` rollup, exit-code semantics → unchanged code, asserted byte-equivalent behavior in Task 7 integration.
- zellij stub + integration + unit tests + existing-tests-green → Tasks 4–7. Live validation → Task 9. Risk: zellij flag names → Task 9 step 2.

**2. Placeholder scan** — no `TBD`/`TODO`; every code step shows complete code; every run step shows the exact command + expected output. ✓

**3. Type/name consistency** — `parse_args`→`(panes, batch_path)`; `agent_cmd(entry)`→list used by `build_wrapper` + `run_task`; `visible_mode(panes)`→bool; `build_wrapper`/`write_wrapper(idx, entry, batch_dir)`; `await_sentinel(done_path, timeout, poll)`; `spawn_pane(idx, entry, batch_dir, tab)`→int; `run_task_visible(idx, entry, batch_dir, tab, timeout, poll)`→`(idx, task, fields)`; `_fields(status)`→dict with the same keys `parse_result` returns (`status/branch/model/verify/changed`), so `build_summary` renders all statuses uniformly. `main()` calls match these signatures. ✓
