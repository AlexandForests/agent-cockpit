# Going public — pre-publish safety checklist

A playbook for taking this cockpit (or anything the cockpit builds) from private to public
without leaking your homelab. Written from a real near-miss — see "What bit us" below.

## What bit us (2026-06-05)

We anonymized everything, the working tree was spotless, and the repo was **still not safe**.
Two traps:

1. **A clean working tree is not a clean repo.** All the anonymization commits landed on a
   feature branch (`phase6-autostart`). The repo's *default* branch (`main`) — what GitHub shows
   visitors and what `git clone` pulls — was 9 commits behind and still tracked
   `mcp/cockpit.mcp.json`, which hardcodes `/Users/<you>/.../obsidian/<vault>` (username + Obsidian
   vault name + nvm path). **Always audit `origin/<default-branch>`, not just your local tree.**

2. **The tip is not the history.** Even after a tip is clean, old commits keep the secrets.
   A purged tailnet IP still lived in 54 commits until `git filter-repo` rewrote them. Verify with
   the pickaxe, not just `git grep` on HEAD.

## The audit (run before every publish)

Set `d=` to the repo and `V=` to anything that fingerprints you (Obsidian vault name, etc.).

```sh
d=~/Desktop/claude/<repo>; V=<your-vault>

# --- working tree ---
git -C "$d" grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}'        # any IPv4 (tailnet 100.64-127.x is the danger)
git -C "$d" grep -n  '/Users/'                            # hardcoded home paths
git -C "$d" grep -ni "$V"                                 # vault / personal names
git -C "$d" grep -niE 'nvapi-|sk-[A-Za-z0-9]{16}|ghp_|github_pat_|-----BEGIN'   # real secret VALUES
git -C "$d" status --ignored --short | grep '^!!'         # confirm personal files are IGNORED, not tracked

# --- the PUSHED default branch (what the public actually sees) ---
for r in origin/main; do
  git -C "$d" grep -nI '/Users/' "$r" --
  git -C "$d" grep -nI "$V" "$r" --
  git -C "$d" ls-tree -r --name-only "$r" -- mcp/         # personal mcp/cockpit.mcp.json must NOT be here
done

# --- full history (pickaxe = definitive "is this string gone?") ---
for s in 100.x.x.x "$V" /Users/<you> nvapi- ; do   # 100.x = your tailnet/CGNAT range
  echo "== $s =="; git -C "$d" log --all --oneline -S"$s"   # empty output = purged from every commit
done

# --- commit metadata is public too ---
git -C "$d" log --all --format='%ae | %cn' | sort -u       # author email shows on every GitHub commit
```

> zsh gotcha: `git grep <pat> $(git rev-list --all)` silently fails — zsh doesn't word-split
> command substitution, so all SHAs become one bogus arg. Use `git log --all -S<string>` (above)
> for history checks; it needs no splitting.

## Checklist

- [ ] Working-tree audit clean (commands above)
- [ ] **`origin/<default-branch>` audit clean** — not just local
- [ ] History pickaxe empty for every identifier (IPs, vault, home path, key prefixes)
- [ ] `mcp/cockpit.mcp.json` is gitignored; only `mcp/cockpit.mcp.example.json` is tracked
- [ ] No hardcoded endpoints — `COCKPIT_ASK_ENDPOINT` / opencode providers come from env, not source
- [ ] Author email on commits is one you're OK being public (or a GitHub `noreply` address)
- [ ] Node names / topology are framed as "reference rig, bring your own" (or scrubbed)

## If you find something

- **Tracked personal config** → `git rm --cached <file>`, gitignore it, ship a `.example`.
- **In history** → `git filter-repo --invert-paths --path <file>` and/or `--replace-text` a
  `find==>replace` map; then force-push. Make a backup first: `git bundle create ../backup.bundle --all`.
- **Cleanest of all** → start a fresh repo / fresh history from the clean tip. No history to chase,
  nothing to force-push. (Trade-off: you lose the commit narrative.)
