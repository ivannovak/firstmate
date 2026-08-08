#!/usr/bin/env bash
# Behavior tests for the captain-facing fleet board.
#
# The board's whole reason to exist is that it must not undercount what awaits
# the captain, so the central tests here DERIVE the expected set from the fixture
# backlog and compare it against the board's own count. A hand-written expected
# number would pass forever against a broken derivation, which is the exact
# defect this board was built to fix.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-fleet-board.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

# A secondmate home only counts as one when it carries the seed marker, its
# AGENTS.md, and a bin/ directory (bin/fm-ff-lib.sh owns that validation).
make_mate_home() {  # <dir-name> <secondmate-id>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config" "$home/bin"
  printf '%s\n' "$2" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$home"
}

# The independent instrument: count live captain holds straight out of the
# fixture markdown with grep/awk, never through the snapshot's jq parser the
# board also uses. If both agree, the board's number is not an artifact of one
# parser agreeing with itself.
expected_captain_held() {  # <backlog-path>
  awk '
    /^## / { section = $0; next }
    /^- \[/ {
      if (section == "## Done") next
      if ($0 ~ /\(hold-kind: captain\)/) n++
    }
    END { print n + 0 }
  ' "$1"
}

board_model() {  # <home> [extra args...]
  local home=$1
  shift
  FM_HOME="$home" "$BOARD" render --json "$@"
}

# --- fixtures ---------------------------------------------------------------

write_mixed_backlog() {  # <home>
  cat > "$1/data/backlog.md" <<'EOF'
## In flight
- [ ] inflight-captain-hold - Ship work parked on the captain (repo: alpha) (kind: ship) (since 2026-08-01) (hold: captain must approve the rollout) (hold-kind: captain)
- [ ] inflight-plain - Ordinary work under way (repo: alpha) (kind: ship) (since 2026-08-02)

## Queued
- [ ] queued-chore-captain-hold - Chore parked on the captain (repo: beta) (kind: chore) (since 2026-08-03) (hold: captain must pick a host) (hold-kind: captain)
- [ ] origin-decision-shape - Dedicated decision record (repo: alpha) (kind: captain) (since 2026-08-03) (hold: captain picks the shape) (hold-kind: captain)
- [ ] queued-blocked-captain-hold - Captain hold behind other work blocked-by: inflight-plain (repo: alpha) (kind: ship) (since 2026-08-04) (hold: captain decides after the other lands) (hold-kind: captain)
- [ ] queued-external-hold - Held on someone else (repo: beta) (kind: ship) (since 2026-08-04) (hold: waiting on the vendor) (hold-kind: external)

## Done
- [x] done-captain-hold - Settled captain question (repo: alpha) (kind: captain) (done 2026-08-05) (hold: was the captain's) (hold-kind: captain)
- [x] done-with-pr - Landed change https://github.com/kunchenguid/firstmate/pull/42 (repo: alpha) (kind: ship) (merged 2026-08-05)
EOF
}

# --- tests ------------------------------------------------------------------

test_needs_you_count_is_derived_not_shaped() {
  local home model expected actual ids
  home=$(make_home derived-count)
  write_mixed_backlog "$home"

  expected=$(expected_captain_held "$home/data/backlog.md")
  model=$(board_model "$home") || fail "board render failed"
  actual=$(printf '%s' "$model" | jq -r '.counts.needs_you')

  [ "$expected" -gt 0 ] || fail "fixture produced no captain holds, so this test proves nothing"
  [ "$actual" = "$expected" ] \
    || fail "needs-you count $actual did not equal the $expected live captain holds in the fixture"

  # The shape trap the original defect fell into: only the dedicated
  # kind=captain queued record surfaced. Name each one that must be present.
  ids=$(printf '%s' "$model" \
    | jq -r '[.columns[]|select(.key=="needs_you")|.groups[].threads[].items[].id]|sort|join(",")')
  [ "$ids" = "inflight-captain-hold,origin-decision-shape,queued-blocked-captain-hold,queued-chore-captain-hold" ] \
    || fail "needs-you held the wrong ids: $ids"
  pass "needs-you counts every live captain hold, whatever the task's state or kind"
}

test_needs_you_count_tracks_a_hold_appearing_and_clearing() {
  local home before after cleared expected_before expected_after

  home=$(make_home count-moves)
  write_mixed_backlog "$home"
  expected_before=$(expected_captain_held "$home/data/backlog.md")
  before=$(board_model "$home" | jq -r '.counts.needs_you')
  [ "$before" = "$expected_before" ] || fail "baseline count was already wrong: $before"

  # Add one captain hold on an ordinary in-flight ship task.
  cat >> "$home/data/backlog.md" <<'EOF'
- [x] filler - Filler so the append lands in Done (repo: alpha) (kind: ship) (done 2026-08-05)
EOF
  sed -i.bak 's#^- \[ \] inflight-plain - Ordinary work under way (repo: alpha) (kind: ship) (since 2026-08-02)$#& (hold: captain must choose the cutover window) (hold-kind: captain)#' \
    "$home/data/backlog.md"
  expected_after=$(expected_captain_held "$home/data/backlog.md")
  [ "$expected_after" -eq $((expected_before + 1)) ] \
    || fail "the fixture edit did not actually add one captain hold"
  after=$(board_model "$home" | jq -r '.counts.needs_you')
  [ "$after" = "$expected_after" ] \
    || fail "adding a captain hold did not raise the count: $before -> $after, expected $expected_after"

  # Resolve it again and watch the count fall back.
  sed -i.bak 's# (hold: captain must choose the cutover window) (hold-kind: captain)##' \
    "$home/data/backlog.md"
  cleared=$(board_model "$home" | jq -r '.counts.needs_you')
  [ "$cleared" = "$expected_before" ] \
    || fail "clearing the captain hold did not lower the count: $after -> $cleared"
  pass "the needs-you count rises when a captain hold appears and falls when it clears"
}

test_blocked_captain_hold_is_counted_but_marked_unanswerable() {
  local model item
  local home
  home=$(make_home blocked-hold)
  write_mixed_backlog "$home"
  model=$(board_model "$home") || fail "board render failed"

  printf '%s' "$model" | jq -e '.counts.needs_you_actionable == 3 and .counts.needs_you_blocked == 1' \
    >/dev/null || fail "actionable/blocked split was wrong: $(printf '%s' "$model" | jq -c .counts)"

  item=$(printf '%s' "$model" | jq -r '
    [.columns[]|select(.key=="needs_you")|.groups[].threads[].items[]
     |select(.id=="queued-blocked-captain-hold")][0]')
  printf '%s' "$item" | jq -e '.actionable == false and .blocked_by == "inflight-plain"' >/dev/null \
    || fail "the blocked captain hold did not name what blocks it: $item"
  pass "a blocked captain hold still counts and says what it is behind"
}

test_every_live_item_lands_in_exactly_one_column() {
  local home model dupes live_total column_total
  home=$(make_home one-column)
  write_mixed_backlog "$home"
  model=$(board_model "$home") || fail "board render failed"

  dupes=$(printf '%s' "$model" | jq -c '
    [.columns[]|.key as $k|.groups[].threads[].items[]|{id,col:$k}]
    | group_by(.id) | map(select(length > 1))')
  [ "$dupes" = "[]" ] || fail "an item appeared in more than one column: $dupes"

  live_total=$(grep -c '^- \[ \]' "$home/data/backlog.md")
  column_total=$(printf '%s' "$model" | jq -r '.counts.needs_you + .counts.moving + .counts.waiting')
  [ "$column_total" = "$live_total" ] \
    || fail "the live columns held $column_total of $live_total live rows"
  pass "every live row lands in exactly one column and none is dropped"
}

test_every_column_header_counts_the_real_total_not_the_shown_slice() {
  local home model
  home=$(make_home header-counts)
  write_mixed_backlog "$home"
  # Bound the landed column below what the fixture holds. The header must keep
  # reporting the true total and disclose the gap, exactly as the live columns
  # do; a header that silently counts only what fits reads as "that is all".
  model=$(FM_BOARD_LANDED=1 board_model "$home") || fail "board render failed"
  printf '%s' "$model" | jq -e '
    (.columns[] | select(.key=="landed") | .count) == .counts.landed
    and .counts.landed == 2
    and ([.columns[] | select(.key=="landed") | .groups[].threads[].items[]] | length) == 1' \
    >/dev/null || fail "the landed header did not report the real total: $(printf '%s' "$model" | jq -c '{header:(.columns[]|select(.key=="landed")|.count),total:.counts.landed}')"
  printf '%s' "$model" | jq -e '[.omitted[] | select(.surface=="landed")] | length == 1' >/dev/null \
    || fail "the capped landed column did not disclose what it dropped"
  pass "every column header counts the real total and discloses anything it could not show"
}

test_waiting_names_who_or_what_it_waits_on() {
  local home model
  home=$(make_home waiting-named)
  write_mixed_backlog "$home"
  model=$(board_model "$home") || fail "board render failed"
  printf '%s' "$model" | jq -e '
    [.columns[]|select(.key=="waiting")|.groups[].threads[].items[]]
    | length > 0 and all(.waiting_on != null and .waiting_on != "")' >/dev/null \
    || fail "a waiting card did not name what it waits on"
  printf '%s' "$model" | jq -e '
    [.columns[]|select(.key=="waiting")|.groups[].threads[].items[]
     |select(.id=="queued-external-hold")][0].waiting_on == "held: external"' >/dev/null \
    || fail "the external hold did not report its holder"
  pass "every waiting card names who or what it is waiting on"
}

test_landed_renders_pull_requests_as_full_urls() {
  local home html
  home=$(make_home landed-urls)
  write_mixed_backlog "$home"
  FM_HOME="$home" "$BOARD" render --out "$home/board.html" >/dev/null || fail "board render failed"
  html=$(cat "$home/board.html")
  case "$html" in
    *'href="https://github.com/kunchenguid/firstmate/pull/42"'*) : ;;
    *) fail "the landed pull request was not linked as a full URL" ;;
  esac
  case "$html" in
    *'>https://github.com/kunchenguid/firstmate/pull/42<'*) : ;;
    *) fail "the landed pull request was not shown as a full URL" ;;
  esac
  pass "a landed pull request renders as its complete https URL"
}

test_threads_group_decision_records_under_their_origin() {
  local home model thread
  home=$(make_home threads)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sweep-decision-alpha-shape - First question (repo: alpha) (kind: captain) (since 2026-08-01) (hold: pick a shape) (hold-kind: captain)
- [ ] sweep-decision-beta-scope - Second question (repo: alpha) (kind: captain) (since 2026-08-01) (hold: pick a scope) (hold-kind: captain)
- [ ] unrelated-hold - Standalone question (repo: alpha) (kind: chore) (since 2026-08-01) (hold: pick a host) (hold-kind: captain)

## Done
EOF
  model=$(board_model "$home") || fail "board render failed"
  thread=$(printf '%s' "$model" | jq -r '
    [.columns[]|select(.key=="needs_you")|.groups[].threads[]
     |select(.thread=="sweep")][0]')
  [ -n "$thread" ] && [ "$thread" != "null" ] \
    || fail "the two sweep decisions were not grouped under their origin thread"
  printf '%s' "$thread" | jq -e '(.items | length) == 2 and .shared == true' >/dev/null \
    || fail "the sweep thread did not hold both of its decisions: $thread"
  printf '%s' "$model" | jq -e '
    [.columns[]|select(.key=="needs_you")|.groups[].threads[]
     |select(.thread=="unrelated-hold")][0].shared == false' >/dev/null \
    || fail "a standalone item was rendered as a shared thread"
  pass "decision records group under the origin thread that raised them"
}

test_age_is_derived_and_absent_when_no_date_exists() {
  local home model
  home=$(make_home ages)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] origin-decision-shape - Dated question (repo: alpha) (kind: captain) (since 2026-08-01) (hold: decide) (hold-kind: captain)
- [ ] plain-dated-hold - Dated ordinary hold (repo: alpha) (kind: chore) (since 2026-08-01) (hold: decide) (hold-kind: captain)
- [ ] undated-hold - Undated question (repo: alpha) (kind: chore) (hold: decide) (hold-kind: captain)

## Done
EOF
  model=$(board_model "$home") || fail "board render failed"
  printf '%s' "$model" | jq -e '
    [.columns[]|select(.key=="needs_you")|.groups[].threads[].items[]
     |select(.id=="origin-decision-shape")][0]
    | .age_days != null and .age_days >= 0 and .age_kind == "waiting on you"' >/dev/null \
    || fail "a dated decision record did not get a derived age"
  # A hold applied to ordinary work is filed before it needed the captain, so it
  # must say "open" rather than overclaim how long the captain has had it.
  printf '%s' "$model" | jq -e '
    [.columns[]|select(.key=="needs_you")|.groups[].threads[].items[]
     |select(.id=="plain-dated-hold")][0]
    | .age_days != null and .age_kind == "open"' >/dev/null \
    || fail "an ordinary captain hold overclaimed its age basis"
  printf '%s' "$model" | jq -e '
    [.columns[]|select(.key=="needs_you")|.groups[].threads[].items[]
     |select(.id=="undated-hold")][0].age_days == null' >/dev/null \
    || fail "an undated item invented an age instead of reporting none"
  pass "ages are derived from the recorded date and stay absent when there is none"
}

test_page_computes_its_own_age_and_escalates_when_stale() {
  local home html
  home=$(make_home staleness)
  write_mixed_backlog "$home"
  FM_HOME="$home" "$BOARD" render --out "$home/board.html" >/dev/null || fail "board render failed"
  html=$(cat "$home/board.html")

  # The age must be computed in the browser from an embedded stamp. A board
  # rendered once and read six days later has to show six days, not "just now".
  case "$html" in
    *'data-epoch="'*) : ;;
    *) fail "the page did not embed the generation epoch it needs to age itself" ;;
  esac
  case "$html" in
    *'Date.now()'*) : ;;
    *) fail "the page did not compute its age against the current time" ;;
  esac
  case "$html" in
    *'OUT OF DATE'*) : ;;
    *) fail "the page carried no expired presentation" ;;
  esac
  case "$html" in
    *'position:sticky'*) : ;;
    *) fail "the age banner was not pinned where it cannot be scrolled past" ;;
  esac
  # With scripting off the page must state the absolute time rather than lie.
  case "$html" in
    *'<noscript>'*'cannot compute how old it is'*) : ;;
    *) fail "the page had no honest fallback when scripting is off" ;;
  esac
  pass "the page ages itself, pins the banner, and degrades honestly without scripting"
}

test_refresh_rebuilds_on_change_and_skips_when_nothing_moved() {
  local home first second third stamp1 stamp2
  home=$(make_home refresh)
  write_mixed_backlog "$home"

  first=$(FM_HOME="$home" "$BOARD" refresh --out "$home/board.html") \
    || fail "first refresh failed"
  case "$first" in *rebuilt*) : ;; *) fail "the first refresh did not build: $first" ;; esac
  stamp1=$(stat -f '%m' "$home/board.html" 2>/dev/null || stat -c '%Y' "$home/board.html")

  second=$(FM_HOME="$home" "$BOARD" refresh --out "$home/board.html") \
    || fail "second refresh failed"
  [ "$second" = "unchanged" ] \
    || fail "an unchanged fleet still rebuilt the board: $second"
  stamp2=$(stat -f '%m' "$home/board.html" 2>/dev/null || stat -c '%Y' "$home/board.html")
  [ "$stamp1" = "$stamp2" ] || fail "the board file was rewritten despite no change"

  # A real change: one more captain hold.
  cat >> "$home/data/backlog.md" <<'EOF'
- [x] later - A later landing (repo: alpha) (kind: ship) (done 2026-08-06)
EOF
  third=$(FM_HOME="$home" "$BOARD" refresh --out "$home/board.html") \
    || fail "third refresh failed"
  case "$third" in *rebuilt*) : ;; *) fail "a real change did not rebuild the board: $third" ;; esac
  pass "refresh rebuilds on real state change and stays silent when nothing moved"
}

test_detached_refresh_returns_at_once_and_runs_single_flight() {
  local home started elapsed second waited
  home=$(make_home detach)
  write_mixed_backlog "$home"

  # The watcher calls this every poll, so it has to come back immediately even
  # though the rebuild behind it is slow.
  started=$(date +%s)
  FM_HOME="$home" "$BOARD" refresh --detach --out "$home/board.html" >/dev/null \
    || fail "detached refresh failed"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 5 ] || fail "detached refresh blocked for ${elapsed}s"

  # A second call while the first still owns the board must stand down rather
  # than start a competing rebuild.
  second=$(FM_HOME="$home" "$BOARD" refresh --detach --out "$home/board.html")
  case "$second" in
    busy|unchanged|rebuilding) : ;;
    *) fail "a concurrent detached refresh reported: $second" ;;
  esac

  waited=0
  while [ ! -f "$home/board.html" ] && [ "$waited" -lt 120 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  [ -f "$home/board.html" ] || fail "the detached rebuild never produced a board"
  [ ! -d "$home/state/.fleet-board.lock" ] \
    || fail "the detached rebuild left its single-flight lock behind"
  pass "a detached refresh returns at once, runs single-flight, and releases its lock"
}

test_a_stale_rebuild_lock_is_reclaimed() {
  local home out
  home=$(make_home stale-lock)
  write_mixed_backlog "$home"
  mkdir -p "$home/state/.fleet-board.lock"

  out=$(FM_HOME="$home" "$BOARD" refresh --out "$home/board.html")
  [ "$out" = "busy" ] || fail "a fresh lock did not hold off a rebuild: $out"

  # With the staleness bound at zero the same lock must be reclaimed, so a
  # killed child cannot wedge the board forever.
  out=$(FM_BOARD_LOCK_STALE=0 FM_HOME="$home" "$BOARD" refresh --out "$home/board.html")
  case "$out" in *rebuilt*) : ;; *) fail "a stale lock was not reclaimed: $out" ;; esac
  pass "a live rebuild lock holds, and a stale one is reclaimed"
}

test_fingerprint_moves_only_with_real_state_change() {
  local home a b c d e empty i
  home=$(make_home fingerprint)
  write_mixed_backlog "$home"

  # A home with no task state at all still has to produce a fingerprint: the
  # gate reads the state directory in bulk, and no matching file is an ordinary
  # resting state, not an error.
  empty=$(FM_HOME="$home" "$BOARD" fingerprint) || fail "an empty state directory broke the fingerprint"
  [ -n "$empty" ] || fail "an empty state directory produced no fingerprint"

  # Enough records that a per-file walk and a bulk read would disagree if the
  # bulk read dropped or reordered anything.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    printf 'window=firstmate:fm-task-%s\nkind=ship\n' "$i" > "$home/state/task-$i.meta"
    printf 'working: task %s under way\n' "$i" > "$home/state/task-$i.status"
  done

  a=$(FM_HOME="$home" "$BOARD" fingerprint)
  b=$(FM_HOME="$home" "$BOARD" fingerprint)
  [ "$a" = "$b" ] || fail "the fingerprint was not stable across two reads"
  [ "$a" != "$empty" ] || fail "ten tasks appearing did not move the fingerprint"

  printf 'working: something happened\n' > "$home/state/newtask.status"
  c=$(FM_HOME="$home" "$BOARD" fingerprint)
  [ "$a" != "$c" ] || fail "a new status event did not move the fingerprint"

  # An append to an existing log, and a metadata rewrite, each on a file the
  # bulk read has already seen.
  printf 'done: task 7 finished\n' >> "$home/state/task-7.status"
  d=$(FM_HOME="$home" "$BOARD" fingerprint)
  [ "$c" != "$d" ] || fail "an appended status event did not move the fingerprint"
  printf 'window=firstmate:fm-task-3\nkind=scout\n' > "$home/state/task-3.meta"
  e=$(FM_HOME="$home" "$BOARD" fingerprint)
  [ "$d" != "$e" ] || fail "a rewritten task metadata file did not move the fingerprint"
  pass "the fingerprint is stable at rest and moves on a real state event"
}

test_fingerprint_follows_secondmate_state_too() {
  local home mate a b c
  home=$(make_home fingerprint-mate)
  mate=$(make_mate_home fingerprint-mate-home mate)
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$mate/data/backlog.md"
  cat > "$home/data/secondmates.md" <<EOF
# Second mates

- mate - owns gamma work (home: $mate; scope: gamma work; projects: gamma; added 2026-08-02)
EOF
  a=$(FM_HOME="$home" "$BOARD" fingerprint)

  # A secondmate's own backlog change must move it: its work shows on the board.
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] mate-question - A question (repo: gamma) (kind: ship) (since 2026-08-02) (hold: captain picks) (hold-kind: captain)

## Done
EOF
  b=$(FM_HOME="$home" "$BOARD" fingerprint)
  [ "$a" != "$b" ] || fail "a secondmate backlog change did not move the fingerprint"

  # So must a secondmate child's status event.
  printf 'working: mate child started\n' > "$mate/state/mate-child.status"
  c=$(FM_HOME="$home" "$BOARD" fingerprint)
  [ "$b" != "$c" ] || fail "a secondmate child status event did not move the fingerprint"
  pass "the fingerprint follows secondmate backlog and child state, not just the main home"
}

# The gate reads data/secondmates.md through the shared registry parser, which is
# anchored to the full record suffix. Scope prose that happens to mention a home
# must not redirect the walk, a remote record must not break it, and a remote home
# is deliberately not fingerprinted: no network call may enter this path.
test_fingerprint_reads_the_registry_the_way_its_owner_does() {
  local home mate decoy a b c d
  home=$(make_home fingerprint-registry)
  mate=$(make_mate_home fingerprint-registry-home mate)
  decoy=$TMP_ROOT/fingerprint-registry-decoy
  mkdir -p "$decoy/state" "$decoy/data"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$mate/data/backlog.md"
  # Ordinary prose that happens to name a home, a real local record, and a remote
  # record: only the middle one is a home this gate may walk.
  cat > "$home/data/secondmates.md" <<EOF
# Second mates

Retired: the gamma mate used to live at (home: $decoy) before it moved.

- mate - owns gamma work (home: $mate; scope: gamma work; projects: gamma; added 2026-08-02)
- faraway - owns delta work (host: elsewhere.example; root: /srv/fm; home: /srv/fm/home; scope: delta work; projects: delta; added 2026-08-03)
EOF
  a=$(FM_HOME="$home" "$BOARD" fingerprint) || fail "a registry with a remote record broke the fingerprint"
  b=$(FM_HOME="$home" "$BOARD" fingerprint)
  [ "$a" = "$b" ] || fail "the fingerprint was not stable across a registry with mixed record forms"

  # A directory named only by prose is not a registered home, so nothing inside
  # it is fleet state and it must not move this gate.
  printf 'working: not a registered home\n' > "$decoy/state/decoy-child.status"
  c=$(FM_HOME="$home" "$BOARD" fingerprint)
  [ "$a" = "$c" ] \
    || fail "prose that merely names a directory made it an input to change detection"

  # The one real local record still is.
  printf 'working: mate child started\n' > "$mate/state/mate-child.status"
  d=$(FM_HOME="$home" "$BOARD" fingerprint)
  [ "$c" != "$d" ] || fail "the registered local mate home stopped moving the fingerprint"
  pass "the change-detection walk resolves registry records through their one owner"
}

# A stat dialect this machine is not running, forced onto PATH together with the
# uname the script selects on, so both branches are exercised wherever the suite
# runs. Each shim accepts ONLY its own format flag and reproduces what the other
# platform's stat really does with a foreign one: GNU prints a filesystem report
# to stdout for every operand and exits 1, and that report carries a free-block
# count that moves between calls.
make_stat_shim() {  # <dir> <bsd|gnu> -> echoes the shim bin directory
  local fb=$1/statshim-$2 host
  mkdir -p "$fb"
  printf '%s\n' "$2" > "$fb/.dialect"
  # Where the real tools are, resolved before PATH is bent, so the shim can
  # delegate without finding itself.
  command -v stat > "$fb/.realstat"
  command -v uname > "$fb/.realuname"
  if [ "$(uname -s)" = Darwin ]; then host=-f; else host=-c; fi
  printf '%s\n' "$host" > "$fb/.host"
  case "$2" in
    bsd) printf 'Darwin\n' > "$fb/.os" ;;
    *) printf 'Linux\n' > "$fb/.os" ;;
  esac
  cat > "$fb/uname" <<'SH'
#!/usr/bin/env bash
set -u
here=$(dirname "$0")
case "${1:-}" in
  ''|-s) cat "$here/.os" ;;
  *) exec "$(cat "$here/.realuname")" "$@" ;;
esac
SH
  cat > "$fb/stat" <<'SH'
#!/usr/bin/env bash
set -u
here=$(dirname "$0")
dialect=$(cat "$here/.dialect")
host=$(cat "$here/.host")
printf '%s\n' "$*" >> "${FM_FAKE_STAT_LOG:?}"

if [ "$dialect" = gnu ]; then own=-c; else own=-f; fi

if [ "${1:-}" != "$own" ]; then
  # A foreign format flag. GNU reads -f as --file-system and still writes a
  # report for every real operand to stdout before failing, and that report
  # carries free-block counts that move; BSD simply refuses.
  if [ "$dialect" = gnu ] && [ "${1:-}" = -f ]; then
    drift=$(( $(cat "$here/.drift" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$drift" > "$here/.drift"
    shift 2 2>/dev/null || true
    for f in "$@"; do
      printf '  File: "%s"\nBlocks: Total: 975653540  Free: %s Available: %s\n' \
        "$f" "$drift" "$drift"
    done
  fi
  exit 1
fi

shift
fmt=$1
shift
if [ "$own" != "$host" ]; then
  if [ "$host" = -c ]; then
    fmt=$(printf '%s' "$fmt" | sed -e 's/%Lp/%a/g' -e 's/%N/%n/g' -e 's/%m/%Y/g' -e 's/%z/%s/g')
  else
    fmt=$(printf '%s' "$fmt" | sed -e 's/%a/%Lp/g' -e 's/%n/%N/g' -e 's/%Y/%m/g' -e 's/%s/%z/g')
  fi
fi
exec "$(cat "$here/.realstat")" "$host" "$fmt" "$@"
SH
  chmod +x "$fb/uname" "$fb/stat"
  printf '%s\n' "$fb"
}

# The fingerprint is the whole freshness gate, so it has to mean the same thing
# under either stat dialect: identical inputs must hash identically however much
# unrelated disk activity happens between two reads, and a real state event must
# still move it.
test_fingerprint_is_identical_under_either_stat_dialect() {
  local home dialect fb a b c
  for dialect in bsd gnu; do
    home=$(make_home "stat-dialect-$dialect")
    write_mixed_backlog "$home"
    printf 'window=firstmate:fm-one\nkind=ship\n' > "$home/state/one.meta"
    printf 'working: one is under way\n' > "$home/state/one.status"
    fb=$(make_stat_shim "$home" "$dialect")
    : > "$home/stat.log"

    a=$(PATH="$fb:$PATH" FM_FAKE_STAT_LOG="$home/stat.log" FM_HOME="$home" "$BOARD" fingerprint) \
      || fail "$dialect: fingerprint failed under a $dialect stat"
    [ -n "$a" ] || fail "$dialect: fingerprint produced nothing"
    [ -s "$home/stat.log" ] \
      || fail "$dialect: the $dialect stat shim was never invoked, so this proves nothing"

    # Unrelated disk activity only. Nothing the board reads has changed, so the
    # gate must not move; a filesystem report would drift here and a per-file
    # metadata read cannot.
    dd if=/dev/zero of="$home/ballast" bs=1024 count=64 >/dev/null 2>&1 || true
    b=$(PATH="$fb:$PATH" FM_FAKE_STAT_LOG="$home/stat.log" FM_HOME="$home" "$BOARD" fingerprint)
    [ "$a" = "$b" ] \
      || fail "$dialect: the fingerprint moved without any fleet change, so it is not reading file metadata"

    # And it must still be a real gate: a state event has to move it. This is
    # what stops the test passing vacuously when a dialect yields no metadata.
    printf 'done: one finished\n' >> "$home/state/one.status"
    c=$(PATH="$fb:$PATH" FM_FAKE_STAT_LOG="$home/stat.log" FM_HOME="$home" "$BOARD" fingerprint)
    [ "$b" != "$c" ] \
      || fail "$dialect: a real state event did not move the fingerprint, so no metadata was read"
  done
  pass "the fingerprint reads file metadata, not filesystem reports, under either stat dialect"
}

# The lock age is arithmetic, so a stat dialect that prints prose instead of a
# number must not be able to abort the rebuild. That failure exits 0 under the
# watcher, which discards stderr, so the board would stop rebuilding in silence.
test_the_stale_lock_reclaim_survives_either_stat_dialect() {
  local home dialect fb out
  for dialect in bsd gnu; do
    home=$(make_home "stat-lock-$dialect")
    write_mixed_backlog "$home"
    fb=$(make_stat_shim "$home" "$dialect")
    : > "$home/stat.log"
    mkdir -p "$home/state/.fleet-board.lock"

    out=$(PATH="$fb:$PATH" FM_FAKE_STAT_LOG="$home/stat.log" FM_BOARD_LOCK_STALE=0 \
      FM_HOME="$home" "$BOARD" refresh --out "$home/board.html" 2>&1) \
      || fail "$dialect: refresh failed outright: $out"
    case "$out" in
      *rebuilt*) : ;;
      *) fail "$dialect: a stale lock was never reclaimed: $out" ;;
    esac
    [ -f "$home/board.html" ] || fail "$dialect: the reclaimed rebuild produced no board"
    [ -s "$home/stat.log" ] \
      || fail "$dialect: the $dialect stat shim was never invoked, so this proves nothing"
  done
  pass "the stale-lock reclaim reads a real mtime under either stat dialect"
}

test_board_never_asserts_how_it_was_opened() {
  local home html
  home=$(make_home offline-copy)
  write_mixed_backlog "$home"
  FM_HOME="$home" "$BOARD" render --out "$home/board.html" >/dev/null || fail "board render failed"
  html=$(cat "$home/board.html")
  # The filed defect: a page-level paragraph claiming the reader had opened the
  # board as a plain file, which is false for a served board. This board is a
  # read surface with no answer channel, so it must make no such claim at all.
  case "$html" in
    *"Opened as a plain file"*) fail "the board still asserts how it was opened" ;;
    *"plain file"*) fail "the board still describes how the reader opened it" ;;
    *) : ;;
  esac
  case "$html" in
    *"Reopen the board"*) fail "the board still instructs the reader to reopen it elsewhere" ;;
    *) : ;;
  esac
  pass "the board makes no claim about how the reader opened it"
}

test_secondmate_captain_holds_reach_the_board() {
  local home mate model
  home=$(make_home secondmate-holds)
  mate=$(make_mate_home mate-home mate)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] mate-question - A question only the captain can answer (repo: gamma) (kind: ship) (since 2026-08-02) (hold: captain picks the target) (hold-kind: captain)

## Done
EOF
  cat > "$home/data/secondmates.md" <<EOF
# Second mates

- mate - owns gamma work (home: $mate; scope: gamma work; projects: gamma; added 2026-08-02)
EOF
  model=$(board_model "$home") || fail "board render failed"
  printf '%s' "$model" | jq -e '.counts.needs_you >= 1' >/dev/null \
    || fail "a secondmate captain hold never reached the board: $(printf '%s' "$model" | jq -c .counts)"
  printf '%s' "$model" | jq -e '
    [.columns[]|select(.key=="needs_you")|.groups[].threads[].items[]
     |select(.id | endswith("mate-question"))][0].owner == "mate"' >/dev/null \
    || fail "the secondmate hold was not attributed to its home"
  pass "a captain hold inside a secondmate home reaches the board with its owner"
}

test_snapshot_exposes_captain_threads_for_every_secondmate_hold() {
  local home mate out
  home=$(make_home mate-threads)
  mate=$(make_mate_home mate-threads-home mate)
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight
- [ ] mate-inflight-hold - In-flight work parked on the captain (repo: gamma) (kind: ship) (since 2026-08-02) (hold: captain approves) (hold-kind: captain)

## Queued
- [ ] mate-blocked-hold - Blocked question blocked-by: mate-inflight-hold (repo: gamma) (kind: chore) (since 2026-08-03) (hold: captain decides later) (hold-kind: captain)

## Done
EOF
  cat > "$home/data/secondmates.md" <<EOF
# Second mates

- mate - owns gamma work (home: $mate; scope: gamma work; projects: gamma; added 2026-08-02)
EOF
  out=$(FM_HOME="$home" "$SNAPSHOT" --json) || fail "snapshot failed"
  printf '%s' "$out" | jq -e '
    [(.secondmate_current.records // [])[] | .captain_threads[]?] as $t
    | ($t | length) == 2
      and ([$t[] | select(.actionable)] | length) == 1
      and ([$t[] | select(.actionable | not)] | length) == 1' >/dev/null \
    || fail "captain_threads did not carry both the actionable and the blocked hold: $out"
  pass "a secondmate home exposes every captain thread with its actionable flag"
}

# A fake tailscale that records every argv it is handed, so the serve path can be
# judged by what it actually runs rather than by reading the script's source.
# FM_FAKE_TS_STATUS_FAIL makes the funnel query itself fail, which is the case
# the guard has to treat as "could not determine" rather than as "all clear".
make_fake_tailscale() {  # <home> <serve-status-json>
  local fb=$1/fakebin
  mkdir -p "$fb"
  printf '%s' "$2" > "$1/serve-status.json"
  cat > "$fb/tailscale" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TS_LOG:?}"
case "$1 ${2:-}" in
  "serve status")
    if [ "${3:-}" = "--json" ]; then
      [ -z "${FM_FAKE_TS_STATUS_FAIL:-}" ] || exit 3
      cat "${FM_FAKE_TS_STATUS:?}"
    else
      echo "https://macbook-pro.example.ts.net/"
    fi
    ;;
  "status --json") printf '{"Self":{"DNSName":"macbook-pro.example.ts.net."}}\n' ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/tailscale"
  printf '%s\n' "$fb"
}

test_a_troubled_secondmate_home_still_surrenders_its_captain_decisions() {
  local home mate out model state
  home=$(make_home mate-troubled)
  mate=$(make_mate_home mate-troubled-home mate)
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  # A live child with no in-flight backlog row makes this home's CURRENT STATE
  # unreconcilable, which drops the record to the untrusted parent-event
  # fallback. Its backlog is still perfectly readable, so the captain hold in it
  # must survive: hiding decisions inside a home that is already in trouble is
  # the undercount this board exists to prevent.
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] mate-question - A question only the captain can answer (repo: gamma) (kind: ship) (since 2026-08-02) (hold: captain picks the target) (hold-kind: captain)

## Done
EOF
  printf 'window=firstmate:orphan\nkind=ship\n' > "$mate/state/orphan-child.meta"
  printf 'working: doing something\n' > "$mate/state/orphan-child.status"
  cat > "$home/data/secondmates.md" <<EOF
# Second mates

- mate - owns gamma work (home: $mate; scope: gamma work; projects: gamma; added 2026-08-02)
EOF

  out=$(FM_HOME="$home" "$SNAPSHOT" --json) || fail "snapshot failed"
  state=$(printf '%s' "$out" | jq -r '(.secondmate_current.records // [])[0].current.state')
  [ "$state" = "unknown" ] \
    || fail "the fixture did not actually produce an unreconcilable home (state=$state)"
  printf '%s' "$out" | jq -e '
    (.secondmate_current.records // [])[0]
    | (.provenance.selected != "structured-home")
      and ((.captain_threads // []) | length) == 1
      and (.holds | length) == 0 and (.queued | length) == 0' >/dev/null \
    || fail "a troubled home either kept untrusted surfaces or lost its captain hold: $(printf '%s' "$out" | jq -c '(.secondmate_current.records//[])[0]|{provenance:.provenance.selected,captain_threads,holds,queued}')"

  model=$(board_model "$home") || fail "board render failed"
  printf '%s' "$model" | jq -e '.counts.needs_you == 1' >/dev/null \
    || fail "the board dropped the captain hold from a troubled home: $(printf '%s' "$model" | jq -c .counts)"
  pass "a secondmate home with unreconcilable current state still surrenders its captain decisions"
}

# Pick a loopback port nothing is listening on, so a busy machine (or a second
# copy of this suite) cannot make the serve tests fail for an unrelated reason.
free_port() {
  local p
  for p in $(seq 18400 18460); do
    if ! nc -z 127.0.0.1 "$p" >/dev/null 2>&1; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  fail "no free loopback port in the test range"
}

# Every test that starts the real local server must stop it again, or the next
# run inherits a bound port and fails for the wrong reason.
stop_served_home() {  # <home> <fakebin> <local-port> <https-port>
  PATH="$2:$PATH" FM_FAKE_TS_LOG="$1/ts.log" FM_FAKE_TS_STATUS="$1/serve-status.json" \
    FM_BOARD_LOCAL_PORT="$3" FM_BOARD_HTTPS_PORT="$4" \
    FM_HOME="$1" "$BOARD" unserve >/dev/null 2>&1 || true
}

test_serve_publishes_through_serve_and_never_funnel() {
  local home fb log lport hport body
  home=$(make_home serve-path)
  write_mixed_backlog "$home"
  FM_HOME="$home" "$BOARD" render --out "$home/board.html" >/dev/null || fail "board render failed"
  fb=$(make_fake_tailscale "$home" '{"AllowFunnel":{}}')
  log=$home/ts.log
  : > "$log"
  lport=$(free_port)
  hport=$((lport + 1))

  PATH="$fb:$PATH" FM_FAKE_TS_LOG="$log" FM_FAKE_TS_STATUS="$home/serve-status.json" \
    FM_BOARD_LOCAL_PORT="$lport" FM_BOARD_HTTPS_PORT="$hport" \
    FM_HOME="$home" "$BOARD" serve --out "$home/board.html" >/dev/null \
    || { stop_served_home "$home" "$fb" "$lport" "$hport"; fail "serve failed against a clean tailnet"; }

  grep -q "^serve --bg --https=$hport 127.0.0.1:$lport$" "$log" \
    || { stop_served_home "$home" "$fb" "$lport" "$hport"
         fail "serve did not proxy the loopback server through tailscale serve: $(cat "$log")"; }
  if grep -q '^funnel' "$log"; then
    stop_served_home "$home" "$fb" "$lport" "$hport"
    fail "the serve path invoked tailscale funnel: $(cat "$log")"
  fi

  # The published directory must hold the board and nothing else: state/ is full
  # of private fleet records and must never be exposed alongside it.
  [ -f "$home/state/.fleet-board-web/index.html" ] \
    || { stop_served_home "$home" "$fb" "$lport" "$hport"; fail "the board was never staged for publishing"; }
  [ "$(find "$home/state/.fleet-board-web" -type f | wc -l | tr -d ' ')" = 1 ] \
    || { stop_served_home "$home" "$fb" "$lport" "$hport"
         fail "the published directory exposed more than the board: $(ls -A "$home/state/.fleet-board-web")"; }

  body=$(curl -fsS --max-time 8 "http://127.0.0.1:$lport/" 2>/dev/null || true)
  case "$body" in
    *"Needs you"*) : ;;
    *) stop_served_home "$home" "$fb" "$lport" "$hport"
       fail "the loopback server did not actually serve the board" ;;
  esac

  stop_served_home "$home" "$fb" "$lport" "$hport"
  [ ! -d "$home/state/.fleet-board-web" ] \
    || fail "withdrawing the board left its published copy on disk"
  curl -fsS -o /dev/null --max-time 4 "http://127.0.0.1:$lport/" 2>/dev/null \
    && fail "withdrawing the board left its local server running"
  pass "publishing proxies a loopback server, exposes only the board, never funnels, and withdraws cleanly"
}

test_serve_refuses_while_a_funnel_is_configured() {
  local home fb log out rc lport hport
  home=$(make_home serve-funnel)
  write_mixed_backlog "$home"
  FM_HOME="$home" "$BOARD" render --out "$home/board.html" >/dev/null || fail "board render failed"
  fb=$(make_fake_tailscale "$home" '{"AllowFunnel":{"macbook-pro.example.ts.net:443":true}}')
  log=$home/ts.log
  : > "$log"

  lport=$(free_port)
  hport=$((lport + 1))
  set +e
  out=$(PATH="$fb:$PATH" FM_FAKE_TS_LOG="$log" FM_FAKE_TS_STATUS="$home/serve-status.json" \
    FM_BOARD_LOCAL_PORT="$lport" FM_BOARD_HTTPS_PORT="$hport" \
    FM_HOME="$home" "$BOARD" serve --out "$home/board.html" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "serve published anyway while a funnel was configured: $out"
  case "$out" in
    *"funnel"*"publicly"*) : ;;
    *) fail "the refusal did not explain the public-exposure risk: $out" ;;
  esac
  if grep -q '^serve --bg ' "$log"; then
    fail "serve published before checking for a funnel: $(cat "$log")"
  fi
  pass "serve refuses to publish while a funnel would expose the board publicly"
}

test_serve_requires_a_built_board() {
  local home fb out rc
  home=$(make_home serve-missing)
  fb=$(make_fake_tailscale "$home" '{"AllowFunnel":{}}')
  set +e
  out=$(PATH="$fb:$PATH" FM_FAKE_TS_LOG="$home/ts.log" FM_FAKE_TS_STATUS="$home/serve-status.json" \
    FM_HOME="$home" "$BOARD" serve --out "$home/absent.html" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "serve published a board that does not exist: $out"
  pass "serve refuses when there is no board to publish"
}

# The funnel guard is the only thing between this board and a pre-existing public
# listener, so "I could not tell" must stop publishing exactly as "yes there is
# one" does. Both unanswerable shapes are exercised: a query that errors, and a
# query that answers with something the guard cannot read.
test_serve_refuses_when_the_funnel_check_cannot_be_answered() {
  local home fb log out rc lport hport
  home=$(make_home serve-funnel-unknown)
  write_mixed_backlog "$home"
  FM_HOME="$home" "$BOARD" render --out "$home/board.html" >/dev/null || fail "board render failed"
  fb=$(make_fake_tailscale "$home" '{"AllowFunnel":{}}')
  log=$home/ts.log
  lport=$(free_port)
  hport=$((lport + 1))

  : > "$log"
  set +e
  out=$(PATH="$fb:$PATH" FM_FAKE_TS_LOG="$log" FM_FAKE_TS_STATUS="$home/serve-status.json" \
    FM_FAKE_TS_STATUS_FAIL=1 FM_BOARD_LOCAL_PORT="$lport" FM_BOARD_HTTPS_PORT="$hport" \
    FM_HOME="$home" "$BOARD" serve --out "$home/board.html" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { stop_served_home "$home" "$fb" "$lport" "$hport"
                       fail "serve published while the funnel query was failing: $out"; }
  case "$out" in
    *"could not be determined"*) : ;;
    *) fail "the refusal did not say the funnel state was undetermined: $out" ;;
  esac
  grep -q '^serve --bg ' "$log" && fail "serve published before it could rule out a funnel: $(cat "$log")"

  # Same requirement for a well-formed reply of the wrong shape.
  printf '%s' '{"AllowFunnel":"probably not"}' > "$home/serve-status.json"
  : > "$log"
  set +e
  out=$(PATH="$fb:$PATH" FM_FAKE_TS_LOG="$log" FM_FAKE_TS_STATUS="$home/serve-status.json" \
    FM_BOARD_LOCAL_PORT="$lport" FM_BOARD_HTTPS_PORT="$hport" \
    FM_HOME="$home" "$BOARD" serve --out "$home/board.html" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { stop_served_home "$home" "$fb" "$lport" "$hport"
                       fail "serve published against an unreadable funnel report: $out"; }
  grep -q '^serve --bg ' "$log" && fail "serve published before it could read the funnel report: $(cat "$log")"
  pass "serve refuses to publish whenever the funnel state cannot be determined"
}

# Proxying whatever happens to answer FM_BOARD_LOCAL_PORT would publish an
# unrelated local service to the whole tailnet, so a contended port is a refusal,
# never an adoption.
test_serve_refuses_when_the_local_port_is_already_held() {
  local home fb log out rc lport hport squatter
  home=$(make_home serve-port-taken)
  write_mixed_backlog "$home"
  FM_HOME="$home" "$BOARD" render --out "$home/board.html" >/dev/null || fail "board render failed"
  fb=$(make_fake_tailscale "$home" '{"AllowFunnel":{}}')
  log=$home/ts.log
  : > "$log"
  lport=$(free_port)
  hport=$((lport + 1))

  mkdir -p "$home/squat"
  printf 'not the board\n' > "$home/squat/index.html"
  python3 -m http.server "$lport" --bind 127.0.0.1 --directory "$home/squat" >/dev/null 2>&1 &
  squatter=$!
  local waited=0
  while [ "$waited" -lt 50 ] \
    && ! curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$lport/" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
  done
  curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$lport/" 2>/dev/null \
    || { kill "$squatter" 2>/dev/null; fail "the fixture never bound the contended port"; }

  set +e
  out=$(PATH="$fb:$PATH" FM_FAKE_TS_LOG="$log" FM_FAKE_TS_STATUS="$home/serve-status.json" \
    FM_BOARD_LOCAL_PORT="$lport" FM_BOARD_HTTPS_PORT="$hport" \
    FM_HOME="$home" "$BOARD" serve --out "$home/board.html" 2>&1)
  rc=$?
  kill "$squatter" 2>/dev/null
  wait "$squatter" 2>/dev/null
  set -e

  [ "$rc" -ne 0 ] || fail "serve adopted a foreign service on the local port: $out"
  case "$out" in
    *"$lport"*) : ;;
    *) fail "the refusal did not name the contended port: $out" ;;
  esac
  if grep -q '^serve --bg ' "$log"; then
    fail "serve published a foreign local service to the tailnet: $(cat "$log")"
  fi
  pass "serve refuses a contended local port instead of proxying a foreign service"
}

# The undercount this board exists to kill, in its last hiding place: the
# snapshot bounds how many of a mate home's captain holds it will LIST, and the
# headline number must still be the true total, with the shortfall disclosed.
test_a_capped_secondmate_home_never_shortens_the_needs_you_total() {
  local home mate model listed i
  home=$(make_home mate-capped)
  mate=$(make_mate_home mate-capped-home mate)
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  {
    printf '## In flight\n\n## Queued\n'
    for i in 1 2 3 4 5; do
      printf -- '- [ ] mate-question-%s - Question %s (repo: gamma) (kind: ship) (since 2026-08-02) (hold: captain picks %s) (hold-kind: captain)\n' \
        "$i" "$i" "$i"
    done
    printf '\n## Done\n'
  } > "$mate/data/backlog.md"
  cat > "$home/data/secondmates.md" <<EOF
# Second mates

- mate - owns gamma work (home: $mate; scope: gamma work; projects: gamma; added 2026-08-02)
EOF

  model=$(FM_SNAPSHOT_SECONDMATE_DECISIONS=2 board_model "$home") || fail "board render failed"
  listed=$(printf '%s' "$model" \
    | jq -r '[.columns[]|select(.key=="needs_you")|.groups[].threads[].items[]] | length')
  [ "$listed" -lt 5 ] \
    || fail "the fixture did not actually cap the mate home's captain holds (listed $listed)"
  printf '%s' "$model" | jq -e '.counts.needs_you == 5' >/dev/null \
    || fail "the capped mate home shortened the needs-you total: $(printf '%s' "$model" | jq -c .counts)"
  printf '%s' "$model" | jq -e '
    [.omitted[] | select(.surface | test("captain threads"))] as $d
    | ($d | length) == 1 and ($d[0].count == (5 - '"$listed"'))' >/dev/null \
    || fail "the dropped captain holds were never disclosed: $(printf '%s' "$model" | jq -c .omitted)"
  pass "a capped secondmate home keeps the needs-you total true and discloses what it could not list"
}

# The board must never say the opposite of what happened. An in-flight row whose
# worker has already finished, or whose worker cannot be read at all, used to
# fall through to "queued for dispatch / Filed and waiting for a slot".
test_a_finished_or_unreadable_worker_is_never_reported_as_queued() {
  local home fb model finished unreadable gen
  home=$(make_home terminal-worker)
  mkdir -p "$home/projects/wt" "$home/fakebin"
  cat > "$home/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'claude\n' ;;
      *) printf '%%1\n' ;;
    esac ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$home/fakebin/no-mistakes" "$home/fakebin/tmux"
  fb=$home/fakebin

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] finished-worker - Work whose worker already finished (repo: alpha) (kind: ship) (since 2026-08-01)
- [ ] unreadable-worker - Work whose worker cannot be read (repo: alpha) (kind: ship) (since 2026-08-01)

## Queued

## Done
EOF
  fm_write_meta "$home/state/finished-worker.meta" \
    "window=firstmate:fm-finished-worker" \
    "worktree=$home/projects/wt" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" finished-worker)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" finished-worker idle --gen "$gen" \
    --source claude-hook --event stop
  printf 'done: the worker finished and never closed the row\n' > "$home/state/finished-worker.status"
  # No worktree at all, so its current state cannot be read.
  fm_write_meta "$home/state/unreadable-worker.meta" \
    "window=firstmate:fm-unreadable-worker" \
    "kind=ship"

  model=$(PATH="$fb:$PATH" board_model "$home") || fail "board render failed"
  finished=$(printf '%s' "$model" | jq -c '
    [.columns[]|select(.key=="waiting")|.groups[].threads[].items[]
     |select(.id=="finished-worker")][0]')
  [ "$finished" != "null" ] && [ -n "$finished" ] \
    || fail "the finished row left the waiting column entirely: $(printf '%s' "$model" | jq -c .counts)"
  printf '%s' "$finished" | jq -e '
    .waiting_on != "queued for dispatch"
    and (.waiting_on | test("finished"))
    and (.detail | test("Filed and waiting for a slot") | not)
    and .attention == true' >/dev/null \
    || fail "a finished worker was still reported as queued for dispatch: $finished"

  unreadable=$(printf '%s' "$model" | jq -c '
    [.columns[]|select(.key=="waiting")|.groups[].threads[].items[]
     |select(.id=="unreadable-worker")][0]')
  printf '%s' "$unreadable" | jq -e '
    .waiting_on != "queued for dispatch"
    and (.waiting_on | test("unknown"))' >/dev/null \
    || fail "an unreadable worker was still reported as queued for dispatch: $unreadable"
  pass "a finished or unreadable worker is named for what it is, never as queued for dispatch"
}

test_board_discloses_that_change_detection_is_local_only() {
  local home html
  home=$(make_home local-only-disclosure)
  write_mixed_backlog "$home"
  FM_HOME="$home" "$BOARD" render --out "$home/board.html" >/dev/null || fail "board render failed"
  html=$(cat "$home/board.html")
  case "$html" in
    *"Change detection covers local homes only"*) : ;;
    *) fail "the board did not disclose that change detection is local-only" ;;
  esac
  case "$html" in
    *"does not by itself trigger a rebuild"*) : ;;
    *) fail "the board did not say what a remote home's own backlog change fails to do" ;;
  esac
  pass "the page states plainly that change detection covers local homes only"
}

# A rebuild takes minutes on a real fleet. Capturing the fingerprint after the
# build would record everything that arrived during it as already shown, leaving
# the next refresh silent about a board that is missing a decision.
test_render_records_the_inputs_as_they_were_before_the_build() {
  local home pid waited late
  home=$(make_home render-order)
  write_mixed_backlog "$home"

  FM_HOME="$home" "$BOARD" render --out "$home/board.html" >/dev/null 2>&1 &
  pid=$!
  # The rebuild stages its board beside the target before it starts projecting,
  # so this file appearing means the build is under way.
  waited=0
  while [ "$waited" -lt 300 ] && ! ls "$home"/board.html.* >/dev/null 2>&1; do
    sleep 0.05
    waited=$((waited + 1))
  done
  ls "$home"/board.html.* >/dev/null 2>&1 || { wait "$pid"; fail "the render never started a build"; }
  kill -0 "$pid" 2>/dev/null || fail "the render finished before the fixture could change state"
  printf 'working: a change that arrived mid-build\n' > "$home/state/midbuild.status"
  wait "$pid" || fail "the render failed"

  late=$(FM_HOME="$home" "$BOARD" refresh --out "$home/board.html")
  case "$late" in
    *rebuilt*) : ;;
    *) fail "a change that arrived during the build was recorded as already shown: $late" ;;
  esac
  pass "render fingerprints the inputs as they were before the build, not after it"
}

test_rendering_elsewhere_never_marks_the_canonical_board_current() {
  local home canonical scratch after
  home=$(make_home render-out-isolation)
  write_mixed_backlog "$home"

  FM_HOME="$home" "$BOARD" render >/dev/null || fail "canonical render failed"
  canonical=$(cat "$home/state/.fleet-board.fingerprint")

  # A real change, then a render to somewhere else entirely. The canonical
  # board still has not seen the change, so its gate must not say otherwise.
  printf 'working: a change the canonical board never saw\n' > "$home/state/scratch-change.status"
  scratch=$home/scratch.html
  FM_HOME="$home" "$BOARD" render --out "$scratch" >/dev/null || fail "scratch render failed"
  [ -f "$scratch" ] || fail "the scratch render produced no board"

  after=$(cat "$home/state/.fleet-board.fingerprint")
  [ "$after" = "$canonical" ] \
    || fail "a render to another path rewrote the canonical board's input fingerprint"
  case "$(FM_HOME="$home" "$BOARD" refresh)" in
    *rebuilt*) : ;;
    *) fail "the canonical board reported itself current after a change it never saw" ;;
  esac
  pass "a render to another path leaves the canonical board's freshness gate alone"
}

# Under the watcher a failed rebuild retries every poll, so a temp file left
# behind per failure is unbounded, and the watcher discards this script's stderr.
test_a_failed_rebuild_leaves_no_temporary_files() {
  local home rc out strays
  home=$(make_home failed-rebuild)
  write_mixed_backlog "$home"

  set +e
  out=$(FM_BOARD_LANDED='not-a-number' FM_HOME="$home" "$BOARD" render --out "$home/board.html" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the forced build failure did not actually fail: $out"

  strays=$(find "$home" -name 'board.html.*' -o -name '.fleet-board.model*.tmp' | wc -l | tr -d ' ')
  [ "$strays" = 0 ] \
    || fail "a failed rebuild left $strays temporary file(s): $(find "$home" -name 'board.html.*' -o -name '.fleet-board.model*.tmp')"
  [ ! -d "$home/state/.fleet-board.lock" ] \
    || fail "a failed rebuild left its single-flight lock behind"
  pass "a failed rebuild cleans up its temporary files and releases its lock"
}

test_needs_you_count_is_derived_not_shaped
test_needs_you_count_tracks_a_hold_appearing_and_clearing
test_blocked_captain_hold_is_counted_but_marked_unanswerable
test_every_live_item_lands_in_exactly_one_column
test_every_column_header_counts_the_real_total_not_the_shown_slice
test_waiting_names_who_or_what_it_waits_on
test_landed_renders_pull_requests_as_full_urls
test_threads_group_decision_records_under_their_origin
test_age_is_derived_and_absent_when_no_date_exists
test_page_computes_its_own_age_and_escalates_when_stale
test_refresh_rebuilds_on_change_and_skips_when_nothing_moved
test_detached_refresh_returns_at_once_and_runs_single_flight
test_a_stale_rebuild_lock_is_reclaimed
test_fingerprint_moves_only_with_real_state_change
test_fingerprint_follows_secondmate_state_too
test_fingerprint_reads_the_registry_the_way_its_owner_does
test_fingerprint_is_identical_under_either_stat_dialect
test_the_stale_lock_reclaim_survives_either_stat_dialect
test_board_never_asserts_how_it_was_opened
test_secondmate_captain_holds_reach_the_board
test_snapshot_exposes_captain_threads_for_every_secondmate_hold
test_a_troubled_secondmate_home_still_surrenders_its_captain_decisions
test_a_capped_secondmate_home_never_shortens_the_needs_you_total
test_a_finished_or_unreadable_worker_is_never_reported_as_queued
test_board_discloses_that_change_detection_is_local_only
test_render_records_the_inputs_as_they_were_before_the_build
test_rendering_elsewhere_never_marks_the_canonical_board_current
test_a_failed_rebuild_leaves_no_temporary_files
test_serve_publishes_through_serve_and_never_funnel
test_serve_refuses_while_a_funnel_is_configured
test_serve_refuses_when_the_funnel_check_cannot_be_answered
test_serve_refuses_when_the_local_port_is_already_held
test_serve_requires_a_built_board
