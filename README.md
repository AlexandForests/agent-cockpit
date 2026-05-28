# agent-cockpit

Build a permanent multi-agent terminal cockpit on monitor 2.

**Start here:** [`PLAN.md`](./PLAN.md) — the full 7-phase build plan.

> **Node-agnostic.** The node names (`razernode`, `gamendoe`), GPUs, and topology below are my reference rig — bring your own: set `COCKPIT_ASK_ENDPOINT` for the completion worker and your own opencode providers for the agentic one.

## Decisions already locked (don't re-litigate)
- **Mac is the cockpit.** All agent CLIs run on the Mac. The GPU boxes are pure model servers.
- **Claude orchestrates** — 2 Claude panes (one routes/dispatches work to the best executor + conserves its own tokens, one codes). opencode local agents are workers; **Codex is on-demand**.
- **Interim = 4 panes:** 2 Claude (orchestrate + code) · opencode→razernode (local completion worker) · opencode→NVIDIA (cloud agentic worker). **WezTerm + Zellij** tile monitor 2.
- **Serving:** Ollama on the 3070 laptop (`razernode`, 8GB, completion only) + NVIDIA API cloud (`qwen3-coder-480b`, the reliable agentic worker, rate/credit limited). vLLM on the 4080 (16GB) **deferred — not set up yet** (adds free local agentic capacity later). Plain HTTP over **Tailscale** to razernode (no TLS — tailnet is encrypted).

## Hardware

Reference setup (configurable — see note above):

| Role | Example node | VRAM | Serves |
|------|------|------|------|
| Cockpit host | a Mac | — | runs all agent CLIs (Claude, Codex, opencode) |
| Light worker | ~8GB GPU on the tailnet (e.g. a 3070, `razernode`) | 8GB | Ollama `qwen2.5-coder:7b` — completions ✅ |
| Heavy worker | ~16GB GPU (e.g. a 4080) | 16GB | vLLM ~14B AWQ — ⏳ deferred |

## Status
**Phases 1–4 done + hardened** (2026-05-29). 4-pane cockpit live in WezTerm (2× Claude, razernode
completion worker, free `opencode/big-pickle` agentic worker). Free-by-default dispatch with reliability
hardening: preflight `cockpit-doctor`, language-aware `--verify`, `cockpit-ask` cloud fallback, and
`cockpit-clean`/`install.sh`. 4080/gamendoe deferred; Windows scrapped. **Next: Phase 5/6 if wanted.**
See `PLAN.md`.

## Setup / health
```sh
./install.sh      # (re)link helpers + layout + protocol, make dirs, check deps (idempotent)
cockpit-doctor    # preflight: razernode, big-pickle, key, PATH — greenlight before starting
```
> `cockpit-ask`/`cockpit-doctor` default to `http://localhost:11434`. Point them at your worker node with `export COCKPIT_ASK_ENDPOINT=http://<your-node>:11434` (e.g. a Tailscale host).

## Dispatch (from the orchestrate pane)
```sh
cockpit-ask "write a function that ..."             # razernode (free); falls back to free cloud if it's asleep
cockpit-ask --model opencode/big-pickle "harder"    # force a specific completion model
cockpit-agent ~/Desktop/claude/myproj "task"        # agentic edit in a worktree -> reviewable diff
cockpit-agent --verify "npx tsc --noEmit" ~/proj "task"          # auto-flag broken diffs
cockpit-agent --model nvidia/moonshotai/kimi-k2-instruct ~/proj "hard task"   # escalate
cockpit-fanout batch.json                           # run N agent tasks concurrently -> one summary
cockpit-fanout --panes batch.json                   # same, but watch each task in a live zellij pane (new fanout-<id> tab)
cockpit-clean ~/Desktop/claude/myproj               # prune merged cockpit/* branches + old records
```
Default agent = **`opencode/big-pickle`** (free; 3/3 @ ~9s in the 2026-05-29 bake-off — vs qwen3-coder's
2/3 @ ~49s metered, kimi-k2/glm 0/3 that night). Override with `--model` / `COCKPIT_AGENT_MODEL`; NVIDIA
key only needed for `nvidia/*`. `--verify`/`COCKPIT_VERIFY` runs a build/test in the worktree and flags
failures. Results/log land in `~/cockpit/tasks/done/`. Routing + model menu: `cockpit-home/CLAUDE.md`.

## Launch
```sh
cockpit          # attach-or-create the 4-pane Zellij session
```
Run it from a fullscreen WezTerm window on monitor 2. All four panes use free models by default
(the agentic pane = `opencode/big-pickle`); `NVIDIA_API_KEY` (in `~/.zshrc`) is only needed if you
escalate `cockpit-agent` to an `nvidia/*` model. Layout: `zellij/cockpit.kdl` → `~/.config/zellij/layouts/cockpit.kdl`.

Deps (so zellij panes resolve the agent binaries by PATH):
`brew install zellij sst/tap/opencode` + `brew install --cask wezterm`; `claude` in `~/.local/bin`.
opencode **must** be on a PATH zellij inherits (e.g. `/opt/homebrew/bin`) — nvm-versioned bins are not seen.

## Starting a project
1. **Bring up the cockpit** (fullscreen WezTerm on monitor 2): `cockpit`. Run `cockpit-doctor` first to confirm everything's green.
2. **Create the project as a git repo with a first commit** — `cockpit-agent` branches from `HEAD`:
   ```sh
   mkdir -p ~/Desktop/claude/myproj && cd ~/Desktop/claude/myproj && git init && git commit --allow-empty -m init
   ```
3. **Drive from the orchestrate pane** — tell it the path + goal in plain language; it loads its routing
   protocol on startup and decomposes/dispatches: bulk→`cockpit-ask` (free), agentic edits→`cockpit-agent`
   (free big-pickle), design→itself/the code pane.
4. **Review every agent branch before merging** (read diff, run tests), then the printed `git merge` line.
5. Other panes: **code pane** = a 2nd independently-directed Claude for a parallel track; **worker panes** =
   watch activity or paste prompts for scratch use.

**Best practices:** commit before dispatching agentic edits · one file per `cockpit-agent` dispatch
(it drops files on multi-file tasks) · verify before merge · free-first, escalate with `--model` only
when needed · keep the orchestrator planning/routing, not typing. The two Claude panes don't share
context — coordinate by talking to each or via repo files.
