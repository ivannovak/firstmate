#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
#   - The update SOURCE is configurable: a home that names its own remote follows
#     that remote for itself and every secondmate, a home that names none still
#     follows origin, a named remote the checkout lacks is skipped rather than
#     silently swapped, and an unusable name refuses the run before anything
#     moves. Fast-forward-only holds identically under a configured source.
#   - A config FILE that exists but cannot be read still resolves to origin, so
#     a home stays usable, but never silently: it names the file and the remote
#     it used instead.
#   - The resolvers in bin/fm-update-source-lib.sh, exercised directly: unsafe
#     remote names refuse with their reason intact in the caller's shell, and
#     one repository normalizes to one forge identity across every URL spelling.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# The shared fast-forward helper, for the one contract below that is about the
# library's own fetch behavior rather than about a whole update run.
# shellcheck source=bin/fm-ff-lib.sh
. "$ROOT/bin/fm-ff-lib.sh"

# The resolvers that decide which remote this fleet follows and which repository
# its upstream contributions go to. They are sourced directly so their own
# refusals can be exercised without a whole update run, and so bin/fm-test-run.sh
# --changed can resolve a change to bin/fm-update-source-lib.sh to a suite: its
# path→family map finds a library's consuming tests by scanning for its basename.
# shellcheck source=bin/fm-update-source-lib.sh
. "$ROOT/bin/fm-update-source-lib.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Give a world a SECOND publishing remote named "fork", seeded from origin's
# current tip and reachable from the firstmate repo (and therefore from every
# worktree of it). Nothing consults it until config/update-remote names it, so
# adding it leaves every origin-sourced test unchanged.
add_fork_remote() {
  local w=$1
  git clone -q --bare "$w/origin.git" "$w/fork.git"
  git -C "$w/fork.git" symbolic-ref HEAD refs/heads/main
  git -C "$w/main" remote add fork "$w/fork.git"
  git clone -q "$w/fork.git" "$w/forkseed"
}

# Advance the FORK remote by one commit, leaving origin exactly where it was.
# mode matches bump_origin: instr changes the instruction surface, readme does not.
bump_fork() {
  local w=$1 mode=$2
  git -C "$w/forkseed" pull -q origin main >/dev/null 2>&1 || true
  printf 'fork-r-%s\n' "$mode" >> "$w/forkseed/README.md"
  if [ "$mode" = instr ]; then
    printf 'fork-v2\n' > "$w/forkseed/AGENTS.md"
    printf 'echo fork\n' > "$w/forkseed/bin/tool.sh"
    printf 'fork-s2\n' > "$w/forkseed/.agents/skills/note.md"
  fi
  git -C "$w/forkseed" add -A
  git -C "$w/forkseed" commit -qm "fork-bump-$mode"
  git -C "$w/forkseed" push -q origin main
}

# Point this home's update source at <remote>.
set_update_remote() {
  local w=$1 remote=$2
  mkdir -p "$w/home/config"
  printf '%s\n' "$remote" > "$w/home/config/update-remote"
}

# The commit the fork remote currently publishes on main.
fork_tip() {
  git -C "$1/fork.git" rev-parse refs/heads/main
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# Same run with stderr folded in, for the refusal cases where the diagnostic and
# the non-zero exit ARE the behavior. Output goes to a file rather than a command
# substitution so RUN_RC reaches the caller's shell instead of dying with a
# subshell (tests/lib.sh documents that boundary).
RUN_RC=0
RUN_OUT=""
run_update_checked() {
  local w=$1 outfile="$TMP_ROOT/update.out"
  RUN_RC=0
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" >"$outfile" 2>&1 || RUN_RC=$?
  RUN_OUT=$(cat "$outfile")
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "updated secondmate is nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 main + secondmate fast-forward (single-parent), reread + nudge signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "fm-sm1" "live-meta secondmate is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

# --- T12: a configured update source, not origin, is what the fleet follows --
# The whole point of the configurable: a commit that lands ONLY on the fork
# reaches this home and its secondmate, with no dependency on origin ever
# carrying it. Origin is deliberately left behind here, so an assertion that
# the targets moved is an assertion that they followed the fork.
test_configured_update_source_reaches_the_fleet() {
  local w out fork_rev origin_rev
  w=$(new_world t12)
  add_fork_remote "$w"
  add_sm "$w" sm1
  set_update_remote "$w" fork
  bump_fork "$w" instr

  out=$(run_update "$w")
  fork_rev=$(fork_tip "$w")
  origin_rev=$(git -C "$w/origin.git" rev-parse refs/heads/main)

  assert_contains "$out" "update-source: fork" "the source actually used is reported"
  assert_contains "$out" "firstmate: updated " "firstmate advanced from the fork"
  assert_contains "$out" "secondmate sm1: updated " "secondmate advanced from the fork"
  assert_contains "$out" "reread-firstmate: yes" "fork instruction change triggers reread"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$fork_rev" ] \
    || fail "firstmate HEAD is not at the fork tip"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$fork_rev" ] \
    || fail "secondmate HEAD is not at the fork tip"
  [ "$fork_rev" != "$origin_rev" ] \
    || fail "fixture did not diverge fork from origin, so the source is unproven"
  # The commit is in the working tree, not just the ref.
  grep -q 'fork-v2' "$w/main/AGENTS.md" || fail "fork content did not land in the checkout"
  # Origin was never advanced by this run, and was never even fetched: its
  # remote-tracking ref still points at the pre-fork commit.
  [ "$(git -C "$w/main" rev-parse refs/remotes/origin/main)" = "$origin_rev" ] \
    || fail "origin remote-tracking ref moved during a fork-sourced update"
  pass "T12 a configured update source carries a fork-only commit to the whole fleet"
}

# --- T13: fast-forward-only survives the source change ----------------------
# The safety property is not weakened by making the source configurable: a home
# holding its own commit is skipped and reported against the CONFIGURED base,
# and its unlanded work is left exactly where it was.
test_diverged_secondmate_skipped_on_configured_source() {
  local w out before
  w=$(new_world t13)
  add_fork_remote "$w"
  add_sm "$w" sm1
  set_update_remote "$w" fork
  printf 'unlanded secondmate work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_fork "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from fork/main" \
    "diverged home is skipped against the configured base"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  grep -q 'unlanded secondmate work' "$w/sm1/AGENTS.md" \
    || fail "unlanded secondmate work was discarded"
  pass "T13 fast-forward-only still refuses a diverged home under a configured source"
}

# --- T14: a source the target does not have is skipped, never guessed -------
test_missing_configured_remote_is_skipped() {
  local w out before
  w=$(new_world t14)
  add_sm "$w" sm1
  set_update_remote "$w" fork   # deliberately never added to this world
  before=$(git -C "$w/main" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "update-source: fork" "the configured source is still reported"
  assert_contains "$out" "firstmate: skipped: no fork remote" "missing remote is named"
  assert_contains "$out" "secondmate sm1: skipped: no fork remote" "secondmate reports the same"
  assert_contains "$out" "nudge-secondmates: none" "nothing advanced, nothing nudged"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "firstmate advanced from a remote it was not told to use"
  pass "T14 a configured source the checkout lacks is skipped, never silently swapped"
}

# --- T15: an unusable configured value refuses the whole run ----------------
# Silently falling back to origin would move the entire fleet to a source the
# operator did not name, so the run stops before any target is touched.
test_unsafe_configured_remote_refuses_before_touching_anything() {
  local w before
  w=$(new_world t15)
  add_sm "$w" sm1
  set_update_remote "$w" '--upload-pack=evil'
  before=$(git -C "$w/main" rev-parse HEAD)
  bump_origin "$w" instr

  run_update_checked "$w"

  [ "$RUN_RC" -ne 0 ] || fail "an unusable update source exited 0"
  assert_contains "$RUN_OUT" "not a safe git remote name" "the refusal names the problem"
  assert_not_contains "$RUN_OUT" "firstmate: updated" "nothing was advanced"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "firstmate advanced despite an unusable configured source"
  pass "T15 an unusable configured source refuses the run instead of falling back"
}

# --- T16: the environment override reaches the same resolution --------------
# This is the path bin/fm-remote-secondmate-control.sh uses to carry the fleet's
# choice into a remote code root that has no home config of its own.
test_environment_override_selects_the_source() {
  local w out fork_rev
  w=$(new_world t16)
  add_fork_remote "$w"
  bump_fork "$w" instr

  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" FM_UPDATE_REMOTE=fork "$UPDATE" 2>/dev/null)
  fork_rev=$(fork_tip "$w")

  assert_contains "$out" "update-source: fork" "the override is reported as the source"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$fork_rev" ] \
    || fail "the environment override did not select the fork"
  pass "T16 FM_UPDATE_REMOTE selects the source for a checkout with no home config"
}

# --- T17: one object store, two sources, both actually fetched -------------
# The helper fetches each object store at most once so a fleet of worktrees
# costs one network round trip. Once the SOURCE is a parameter, that saving must
# be per source: fetching one remote does not refresh another, so a second
# source asked for on the same object store must still be fetched.
test_fetch_is_deduped_per_source_not_per_object_store() {
  local w origin_before fork_before
  w=$(new_world t17)
  add_fork_remote "$w"
  bump_origin "$w" instr
  bump_fork "$w" readme
  origin_before=$(git -C "$w/main" rev-parse refs/remotes/origin/main)
  fork_before=$(git -C "$w/main" rev-parse refs/remotes/fork/main)

  FETCHED=""
  fetch_once "$w/main" origin || fail "fetching origin failed"
  fetch_once "$w/main" fork || fail "fetching fork failed"

  [ "$(git -C "$w/main" rev-parse refs/remotes/origin/main)" != "$origin_before" ] \
    || fail "origin was not fetched"
  [ "$(git -C "$w/main" rev-parse refs/remotes/fork/main)" != "$fork_before" ] \
    || fail "fork was not fetched after origin (dedup collapsed two sources into one)"
  pass "T17 fetch dedup is per source, so a second source on one object store still refreshes"
}

# --- T18: an unreadable source file falls back to origin, but never quietly --
# The fallback itself is deliberate: an unconfigured or reconciled home must
# keep working. What must never happen is that a permissions accident or a
# stray symlink moves the whole fleet's source with nothing to notice, so the
# run continues and says which file it could not read and what it used instead.
test_unreadable_source_config_falls_back_loudly() {
  local w
  w=$(new_world t18)
  add_fork_remote "$w"
  mkdir -p "$w/home/config"
  printf 'fork\n' > "$w/dotfiles-update-remote"
  ln -s "$w/dotfiles-update-remote" "$w/home/config/update-remote"
  bump_origin "$w" instr

  run_update_checked "$w"

  [ "$RUN_RC" -eq 0 ] || fail "an unreadable update-source file refused the run"
  assert_contains "$RUN_OUT" "update-source: origin" "the fallback source is reported"
  assert_contains "$RUN_OUT" "config/update-remote is not a readable ordinary file" \
    "the warning names the file it could not read"
  assert_contains "$RUN_OUT" "using the default update source 'origin'" \
    "the warning states the remote actually used"
  assert_contains "$RUN_OUT" "firstmate: updated" "the fallback still updated the fleet"

  # Positive control: the same run with an ordinary readable file follows the
  # configured source and is silent, so the warning above is not unconditional.
  rm -f "$w/home/config/update-remote"
  printf 'fork\n' > "$w/home/config/update-remote"
  run_update_checked "$w"
  [ "$RUN_RC" -eq 0 ] || fail "a readable update-source file refused the run"
  assert_contains "$RUN_OUT" "update-source: fork" "a readable file selects its remote"
  assert_not_contains "$RUN_OUT" "not a readable ordinary file" \
    "a readable file still warned"
  pass "T18 an unreadable update-source file falls back to origin loudly, not silently"
}

# --- T19: the resolvers' own contracts, exercised directly ------------------
# These decide which remote a whole fleet follows and which pull requests are
# never waited on, and both answers are consumed by scripts (bin/fm-pr-check.sh,
# bin/fm-pr-lib.sh, bin/fm-absorb-upstream.sh) whose suites cannot reach these
# refusals themselves.
test_source_resolvers_refuse_and_normalize() {
  local w err id
  w=$(new_world t19)

  for id in fork upstream-2 a.b_c-1 o; do
    fm_update_source_remote_name_safe "$id" || fail "safe remote name '$id' was rejected"
  done
  # shellcheck disable=SC2016 # Literal rejected remote-name bytes are test data.
  for id in '' '-x' '--upload-pack=evil' 'a b' 'a/b' 'a;b' '$(x)' "$(printf 'a%.0s' $(seq 65))"; do
    ! fm_update_source_remote_name_safe "$id" || fail "unsafe remote name '$id' was accepted"
  done

  # One repository, spelled the three ways a git remote URL is actually
  # written, plus a different letter case: one normalized identity.
  local https_id ssh_id scp_id
  https_id=$(fm_update_source_forge_identity 'https://github.com/Upstream-Org/FirstMate.git') \
    || fail "an https remote URL had no forge identity"
  ssh_id=$(fm_update_source_forge_identity 'ssh://git@github.com/upstream-org/firstmate') \
    || fail "an ssh remote URL had no forge identity"
  scp_id=$(fm_update_source_forge_identity 'git@github.com:upstream-org/firstmate.git/') \
    || fail "an scp-like remote URL had no forge identity"
  [ "$https_id" = "$ssh_id" ] && [ "$ssh_id" = "$scp_id" ] \
    || fail "the same repository resolved to different forge identities"
  [ "$https_id" = "$(printf 'github.com\tupstream-org/firstmate')" ] \
    || fail "forge identity was not normalized to host and owner/repo"
  for id in '' '/srv/git/mirror.git' 'file:///srv/git/mirror.git' 'https://github.com' \
    'https://github.com/no-owner' 'ssh://git@/firstmate' '-upload-pack=evil'; do
    ! fm_update_source_forge_identity "$id" >/dev/null \
      || fail "'$id' was accepted as a forge identity"
  done

  # An unsafe configured NAME refuses and says why; the value is cleared so no
  # caller can proceed on a stale one.
  mkdir -p "$w/home/config"
  printf -- '--upload-pack=evil\n' > "$w/home/config/upstream-remote"
  ! fm_upstream_contribution_remote_var "$w/home/config" \
    || fail "an unsafe upstream remote name resolved successfully"
  [ -z "$FM_UPSTREAM_CONTRIBUTION_REMOTE" ] || fail "a refused upstream name still set a value"
  assert_contains "$FM_UPDATE_SOURCE_ERROR" "not a safe git remote name" \
    "the upstream refusal states the reason in the caller's own shell"

  # An unreadable upstream file loses the check, so it warns too.
  rm -f "$w/home/config/upstream-remote"
  printf 'upstream\n' > "$w/dotfiles-upstream-remote"
  ln -s "$w/dotfiles-upstream-remote" "$w/home/config/upstream-remote"
  err="$w/upstream-warn.txt"
  fm_upstream_contribution_remote_var "$w/home/config" 2> "$err" \
    || fail "an unreadable upstream file refused instead of reporting no upstream"
  [ -z "$FM_UPSTREAM_CONTRIBUTION_REMOTE" ] || fail "an unreadable upstream file yielded a remote"
  assert_grep 'upstream-remote is not a readable ordinary file' "$err" \
    "the unreadable upstream file was reported"

  # The identity match itself: a positive match only, in every URL spelling,
  # and never for another repository.
  rm -f "$w/home/config/upstream-remote"
  printf 'upstream\n' > "$w/home/config/upstream-remote"
  for id in 'https://github.com/upstream-org/firstmate.git' \
    'git@github.com:Upstream-Org/FirstMate.git' \
    'ssh://git@github.com/upstream-org/firstmate'; do
    git -C "$w/main" remote remove upstream >/dev/null 2>&1 || true
    git -C "$w/main" remote add upstream "$id"
    fm_upstream_contribution_pr_match "$w/home/config" "$w/main" github.com upstream-org/firstmate \
      || fail "an upstream pull request did not match for '$id'"
    ! fm_upstream_contribution_pr_match "$w/home/config" "$w/main" github.com captain/example-core \
      || fail "an unrelated repository matched the upstream identity for '$id'"
    ! fm_upstream_contribution_pr_match "$w/home/config" "$w/main" gitlab.com upstream-org/firstmate \
      || fail "a different host matched the upstream identity for '$id'"
  done

  # An upstream that cannot be resolved is not a match, and says why rather
  # than leaving the caller to guess.
  git -C "$w/main" remote remove upstream
  git -C "$w/main" remote add upstream "$w/not-a-forge"
  ! fm_upstream_contribution_pr_match "$w/home/config" "$w/main" github.com upstream-org/firstmate \
    || fail "an unresolvable upstream produced a match"
  assert_contains "$FM_UPSTREAM_CONTRIBUTION_WARNING" "no resolvable forge identity" \
    "an unresolvable upstream reports why it could not judge"

  # A home with no upstream configured has nothing to say and nothing to match.
  rm -f "$w/home/config/upstream-remote"
  ! fm_upstream_contribution_pr_match "$w/home/config" "$w/main" github.com upstream-org/firstmate \
    || fail "a home with no upstream matched one"
  [ -z "$FM_UPSTREAM_CONTRIBUTION_WARNING" ] \
    || fail "a home with no upstream warned about one"
  pass "T19 the update-source resolvers refuse unsafe values and normalize one repository to one identity"
}

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_configured_update_source_reaches_the_fleet
test_diverged_secondmate_skipped_on_configured_source
test_missing_configured_remote_is_skipped
test_unsafe_configured_remote_refuses_before_touching_anything
test_environment_override_selects_the_source
test_fetch_is_deduped_per_source_not_per_object_store
test_unreadable_source_config_falls_back_loudly
test_source_resolvers_refuse_and_normalize

echo "# all fm-update tests passed"
