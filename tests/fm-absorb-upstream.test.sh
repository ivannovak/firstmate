#!/usr/bin/env bash
# Tests for bin/fm-absorb-upstream.sh: pulling the upstream open-source
# project's work INTO the fork this fleet runs from.
#
# This is the direction that carries a third party's history into the branch
# every home fast-forwards from, so the guarantees under test are mostly about
# what it REFUSES to do:
#   - FAST-FORWARD ONLY. Upstream lands on the fork only when the fork's tip is
#     already an ancestor of it, and the fork's previous tip stays reachable
#     from the new one - history is extended, never rewritten.
#   - Genuine divergence (each side carrying commits the other lacks) is
#     reported with ahead/behind counts and exits non-zero, having written
#     nothing. It is never merged, rebased, or forced away.
#   - The UPSTREAM remote is never written to at all, in any outcome.
#   - The local checkout is never moved; advancing checkouts stays with
#     bin/fm-update.sh.
#   - --dry-run reports the same verdict and writes nothing.
#   - An unconfigured, unsafe, or self-referential remote pair refuses rather
#     than guessing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ABSORB="$ROOT/bin/fm-absorb-upstream.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-absorb-upstream)

# A world with the real two-remote shape: a bare "upstream" everyone reads, a
# bare "fork" this fleet runs from, seeded from the same first commit, and a
# firstmate repo carrying both remotes plus a home dir. Echoes the world dir.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/upstream.git"
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/upstream.git" "$w/upseed" 2>/dev/null
  printf 'v1\n' > "$w/upseed/AGENTS.md"
  printf 'r1\n' > "$w/upseed/README.md"
  git -C "$w/upseed" add -A
  git -C "$w/upseed" commit -qm c1
  git -C "$w/upseed" push -q origin main

  git clone -q --bare "$w/upstream.git" "$w/fork.git"
  git -C "$w/fork.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/fork.git" "$w/forkseed" 2>/dev/null

  git clone -q "$w/fork.git" "$w/main"
  git -C "$w/main" remote rename origin fork >/dev/null 2>&1
  git -C "$w/main" remote add upstream "$w/upstream.git"
  git -C "$w/main" remote set-head fork main >/dev/null 2>&1 || true
  git -C "$w/main" fetch -q upstream

  printf 'fork\n' > "$w/home/config/update-remote"
  printf 'upstream\n' > "$w/home/config/upstream-remote"

  printf '%s\n' "$w"
}

# Advance the upstream project by one commit.
bump_upstream() {
  local w=$1 note=$2
  printf 'upstream-%s\n' "$note" >> "$w/upseed/README.md"
  git -C "$w/upseed" add -A
  git -C "$w/upseed" commit -qm "upstream-$note"
  git -C "$w/upseed" push -q origin main
}

# Land one of the captain's own commits on the fork.
bump_fork() {
  local w=$1 note=$2
  git -C "$w/forkseed" pull -q origin main >/dev/null 2>&1 || true
  printf 'fork-%s\n' "$note" >> "$w/forkseed/AGENTS.md"
  git -C "$w/forkseed" add -A
  git -C "$w/forkseed" commit -qm "fork-$note"
  git -C "$w/forkseed" push -q origin main
}

fork_tip() { git -C "$1/fork.git" rev-parse refs/heads/main; }
upstream_tip() { git -C "$1/upstream.git" rev-parse refs/heads/main; }

RUN_RC=0
RUN_OUT=""
# Output goes through a file, not a command substitution, so RUN_RC survives in
# the caller's shell (tests/lib.sh documents that subshell boundary).
run_absorb() {
  local w=$1
  shift
  local outfile="$TMP_ROOT/absorb.out"
  RUN_RC=0
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$ABSORB" "$@" >"$outfile" 2>&1 || RUN_RC=$?
  RUN_OUT=$(cat "$outfile")
}

# --- A1: upstream already contained in the fork is a no-op ------------------
test_current_when_fork_already_has_upstream() {
  local w fork_before
  w=$(new_world a1)
  bump_fork "$w" own-work        # fork strictly ahead: the steady state
  fork_before=$(fork_tip "$w")

  run_absorb "$w"

  [ "$RUN_RC" -eq 0 ] || fail "a fork already carrying upstream exited $RUN_RC"
  assert_contains "$RUN_OUT" "absorb-upstream: current" "reports nothing to absorb"
  [ "$(fork_tip "$w")" = "$fork_before" ] || fail "the fork moved with nothing to absorb"
  pass "A1 a fork that already contains upstream absorbs nothing"
}

# --- A2: a clean fast-forward lands upstream on the fork --------------------
test_fast_forward_absorbs_upstream() {
  local w fork_before up_after
  w=$(new_world a2)
  fork_before=$(fork_tip "$w")
  bump_upstream "$w" one
  bump_upstream "$w" two

  run_absorb "$w"
  up_after=$(upstream_tip "$w")

  [ "$RUN_RC" -eq 0 ] || fail "a clean fast-forward exited $RUN_RC"
  assert_contains "$RUN_OUT" "absorb-upstream: absorbed " "reports the absorb"
  [ "$(fork_tip "$w")" = "$up_after" ] || fail "the fork did not reach the upstream tip"
  # History was EXTENDED, not rewritten: the fork's previous tip is still an
  # ancestor of where it now points.
  git -C "$w/main" merge-base --is-ancestor "$fork_before" "$(fork_tip "$w")" \
    || fail "the fork's previous tip is no longer reachable (history was rewritten)"
  pass "A2 a clean fast-forward lands upstream on the fork without rewriting it"
}

# --- A3: genuine divergence is reported, never forced -----------------------
# The case the captain's model actually produces: the fork carries work upstream
# has not taken, and upstream has moved on independently.
test_diverged_reports_and_writes_nothing() {
  local w fork_before up_before
  w=$(new_world a3)
  bump_fork "$w" own-work
  bump_upstream "$w" their-work
  fork_before=$(fork_tip "$w")
  up_before=$(upstream_tip "$w")

  run_absorb "$w"

  [ "$RUN_RC" -ne 0 ] || fail "a diverged absorb exited 0"
  assert_contains "$RUN_OUT" "absorb-upstream: diverged ahead=1 behind=1" \
    "reports the shape of the divergence"
  [ "$(fork_tip "$w")" = "$fork_before" ] || fail "the fork was moved despite divergence"
  [ "$(upstream_tip "$w")" = "$up_before" ] || fail "upstream was written to"
  # The fork's own commit is still there, not replaced by upstream's.
  git -C "$w/main" fetch -q fork
  git -C "$w/main" merge-base --is-ancestor "$fork_before" refs/remotes/fork/main \
    || fail "the fork's own work was discarded"
  pass "A3 genuine divergence is reported with counts and writes nothing"
}

# --- A4: --dry-run reaches the same verdict and writes nothing --------------
test_dry_run_writes_nothing() {
  local w fork_before
  w=$(new_world a4)
  fork_before=$(fork_tip "$w")
  bump_upstream "$w" one

  run_absorb "$w" --dry-run

  [ "$RUN_RC" -eq 0 ] || fail "--dry-run exited $RUN_RC"
  assert_contains "$RUN_OUT" "absorb-upstream: would-absorb " "reports what it would do"
  [ "$(fork_tip "$w")" = "$fork_before" ] || fail "--dry-run pushed to the fork"
  pass "A4 --dry-run reports the verdict and writes nothing"
}

# --- A5: the local checkout is never advanced -------------------------------
# Advancing checkouts belongs to bin/fm-update.sh; absorbing only moves the
# remote branch the fleet then updates from.
test_local_checkout_untouched() {
  local w head_before
  w=$(new_world a5)
  head_before=$(git -C "$w/main" rev-parse HEAD)
  bump_upstream "$w" one

  run_absorb "$w"

  [ "$RUN_RC" -eq 0 ] || fail "absorb exited $RUN_RC"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$head_before" ] \
    || fail "the local checkout was advanced by the absorb path"
  pass "A5 absorbing never advances the local checkout"
}

# --- A6: an unconfigured or self-referential pair refuses -------------------
test_refuses_without_a_usable_pair() {
  local w fork_before
  w=$(new_world a6)
  fork_before=$(fork_tip "$w")
  bump_upstream "$w" one

  rm -f "$w/home/config/upstream-remote"
  run_absorb "$w"
  [ "$RUN_RC" -ne 0 ] || fail "absorbing with no upstream configured exited 0"
  assert_contains "$RUN_OUT" "no upstream contribution remote is configured" \
    "names the missing configuration"

  printf 'fork\n' > "$w/home/config/upstream-remote"
  run_absorb "$w"
  [ "$RUN_RC" -ne 0 ] || fail "upstream == update source exited 0"
  assert_contains "$RUN_OUT" "nothing to absorb between them" "refuses a self-referential pair"

  printf -- '--upload-pack=evil\n' > "$w/home/config/upstream-remote"
  run_absorb "$w"
  [ "$RUN_RC" -ne 0 ] || fail "an unsafe upstream remote name exited 0"
  assert_contains "$RUN_OUT" "not a safe git remote name" "refuses an unsafe remote name"

  printf 'nosuchremote\n' > "$w/home/config/upstream-remote"
  run_absorb "$w"
  [ "$RUN_RC" -ne 0 ] || fail "a missing upstream remote exited 0"
  assert_contains "$RUN_OUT" "no nosuchremote remote" "names the missing remote"

  [ "$(fork_tip "$w")" = "$fork_before" ] || fail "a refused absorb still wrote to the fork"
  pass "A6 an unconfigured, self-referential, unsafe, or missing pair refuses and writes nothing"
}

test_current_when_fork_already_has_upstream
test_fast_forward_absorbs_upstream
test_diverged_reports_and_writes_nothing
test_dry_run_writes_nothing
test_local_checkout_untouched
test_refuses_without_a_usable_pair

echo "# all fm-absorb-upstream tests passed"
