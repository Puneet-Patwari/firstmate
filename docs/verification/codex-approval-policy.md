# Verification: the codex approval-policy override and hook-trust dialog

Audience: maintainer verification.

Active empirical evidence for two codex-cli 0.145.0 launch findings: the residual per-command approval prompt that no tested flag combination suppressed, and the new hooks-review onboarding dialog that `--dangerously-bypass-hook-trust` suppressed in the one configuration tested.
[`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts; this record owns the exact commands, the exact output, and what is still unproven.
Task chronology and ruled-out hypotheses stay in the private task report or PR evidence.

`docs/verification/supervision.md` "Semantic busy state" owns the separate codex 0.145.0 hook-DISCOVERY evidence (which hook scopes fire for a firstmate-launched worker) and is not superseded by this record.

## Subject

| Field | Value |
|---|---|
| Version | codex-cli 0.145.0 |
| Verified | 2026-08-27 |
| Platform | macOS arm64 (Darwin 25.6.0) |
| Host policy | enterprise-managed requirements `Baseline (8e96d288-57e1-4cca-97eb-78f1ac9c3e66)` |

Every run below was driven against codex directly, never through `bin/fm-spawn.sh` and never against a live fleet pane.
The probe was a real shell write inside the agent's own worktree, `mkdir -p sub/dir && echo ok > sub/dir/proof.txt`, the same shape as the originally reported `mkdir -p docs/design-audit/stage1` incident.

## Approval override: commands run

```sh
codex --dangerously-bypass-approvals-and-sandbox "<probe brief>"
codex -a never -s danger-full-access "<probe brief>"
codex exec --dangerously-bypass-approvals-and-sandbox "<probe brief>"
codex exec -a never -s danger-full-access "<probe brief>"
codex doctor
```

The two interactive launches produced byte-identical behavior: the same override warnings at launch, and the same blocking `Would you like to run the following command?` prompt at the same command.
Neither wrote the probe file without a human answering that prompt.

## Approval override: launch warnings

Every launch above printed override warnings naming the rejected value and the allowed set.
Two of those warning lines were captured:

```
warning: Configured value for `approval_policy` is disallowed by requirements; falling back to required value OnRequest. Details: invalid value for `approval_policy`: `Never` is not in the allowed set [OnRequest, UnlessTrusted] (set by enterprise-managed requirements Baseline (8e96d288-57e1-4cca-97eb-78f1ac9c3e66))
warning: Configured value for `permission_profile` is disallowed by requirements; falling back to required value Managed { ... }. Details: invalid value for `sandbox_mode`: `DangerFullAccess` is not in the allowed set [WorkspaceWrite, ReadOnly] (set by enterprise-managed requirements Baseline (8e96d288-57e1-4cca-97eb-78f1ac9c3e66))
```

The second line carries `Managed { ... }` exactly as recorded; the struct body is not part of this record, so the resolved profile's contents are unestablished.
The original note reported a third override warning line, concerning `windows.sandbox`, that was never transcribed, so it is not reproduced here and its exact text is unestablished.
Because of that gap, match on the literal substring `enterprise-managed requirements Baseline` rather than on a fixed warning count when identifying an override host.

## `codex doctor`

```
sandbox restricted fs + restricted network · approval OnRequest
```

## Non-interactive `codex exec`

`codex exec` with the same flags hard-fails the probe write instead of prompting:

```
command execution approval is not supported in exec mode
Rejected("approval request failed")
```

## Symbols in the installed binary

The installed binary's strings contain `MdmManagedPreferences`, `EnterpriseManagedSystemRequirementsToml`, and a "Config layer stack" entry carrying `allowed_approval_policies` and `allowed_sandbox_modes` fields.

## Delivery vehicle: not established

```sh
profiles list
profiles show
system_profiler SPConfigurationProfileDataType
```

`profiles list` reported two installed profiles.
`profiles show` and `system_profiler SPConfigurationProfileDataType` returned no readable profile content in this environment, so no admin policy document was inspected and the delivery vehicle on this host is unconfirmed.

## What is proven, and what is open

Proven:

- Three flag combinations - `--dangerously-bypass-approvals-and-sandbox`, the explicit pair `-a never -s danger-full-access`, and both again through `codex exec` - all failed identically to get an in-worktree write through without a human answer.
- Codex's own diagnostics report an enterprise-managed requirements override of both `approval_policy` and `sandbox_mode`.

Open:

- The mechanism is not established, including why this particular write was gated.
  The warning's allowed `sandbox_mode` set nominally includes `WorkspaceWrite`, and the probe write was inside the agent's own worktree.
- The resolved managed `permission_profile`'s contents were never captured.
- Whether a codex version upgrade changes any of this was not tested and is not claimed either way.

Not attempted, by explicit owner direction after a mid-task scope cut: any workaround for the approval override, any change to `bin/fm-spawn.sh`'s codex launch flags, and any further codex runs.

## Hook-trust dialog

codex-cli 0.145.0 adds a second onboarding dialog after directory trust:

```
Hooks need review
N hooks are new or changed. Hooks can run outside the sandbox after you trust them.
  1. Review hooks
  2. Trust all and continue
  3. Continue without trusting (hooks won't run)
```

Reproduced with a scratch `CODEX_HOME` copy of the operator's real GLOBAL `~/.codex/hooks.json`, carrying the same hook content but no persisted `hooks.state` trust entries.
The cursor default is option 1, `Review hooks`.
`--dangerously-bypass-hook-trust` suppressed the dialog reliably in that same scratch `CODEX_HOME`, and those global hooks then ran with no review dialog at all.

That result is scoped to the GLOBAL hooks in that scratch `CODEX_HOME`, the only hook scope this test exercised.
It establishes nothing about firstmate-written PROJECT hooks under `<worktree>/.codex/hooks.json`: `docs/verification/supervision.md` "Semantic busy state" (line 196) and `bin/fm-busy-lib.sh`'s `fm_busy_codex_hooks_verified` (lines 131-137) own that negative and the codex busy-state gate it holds closed.
Whether those project hooks were ever trusted under 0.145.0's new hooks-review gate is itself unrecorded, so the hook-trust state of that probe is an open question.
