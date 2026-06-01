# Autostart Cockpit on Login — Design

_Design spec · 2026-06-01_

## Context

The cockpit launcher (`bin/cockpit`, attach-or-create a `cockpit` zellij session) and zellij session
resurrection are done (Phase 6). The remaining Phase 6 piece: at **login**, automatically open the
cockpit as a **fullscreen WezTerm window on the right monitor**, so the grid is just there.

Machine facts (probed 2026-06-01):
- **No window manager** (yabai/skhd/aerospace absent) → window placement must be done by WezTerm
  itself, via its Lua `gui-startup` event + `wezterm.gui.screens()`.
- **WezTerm 20240203** at `/opt/homebrew/bin/wezterm`; **no `~/.config/wezterm`** exists (clean slate).
- Three displays: **LG SDQHD** (3200×3600 / 1600×1800 logical, tall) ← the cockpit's home,
  **LC27RG50** (1920×1080@240, currently Main), **Sidecar Display** (iPad).
- `install.sh` is the idempotent installer (symlinks helpers + layout + protocol).

## Goal / scope

At login, an opt-in LaunchAgent opens a WezTerm window **fullscreen on the LG SDQHD** running
`cockpit`. Reversible with one command. If LG SDQHD is absent, fall back to the active/main display.

## Non-goals (YAGNI)

- No window manager install; no general-purpose multi-monitor layout logic beyond "target + fallback".
- Not auto-enabled by `install.sh` — enabling login autostart is an explicit opt-in.
- Login-only (a per-user LaunchAgent), not a boot-time daemon. No `KeepAlive` (closing the cockpit
  must not relaunch it).
- No change to `bin/cockpit`, the zellij layout, or the dispatch tooling.

## Design

### Behavior
- At login the LaunchAgent runs once (`RunAtLoad`) → a WezTerm window opens fullscreen on LG SDQHD
  running `cockpit` (the 4-pane grid).
- LG SDQHD absent (e.g. undocked) → opens fullscreen on the active/main display instead.
- Idempotent: if a cockpit WezTerm is already running, it does nothing (no duplicate window).

### Components (version-controlled in the repo)
- `wezterm/cockpit.lua` — dedicated WezTerm config: placement + launches `cockpit`. **Not** named
  `wezterm.lua` and **not** installed as the global config; it is loaded only via `--config-file`.
- `bin/cockpit-autostart-run` — the wrapper the LaunchAgent executes (login shell: PATH + idempotency).
- `bin/cockpit-autostart` — `install` / `uninstall` / `status` for the LaunchAgent.
- `install.sh` — symlinks the two new helpers and **prints a hint** to run `cockpit-autostart install`
  (does not enable autostart itself).
- The plist is **generated** by `cockpit-autostart install` (absolute paths, this user's UID/label);
  it is not committed.

### Placement (`wezterm/cockpit.lua`)
```lua
local wezterm = require 'wezterm'
local mux = wezterm.mux
local config = wezterm.config_builder()

config.native_macos_fullscreen_mode = false   -- non-native: fills the monitor, no separate Space

local TARGET = 'LG SDQHD'

wezterm.on('gui-startup', function()
  local screens = wezterm.gui.screens()
  local target = screens.by_name[TARGET] or screens.active or screens.main   -- fallback if unplugged
  local _, _, window = mux.spawn_window { args = { os.getenv('HOME') .. '/.local/bin/cockpit' } }
  local gui = window:gui_window()
  gui:set_position(target.x, target.y)   -- move onto the target monitor
  gui:toggle_fullscreen()                -- non-native fullscreen fills that monitor
end)

return config
```
`screens().by_name['LG SDQHD']` is the "put this window on that monitor" API. Non-native fullscreen
(`native_macos_fullscreen_mode = false`) avoids macOS Spaces, which is what makes pinning to a chosen
monitor reliable. `cockpit` is referenced by absolute path because the GUI process's PATH is minimal
(see below).

### PATH handling (critical)
launchd hands processes a minimal PATH. If WezTerm → `cockpit` → the zellij server inherited that, the
worker panes would not find `opencode`/`claude` (the Phase 3 "command not found" problem). Fix:
**`cockpit-autostart-run` is a login shell** so the full interactive PATH flows down to wezterm →
zellij → every pane.

```zsh
#!/bin/zsh -l
# LaunchAgent wrapper. $1 = absolute path to cockpit.lua (baked into the plist at install time).
# Login shell (-l) sources the profile so PATH reaches wezterm -> zellij -> panes (opencode/claude).
pgrep -f 'wezterm.*cockpit\.lua' >/dev/null 2>&1 && exit 0   # already up — no duplicate window
exec wezterm --config-file "$1" start
```

### Install / uninstall (`bin/cockpit-autostart`)
- `install` — resolve the repo root; write `~/Library/LaunchAgents/com.<user>.cockpit.plist` (label
  `com.<user>.cockpit` from `id -un`; `RunAtLoad`; `ProgramArguments` = the wrapper + the absolute
  `wezterm/cockpit.lua` path; logs to `~/cockpit/autostart.log`); then
  `launchctl bootstrap gui/$(id -u) <plist>` (fallback `launchctl load`). `plutil -lint` the plist first.
- `uninstall` — `launchctl bootout gui/$(id -u)/com.<user>.cockpit` (fallback `launchctl unload`) + rm plist.
- `status` — `launchctl print gui/$(id -u)/com.<user>.cockpit` (loaded? last exit?), else "not installed".

Generated plist shape:
```xml
<dict>
  <key>Label</key><string>com.<user>.cockpit</string>
  <key>ProgramArguments</key>
  <array>
    <string>/abs/repo/bin/cockpit-autostart-run</string>
    <string>/abs/repo/wezterm/cockpit.lua</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/Users/<user>/cockpit/autostart.log</string>
  <key>StandardErrorPath</key><string>/Users/<user>/cockpit/autostart.log</string>
</dict>
```

## Testing
- **Automated-ish (no login required):**
  - `plutil -lint` the generated plist → OK.
  - `cockpit-autostart install` → `status` shows the agent loaded → `uninstall` → `status` shows not
    installed (there is only one cockpit label, so install-then-uninstall is a clean round-trip).
  - Idempotency: with a fake `wezterm ... cockpit.lua` process present, `cockpit-autostart-run` exits 0
    without launching (assert via a stubbed `wezterm` on PATH that would write a marker).
  - `wezterm --config-file wezterm/cockpit.lua ls-fonts >/dev/null` (or equivalent) → config parses, exit 0.
- **Manual acceptance (the real test, needs a GUI session):**
  - `launchctl kickstart -k gui/$(id -u)/com.<user>.cockpit` simulates the login trigger *without*
    logging out → a WezTerm window appears **fullscreen on LG SDQHD** running the cockpit grid.
  - Real logout → login → same result.
  - Undocked (LG SDQHD absent) → opens fullscreen on the main display (fallback).
  - Second `kickstart` while already up → no duplicate window (idempotency).

## Risks
- **WezTerm placement timing:** `set_position` then `toggle_fullscreen` in `gui-startup` may need a
  small reorder/defer on this WezTerm build; confirm during the manual test (adjust the Lua if a race
  shows). This is the main fiddly area.
- **Login timing:** at `RunAtLoad`, displays/WindowServer are normally ready for a per-user LaunchAgent;
  if LG SDQHD attaches a beat late, the fallback (active/main) triggers — acceptable.
- **`launchctl` syntax** differs across macOS versions (`bootstrap`/`bootout` vs `load`/`unload`); the
  helper tries the modern form and falls back.
