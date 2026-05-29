#!/usr/bin/env bash
# install.sh — (re)install the agent cockpit: symlink helpers + layout + protocol,
# create runtime dirs, and check dependencies. Idempotent — safe to re-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.local/bin" "$HOME/.config/zellij/layouts" \
         "$HOME/cockpit/tasks/inbox" "$HOME/cockpit/tasks/done" "$HOME/cockpit/worktrees"

echo "helpers -> ~/.local/bin:"
for b in cockpit cockpit-ask cockpit-agent cockpit-doctor cockpit-clean cockpit-fanout cockpit-autostart cockpit-autostart-run; do
    chmod +x "$REPO/bin/$b"
    ln -sf "$REPO/bin/$b" "$HOME/.local/bin/$b"
    echo "  linked $b"
done

ln -sf "$REPO/zellij/cockpit.kdl" "$HOME/.config/zellij/layouts/cockpit.kdl"
echo "linked layout    -> ~/.config/zellij/layouts/cockpit.kdl"
ln -sf "$REPO/cockpit-home/CLAUDE.md" "$HOME/cockpit/CLAUDE.md"
echo "linked protocol  -> ~/cockpit/CLAUDE.md"
echo "autostart        -> opt-in: run 'cockpit-autostart install' to open the cockpit on login"

echo "deps:"
miss=0
for t in claude opencode zellij git python3; do
    if command -v "$t" >/dev/null 2>&1; then echo "  ✓ $t"; else echo "  ✗ $t MISSING"; miss=1; fi
done
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "  ! ~/.local/bin not on PATH — add it to your shell rc";; esac

echo
echo "done. Next: run 'cockpit-doctor' to greenlight, then 'cockpit'."
[ $miss = 0 ] || { echo "(install missing deps first — see README)"; exit 1; }
