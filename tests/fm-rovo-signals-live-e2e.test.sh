#!/usr/bin/env bash
# Live guard for the real, installed Rovo CLI (bin/fm-test-run.sh's
# live-harness-optin family). Env-gated and self-skipping: it drives the real
# binary through a raw PTY (the same TTY contract tmux/herdr allocate) rather
# than requiring tmux, so it runs on hosts without tmux installed. It launches
# the exact production form - `rovo run --yolo "<brief>"` with the brief as the
# positional argument - and proves the harness-dependent facts
# bin/fm-busy-lib.sh and bin/fm-control-lib.sh encode for rovo: that a
# positional brief IS the delivery (the "Rovo is thinking" busy line appears
# from the launch alone, with zero further input), that an Escape sent
# mid-tool-call never wedges the session, and clean /exit.
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
TRANSCRIPT="$LAB/transcript.log"

# Drive the real binary over a raw PTY, launching the exact production form:
# `rovo run --yolo "<brief>"` with the brief as the positional argument at exec
# time and nothing typed after launch. The brief triggers a slow bash tool
# call, so delivery-at-launch is proven (the busy line appears from the
# positional brief alone) and the busy/interrupt window is long enough. Bytes
# are dumped raw to TRANSCRIPT for the shell-side substring checks below; this
# script only pumps output and enforces readiness and shutdown timeouts.
python3 - "$ROVO_BIN" "$WORKSPACE" "$TRANSCRIPT" <<'PY' || fail "the PTY driver reported a failure"
import os
import pty
import select
import subprocess
import sys
import time

rovo_bin, workspace, transcript_path = sys.argv[1:4]

# The production launch shape: the brief IS the positional argument, so the
# turn starts from the launch alone with zero further input.
brief = "Run this exact bash command and nothing else: sleep 25"

pid, fd = pty.fork()
if pid == 0:
    os.chdir(workspace)
    os.execvp(rovo_bin, [rovo_bin, "run", "--yolo", brief])
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
    return buf

# 1. The positional brief IS the delivery: with nothing typed after launch, the
# slow bash tool call must drive the busy line on its own.
pump(60, want=b"Rovo is thinking")

# 2. Interrupt with a single Escape while the tool call is genuinely in flight.
# bin/fm-control-lib.sh records rovo's cancellation acknowledgement as 'none'
# (like claude/codex/grok/kimi/cursor), a control-plane fact independent of the
# render. Real tmux 3.6a DID reproduce the scout's "Agent cancelled" render on
# this same Escape (see docs/verification/rovo.md); an earlier raw-PTY check did
# not, so this PTY-specific driver is the weaker of the two guards for that one
# fact and asserts only the load-bearing claim ack_source=none depends on:
# Escape never wedges the session, so control can still exit it afterward.
time.sleep(5)
os.write(fd, b"\x1b")
pump(5)

# 3. Exit cleanly, proving Escape left the session controllable.
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

grep -aFq 'Rovo is thinking' "$TRANSCRIPT" \
  || fail "real rovo never rendered its busy line from the positional brief alone"
printf '%s\n' "Rovo is thinking..." | fm_busy_rovo_tail_busy \
  || fail "fm_busy_rovo_tail_busy did not classify the real busy line as busy"
pass "real rovo delivers the positional brief at launch and renders its busy line"
pass "real rovo's session survives a mid-tool-call Escape and still exits cleanly on /exit"

grep -aFq 'resume your' "$TRANSCRIPT" \
  || fail "real rovo did not print its resume hint after /exit"
pass "real rovo exits cleanly on /exit"
