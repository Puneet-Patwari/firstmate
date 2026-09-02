# Verification: the rovo (Atlassian Rovo CLI) crewmate/scout adapter

Active empirical evidence for firstmate's rovo adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/references/harness/rovo.md) owns the operating facts; this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `Rovo CLI: 202609.1.2` |
| Verified | 2026-09-02 |
| Binary | `~/.local/bin/rovo`, a bash wrapper that execs a PyArmor-obfuscated PyInstaller bundle under `~/.local/share/rovo/active/` |
| Platform | macOS arm64 (Darwin 25.6.0) |

An earlier scout task (`fm-rovo-smoke-s1`) established the baseline empirical facts through a hand-written PTY VT emulator, no adapter code, and no dispatchable wiring.
This task landed the executable owners against those facts and re-verified the load-bearing ones live, including two facts the scout could not test (auth refresh under an expired access token, and a mid-tool-call Escape).
Every command below ran unsandboxed, because rovo's OAuth credentials live in the macOS keychain, which a sandboxed shell cannot read.

## Detection

```
$ rovo --version
Rovo CLI: 202609.1.2
```

`bin/fm-harness.sh` tests `ATLASSIAN_AGENT_TYPE=rovo` and `ROVODEV_CLI=1` before the `CLAUDECODE` line and matches ancestry `comm=rovo` otherwise; `tests/fm-rovo-harness.test.sh` pins both the marker-precedence order (a rovo marker outranks an inherited `CLAUDECODE`) and the markerless-ancestry fallback with faked `ps` output.

## Launch and the startup-receipt readiness signal

`fm-spawn.sh` builds `env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS <rovo-bin> run --startup-receipt <path> --yolo <model/effort flags> "<brief>"`, wrapped by the shared `env -u CURSOR_AGENT -u CURSOR_INVOKED_AS` prefix every non-cursor harness gets.
`rovo_wait_for_receipt` polls that path for a JSON object containing `"state":"input_ready"` rather than scraping the composer.
A real launch under a raw PTY (no tmux/herdr) produced exactly that receipt:

```
$ cat receipt.json
{"schema_version":1,"native_session_id":"...","workspace_root":"/private/tmp/.../workspace","pid":NNNN,"state":"input_ready"}
```

`tests/fm-rovo-harness.test.sh` pins the launch template, the model/effort flags, the marker-clearing, the missing-binary refusal before any pane exists, the missing-receipt failure, and the crew/scout-only secondmate refusal, all against a fake `tmux` and a fake `rovo` binary (no real network or credentials needed for that portable suite).

## Busy state: the "Rovo is thinking" fallback

Live, over a raw PTY, submitting a prompt that runs a real `sleep 25` bash tool call rendered the busy line and footer:

```
⬢ Rovo is thinking...
Enter to queue, Ctrl+Enter to steer
```

`fm_busy_rovo_tail_busy` (`bin/fm-busy-lib.sh`) matches that exact rendered text; `fm_busy_classify` was confirmed live-and-portably to read it as `busy rovo-regex`, and an idle footer with no busy line as `idle rovo-regex`.
This is a rendered-tail fallback exactly like Grok's, not a semantic source: rovo's `eventHooks` (`~/.rovo/config.yml`) fire at tool granularity (`on_tool_start`/`on_tool_end`) only, never at turn-end, so no writer is armed and none is seeded.
Grok was previously the only rendered-text arm the redesigned busy contract allowed; this task extends that same documented exception to rovo, scoped to `harness=rovo` exactly like Grok is scoped to `harness=grok`, and neither can classify the other (`tests/fm-rovo-harness.test.sh`'s isolation case).

## Composer ghost text: measured, deliberately left unfixed

A live idle-composer capture over a raw PTY located the inline placeholder chip inside the actual bordered content row, not merely in a suggestion list below it:

```
row 10  ╭──────────────────────────────────────╮
row 11  │ Summarize my open tasks               │   fg 38;2;162;163;165 (luminance ~163)
row 12  ╰──────────────────────────────────────╯
```

Real typed text in the same row, captured separately, renders at `38;2;206;207;210` (luminance ~207).
Both values sit above `bin/fm-composer-lib.sh`'s default `FM_COMPOSER_GHOST_LUMA_MAX` of 128, so `fm_composer_strip_ghost` leaves the placeholder unstripped and a fresh rovo composer can misclassify as `pending` rather than `empty`.
Raising the shared default was considered and rejected: muse's own real, must-not-be-stripped prompt glyph measures luminance ~149.9 (`muse.md`), below rovo's ghost luminance of ~163, so no single global threshold can keep muse's glyph real while dropping rovo's ghost chip.
This is recorded as a known gap rather than patched, because the safe fix needs a harness-scoped signal the shared composer classifier does not carry today, and a threshold change risks regressing muse's already-credentialed behavior for a rovo-scoped fix.
The blast radius is bounded to composer-emptiness consumers such as steering delivery, which already retries through the doorbell ladder on a non-`empty` read; it does not reach this adapter's own readiness gate, which polls the `--startup-receipt` sidecar instead.

## Interrupt: Escape did not reproduce the scout's rendered ack

The `fm-rovo-smoke-s1` scout report recorded a single Escape printing `Agent cancelled` during a running tool call, using its own hand-rolled PTY VT emulator.
This task's live PTY check (`tests/fm-rovo-signals-live-e2e.test.sh`, `FM_ROVO_SIGNALS_LIVE=1`) repeated that exact scenario - a real `sleep 25` bash tool call, confirmed mid-flight from the rendered `Enter to queue, Ctrl+Enter to steer` footer, then a single Escape - and did not observe `Agent cancelled` or any other "cancel" string in the raw transcript; the busy line kept rendering afterward.
What did hold: the session was never wedged.
`/exit` still exited cleanly with the `Run rovo --restore <id> to resume your conversation` hint immediately after the Escape, in every run, with or without a prior Escape.
`bin/fm-control-lib.sh` records rovo's `fm_control_interrupt_ack_source` as `none`, the same conservative choice already made for claude, codex, grok, kimi, and cursor, precisely because a rendered acknowledgement is not something the control plane depends on for any of those adapters either.
Escape stays the recorded interrupt key because it remains the best-documented cancel key and the session recovers cleanly either way; the divergence from the scout's own observation is recorded here rather than silently dropped, and the exact rendered ack should be re-verified (with attention to PTY/terminal setup differences) before anything is ever built to depend on it.

## OAuth token lifetime and silent refresh

The captain corrected this task's initial brief, which had treated the ~1h access-token lifetime as a hard mid-task blocker; this task's own live evidence confirms the corrected model.

```
$ rovo auth status
authenticated — Access token expired (2026-09-02 13:39:55 UTC), but a refresh
token is present.

$ rovo run --yolo --output-file out.json "Reply with exactly the single word PONG and nothing else."
Run rovo --restore <session-id> to resume your conversation
$ cat out.json
PONG

$ rovo auth status
authenticated — Access token valid, expires in 3574s (2026-09-02 15:15:40 UTC).
```

No browser prompt, no interactive step, and no visible interruption occurred between the first and second `rovo auth status` calls; the run in between silently refreshed the access token from the stored refresh token.
Treat the ~1h access-token lifetime as an ordinary operational fact rather than a non-negotiable-safety blocker: `rovo auth login` (interactive browser OAuth) is needed only after roughly four weeks of disuse or an invalidated refresh token, not mid-task.

## Effort and model

`agent.efficiencyLevel` accepts `low|medium|high|max` live via `--config-override '{"agent":{"efficiencyLevel":"<value>"}}'`; a requested `xhigh` (unsupported) is recorded in task metadata but the launch omits the flag, both verified against the fake-binary suite.
Model discovery is per-account (`/models` or ACP `session/new`); the observed live list is recorded in `references/harness/rovo.md` and must never be hardcoded.

## Backend liveness: tmux pending, herdr full pane-placement not attempted

This host has no tmux installed, matching the `fm-rovo-smoke-s1` scout's own finding; [`runtime-backends.md`](runtime-backends.md) owns that gap and the general tmux-availability record.
`bin/backends/tmux.sh`'s `fm_backend_tmux_classify_process_name` now matches `*rovo*` alongside the other globbed harness names, so a rovo pane classifies `agent` (not `other`) wherever that classifier runs; this is a structural, portable change, not itself a live tmux capture.
A full `fm-spawn.sh --backend herdr` placement was deliberately not driven to completion on this host: this task's own agent process runs inside the shared production Herdr session, and `fm-spawn.sh`'s cross-session placement guard correctly refused to place a worker pane from a session-mismatched parent identity when a separate scratch Herdr session was requested.
Forcing that placement into the shared default session was rejected as unacceptable interference with the live, human-observed fleet for a verification task.
The live PTY checks above exercise the exact same `rovo run --startup-receipt ... --yolo` command any backend places into a pane, over the same raw TTY contract tmux and herdr allocate, so the launch, readiness, busy, interrupt, and exit facts are real; only the backend's own `capture-pane`/pane-registration plumbing around that command is unverified here.
Confirm `capture-pane` renders the box composer and the busy line, and that `fm_backend_agent_state` (tmux) or the herdr agent-registration classifier can prove the pane alive/stopped, on a host where an isolated session or a tmux install does not collide with a live fleet.

## Skill-loading interop gap (documented, not fixed)

```
⚠ Invalid skill definition in .../.agents/skills/bootstrap-diagnostics/SKILL.md: 'metadata -> internal': Input should be a valid string
```

rovo's skill loader rejects every firstmate skill because `metadata.internal` is a boolean in firstmate's frontmatter and rovo's schema wants a string.
This blocks `/no-mistakes` and every other firstmate skill invocation inside a rovo worker until firstmate's `SKILL.md` frontmatter is made rovo-compatible, a separate deferred follow-up that touches every skill file and the installer contract (`.agents/skills/firstmate-coding-guidelines/SKILL.md`).
A `no-mistakes`-mode rovo ship crewmate is blocked by this gap; a rovo scout, which invokes no skill, is unaffected.

## quota-axi provider mapping: not established

`bin/fm-quota-choose.sh`'s `provider_for_harness` has no `rovo` entry.
rovo routes to several distinct underlying model families (OpenAI, Anthropic, Gemini) through Atlassian's own account, and this task found no live evidence of how, or whether, `quota-axi` models that relationship.
Rather than guess a provider family and risk a wrong quota verdict, `rovo` stays absent from that mapping, so a `rovo` candidate in a quota-balanced dispatch array fails closed with `unknown harness: rovo` instead of being silently misjudged; establishing the real mapping is follow-up work, not part of this adapter.

## Refreshing this record

Run the portable suite and the live guard after any rovo upgrade, because the process name, marker set, receipt schema, and rendered busy/interrupt text are all vendor-controlled surfaces:

```
bin/fm-test-run.sh tests/fm-rovo-harness.test.sh
FM_ROVO_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-rovo-signals-live-e2e.test.sh
```

The live guard requires a real, authenticated `rovo` binary but drives it through a raw PTY rather than tmux, so it runs on hosts without tmux installed; it does not itself prove tmux or herdr pane-placement liveness, which remains the one gap this record leaves open.
