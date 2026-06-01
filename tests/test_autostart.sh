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

# --- Task 2: wrapper launches when not running, skips when already running ---
# Run as `zsh <path>` so the `#!/bin/zsh -l` is bypassed and the stub wezterm on the
# prepended PATH is used (a login shell would re-source the profile and find real wezterm).
marker="$(mktemp)"; : > "$marker"
PATH="$REPO/tests/stubs:$PATH" WEZTERM_STUB_MARKER="$marker" COCKPIT_AUTOSTART_FORCE_RUNNING=0 \
    zsh "$REPO/bin/cockpit-autostart-run" "$LUA"
check "wrapper launches wezterm when not running" "[ -s '$marker' ]"
check "wrapper passes --config-file"              "grep -q -- '--config-file' '$marker'"
: > "$marker"
PATH="$REPO/tests/stubs:$PATH" WEZTERM_STUB_MARKER="$marker" COCKPIT_AUTOSTART_FORCE_RUNNING=1 \
    zsh "$REPO/bin/cockpit-autostart-run" "$LUA"
check "wrapper skips when already running"        "[ ! -s '$marker' ]"
rm -f "$marker"

# --- Task 4: install.sh symlinks the new helpers into ~/.local/bin ---
check "cockpit-autostart symlinked"     "[ -L \"\$HOME/.local/bin/cockpit-autostart\" ]"
check "cockpit-autostart-run symlinked" "[ -L \"\$HOME/.local/bin/cockpit-autostart-run\" ]"

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

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
