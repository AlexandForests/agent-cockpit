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
