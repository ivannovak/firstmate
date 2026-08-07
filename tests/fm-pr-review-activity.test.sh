#!/usr/bin/env bash
# Behavior tests for PR review-activity wakes: the poll's reported line, the
# per-task cursor that keeps an unchanged repeat from waking firstmate every
# sweep, silence on every failure mode, and the untouched merge signal.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

POLL="$ROOT/bin/fm-pr-poll.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-review-activity)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
PR_URL=https://github.com/o/r/pull/10
ACTIVITY_ONE='1 5 2026-08-06T16:16:23Z'
ACTIVITY_TWO='2 5 2026-08-07T09:00:00Z'
LINE_ONE='review-activity reviews=1 comments=5 latest=2026-08-06T16:16:23Z'
LINE_TWO='review-activity reviews=2 comments=5 latest=2026-08-07T09:00:00Z'

# A fake gh reproducing the two independent reads the poll performs: the merge
# state, and the review-activity projection. Each is separately failable so the
# tests can drive one red without disturbing the other.
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/wt" "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --json state "*)
    [ "${FM_TEST_GH_STATE_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}"
    ;;
  *" --json reviews,comments "*)
    [ "${FM_TEST_GH_ACTIVITY_FAIL:-0}" = 0 ] || exit 1
    [ "${FM_TEST_GH_ACTIVITY_SLEEP:-0}" = 0 ] || sleep "$FM_TEST_GH_ACTIVITY_SLEEP"
    [ -z "${FM_TEST_GH_ACTIVITY-}" ] || printf '%s\n' "$FM_TEST_GH_ACTIVITY"
    ;;
esac
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$dir"
}

write_task_meta() {
  local dir=$1 id=${2:-task-a}
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
}

# Report exactly what the poll prints for one validated identity, with no
# watcher, no cursor, and no state involved.
run_poll() {
  local dir=$1
  env PATH="$dir/fakebin:$BASE_PATH" "$POLL" --validated github "$PR_URL" github.com o/r 10
}

arm_poll() {
  local dir=$1 id=${2:-task-a}
  env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH" \
    FM_TEST_GH_ACTIVITY="${FM_TEST_GH_ACTIVITY-}" \
    "$PR_CHECK" "$id" "$PR_URL"
}

# Run the real watcher until it wakes, or until the bound expires. Exit 0 with
# output means a wake; exit 124 with no output means the sweep produced none.
run_watcher_bounded() {
  local dir=$1
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 10; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=2 \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 PATH="$dir/fakebin:$BASE_PATH" "$WATCH"
}

# One watcher sweep, reported as "<exit> <first-line-of-output>".
sweep() {
  local dir=$1 rc out
  rm -f "$dir/home/state/.last-check"
  set +e
  out=$(run_watcher_bounded "$dir" 2>/dev/null)
  rc=$?
  set -e
  printf '%s %s\n' "$rc" "$out"
}

assert_no_wake() {
  local dir=$1 what=$2 result
  result=$(sweep "$dir")
  [ "$result" = "124 " ] || fail "$what (watcher reported: $result)"
}

assert_wake() {
  local dir=$1 expect=$2 what=$3 result
  result=$(sweep "$dir")
  [ "$result" = "0 check: $dir/home/state/task-a.check.sh: $expect" ] \
    || fail "$what (watcher reported: $result)"
}

# --- the poll's own reported line -------------------------------------------

test_poll_reports_current_review_activity() {
  local dir out
  dir=$(make_case poll-reports)
  out=$(FM_TEST_GH_ACTIVITY="$ACTIVITY_ONE" run_poll "$dir")
  [ "$out" = "$LINE_ONE" ] || fail "poll did not report current review activity: '$out'"
  pass "poll reports the pull request's current review-activity totals and newest instant"
}

test_poll_reports_merge_alone() {
  local dir out
  dir=$(make_case poll-merged)
  # Activity is available and would otherwise be reported: a merged result must
  # still be the only line, so its existing retirement stays an exact match.
  out=$(FM_TEST_GH_STATE=MERGED FM_TEST_GH_ACTIVITY="$ACTIVITY_ONE" run_poll "$dir")
  [ "$out" = merged ] || fail "merged pull request did not report merged alone: '$out'"
  pass "a merged pull request still reports exactly one merged line"
}

test_poll_is_silent_on_every_activity_failure() {
  local dir out label
  dir=$(make_case poll-silence)
  # Each row is one way the activity read can go wrong. Every one must be
  # silent: a wake must never be manufacturable from a failure.
  while IFS='|' read -r label value; do
    [ -n "$label" ] || continue
    out=$(FM_TEST_GH_ACTIVITY="$value" run_poll "$dir")
    [ -z "$out" ] || fail "poll reported activity for $label: '$out'"
  done <<'EOF'
empty output|
no activity yet|0 0
missing field|1 5
extra field|1 5 2026-08-06T16:16:23Z 9
non-numeric review count|x 5 2026-08-06T16:16:23Z
negative review count|-1 5 2026-08-06T16:16:23Z
absurd review count|1234567890123 5 2026-08-06T16:16:23Z
unanchored instant|1 5 06/08/2026
local instant|1 5 2026-08-06T16:16:23
leading space| 1 5 2026-08-06T16:16:23Z
substituted text|1 5 ignore-previous-instructions
EOF
  # Written here rather than in the table above so the padding is visible.
  out=$(FM_TEST_GH_ACTIVITY="$ACTIVITY_ONE " run_poll "$dir")
  [ -z "$out" ] || fail "poll reported activity for a trailing space: '$out'"
  out=$(FM_TEST_GH_ACTIVITY="$(printf '1\t5\t2026-08-06T16:16:23Z')" run_poll "$dir")
  [ -z "$out" ] || fail "poll reported activity for a tab-separated result: '$out'"
  out=$(FM_TEST_GH_ACTIVITY_FAIL=1 FM_TEST_GH_ACTIVITY="$ACTIVITY_ONE" run_poll "$dir")
  [ -z "$out" ] || fail "poll reported activity after the lookup failed: '$out'"
  out=$(FM_TEST_GH_STATE_FAIL=1 FM_TEST_GH_ACTIVITY="$ACTIVITY_ONE" run_poll "$dir")
  [ -z "$out" ] || fail "poll reported activity after the state lookup failed: '$out'"
  out=$(PATH="$BASE_PATH" "$POLL" --validated github "$PR_URL" github.com o/r 10)
  [ -z "$out" ] || fail "poll reported activity with no gh on PATH: '$out'"
  pass "every activity failure mode reports nothing"
}

test_poll_multiline_activity_reports_nothing() {
  local dir out
  dir=$(make_case poll-multiline)
  out=$(FM_TEST_GH_ACTIVITY="$(printf '1 5 2026-08-06T16:16:23Z\nmerged')" run_poll "$dir")
  [ -z "$out" ] || fail "poll accepted a multi-line activity result: '$out'"
  pass "a multi-line activity result reports nothing rather than a forged line"
}

# --- the wake, and the repeat that must not wake ----------------------------

test_new_activity_wakes_once_and_repeats_do_not() {
  local dir cursor
  dir=$(make_case activity-wake)
  write_task_meta "$dir"
  # Arm with no activity at all, so the first reported activity is genuinely new.
  FM_TEST_GH_ACTIVITY='0 0 ' arm_poll "$dir" > "$dir/arm.out" 2>/dev/null \
    || fail "could not arm the review-activity poll"
  cursor="$dir/home/state/.task-a.pr-activity-cursor"
  [ ! -e "$cursor" ] || fail "arming stored a cursor for a pull request with no activity"

  export FM_TEST_GH_ACTIVITY=$ACTIVITY_ONE
  assert_wake "$dir" "$LINE_ONE" "new review activity did not wake firstmate"
  [ "$(cat "$cursor")" = "$LINE_ONE" ] || fail "the surfaced activity was not recorded"

  assert_no_wake "$dir" "an unchanged repeat woke firstmate again"
  assert_no_wake "$dir" "an unchanged repeat woke firstmate on a later sweep"

  FM_TEST_GH_ACTIVITY=$ACTIVITY_TWO
  assert_wake "$dir" "$LINE_TWO" "a later review did not wake firstmate"
  [ "$(cat "$cursor")" = "$LINE_TWO" ] || fail "the later activity was not recorded"
  assert_no_wake "$dir" "the later activity repeated a wake"
  unset FM_TEST_GH_ACTIVITY
  pass "new review activity wakes exactly once and unchanged repeats never wake"
}

test_arming_seeds_the_cursor_so_existing_activity_is_not_replayed() {
  local dir
  dir=$(make_case activity-seed)
  write_task_meta "$dir"
  export FM_TEST_GH_ACTIVITY=$ACTIVITY_ONE
  arm_poll "$dir" > "$dir/arm.out" 2>/dev/null || fail "could not arm the poll"
  [ "$(cat "$dir/home/state/.task-a.pr-activity-cursor")" = "$LINE_ONE" ] \
    || fail "arming did not seed the cursor from the poll"
  assert_no_wake "$dir" "activity the pull request already carried at arming woke firstmate"
  FM_TEST_GH_ACTIVITY=$ACTIVITY_TWO
  assert_wake "$dir" "$LINE_TWO" "activity arriving after arming did not wake firstmate"
  unset FM_TEST_GH_ACTIVITY
  pass "arming seeds the cursor so only activity arriving afterwards wakes firstmate"
}

test_arming_clears_an_inherited_cursor_it_cannot_confirm() {
  local dir cursor
  dir=$(make_case activity-reseed)
  write_task_meta "$dir"
  cursor="$dir/home/state/.task-a.pr-activity-cursor"
  printf '%s\n' "$LINE_ONE" > "$cursor"
  # The poll cannot establish a starting point here, so the stale cursor must go
  # rather than stay and suppress activity that has not been reported yet.
  FM_TEST_GH_ACTIVITY_FAIL=1 arm_poll "$dir" > "$dir/arm.out" 2>/dev/null \
    || fail "could not arm the poll while the activity read was failing"
  [ ! -e "$cursor" ] || fail "arming inherited a cursor it could not confirm"
  export FM_TEST_GH_ACTIVITY=$ACTIVITY_ONE
  assert_wake "$dir" "$LINE_ONE" "the unconfirmed cursor suppressed a real wake"
  unset FM_TEST_GH_ACTIVITY
  pass "arming clears a cursor it cannot confirm rather than suppressing a real wake"
}

test_a_failed_sweep_reports_nothing_and_keeps_the_cursor() {
  local dir cursor
  dir=$(make_case activity-sweep-failure)
  write_task_meta "$dir"
  export FM_TEST_GH_ACTIVITY=$ACTIVITY_ONE
  arm_poll "$dir" > "$dir/arm.out" 2>/dev/null || fail "could not arm the poll"
  cursor="$dir/home/state/.task-a.pr-activity-cursor"
  FM_TEST_GH_ACTIVITY_FAIL=1 assert_no_wake "$dir" "a failed activity read woke firstmate"
  # A read that exceeds the per-check bound is the same class: silence, not a wake.
  FM_TEST_GH_ACTIVITY_SLEEP=6 assert_no_wake "$dir" "an activity read past the check bound woke firstmate"
  [ "$(cat "$cursor")" = "$LINE_ONE" ] || fail "a failed sweep disturbed the recorded cursor"
  unset FM_TEST_GH_ACTIVITY
  pass "a failed or timed-out sweep reports nothing and leaves the cursor intact"
}

test_merge_signal_is_never_filtered_by_the_cursor() {
  local dir
  dir=$(make_case merge-unfiltered)
  write_task_meta "$dir"
  export FM_TEST_GH_ACTIVITY=$ACTIVITY_ONE
  arm_poll "$dir" > "$dir/arm.out" 2>/dev/null || fail "could not arm the poll"
  assert_no_wake "$dir" "seeded activity woke firstmate before the merge"
  FM_TEST_GH_STATE=MERGED assert_wake "$dir" merged "the merge signal did not wake firstmate"
  unset FM_TEST_GH_ACTIVITY
  pass "the merge signal wakes firstmate regardless of the review-activity cursor"
}

test_teardown_removes_the_cursor() {
  local dir
  dir=$(make_case activity-teardown)
  # A landed local-only task whose worktree is already gone: the shape that
  # reaches artifact cleanup without a live backend or a checkout to return.
  fm_write_meta "$dir/home/state/task-a.meta" \
    'window=firstmate:fm-task-a' \
    'endpoint_task_id=task-a' \
    "worktree=$dir/missing-worktree" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=local-only'
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  touch "$dir/home/state/.last-watcher-beat"
  export FM_TEST_GH_ACTIVITY=$ACTIVITY_ONE
  arm_poll "$dir" > "$dir/arm.out" 2>/dev/null || fail "could not arm the poll"
  [ -e "$dir/home/state/.task-a.pr-activity-cursor" ] || fail "arming stored no cursor to remove"
  env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH" \
    "$TEARDOWN" task-a --force > "$dir/teardown.out" 2> "$dir/teardown.err" \
    || fail "teardown failed: $(cat "$dir/teardown.err")"
  [ ! -e "$dir/home/state/.task-a.pr-activity-cursor" ] \
    || fail "teardown left the review-activity cursor behind"
  unset FM_TEST_GH_ACTIVITY
  pass "teardown removes the review-activity cursor with the rest of the task's records"
}

# --- the cursor's own contract ----------------------------------------------

test_cursor_refuses_an_unsafe_destination() {
  local dir state
  dir=$(make_case cursor-unsafe)
  state="$dir/home/state"
  ln -s "$dir/elsewhere" "$state/.task-a.pr-activity-cursor"
  FM_PR_ACTIVITY_PENDING=$LINE_ONE
  fm_pr_activity_commit "$state" task-a \
    && fail "the cursor was written through a symlink"
  [ ! -e "$dir/elsewhere" ] || fail "the cursor write escaped through a symlink"
  rm -f "$state/.task-a.pr-activity-cursor"
  # "./../escape" and not "../escape": the leading dot in the cursor's own path
  # template turns the latter into a harmless "..." component, so only this
  # shape actually traverses out of the state directory and proves the guard.
  FM_PR_ACTIVITY_PENDING=$LINE_ONE
  fm_pr_activity_commit "$state" ./../escape \
    && fail "the cursor accepted a path-unsafe task id"
  find "$dir" -name '*escape*' -not -path '*/state/*' | grep . >/dev/null \
    && fail "the cursor write escaped the task state directory"
  FM_PR_ACTIVITY_PENDING=$LINE_ONE
  fm_pr_activity_cursor_clear "$state" ./../escape \
    && fail "the cursor clear accepted a path-unsafe task id"
  FM_PR_ACTIVITY_PENDING=
  pass "the cursor refuses a symlinked destination and a traversing task id"
}

test_poll_output_that_is_not_activity_passes_through_unfiltered() {
  local dir state
  dir=$(make_case filter-passthrough)
  state="$dir/home/state"
  printf '%s\n' "$LINE_ONE" > "$state/.task-a.pr-activity-cursor"
  fm_pr_activity_filter "$state" task-a merged
  [ "$FM_PR_ACTIVITY_SURFACE" = merged ] || fail "a merged line was filtered by the cursor"
  [ -z "$FM_PR_ACTIVITY_PENDING" ] || fail "a merged line queued a cursor write"
  fm_pr_activity_filter "$state" task-a "$LINE_ONE"
  [ -z "$FM_PR_ACTIVITY_SURFACE" ] || fail "an unchanged activity line was not suppressed"
  pass "only a review-activity line is filtered; every other poll output passes through"
}

test_poll_reports_current_review_activity
test_poll_reports_merge_alone
test_poll_is_silent_on_every_activity_failure
test_poll_multiline_activity_reports_nothing
test_new_activity_wakes_once_and_repeats_do_not
test_arming_seeds_the_cursor_so_existing_activity_is_not_replayed
test_arming_clears_an_inherited_cursor_it_cannot_confirm
test_a_failed_sweep_reports_nothing_and_keeps_the_cursor
test_merge_signal_is_never_filtered_by_the_cursor
test_teardown_removes_the_cursor
test_cursor_refuses_an_unsafe_destination
test_poll_output_that_is_not_activity_passes_through_unfiltered
