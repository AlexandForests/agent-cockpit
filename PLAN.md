# Agent Cockpit

## Summary
Turn monitor 2 into a permanent full-screen Zellij grid of coding agents. Claude Code
coordinates (one pane plans/dispatches, one pane codes); Codex and local-model agents
(opencode) are workers. The Mac runs all the CLIs; a 3070 laptop (8GB) and a 4080
desktop ("gamendoe", 16GB) serve local models over Tailscale.

> Node names (`razernode`, `gamendoe`), specs, and topology throughout this doc are my reference rig — the cockpit is node-agnostic; point it at your own via `COCKPIT_ASK_ENDPOINT` and your opencode providers.

## Status & locked decisions (2026-05-28)
- **Interim scope = razernode only.** The 4080 (`gamendoe`) isn't set up yet — **deferred to a later phase**. Build the cockpit against the one live node first.
- **Interim layout = 4 panes:** Claude-orchestrate · Claude-code · **razernode completion-worker** (local, free, no tool loop) · **NVIDIA agentic-worker** (cloud opencode, drives the full tool loop reliably — see Phase 2). **Codex is on-demand**, not a pane.
- **We have a reliable agentic worker now without the 4080** — the NVIDIA-hosted `qwen3-coder-480b` does what razernode's 7B couldn't. The 4080, when it lands, becomes *additional local* agentic capacity (free, no quota), not a prerequisite.
- **Routing rule (because NVIDIA is metered):** Claude sends bulk/cheap completions to razernode (free); reserves the NVIDIA pane for tasks that genuinely need a reliable tool loop or a big model. Don't grind on NVIDIA — it's rate- and credit-limited.
- **Phases 1 & 2 ✅ done** (2026-05-28). CLIs installed; razernode + NVIDIA providers configured; reality-checks run on both.
- **Claude is the router first.** The orchestrate pane decides *what runs where* — dispatching each task to whichever agent/model does it best, deliberately conserving Claude's own tokens by offloading mechanical work to the local node(s). Coordination > coding for that pane.
- **Terminal = WezTerm** (best CLI-driven window placement on macOS; Zellij does the tiling).
- **3070 node = `razernode`** — Linux, tailnet `<tailnet-ip>`, Ollama (`ollama-burst` container) on `:11434`, `qwen2.5-coder:7b` Q4_K_M already pulled. **Phase 1 VERIFIED** from the Mac: `/v1/chat/completions` returns a completion. (Cold-start: first hit to an unloaded model takes >30s while it loads into VRAM; instant after.)
- **Endpoints stay plain HTTP over tailnet IP** — tailnet is already encrypted, avoids the macOS Python CA-bundle problem (see [[feedback-python-ssl-macos]]).

### Deferred (revisit when hardware is ready)
- **`gamendoe` (4080) setup** — OS confirm (Linux→vLLM systemd unit, Windows→WSL2+CUDA or Ollama-fallback), serve `Qwen2.5-Coder-14B`, add it as the 2nd worker node + 4th pane.

## Problem
Running agents one-at-a-time wastes the parallelism that's actually available — Claude
can plan while local models grind boilerplate/refactors for free on idle GPU hardware.
There's no single, glanceable surface where work is dispatched and progress is visible.
Cloud spend is also avoidable for the bulk, mechanical work the 3070/4080 can absorb.

## Goals
- Monitor 2 boots to a fixed 4-pane Zellij layout: Claude-orchestrate, Claude-code, opencode→razernode (completion), opencode→NVIDIA (agentic). Codex on-demand.
- One command (`cockpit`) brings the whole grid up and a Mac reboot restores it.
- The Claude orchestrate pane routes discrete tasks to the agent/model that does them best and collects the result — spending its own tokens on routing, not grunt work.
- Local agents run entirely on the 3070/4080 over Tailscale — zero cloud cost for that tier.
- Each task is matched to its executor (heavy refactor → 4080, quick edits → 3070, planning/routing → Claude orchestrate, focused coding → Claude code, second opinion → Codex on-demand).

## Constraints
- Mac is the only cockpit host; nodes are headless model servers (no agent runtime on them).
- VRAM: 3070 = 8GB (≈7B Q4 GGUF max), 4080 = 16GB (≈14B AWQ comfortably; 32B won't fit).
- Reachability is Tailscale-only; serving must bind to the tailnet interface, not public.
- Codex CLI is OpenAI-tied (cloud); only opencode panes use the local endpoints.
- Solo build, incremental — independent panes must work before any auto-dispatch exists.

## Rough Approach — phased build

### Phase 1 — Model serving + network ✅ (interim scope: razernode)
- **3070 node (`razernode`, <tailnet-ip>):** ✅ DONE — Ollama, `qwen2.5-coder:7b` Q4_K_M, OpenAI-compatible `/v1` on `:11434`, verified from the Mac via `curl .../v1/chat/completions`.
- **4080 node (`gamendoe`):** deferred — see "Deferred" above. (vLLM 14B-AWQ, KV-cache caps, +4th pane.)

### Phase 2 — Agent CLIs on the Mac ✅ (2026-05-28)
- Claude Code ✅ (2.1.156). opencode ✅ (already installed, 1.15.10). Codex ✅ installed (0.135.0) — **auth pending** (`codex login` / `OPENAI_API_KEY`), on-demand.
- opencode `provider` config (`~/.config/opencode/config.json`): added `razernode` (`http://<tailnet-ip>:11434/v1`, `qwen2.5-coder-32k:latest`) and `nvidia` (cloud — see below). Left the pre-existing `ollama` (LAN) provider untouched.
- Created `qwen2.5-coder-32k` on razernode (`FROM qwen2.5-coder:7b` + `num_ctx 32768`) — the default ~4k context was far too small for agentic prompts. KV math holds (~6.5GB on the 8GB 3070).

**Reality-check result (the key finding):** the 7B-Q4 *reasons* correctly — it picks the right tool with the right arguments — but it's **unreliable at the tool-call wire format**, emitting bare JSON instead of wrapping it in the `<tool_call>` tags Ollama's parser needs. So opencode never sees a tool call and no file gets edited. Run-to-run inconsistent (sometimes just asks for the file). Template + infra are correct; it's a small-quant / coder-model discipline limit.

**→ Decision: razernode = completion/codegen worker, not an autonomous agent.** Plain no-tools completions are rock-solid (verified: clean fence-free code). Claude dispatches bounded tasks (write/explain/draft) and collects output.

**NVIDIA agentic worker (added 2026-05-28).** Provider `nvidia` → `https://integrate.api.nvidia.com/v1`, key via `{env:NVIDIA_API_KEY}` (in `~/.zshrc`; never in any file/repo). Model `qwen/qwen3-coder-480b-a35b-instruct` (MoE, ~35B active). **Reality-check PASSED end-to-end:** opencode drove read→edit and actually fixed `calc.py` (`-1`→`5`); the model returns proper structured `tool_calls`. opencode model path: `nvidia/qwen/qwen3-coder-480b-a35b-instruct`.
  - *Gotcha:* the originally-planned `qwen2.5-coder-32b-instruct` hit **EOL 2026-05-12** — gone. Check `/v1/models` before pinning a model.
  - *Gotcha:* opencode streams and has **no request timeout** — if NVIDIA transiently stalls (free-tier queue spikes; observed once), the pane hangs. Just restart the run/pane.
  - *Limits:* rate- and credit-capped. Route only tool-loop / big-model work here; keep bulk on razernode.

### Phase 3 — Zellij cockpit layout ✅ files built (2026-05-28)
- `zellij/cockpit.kdl` — 2×2 grid via `default_tab_template` (tab-bar + status-bar): top row `claude` (orchestrate) | `claude` (code); bottom row `opencode -m razernode/qwen2.5-coder-32k:latest` (completion) | `opencode -m nvidia/qwen/qwen3-coder-480b-a35b-instruct` (agentic). Panes inherit the launch CWD. Symlinked → `~/.config/zellij/layouts/cockpit.kdl`.
- `bin/cockpit` — attach-or-create: if a `cockpit` session exists `zellij attach cockpit`, else `zellij -n cockpit -s cockpit` (NB: `-s name -l layout` does NOT create — `--session`+`--layout` means "add a tab to existing"; use `-n <layout> -s <name>`). Guards against running inside an existing session. Symlinked → `~/.local/bin/cockpit` (on PATH).
- Installed: zellij 0.44.3, WezTerm (cask). Layout **parse-validated** (`zellij setup --dump-layout cockpit`, exit 0).
- **opencode must live on a PATH zellij panes inherit.** zellij `command` runs binaries directly (no shell), so the nvm-versioned bin is NOT seen → "Command not found: opencode". Fix: installed via `brew install sst/tap/opencode` → `/opt/homebrew/bin/opencode` (stable, nvm-independent, already on the login PATH). `claude` already worked from `~/.local/bin`. (opencode had vanished from the nvm bin between Phase 2 and 3 — brew reinstall is the durable fix.)
- **Gotcha — Claude must launch via an interactive shell.** As a bare `command "claude"`, the pane showed only the MCP banner and never painted: Claude renders its TUI *inline* (no alt-screen) and needs a shell-initialized terminal (also fixes a `TERM=xterm-ghostty` mismatch). Fix: `command "zsh"` + `args "-ilc" "claude"`. opencode is unaffected (it uses alt-screen). NB: changing the layout means deleting the resurrectable `cockpit` session (`zellij delete-session cockpit -f`) so a fresh one is built.
- **VERIFIED LIVE (2026-05-28):** `cockpit` brings up the 4-pane grid in WezTerm; the two opencode panes land in their TUIs (razernode `qwen2.5-coder-32k`, NVIDIA `qwen3-coder-480b`). Claude panes pending re-test after the shell-wrapper fix. NVIDIA pane inherits `NVIDIA_API_KEY` from `~/.zshrc`.
- Note: both Claude panes load the global Obsidian MCP (`mcp-obsidian`, user-scoped in `~/.claude.json`) — kept intentionally (matches the vault session-log workflow); its `running on stdio` banner is harmless startup noise. (Aside: `obsidian-rest` SSE + `plugin:github` MCPs are failing to connect — pre-existing, unrelated.)
- Remaining polish (Alex, cosmetic): pin the WezTerm window fullscreen to display 2.

### Phase 4 — Coordination (Claude as orchestrator) ✅ done (2026-05-29)
Chose **dispatch helper commands** over a file-queue/watcher model: the orchestrate Claude shells
out to them, conserving its own tokens. Worker panes stay interactive. Runtime dir `~/cockpit/`
(`tasks/{inbox,done}/`, `worktrees/`); helpers symlinked onto PATH; `~/cockpit/CLAUDE.md` (→ repo
`cockpit-home/CLAUDE.md`) gives the orchestrate pane its routing protocol.
- **`cockpit-ask "<prompt>"`** (`bin/cockpit-ask`, python) — razernode completion, **free**, no tool
  loop. Returns text to stdout; Claude reviews/applies. ✅ verified (returned correct code).
- **`cockpit-agent <repo> "<task>"`** (`bin/cockpit-agent`, bash) — NVIDIA agentic edit via
  `opencode run` in an **isolated git worktree** on a fresh `cockpit/<ts>` branch; commits, prints a
  diff; logs to `tasks/done/` (outside the worktree, so it isn't committed). 5-min watchdog (opencode
  has no request timeout). ✅ verified both paths: happy path edited+verified the file correctly;
  failure path (NVIDIA stall / model `</function>` degenerate loop) → watchdog killed it, garbage
  stayed on the throwaway branch, **real repo HEAD untouched**.
- **Orchestrate pane homes in `~/cockpit`** (layout `cwd`), so it auto-loads the dispatch protocol.
- Known intermittent: the NVIDIA qwen3-coder agent occasionally stalls / loops on `</function>`; the
  watchdog handles it — just retry. Keep bulk on free razernode; reserve cockpit-agent for real agentic work.

**Validated end-to-end (2026-05-29):** built a real 3-file Python project (todo CLI: store + cli +
tests) entirely through the cockpit — razernode generated the modules/tests, the orchestrator ran
tests/CLI and caught bugs, the NVIDIA agent fixed single-file ones, and when the agent hit a flaky
streak (failed all retries) the **razernode fallback + orchestrator apply** carried it. Final: 9/9
tests pass, full CLI lifecycle works. Hardening that came out of it: `cockpit-ask` fence-stripping,
`cockpit-agent` 3× retry + worktree auto-cleanup, and the "use cockpit-agent reliably" protocol
(decompose to one file/dispatch; verify with py_compile+tests before merge; expect retries; patch
trivial fixes yourself). Reality: the NVIDIA agent is ~50% reliable on a bad night — the cockpit
handles projects anyway because the free razernode tier + orchestrator review absorb the flakiness.

**Agent model bake-off + new default (2026-05-29).** Tested candidate agent models on the agentic
edit task (single-attempt reliability, 3× each): `opencode/big-pickle` **3/3 ~9s (free)**,
`opencode/deepseek-v4-flash-free` 2/3 ~7s (free), `nvidia/qwen3-coder-480b` 2/3 but **~49s (5× slower),
metered**, and `nvidia/kimi-k2-instruct` + `nvidia/glm-5.1` **0/3 (NVIDIA free tier flaky that night)**.
big-pickle wins on all three axes — reliability, speed, cost. So `cockpit-agent`'s
default switched from `nvidia/qwen/qwen3-coder-480b` to **`opencode/big-pickle` (free, reliable)**.
`cockpit-agent` is now model-selectable: `--model PROVIDER/MODEL` or `COCKPIT_AGENT_MODEL=…`, and the
NVIDIA key is only required when an `nvidia/*` model is chosen. opencode's free tier (`opencode/*`)
needs no extra auth — it worked out of the box. No new panes (dispatch targets only, per the decision).

**Finalization / hardening pass (2026-05-29)** — before starting a real project:
- `bin/cockpit-doctor` — preflight: greenlights tools/helpers on PATH, razernode reachable + model
  loaded, big-pickle responds, key set, runtime dirs. Run it before any project.
- `cockpit-agent --verify "<cmd>"` (or `COCKPIT_VERIFY`) — runs a build/test in the worktree and
  reports `✓/✗`, auto-flagging broken diffs. Protocol made language-aware (py_compile / `tsc --noEmit` / etc.).
- `cockpit-ask` resilience — falls back to a free cloud model (`opencode/deepseek-v4-flash-free`) when
  razernode (the laptop) is unreachable; now model-selectable (`--model`) and endpoint-overridable
  (`COCKPIT_ASK_ENDPOINT`).
- `bin/cockpit-clean` — prunes MERGED `cockpit/*` branches (keeps unmerged), trims old audit records.
- `install.sh` — idempotent (re)install of symlinks + dirs + dep check. Agentic pane repointed to
  free `big-pickle`. Session resurrection already on by default; launcher now catches exited sessions
  + `attach -f` re-runs commands on resurrect. `cockpit-doctor` → READY ✓ verified.

### Phase 5 — Roles + concurrency tuning
- Map model→role: heavy refactor/multi-file → 4080; quick edits/boilerplate → 3070; planning/dispatch → Claude; adversarial review/second opinion → Codex.
- Set vLLM max-batched-tokens / context sizes; cap concurrent opencode requests per node.
- **Verify:** a real task fans out to 3 agents at once; watch `nvidia-smi` VRAM + tokens/sec on both nodes; no OOM.

### Phase 6 — Persistence + ergonomics
- Zellij session resurrection; autostart `cockpit` on login (launchd or terminal startup).
- Status bar / status line showing node health + VRAM (nvidia-smi over Tailscale SSH).
- Focus keybinds for fast pane switching.
- **Verify:** reboot the Mac → `cockpit` (or login) restores the full grid; node health is visible at a glance.

### Phase 7 — (stretch) Smarter orchestration
- Replace file dispatch with `zellij action write-chars` injection or a tiny task queue / MCP so Claude pushes prompts straight into worker panes and aggregates results.
- Parallel fan-out + result rollup back into the coordinate pane.
- **Verify:** Claude dispatches N subtasks programmatically and presents a merged summary.

**Phase 7 Approach 1 — parallel delegation (2026-05-30).** `cockpit-fanout batch.json` runs N
`cockpit-agent` tasks bounded-concurrent (default 3, `COCKPIT_FANOUT_JOBS`) into
`~/cockpit/tasks/done/<batch-id>/summary.md` for review+merge. `cockpit-agent` now has a free-only
model-fallback chain (`COCKPIT_AGENT_MODELS`, default big-pickle→deepseek-v4-flash-free) + a
machine-readable `RESULT` line. Visible task panes deferred to Approach 2.
Spec: `docs/superpowers/specs/2026-05-30-cockpit-parallel-delegation-design.md`.

**Phase 7 Approach 2 — visible task panes (2026-05-31, MERGED `6c29d4f`).** `cockpit-fanout --panes`
runs each task in a live zellij pane in a new `fanout-<id>` tab (reuses the pool for bounded waves +
the same `summary.md`); falls back to headless outside a zellij session. Built TDD (17 unit tests + a
`zellij` stub-driven integration test); live-validated in the cockpit (3-task fan-out, all `status=ok`).
Spec: `docs/superpowers/specs/2026-05-30-cockpit-visible-task-panes-design.md`.

## Open Questions
- Once the 4080 is up: does a 14B-AWQ drive opencode's tool loop reliably? (re-run the same reality-check against gamendoe).
- Worker-pane UX for a completion engine: plain `opencode`/chat against razernode, or a thin `ask-razer` dispatch helper Claude calls? (Phase 3/4 design.)

_Resolved 2026-05-28:_ terminal = WezTerm · Phases 1 & 2 done · **razernode = completion worker** (7B-Q4 drops `<tool_call>` tags) · **NVIDIA `qwen3-coder-480b` = agentic worker** (tool loop verified end-to-end) · interim = 4 panes · Codex on-demand (installed, auth pending) · 4080/gamendoe deferred (adds free local agentic capacity later).

## Links / References
- opencode (sst/opencode) — multi-provider agent CLI, local OpenAI-compatible support
- vLLM OpenAI-compatible server docs; Qwen2.5-Coder model card (AWQ + GGUF variants)
- Zellij layouts (KDL) + `zellij action` CLI
- Tailscale serve / tailnet binding for model endpoints
- Existing homelab Ollama on `alex@homelab` (current baseline to extend)
