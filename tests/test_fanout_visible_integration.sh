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
