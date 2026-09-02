#!/usr/bin/env bash
# Behavior tests for the verified Rovo CLI crewmate/scout adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside Cursor, Claude, Pi, or Grok inherits those markers, which outrank
# the fake ancestry the detection cases set up. Drop the ambient markers so the
# asserted verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-rovo-harness)

# A minimal fake tmux for rovo's one-shot launch shape: send-keys -l logs the
# literal launch command so the launch template can be asserted. rovo has no
# readiness sidecar to simulate - a positional brief IS the delivery, exactly
# like grok/cursor/muse - so this is a bare send-keys logger.
make_rovo_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      [ -z "${FM_FAKE_LAUNCH_LOG:-}" ] || printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
    fi
    exit 0
    ;;
  capture-pane) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  fm_fake_exit0 "$fakebin" rovo
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_rovo_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for rovo\n' > "$home/data/$id/brief.md"
  printf 'rovo\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness rovo --mode no-mistakes --yolo off "$@" 2>&1
}

test_rovo_launch_is_verified() {
  local id rec out rc launch meta
  id="rovo-success-z1-$$"
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  out=$(run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model auto --effort high)
  rc=$?
  expect_code 0 "$rc" "verified rovo launch should succeed"
  assert_contains "$out" "spawned $id harness=rovo" "rovo spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "$FAKEBIN_DIR/rovo' run --yolo" "rovo launch did not use the resolved binary with the plain positional-brief shape"
  assert_not_contains "$launch" "--startup-receipt" "rovo launch used the incompatible --startup-receipt flag"
  assert_contains "$launch" "--model 'auto'" "rovo launch omitted the requested model"
  assert_contains "$launch" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS" \
    "rovo launch did not clear foreign primary markers"
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS" \
    "rovo launch did not clear cursor's markers via the shared outer wrap"
  assert_not_contains "$launch" "turn-ended" "rovo launch embedded a turn-end path it does not own"

  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=auto' "$meta" "rovo meta lost the requested model"
  assert_grep 'effort=high' "$meta" "rovo meta lost the requested effort"
  pass "fm-spawn: rovo launches positionally with the plain-brief shape and clears foreign markers"
}

test_rovo_effort_xhigh_is_recorded_but_omitted() {
  local id rec out rc launch meta
  id="rovo-xhigh-z2-$$"
  rec=$(make_spawn_case xhigh "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --effort xhigh)
  rc=$?
  expect_code 0 "$rc" "rovo spawn with an unsupported effort should still succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "config-override" "rovo launch emitted a config-override for an unsupported effort value"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'effort=xhigh' "$meta" "rovo meta did not retain the unsupported effort axis"
  pass "fm-spawn: rovo omits the launch flag for xhigh but keeps it in task metadata"
}

test_rovo_effort_high_sets_config_override() {
  local id rec out rc launch
  id="rovo-effort-z6-$$"
  rec=$(make_spawn_case effort-high "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --effort high)
  rc=$?
  expect_code 0 "$rc" "rovo spawn with a supported effort should succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" 'efficiencyLevel' "rovo launch did not set agent.efficiencyLevel via --config-override"
  assert_contains "$launch" '"high"' "rovo launch did not carry the requested efficiency level"
  pass "fm-spawn: rovo's supported effort values ride --config-override"
}

test_rovo_missing_binary_refuses_before_pane_creation() {
  local id rec out rc
  id="rovo-missing-z4-$$"
  rec=$(make_spawn_case missing "$id")
  read_spawn_record "$rec"
  rm "$FAKEBIN_DIR/rovo"
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "missing rovo executable should refuse the spawn"
  assert_contains "$out" "searched PATH for 'rovo'" "missing rovo diagnostic omitted PATH search"
  [ -s "$CASE_DIR/launch.log" ] && fail "missing rovo executable created a launch command" || true
  pass "fm-spawn: missing rovo executable refuses before pane creation"
}

test_rovo_secondmate_is_refused() {
  local id rec out rc
  id="rovo-secondmate-z5-$$"
  rec=$(make_spawn_case secondmate-refuse "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" --secondmate rovo 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a rovo secondmate spawn should be refused"
  assert_contains "$out" "rovo is a verified crewmate/scout adapter only" \
    "rovo secondmate refusal lacked its concrete reason"
  pass "fm-spawn: rovo cannot be launched as a secondmate"
}

test_rovo_detection_precedence_and_ancestry() {
  local dir fakebin cfg out
  dir="$TMP_ROOT/detection"
  fakebin=$(fm_fakebin "$dir")
  cfg="$dir/config"
  mkdir -p "$cfg"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
pid=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:4242) printf 'rovo\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = rovo ] || fail "rovo ancestry detection returned '$out'"

  out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    ATLASSIAN_AGENT_TYPE=rovo CLAUDECODE=1 \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = rovo ] || fail "rovo's ATLASSIAN_AGENT_TYPE marker did not outrank an inherited CLAUDECODE, got '$out'"

  out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    ROVODEV_CLI=1 CLAUDECODE=1 \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = rovo ] || fail "rovo's ROVODEV_CLI marker did not outrank an inherited CLAUDECODE, got '$out'"

  out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    CLAUDECODE=1 PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "verified env-marker precedence changed, got '$out'"
  pass "fm-harness: rovo's markers outrank an inherited CLAUDECODE, and markerless ancestry still resolves rovo"
}

test_rovo_control_lib_table() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-control-lib.sh"
  [ "$(fm_control_interrupt_key rovo)" = Escape ] || fail "rovo interrupt key is not Escape"
  [ "$(fm_control_interrupt_repeat rovo)" = 1 ] || fail "rovo interrupt repeat is not 1"
  [ -z "$(fm_control_interrupt_clear_key rovo)" ] || fail "rovo should need no interrupt clear key"
  [ "$(fm_control_interrupt_ack_source rovo)" = none ] || fail "rovo interrupt ack source is not none"
  [ "$(fm_control_exit_command rovo)" = /exit ] || fail "rovo exit command is not /exit"
  [ "$(fm_control_harness_family rovo-anything)" = rovo ] || fail "rovo harness family prefix match failed"
  fm_control_harness_supports_kind rovo ship || fail "rovo should support ship tasks"
  fm_control_harness_supports_kind rovo scout || fail "rovo should support scout tasks"
  if fm_control_harness_supports_kind rovo secondmate; then
    fail "rovo should never support secondmate tasks"
  fi
  pass "fm-control-lib: rovo's lifecycle table matches its verified facts"
}

test_rovo_busy_regex_isolated() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-busy-lib.sh"
  printf 'Enter to queue, Ctrl+Enter to steer\n⬢ Rovo is thinking...\n' | fm_busy_rovo_tail_busy \
    || fail "rovo's real busy line was not recognized as busy"
  printf 'Context: 5.3%% 48.7K/922K\n? for shortcuts.\n' | fm_busy_rovo_tail_busy \
    && fail "an idle rovo composer footer was misread as busy"
  printf 'Ctrl+c:cancel\n' | fm_busy_rovo_tail_busy \
    && fail "Grok's exact busy token leaked into rovo's harness-scoped matcher"
  printf 'Rovo is thinking\n' | fm_busy_grok_tail_busy \
    && fail "rovo's busy line leaked into Grok's harness-scoped matcher"

  local out
  out=$(fm_busy_classify tmux fake:0 rovo taskid /nonexistent-state '⬢ Rovo is thinking...')
  [ "$out" = "busy rovo-regex" ] || fail "fm_busy_classify did not read a real rovo busy tail as busy rovo-regex, got '$out'"
  out=$(fm_busy_classify tmux fake:0 rovo taskid /nonexistent-state 'Context: 1% 2K/900K')
  [ "$out" = "idle rovo-regex" ] || fail "fm_busy_classify did not read a real rovo idle tail as idle rovo-regex, got '$out'"
  pass "busy detection: rovo's rendered busy line classifies through its own isolated fallback"
}

test_rovo_launch_is_verified
test_rovo_effort_xhigh_is_recorded_but_omitted
test_rovo_effort_high_sets_config_override
test_rovo_missing_binary_refuses_before_pane_creation
test_rovo_secondmate_is_refused
test_rovo_detection_precedence_and_ancestry
test_rovo_control_lib_table
test_rovo_busy_regex_isolated
