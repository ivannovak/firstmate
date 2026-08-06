#!/usr/bin/env bash
# Behavioral coverage for shared Firstmate branch naming and compatibility.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-branch-lib.sh
. "$ROOT/bin/fm-branch-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-branch)

test_names_follow_project_convention() {
  [ "$(fm_branch_name dev-5579)" = "ivannovak/dev-5579" ] \
    || fail "ticketed task branch did not preserve its Linear id"
  [ "$(fm_branch_name auctic-generated-seeder-collision)" = "ivannovak/dev-000-auctic-generated-seeder-collision" ] \
    || fail "unticketed task branch did not gain the dev-000 marker"
  pass "shared branch naming follows the handle and Linear conventions"
}

test_briefs_use_shared_names() {
  local home ticketed unticketed
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" dev-5579 firstmate --mode no-mistakes >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" auctic-generated-seeder-collision firstmate --mode local-only >/dev/null
  ticketed="$home/data/dev-5579/brief.md"
  unticketed="$home/data/auctic-generated-seeder-collision/brief.md"
  assert_grep 'git checkout -b ivannovak/dev-5579' "$ticketed" \
    "ticketed ship brief did not use the shared branch name"
  assert_grep 'git checkout -b ivannovak/dev-000-auctic-generated-seeder-collision' "$unticketed" \
    "unticketed ship brief did not use the shared branch name"
  assert_grep 'ready in branch ivannovak/dev-000-auctic-generated-seeder-collision' "$unticketed" \
    "local-only completion contract did not use the shared branch name"
  pass "ship briefs use shared ticketed and unticketed branch names"
}

test_current_and_legacy_branches_resolve() {
  local repo
  repo="$TMP_ROOT/resolve-repo"
  fm_git_init_commit "$repo"
  git -C "$repo" branch ivannovak/dev-000-current-task
  git -C "$repo" branch fm/legacy-task
  [ "$(fm_branch_resolve_local "$repo" current-task)" = "ivannovak/dev-000-current-task" ] \
    || fail "current task branch did not resolve"
  [ "$(fm_branch_resolve_local "$repo" legacy-task)" = "fm/legacy-task" ] \
    || fail "legacy task branch did not remain resolvable"
  pass "current and legacy task branches both resolve"
}

test_promote_instruction_uses_shared_name() {
  local home out
  home="$TMP_ROOT/promote-home"
  mkdir -p "$home/state"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/auctic-generated-seeder-collision.meta" \
    "window=fm-auctic-generated-seeder-collision" \
    "worktree=$TMP_ROOT/promote-worktree" \
    "project=$TMP_ROOT/promote-project" \
    "harness=codex" \
    "kind=scout"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-promote.sh" auctic-generated-seeder-collision --mode no-mistakes --yolo off)
  assert_contains "$out" 'create branch ivannovak/dev-000-auctic-generated-seeder-collision' \
    "promotion handoff did not use the shared branch name"
  pass "promotion handoff uses the shared branch name"
}

test_names_follow_project_convention
test_briefs_use_shared_names
test_current_and_legacy_branches_resolve
test_promote_instruction_uses_shared_name
