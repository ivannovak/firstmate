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
  local home a b c
  home=$(make_home fingerprint)
  write_mixed_backlog "$home"
  a=$(FM_HOME="$home" "$BOARD" fingerprint)
  b=$(FM_HOME="$home" "$BOARD" fingerprint)
  [ "$a" = "$b" ] || fail "the fingerprint was not stable across two reads"

  printf 'working: something happened\n' > "$home/state/newtask.status"
  c=$(FM_HOME="$home" "$BOARD" fingerprint)
  [ "$a" != "$c" ] || fail "a new status event did not move the fingerprint"
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
    if [ "${3:-}" = "--json" ]; then cat "${FM_FAKE_TS_STATUS:?}"; else echo "https://macbook-pro.example.ts.net/"; fi
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
test_board_never_asserts_how_it_was_opened
test_secondmate_captain_holds_reach_the_board
test_snapshot_exposes_captain_threads_for_every_secondmate_hold
test_a_troubled_secondmate_home_still_surrenders_its_captain_decisions
test_serve_publishes_through_serve_and_never_funnel
test_serve_refuses_while_a_funnel_is_configured
test_serve_requires_a_built_board
