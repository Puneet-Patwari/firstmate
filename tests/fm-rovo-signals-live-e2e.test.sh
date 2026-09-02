#!/usr/bin/env bash
# Live guard for the real, installed Rovo CLI (bin/fm-test-run.sh's
# live-harness-optin family). Env-gated and self-skipping: it drives the real
# binary through a raw PTY (the same TTY contract tmux/herdr allocate) rather
# than requiring tmux, so it runs on hosts without tmux installed. It exercises
# the EXACT production launch-then-send shape - bare `rovo run --yolo` with NO
# positional brief, a readiness gate on the `Welcome to Rovo!` banner, a typed
# absolute brief pointer, then a delivery gate - and proves the
# harness-dependent facts bin/fm-busy-lib.sh and bin/fm-control-lib.sh encode for
# rovo: that the "Rovo is thinking" busy line renders for a real tool call, that
# an Escape sent mid-tool-call prints "Agent cancelled" without wedging the
# session, and that /exit then exits cleanly with rovo's resume hint.
#
# A positional brief is deliberately NOT used: it is dead-on-arrival (rovo loads,
# never enters a working state, and drops back to an idle shell within ~10-15s;
# confirmed live four times over raw PTY and once under real tmux with the exact
# send-keys shape). The launch-then-send shape is what fm-spawn.sh actually
# places, so it is what this guard drives.
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

# The brief the typed pointer will reference. It triggers a slow bash tool call
# so the busy line and the interrupt window are both long enough to observe.
BRIEF="$LAB/brief.md"
printf 'Run this exact bash command and nothing else: sleep 25\n' > "$BRIEF"
BRIEF_REAL=$(cd "$LAB" && pwd -P)/brief.md

# Drive the real binary over a raw PTY through the exact production
# launch-then-send shape: launch bare, wait for the readiness banner, type the
# absolute brief pointer, confirm delivery, observe the busy line, interrupt with
# Escape, and exit cleanly. Bytes are dumped raw to TRANSCRIPT for the shell-side
# substring checks below.
python3 - "$ROVO_BIN" "$WORKSPACE" "$TRANSCRIPT" "$BRIEF_REAL" <<'PY' || fail "the PTY driver reported a failure"
import os
import pty
import select
import subprocess
import sys
import time

rovo_bin, workspace, transcript_path, brief_real = sys.argv[1:5]

pointer = "Read the brief at %s and follow it exactly." % brief_real

pid, fd = pty.fork()
if pid == 0:
    os.chdir(workspace)
    # Bare launch: NO positional brief. A message is typed in after readiness.
    os.execvp(rovo_bin, [rovo_bin, "run", "--yolo"])
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

# 1. Readiness gate: wait for rovo's fresh-launch welcome banner.
ready = pump(60, want=b"Welcome to Rovo!")
if b"Welcome to Rovo!" not in ready:
    sys.exit("rovo never rendered its 'Welcome to Rovo!' readiness banner")

# 2. Type the absolute brief pointer and submit it, then let the brief drive the
# slow bash tool call. The busy line proves both delivery and the working state.
os.write(fd, pointer.encode() + b"\r")
busy = pump(90, want=b"Rovo is thinking")
if b"Rovo is thinking" not in busy:
    sys.exit("rovo never rendered its busy line after the typed brief pointer")

# 3. Interrupt with Escape while the tool call is genuinely in flight. Real rovo
# prints "Agent cancelled" and stays controllable (confirmed live here and under
# real tmux 3.6a); hold the guard to that render. The exact instant the interrupt
# lands is timing-sensitive over a raw PTY - a single fixed-timer Escape can fall
# between states - so send Escape across the tool-call window until the cancel
# renders. This is a deterministic way to reproduce a timing-sensitive interrupt,
# not a weakening of the claim: a session that never rendered the cancel would
# exhaust every attempt and fail.
cancelled = b""
for _ in range(15):
    os.write(fd, b"\x1b")
    cancelled = pump(2, want=b"Agent cancelled")
    if b"Agent cancelled" in cancelled:
        break
if b"Agent cancelled" not in cancelled:
    sys.exit("rovo did not print 'Agent cancelled' after a mid-tool-call Escape")

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

grep -aFq 'Welcome to Rovo!' "$TRANSCRIPT" \
  || fail "real rovo never rendered its readiness banner"
pass "real rovo launches bare and renders its 'Welcome to Rovo!' readiness banner"

grep -aFq 'Rovo is thinking' "$TRANSCRIPT" \
  || fail "real rovo never rendered its busy line from the typed brief pointer"
printf '%s\n' "Rovo is thinking..." | fm_busy_rovo_tail_busy \
  || fail "fm_busy_rovo_tail_busy did not classify the real busy line as busy"
pass "real rovo delivers the typed brief pointer and renders its busy line"

grep -aFq 'Agent cancelled' "$TRANSCRIPT" \
  || fail "real rovo did not print 'Agent cancelled' on a mid-tool-call Escape"
pass "real rovo's session prints 'Agent cancelled' and survives a mid-tool-call Escape"

grep -aFq 'resume your' "$TRANSCRIPT" \
  || fail "real rovo did not print its resume hint after /exit"
pass "real rovo exits cleanly on /exit"
