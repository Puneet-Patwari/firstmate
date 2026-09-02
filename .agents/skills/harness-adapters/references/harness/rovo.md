# Rovo CLI

Verified 2026-09-02 on Rovo CLI 202609.1.2 for crewmate/scout work only.
Not verified, and not naturally verifiable, as a secondmate or primary: rovo has no turn-end hook and no primary supervision protocol, the same gap that scopes muse to crewmate/scout.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `resolve_rovo_binary` in `../../../bin/fm-spawn.sh` resolves `PATH`, then falls back to `$HOME/.local/bin/rovo`; spawning refuses if neither is executable. |
| Launch | Positional instructions, the grok/cursor/muse shape (`rovo run --startup-receipt <path> --yolo <brief>`), needing no launch-then-type step. |
| Models | `--model <model>`, discovered from the in-session `/models` command or ACP `session/new`; the observed live list (GPT-5.6 Terra/Sol/Luna, GPT-5.5, GPT-5.4, several Claude Sonnet/Opus/Haiku ids, Gemini 3 ids) is per-account and must never be hardcoded. |
| Busy state | Rendered-tail fallback, isolated to rovo like Grok's - the animated `Rovo is thinking...` line, matched by `fm_busy_rovo_tail_busy` in `../../../bin/fm-busy-lib.sh` - because rovo's `eventHooks` fire at tool granularity only (`on_tool_start`/`on_tool_end`), never at turn-end, so no semantic writer exists to arm. |
| Exit command | `/exit` (also `/quit`, and a single idle Ctrl-C); prints `Run rovo --restore <session-id> to resume your conversation`. |
| Interrupt | Single Escape is the best-documented cancel key; `../../../bin/fm-control-lib.sh` records its acknowledgement source as `none` (see "Interrupt evidence" below), the same conservative choice as claude/codex/grok/kimi/cursor. |
| Skill invocation | `/<skill>`, the Claude/Grok form, but see "Skill-loading interop gap" below - a rovo worker cannot invoke a firstmate skill until that gap is resolved. |
| Autonomy | `--disable-permission-checks` (alias `--yolo`) runs every file CRUD operation and bash command without confirmation, though its own printed caveat keeps permission checks on tools accessing Atlassian data and user-provided MCP servers, which crew/scout tasks never touch. |
| Trust dialog | None observed on a clean launch in a fresh worktree; `--yolo` is the only gate crew/scout needs. |
| Environment marker | `ATLASSIAN_AGENT_TYPE=rovo` (most specific) and `ROVODEV_CLI=1`, both set on rovo's tool subprocesses alongside `AGENT=rovodev_cli`, none of which rovo scrubs from an inherited `CLAUDECODE`/`CURSOR_AGENT`/etc - so `../../../bin/fm-harness.sh` tests rovo's markers before the `CLAUDECODE` line (the same ordering hazard cursor already documents, issue #3517) and `../../../bin/fm-spawn.sh` clears foreign markers at the launch boundary too. |
| Process name | `comm=rovo` on the tool subprocess and the `rovo run` process itself, because the installed wrapper execs the generation's `rovo` shim so argv[0] stays `rovo` even though the on-disk binary is `atlassian_cli_rovodev`. |
| Composer | The existing bordered `box` shape family (`╭─╮ │ │ ╰─╯`) `../../../bin/fm-composer-lib.sh` already reads, with an empty composer showing de-emphasized suggestion chips and a `? for shortcuts.` hint, and a busy footer reading `Enter to queue, Ctrl+Enter to steer`. |
| Readiness signal | `--startup-receipt PATH` atomically writes `{"schema_version":1,"native_session_id":"...","workspace_root":"...","pid":N,"state":"input_ready"}` once the composer is prompt-free and input-ready, and `../../../bin/fm-spawn.sh` polls this file (`rovo_wait_for_receipt`) as a genuine postcondition instead of scraping the composer, recording the session id into `state/<id>.meta` as `rovo_session_id=` when present. |
| Effort | `agent.efficiencyLevel`, accepted `low\|medium\|high\|max` (default `medium`, no CLI `--effort` flag), set live via `--config-override '{"agent":{"efficiencyLevel":"<value>"}}'`, with an `xhigh` request recorded in task metadata but omitted from the launch command per `../../../references/common/model-and-effort.md`'s record-and-omit contract because rovo has no `xhigh`. |

## Detection

`../../../bin/fm-harness.sh` checks `ATLASSIAN_AGENT_TYPE=rovo` and `ROVODEV_CLI=1` before the `CLAUDECODE` line, then falls back to ancestry (`rovo)` case, beside `kimi)`).
Both layers matter for the same reason cursor's do: marker ordering covers a rovo session a human started by hand under an inherited foreign marker, while `../../../bin/fm-spawn.sh`'s launch-boundary `env -u` clearing covers every firstmate-launched worker regardless of ordering.

## Launch and readiness

The launch template clears `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, and `FM_PI_HARNESS` inline (rovo's own foreign-marker exposure), and the shared outer wrap clears `CURSOR_AGENT`/`CURSOR_INVOKED_AS` like every other non-cursor harness.
Because the brief rides the positional argument, delivery is the launch itself - there is no separate kimi-style launch-then-send step.
What still needs confirming is that the pane actually came up: `rovo_wait_for_receipt` in `../../../bin/fm-spawn.sh` polls `state/<id>.rovo-receipt` for `"state":"input_ready"` (`FM_ROVO_READY_POLLS`/`FM_ROVO_POLL_INTERVAL` govern the poll, mirroring kimi's knobs), and fails the spawn loudly if the receipt never appears.
`../../../bin/fm-teardown.sh` and `../../../bin/fm-control-lib.sh`'s wiring-paths table both retire that one sidecar file; rovo leaves no worktree-resident artifact at all.

## Composer ghost text: a known, unfixed gap

rovo's empty composer renders an inline placeholder chip (e.g. `Summarize my open tasks`) directly inside the bordered content row, not merely as a separate suggestion list below it.
Measured live, that placeholder's foreground is `38;2;162;163;165` (luminance ~163), while real typed text in the same box is `38;2;206;207;210` (luminance ~207) - a real gap, but one that sits entirely above `../../../bin/fm-composer-lib.sh`'s default `FM_COMPOSER_GHOST_LUMA_MAX` of 128, so `fm_composer_strip_ghost` does not strip it and a fresh rovo composer can misclassify as `pending` instead of `empty`.
Raising the shared default to catch it is not safe: muse's own real, must-not-be-stripped prompt glyph measures luminance ~149.9, below rovo's ghost luminance, so no single global threshold can keep muse's real glyph while dropping rovo's ghost chip.
This is deliberately left unfixed rather than patched with a threshold change that would risk muse's already-verified behavior; a real fix needs a harness-scoped signal the shared composer classifier does not currently carry.
The practical consequence is bounded to composer-emptiness consumers - steering into an idle rovo pane may see a non-empty verdict and retry through the normal doorbell ladder rather than deliver on the first try - and does not affect this adapter's own readiness gate, which polls the `--startup-receipt` sidecar instead of the composer.

## Interrupt evidence

The original verification scout (`fm-rovo-smoke-s1`, PTY smoke) observed a single Escape print `Agent cancelled` during a running tool call.
This task's own live PTY check (`../../../tests/fm-rovo-signals-live-e2e.test.sh`, `FM_ROVO_SIGNALS_LIVE=1`) sent Escape during a genuine mid-flight `sleep 25` bash tool call and did not reproduce that rendered text - the busy state persisted, and no "cancel" string appeared anywhere in the raw transcript.
The session was never wedged: `/exit` still exited cleanly with the resume hint immediately afterward, both with and without a prior Escape.
Escape remains the best-documented interrupt key and is what `fm_control_interrupt_key` returns, but its confirmation text render appears sensitive to something this task did not isolate (terminal/PTY setup is one candidate).
This is exactly why `fm_control_interrupt_ack_source` records `none` for rovo rather than a rendered claim: the control plane sends the key and lets its own postcondition polling - not a parsed string - decide whether the agent actually stopped.
Re-verify the rendered ack specifically before ever depending on it.

## OAuth token lifetime

The access token lasts about one hour, but `rovo` refreshes it silently and non-interactively from a stored refresh token (about four weeks' lifetime) with no browser prompt and no visible interruption - this is standing captain-corrected guidance, not this task's own discovery, and this task's own live checks corroborated it empirically: `rovo auth status` showed `Access token expired ... but a refresh token is present`, then a plain `rovo run` completed successfully and a follow-up `rovo auth status` showed a freshly valid token with no interactive step in between.
Treat the ~1h access-token lifetime as an ordinary operational fact, not a non-negotiable-safety blocker: a rovo worker does not need to be scoped short to survive it.
`rovo auth login` (interactive browser OAuth) is needed only after roughly four weeks of disuse or if the refresh token itself is invalidated.

## Skill-loading interop gap

rovo's skill loader rejects every firstmate skill: `Invalid skill definition in .../SKILL.md: 'metadata -> internal': Input should be a valid string`, because firstmate's `metadata.internal` is a boolean and rovo's schema wants a string.
This blocks `/no-mistakes` and every other firstmate skill invocation inside a rovo worker until firstmate's `SKILL.md` frontmatter is made rovo-compatible (a separate, deferred follow-up - it touches every skill file and the installer contract, per `../../firstmate-coding-guidelines/SKILL.md`).
A `no-mistakes`-mode rovo ship crewmate is blocked by this gap; a rovo scout, which invokes no skill, is unaffected.

## ACP as a future upgrade

`rovo acp` (Agent Client Protocol) and `rovo serve --non-interactive` expose a fully structured, machine-readable turn lifecycle: `session/prompt` returns a real `{"stopReason":"end_turn"}`, and `session/cancel` is a protocol-native interrupt.
This is a cleaner done-signal than any current adapter has, but consuming it means firstmate runs a JSON-RPC client and owns the session lifecycle itself - a new backend-shaped surface, not a drop-in TUI adapter - so it is out of scope here.
It remains a deliberate future upgrade for a rovo-as-structured-backend follow-up, not a near-term path; do not build it as part of this TUI-path adapter.
