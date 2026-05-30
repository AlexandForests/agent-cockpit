#!/usr/bin/env bash
# Integration test for cockpit-agent model-fallback + RESULT line, using a stub opencode.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$REPO_ROOT/bin:$REPO_ROOT/tests/stubs:$PATH"   # real cockpit-agent (bin) + stub opencode (only in stubs); bin must win over the stub cockpit-agent
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
