#!/usr/bin/env bash
# Live guard for the real, installed Rovo CLI (bin/fm-test-run.sh's
# live-harness-optin family). Env-gated and self-skipping: it drives the real
# binary through a raw PTY (the same TTY contract tmux/herdr allocate) rather
# than requiring tmux, because tmux is not installed on every host this guard
# runs from (docs/verification/runtime-backends.md records that gap). It
# proves the harness-dependent facts bin/fm-busy-lib.sh and
# bin/fm-control-lib.sh encode for rovo: the "Rovo is thinking" busy line, the
# --startup-receipt readiness sidecar, that an Escape sent mid-tool-call never
# wedges the session, and clean /exit.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROVO_BIN=$(command -v rovo 2>/dev/null || true)
[ -x "${ROVO_BIN:-}" ] || ROVO_BIN="$HOME/.local/bin/rovo"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

if [ "${FM_ROVO_SIGNALS_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_ROVO_SIGNALS_LIVE=1 to run the real Rovo signal drift guard"
  exit 0
fi

[ -x "$ROVO_BIN" ] || fail "FM_ROVO_SIGNALS_LIVE=1 but no real rovo executable is installed"
command -v python3 >/dev/null 2>&1 || fail "python3 is required to drive rovo through a PTY"

VERSION_OUT=$("$ROVO_BIN" --version 2>&1) || fail "rovo --version failed: $VERSION_OUT"
echo "BOOTSTRAP_INFO: live rovo version: $VERSION_OUT"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-rovo-signals.XXXXXX") || fail "could not create the isolated Rovo lab"
cleanup() { rm -rf -- "$LAB"; }
trap cleanup EXIT
mkdir -p "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated Rovo workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated Rovo workspace"
RECEIPT="$LAB/receipt.json"
TRANSCRIPT="$LAB/transcript.log"

# Drive the real binary over a raw PTY: send a benign prompt after readiness,
# capture the rendered busy line, interrupt with Escape, then exit with
# /exit. Bytes are dumped raw to TRANSCRIPT for the shell-side substring
# checks below; this script only pumps input/output and enforces readiness
# and shutdown timeouts.
python3 - "$ROVO_BIN" "$WORKSPACE" "$RECEIPT" "$TRANSCRIPT" <<'PY' || fail "the PTY driver reported a failure"
import os
import pty
import select
import subprocess
import sys
import time

rovo_bin, workspace, receipt, transcript_path = sys.argv[1:5]

pid, fd = pty.fork()
if pid == 0:
    os.chdir(workspace)
    os.execvp(rovo_bin, [rovo_bin, "run", "--yolo", "--startup-receipt", receipt])
    os._exit(127)

transcript = open(transcript_path, "wb")

def pump(timeout, want=None):
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.5)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            transcript.write(chunk)
            transcript.flush()
            buf += chunk
        if want and want in buf:
            return buf
        if os.path.exists(receipt) and os.path.getsize(receipt) > 0:
            if want is None:
                return buf
    return buf

# 1. Wait for the startup receipt (readiness), not a rendered guess.
pump(45, want=None)
deadline = time.time() + 45
while time.time() < deadline and not (os.path.exists(receipt) and os.path.getsize(receipt) > 0):
    pump(1)
if not (os.path.exists(receipt) and os.path.getsize(receipt) > 0):
    sys.exit("rovo never wrote its --startup-receipt sidecar")

# 2. Submit a prompt that runs a slow bash tool call, so the busy window is
# long enough to interrupt mid-turn (a near-instant text reply can finish
# streaming before Escape lands).
os.write(fd, b"Run this exact bash command and nothing else: sleep 25\r")
pump(30, want=b"Rovo is thinking")

# 3. Interrupt with a single Escape while the tool call is genuinely in
# flight. bin/fm-control-lib.sh deliberately records rovo's cancellation
# acknowledgement as 'none' (like claude/codex/grok/kimi/cursor): this task's
# own live check sent Escape mid-tool-call and did not reproduce the scout
# report's "Agent cancelled" render (see references/harness/rovo.md), so no
# rendered ack is asserted here either. What must hold is the weaker,
# load-bearing claim ack_source=none actually depends on: Escape never wedges
# the session, so control can still exit it afterward.
time.sleep(5)
os.write(fd, b"\x1b")
pump(5)

# 4. Exit cleanly, proving Escape left the session controllable.
time.sleep(1)
os.write(fd, b"/exit\r")
for _ in range(60):
    try:
        done_pid, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        done_pid = pid
        status = 0
    if done_pid == pid:
        break
    pump(1)
else:
    subprocess.run(["kill", "-9", str(pid)])
    sys.exit("rovo did not exit after /exit, sent after a mid-tool-call Escape")

transcript.close()
PY

grep -Fq '"state":"input_ready"' "$RECEIPT" 2>/dev/null \
  || fail "real rovo's --startup-receipt never reached state:input_ready"
pass "real rovo writes its --startup-receipt readiness sidecar"

TAIL=$(tail -c 4096 "$TRANSCRIPT" 2>/dev/null || true)
grep -aFq 'Rovo is thinking' "$TRANSCRIPT" \
  || fail "real rovo never rendered its busy line for a submitted turn"
printf '%s\n' "Rovo is thinking..." | fm_busy_rovo_tail_busy \
  || fail "fm_busy_rovo_tail_busy did not classify the real busy line as busy"
pass "real rovo's busy line matches fm_busy_rovo_tail_busy"
pass "real rovo's session survives a mid-tool-call Escape and still exits cleanly on /exit"

grep -aFq 'resume your' "$TRANSCRIPT" \
  || fail "real rovo did not print its resume hint after /exit"
pass "real rovo exits cleanly on /exit"
