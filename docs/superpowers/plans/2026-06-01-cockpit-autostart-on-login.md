# Autostart Cockpit on Login — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** At login, an opt-in per-user LaunchAgent opens a WezTerm window fullscreen on the LG SDQHD running `cockpit`, with a main-display fallback, idempotency, and one-command install/uninstall.

**Architecture:** A `RunAtLoad` LaunchAgent runs a login-shell wrapper (`cockpit-autostart-run`) so the interactive PATH reaches wezterm → zellij → panes; the wrapper launches WezTerm with a dedicated `wezterm/cockpit.lua` whose `gui-startup` event places the window on the `LG SDQHD` screen (via `wezterm.gui.screens()`) + non-native fullscreen, then runs `cockpit`. A `cockpit-autostart` helper generates the plist and loads/unloads it. Testability hooks (`COCKPIT_AUTOSTART_PLIST`, `COCKPIT_AUTOSTART_NO_LOAD`, `COCKPIT_AUTOSTART_FORCE_RUNNING`) let the plist generation and the idempotency guard be tested without touching real launchd or launching a GUI.

**Tech Stack:** macOS launchd (LaunchAgent plist), WezTerm 20240203 Lua config, bash + zsh, `launchctl`, `plutil`.

**Spec:** `docs/superpowers/specs/2026-06-01-cockpit-autostart-on-login-design.md`

**Branch:** `phase6-autostart` (already created off `main`).

---

## File Structure

| File | Create/Modify | Responsibility |
|------|---------------|----------------|
| `wezterm/cockpit.lua` | Create | WezTerm config: place window on `LG SDQHD` (or fallback) + non-native fullscreen, launch `cockpit`. |
| `bin/cockpit-autostart-run` | Create | Login-shell wrapper the LaunchAgent runs: PATH for panes + idempotency guard, then `exec wezterm`. |
| `bin/cockpit-autostart` | Create | `install` / `uninstall` / `status`: generate the plist + load/unload via `launchctl`. |
| `tests/stubs/wezterm` | Create | Test stub: records args to `$WEZTERM_STUB_MARKER` instead of launching a GUI. |
| `tests/test_autostart.sh` | Create | Bash check-runner: cockpit.lua parses, wrapper guard (launch/skip), plist install/uninstall, install.sh symlinks. |
| `install.sh` | Modify | Add the two new helpers to the symlink loop; print a hint to run `cockpit-autostart install`. |

Unchanged: `bin/cockpit`, `bin/cockpit-fanout`, `bin/cockpit-agent`, `zellij/cockpit.kdl`, all existing tests.

**Notes for the implementer (zero-context assumptions):**
- Run everything from the repo root `/Users/<user>/Desktop/claude/agent-cockpit`. Confirm you are on branch `phase6-autostart` (`git branch --show-current`).
- `cockpit` lives at `~/.local/bin/cockpit` (symlinked by `install.sh`); `wezterm` at `/opt/homebrew/bin/wezterm`.
- The target display's WezTerm screen name is exactly `LG SDQHD`. `wezterm.gui.screens()` returns `{ main, active, by_name = { [name]=screen }, ... }` and each screen has `.x/.y/.width/.height`.
- launchd hands processes a minimal PATH — that's why the wrapper is a **login shell** (`#!/bin/zsh -l`). Tests invoke the wrapper as `zsh <path>` (which bypasses the `-l` so the stub `wezterm` on the test PATH is used).
- Run the autostart test after any task: `bash tests/test_autostart.sh`.

---

### Task 1: `wezterm/cockpit.lua` — placement config

**Files:**
- Create: `tests/test_autostart.sh`
- Create: `wezterm/cockpit.lua`

- [ ] **Step 1: Write the failing test**

Create `tests/test_autostart.sh`:

```bash
#!/usr/bin/env bash
# Autostart helpers: cockpit.lua parses, wrapper guard, plist install/uninstall, install.sh symlinks.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$REPO/bin:$PATH"     # cockpit-autostart* resolve from the repo; real wezterm stays on PATH
LUA="$REPO/wezterm/cockpit.lua"
fail=0
check() { if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; fi; eval "$2" || fail=1; }

# --- Task 1: cockpit.lua parses under real wezterm ---
check "cockpit.lua present + loads w/o error" "[ -f '$LUA' ] && ! { wezterm --config-file '$LUA' ls-fonts 2>&1 >/dev/null | grep -q ERROR; }"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
```

Make it executable: `chmod +x tests/test_autostart.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_autostart.sh`
Expected: `FAILURES` — the check FAILs via the `[ -f ]` gate (`cockpit.lua` doesn't exist yet). NB: `wezterm --config-file <missing> ls-fonts` exits 0 (it warns + falls back to defaults), so the check gates on file existence and greps stderr for `ERROR` instead of trusting the exit code.

- [ ] **Step 3: Write minimal implementation**

Create `wezterm/cockpit.lua`:

```lua
local wezterm = require 'wezterm'
local mux = wezterm.mux
local config = wezterm.config_builder()

-- Non-native fullscreen fills the chosen monitor without creating a separate macOS Space,
-- which is what makes pinning the cockpit to a specific display reliable.
config.native_macos_fullscreen_mode = false

local TARGET = 'LG SDQHD'

wezterm.on('gui-startup', function()
  local screens = wezterm.gui.screens()
  local target = screens.by_name[TARGET] or screens.active or screens.main
  local _, _, window = mux.spawn_window { args = { os.getenv('HOME') .. '/.local/bin/cockpit' } }
  local gui = window:gui_window()
  gui:set_position(target.x, target.y)
  gui:toggle_fullscreen()
end)

return config
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_autostart.sh`
Expected: `ALL PASS` (file exists and wezterm loads it with no `ERROR` on stderr; `gui-startup`/`screens()` aren't evaluated without a GUI, so this is a parse/load check).

- [ ] **Step 5: Commit**

```bash
git add wezterm/cockpit.lua tests/test_autostart.sh
git commit -m "cockpit autostart: wezterm/cockpit.lua — place on LG SDQHD + fullscreen, run cockpit"
```

---

### Task 2: `cockpit-autostart-run` — login-shell wrapper + idempotency

**Files:**
- Create: `tests/stubs/wezterm`
- Modify: `tests/test_autostart.sh`
- Create: `bin/cockpit-autostart-run`

- [ ] **Step 1: Write the failing test**

Create `tests/stubs/wezterm`:

```bash
#!/usr/bin/env bash
# Stub wezterm for autostart tests: record args instead of launching a GUI.
echo "wezterm $*" >> "${WEZTERM_STUB_MARKER:-/dev/null}"
exit 0
```

Make it executable: `chmod +x tests/stubs/wezterm`

Then add this block to `tests/test_autostart.sh` immediately before the final `[ $fail -eq 0 ]` line:

```bash
# --- Task 2: wrapper launches when not running, skips when already running ---
# Run the wrapper as `zsh <path>` so the `#!/bin/zsh -l` is bypassed and the stub wezterm
# on the prepended PATH is used (a login shell would re-source the profile and find real wezterm).
marker="$(mktemp)"; : > "$marker"
PATH="$REPO/tests/stubs:$PATH" WEZTERM_STUB_MARKER="$marker" COCKPIT_AUTOSTART_FORCE_RUNNING=0 \
    zsh "$REPO/bin/cockpit-autostart-run" "$LUA"
check "wrapper launches wezterm when not running" "[ -s '$marker' ]"
check "wrapper passes --config-file"               "grep -q -- '--config-file' '$marker'"
: > "$marker"
PATH="$REPO/tests/stubs:$PATH" WEZTERM_STUB_MARKER="$marker" COCKPIT_AUTOSTART_FORCE_RUNNING=1 \
    zsh "$REPO/bin/cockpit-autostart-run" "$LUA"
check "wrapper skips when already running"          "[ ! -s '$marker' ]"
rm -f "$marker"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_autostart.sh`
Expected: `FAILURES` — the three wrapper checks FAIL (`bin/cockpit-autostart-run` does not exist yet, so `zsh` can't run it and the marker stays empty / the launch check fails).

- [ ] **Step 3: Write minimal implementation**

Create `bin/cockpit-autostart-run`:

```zsh
#!/bin/zsh -l
# LaunchAgent wrapper, run at login. $1 = absolute path to the cockpit WezTerm config.
#
# Login shell (-l) so the interactive PATH (Homebrew, ~/.local/bin) flows down to
# wezterm -> cockpit -> the zellij server -> every pane. launchd's own PATH is minimal,
# which would otherwise leave the worker panes unable to find opencode/claude.
#
# Idempotent: if a cockpit WezTerm is already running, do nothing (no duplicate window).
# COCKPIT_AUTOSTART_FORCE_RUNNING=1/0 overrides the detection (used by tests).

running="${COCKPIT_AUTOSTART_FORCE_RUNNING:-}"
if [[ -z "$running" ]]; then
  if pgrep -f 'wezterm --config-file.*cockpit\.lua' >/dev/null 2>&1; then running=1; else running=0; fi
fi
[[ "$running" == 1 ]] && exit 0

exec wezterm --config-file "$1" start
```

Make it executable: `chmod +x bin/cockpit-autostart-run`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_autostart.sh`
Expected: `ALL PASS` (launch writes the marker incl. `--config-file`; skip leaves it empty).

- [ ] **Step 5: Commit**

```bash
git add bin/cockpit-autostart-run tests/stubs/wezterm tests/test_autostart.sh
git commit -m "cockpit autostart: cockpit-autostart-run wrapper (login-shell PATH + idempotency)"
```

---

### Task 3: `cockpit-autostart` — generate plist, install/uninstall/status

**Files:**
- Modify: `tests/test_autostart.sh`
- Create: `bin/cockpit-autostart`

- [ ] **Step 1: Write the failing test**

Add this block to `tests/test_autostart.sh` immediately before the final `[ $fail -eq 0 ]` line:

```bash
# --- Task 3: install generates a valid plist; uninstall removes it (no real launchctl) ---
plist="$(mktemp -t cockpit-autostart-XXXX).plist"; rm -f "$plist"
COCKPIT_AUTOSTART_PLIST="$plist" COCKPIT_AUTOSTART_NO_LOAD=1 cockpit-autostart install >/dev/null
check "install wrote a plist"        "[ -f '$plist' ]"
check "plist is valid"               "plutil -lint '$plist' >/dev/null"
check "plist has RunAtLoad"          "grep -q RunAtLoad '$plist'"
check "plist references the runner"  "grep -q 'bin/cockpit-autostart-run' '$plist'"
check "plist references cockpit.lua" "grep -q 'wezterm/cockpit.lua' '$plist'"
COCKPIT_AUTOSTART_PLIST="$plist" COCKPIT_AUTOSTART_NO_LOAD=1 cockpit-autostart uninstall >/dev/null
check "uninstall removed the plist"  "[ ! -f '$plist' ]"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_autostart.sh`
Expected: `FAILURES` — the Task 3 checks FAIL (`cockpit-autostart` does not exist; `command not found`, no plist written).

- [ ] **Step 3: Write minimal implementation**

Create `bin/cockpit-autostart`:

```bash
#!/usr/bin/env bash
# cockpit-autostart — enable/disable login autostart of the cockpit (a per-user LaunchAgent).
#   install    write the plist + load it (cockpit opens fullscreen at login)
#   uninstall  unload + remove it
#   status     show whether it's loaded
# Test hooks: COCKPIT_AUTOSTART_PLIST overrides the plist path; COCKPIT_AUTOSTART_NO_LOAD skips launchctl.
set -uo pipefail

# Resolve the repo root even when invoked via the ~/.local/bin symlink.
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
REPO="$(cd -P "$(dirname "$src")/.." && pwd)"

UID_NUM="$(id -u)"
LABEL="com.$(id -un).cockpit"
PLIST="${COCKPIT_AUTOSTART_PLIST:-$HOME/Library/LaunchAgents/${LABEL}.plist}"
RUNNER="$REPO/bin/cockpit-autostart-run"
LUA="$REPO/wezterm/cockpit.lua"
LOG="$HOME/cockpit/autostart.log"

write_plist() {
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RUNNER}</string>
    <string>${LUA}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${LOG}</string>
  <key>StandardErrorPath</key><string>${LOG}</string>
</dict>
</plist>
PLIST
    plutil -lint "$PLIST" >/dev/null
}

case "${1:-}" in
  install)
    write_plist
    echo "wrote $PLIST"
    [ -n "${COCKPIT_AUTOSTART_NO_LOAD:-}" ] && { echo "(skipped load)"; exit 0; }
    launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null
    launchctl bootstrap "gui/${UID_NUM}" "$PLIST" 2>/dev/null || launchctl load "$PLIST"
    echo "loaded ${LABEL} — opens at login; test now with: launchctl kickstart -k gui/${UID_NUM}/${LABEL}"
    ;;
  uninstall)
    [ -z "${COCKPIT_AUTOSTART_NO_LOAD:-}" ] && \
        { launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null; }
    rm -f "$PLIST"
    echo "removed ${LABEL}"
    ;;
  status)
    if launchctl print "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1; then echo "${LABEL}: loaded"
    elif [ -f "$PLIST" ]; then echo "${LABEL}: plist present, not loaded ($PLIST)"
    else echo "${LABEL}: not installed"; fi
    ;;
  *) echo "usage: cockpit-autostart {install|uninstall|status}" >&2; exit 2 ;;
esac
```

Make it executable: `chmod +x bin/cockpit-autostart`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_autostart.sh`
Expected: `ALL PASS` (plist written + `plutil`-valid with RunAtLoad + both paths; uninstall removes it).

- [ ] **Step 5: Commit**

```bash
git add bin/cockpit-autostart tests/test_autostart.sh
git commit -m "cockpit autostart: cockpit-autostart install/uninstall/status (plist gen + launchctl)"
```

---

### Task 4: `install.sh` — symlink the new helpers + hint

**Files:**
- Modify: `install.sh`
- Modify: `tests/test_autostart.sh`

- [ ] **Step 1: Write the failing test**

Add this block to `tests/test_autostart.sh` immediately before the final `[ $fail -eq 0 ]` line:

```bash
# --- Task 4: install.sh symlinks the new helpers into ~/.local/bin ---
check "cockpit-autostart symlinked"     "[ -L \"\$HOME/.local/bin/cockpit-autostart\" ]"
check "cockpit-autostart-run symlinked" "[ -L \"\$HOME/.local/bin/cockpit-autostart-run\" ]"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_autostart.sh`
Expected: `FAILURES` — the two symlink checks FAIL (install.sh hasn't been updated/run, so the symlinks don't exist).

- [ ] **Step 3: Write minimal implementation**

In `install.sh`, change the helper list line:

```bash
for b in cockpit cockpit-ask cockpit-agent cockpit-doctor cockpit-clean cockpit-fanout; do
```

to:

```bash
for b in cockpit cockpit-ask cockpit-agent cockpit-doctor cockpit-clean cockpit-fanout cockpit-autostart cockpit-autostart-run; do
```

Then add an autostart hint. After this existing block:

```bash
ln -sf "$REPO/cockpit-home/CLAUDE.md" "$HOME/cockpit/CLAUDE.md"
echo "linked protocol  -> ~/cockpit/CLAUDE.md"
```

insert:

```bash
echo "autostart        -> opt-in: run 'cockpit-autostart install' to open the cockpit on login"
```

Then run the installer to create the symlinks: `./install.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_autostart.sh`
Expected: `ALL PASS` (both helpers now symlinked into `~/.local/bin`).

Also confirm nothing else regressed:
Run: `bash tests/test_cockpit_agent.sh && bash tests/test_fanout_integration.sh && bash tests/test_fanout_visible_integration.sh && python3 -m pytest tests/test_fanout.py -q`
Expected: `ALL PASS` ×3 + pytest green.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/test_autostart.sh
git commit -m "install.sh: symlink cockpit-autostart helpers + login-autostart hint"
```

---

### Task 5: Live validation (manual — the acceptance test)

Can't run in CI (needs a GUI login session + the real displays). Do it on the actual machine.

- [ ] **Step 1: Enable it for real**

```bash
cockpit-autostart install
cockpit-autostart status        # expect: com.<user>.cockpit: loaded
```

- [ ] **Step 2: Trigger the login behavior without logging out**

```bash
launchctl kickstart -k gui/$(id -u)/com.$(id -un).cockpit
```
Expected: a WezTerm window opens **fullscreen on the LG SDQHD**, running the cockpit 4-pane grid; the worker panes resolve `opencode`/`claude` (proves the login-shell PATH worked). If the window opens but isn't fullscreen/positioned right, check `~/cockpit/autostart.log` and adjust the `set_position`/`toggle_fullscreen` ordering in `wezterm/cockpit.lua` (a brief `wezterm.sleep_ms` before fullscreen may be needed on this build).

- [ ] **Step 3: Idempotency**

With the cockpit already open, run the kickstart again:
```bash
launchctl kickstart -k gui/$(id -u)/com.$(id -un).cockpit
```
Expected: no second window (the `pgrep` guard skips).

- [ ] **Step 4: Fallback (optional)**

Disconnect/turn off the LG SDQHD (or test from the laptop undocked), kickstart again → the cockpit opens fullscreen on the main display instead.

- [ ] **Step 5: Real login**

Log out and back in → the cockpit comes up on the LG SDQHD automatically.

- [ ] **Step 6: Report**

Report results. If good, the branch is finished via `finishing-a-development-branch` (merge → main) and `HANDOFF.md` is updated to mark Phase 6 autostart done. To disable later: `cockpit-autostart uninstall`.

---

## Self-Review

**1. Spec coverage** — every spec requirement maps to a task:
- LaunchAgent `RunAtLoad` + opt-in install/uninstall/status → Task 3. install.sh stays opt-in (hint only) → Task 4.
- Window fullscreen on `LG SDQHD` via `screens()` + non-native fullscreen, runs `cockpit` → Task 1 (`cockpit.lua`); verified live Task 5.
- Fallback to active/main when LG SDQHD absent → Task 1 (`by_name[TARGET] or screens.active or screens.main`); verified Task 5 step 4.
- PATH-for-panes via login-shell wrapper → Task 2; verified Task 5 step 2.
- Idempotency (no duplicate window) → Task 2 (`pgrep` guard + test); verified Task 5 step 3.
- Generated plist shape (label/ProgramArguments/RunAtLoad/log) → Task 3.
- Testing: plist `plutil -lint`, install/uninstall round-trip, idempotency via stub, config parses → Tasks 1-3; manual acceptance → Task 5.

**2. Placeholder scan** — no `TBD`/`TODO`; every code step shows complete file contents; every run step has the exact command + expected output. The only `<user>`/`<path>` tokens are in prose describing runtime-derived values (`id -un`, repo path), not in code.

**3. Type/name consistency** — `cockpit-autostart-run` takes `$1` = config path, used identically in Task 2 (wrapper), Task 3 (plist `ProgramArguments` second `<string>`), and the tests. Label `com.$(id -un).cockpit` is consistent across `cockpit-autostart` and Task 5's `launchctl` commands. Env hooks (`COCKPIT_AUTOSTART_PLIST`, `COCKPIT_AUTOSTART_NO_LOAD`, `COCKPIT_AUTOSTART_FORCE_RUNNING`, `WEZTERM_STUB_MARKER`) are spelled identically in the helpers and the tests. `TARGET = 'LG SDQHD'` matches the probed screen name. `tests/test_autostart.sh` prepends `$REPO/bin` (helpers) globally and `$REPO/tests/stubs` only for the wrapper checks, so the cockpit.lua parse check uses the real `wezterm` while the wrapper checks use the stub.
