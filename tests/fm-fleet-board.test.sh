#!/usr/bin/env bash
# Tests for bin/fm-fleet-board.sh: the two-way visual fleet board renderer over
# fm-bearings-snapshot.sh.
#
# The load-bearing test is COVERAGE: every item bearings publishes must appear on
# the board, so a bounded projection never renders as a complete one. That check
# is only worth anything if it can fail, so case (b) is a negative control that
# feeds the renderer a REDUCED document while asserting against the FULL key set -
# exactly the "the board silently dropped an item" failure - and requires the
# shared assertion to go red with a nonzero exit. Cases (a) and (b) call the same
# board_missing_keys function, so a green (a) is backed by a proven instrument.
#
# Matrix:
#   (a) every item in the projection renders, keyed <surface>:<id|index>
#   (b) NEGATIVE CONTROL: a dropped item makes that same assertion fail non-zero
#   (c) omitted[] is disclosed on the board, surface text and all
#   (d) every open decision is answerable inline and queues an identifying prompt
#   (e) the artifact is self-contained: no local/relative asset references
#   (f) PRs render as full https URLs, never a bare #number
#   (g) the board never writes fleet state (data/, state/, backlog untouched)
#   (h) both light and dark themes are present and driven by the viewer
#   (i) lavish-axi is invoked by default and skipped under --no-open
#   (j) a non-bearings document is refused instead of rendering an empty board
#   (k) --help works and the artifact path is printed on stdout
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-fleet-board.sh"
# fm_test_tmproot registers its cleanup inside the command-substitution subshell,
# so the directory is gone by the time it is echoed back and the parent never gets
# the EXIT trap. Recreate it and own teardown here, which is the extra-teardown
# path tests/lib.sh documents.
TMP_ROOT=$(fm_test_tmproot fm-fleet-board-tests)
mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

command -v jq >/dev/null 2>&1 || { printf 'ok - fm-fleet-board: skipped (jq not found)\n'; exit 0; }

# A hermetic fm-bearings.v1 fixture. It carries every array surface the renderer
# knows about, including candidate_prs (whose rows have no `id`, exercising the
# index-keyed fallback) and a secondmate row, so coverage is proved across all of
# them rather than only the ones a given live fleet happens to have.
FIXTURE="$TMP_ROOT/bearings.json"
cat > "$FIXTURE" <<'JSON'
{
  "schema": "fm-bearings.v1",
  "home": "Code/firstmate",
  "generated": "2026-08-02T14:51:01Z",
  "prs": "not_requested (run: /bearings include PRs)",
  "in_flight": [
    {"id": "alpha-ship", "kind": "ship", "state": "working", "doing": "implementing the parser"},
    {"id": "beta-scout", "kind": "scout", "state": "paused", "doing": "waiting on an upstream release"},
    {"id": "gamma-mate", "kind": "secondmate", "state": "active_child_work", "doing": "delta-task: working"}
  ],
  "secondmates": [
    {"id": "gamma-mate", "state": "active_child_work", "doing": "delta-task: working",
     "provenance": "structured-home", "freshness": "fresh", "age_seconds": 0,
     "contradiction": false, "reason": "-"},
    {"id": "epsilon-mate", "state": "externally_held", "doing": "held-task: firstmate hold",
     "provenance": "structured-home", "freshness": "stale", "age_seconds": 900,
     "contradiction": true, "reason": "conflicting parent evidence"}
  ],
  "decisions_open": [
    {"id": "alpha-ship-decision-schema-shape", "key": "alpha-ship-decision-schema-shape",
     "verb": "captain-hold", "summary": "Flat or nested schema?: both round-trip", "owner": "(main)"},
    {"id": "gamma-mate/zeta-decision-retention", "key": "zeta-decision-retention",
     "verb": "captain-hold", "summary": "How long to retain raw events?: storage cost vs replay",
     "owner": "gamma-mate"}
  ],
  "landed": [
    {"id": "eta-done", "what": "Ship the retry backoff", "artifact": "https://github.com/o/r/pull/41", "owner": "(main)"},
    {"id": "theta-done", "what": "Scout the cache invalidation path", "artifact": "data/theta-done/report.md", "owner": "gamma-mate"}
  ],
  "gates": [
    {"id": "iota-queued", "title": "Split the migration into two passes", "blocked_by": "eta-done",
     "reason": "waiting on the backoff ship", "owner": "(main)"},
    {"id": "kappa-queued", "title": "Retire the legacy exporter", "blocked_by": "-",
     "reason": "code freeze until 2026-08-10", "owner": "gamma-mate"}
  ],
  "reports": [
    {"id": "beta-scout", "path": "/tmp/fm/data/beta-scout/report.md"}
  ],
  "recorded_prs": [
    {"id": "alpha-ship", "url": "https://github.com/o/r/pull/42"},
    {"id": "iota-queued", "url": "https://github.com/o/r/pull/43"}
  ],
  "unhealthy_endpoints": [
    {"id": "lambda-dead", "backend": "tmux", "target": "firstmate:fm-lambda-dead",
     "exists": false, "agent": "dead"}
  ],
  "candidate_prs": [
    {"num": "44", "repo": "o/r", "task": "alpha-ship", "url": "https://github.com/o/r/pull/44",
     "review": "none", "mergeable": "MERGEABLE", "checks": "passing"}
  ],
  "omitted": [
    {"surface": "backlog item bodies", "reveal": "--fields bodies"},
    {"surface": "gates showing 20 of 23", "reveal": "--all-queued"}
  ]
}
JSON

# --- the shared coverage assertion -----------------------------------------
#
# Derives the expected key set from the JSON independently of the renderer, then
# reports every key missing from the rendered board. Prints missing keys and
# returns 1 when anything was dropped, 0 when the board is complete. Both the
# real coverage case and the negative control run through THIS function, so the
# green case is only as trustworthy as the red one.

board_keys_from_json() {  # <bearings-json>
  jq -r '
    to_entries[]
    | select((.value | type) == "array")
    | .key as $surface
    | (.value | to_entries[])
    | "\($surface):\(if (.value.id // "") == "" then (.key | tostring) else .value.id end)"
  ' "$1"
}

board_missing_keys() {  # <keys-file> <html-file>; returns 1 if any key is absent
  local keys=$1 html=$2 key missing=0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if ! grep -qF -- "data-fm-item='$key'" "$html"; then
      printf 'missing from board: %s\n' "$key"
      missing=1
    fi
  done < "$keys"
  return "$missing"
}

FULL_KEYS="$TMP_ROOT/full-keys.txt"
board_keys_from_json "$FIXTURE" > "$FULL_KEYS"
[ "$(wc -l < "$FULL_KEYS")" -ge 15 ] || fail "fixture key set is implausibly small"

# --- (a) every item renders --------------------------------------------------
FULL_HTML="$TMP_ROOT/full.html"
out=$("$BOARD" --from-json "$FIXTURE" --out "$FULL_HTML" --no-open)
rc=$?
expect_code 0 "$rc" "(a) rendering the full projection"
[ "$out" = "$FULL_HTML" ] || fail "(a) expected the artifact path on stdout, got '$out'"
assert_present "$FULL_HTML" "(a) the board artifact was not written"

if ! coverage=$(board_missing_keys "$FULL_KEYS" "$FULL_HTML"); then
  fail "(a) the board dropped items bearings published:"$'\n'"$coverage"
fi
pass "(a) every item in the projection renders on the board"

# --- (b) NEGATIVE CONTROL: the coverage assertion must be able to fail --------
#
# Feed the renderer a document with one in_flight item dropped, but assert
# against the FULL key set. That is precisely the silent-drop failure criterion 2
# forbids, so board_missing_keys MUST return non-zero here. If this ever passes,
# case (a) proved nothing.
REDUCED="$TMP_ROOT/bearings-reduced.json"
jq '.in_flight |= [.[] | select(.id != "beta-scout")]' "$FIXTURE" > "$REDUCED"
grep -q 'beta-scout' "$REDUCED" || fail "(b) fixture reduction removed more than the one item"
REDUCED_HTML="$TMP_ROOT/reduced.html"
"$BOARD" --from-json "$REDUCED" --out "$REDUCED_HTML" --no-open >/dev/null \
  || fail "(b) rendering the reduced projection failed"

control=$(board_missing_keys "$FULL_KEYS" "$REDUCED_HTML")
control_rc=$?
expect_code 1 "$control_rc" "(b) the coverage assertion must go red on a dropped item"
assert_contains "$control" "in_flight:beta-scout" "(b) the coverage assertion must name the dropped item"
pass "(b) the coverage assertion fails non-zero when an item is dropped"

# --- (c) omitted[] is disclosed ----------------------------------------------
board=$(cat "$FULL_HTML")
assert_contains "$board" "backlog item bodies" "(c) an omitted surface is not disclosed on the board"
assert_contains "$board" "gates showing 20 of 23" "(c) a bounded-count disclosure is missing"
assert_contains "$board" "bounded view" "(c) the board does not warn that it is a bounded view"
pass "(c) omitted surfaces are visibly disclosed"

# --- (d) decisions are answerable inline and identify themselves -------------
assert_contains "$board" "data-decision-id='alpha-ship-decision-schema-shape'" \
  "(d) a main-home decision has no inline answer form"
assert_contains "$board" "data-decision-key='zeta-decision-retention'" \
  "(d) a secondmate decision does not carry its own decision key"
assert_contains "$board" "data-decision-owner='gamma-mate'" \
  "(d) a decision does not carry its owning home"
assert_contains "$board" "FLEET BOARD DECISION" "(d) the queued prompt has no identifying header"
assert_contains "$board" "'decision_id: '" "(d) the queued prompt does not name the decision id"
assert_contains "$board" "'decision_key: '" "(d) the queued prompt does not name the decision key"
assert_contains "$board" "'answer: '" "(d) the queued prompt does not carry the answer"
assert_contains "$board" "window.lavish.queuePrompt" "(d) answers are never queued back to the agent"
assert_contains "$board" "queueKey" "(d) re-answering does not replace the prior unsent answer"
# Reversible until submitted: no queuePrompt on a per-keystroke or change handler.
assert_not_contains "$board" "addEventListener('change'" \
  "(d) a change handler must not queue a prompt before the captain submits"
pass "(d) every open decision is answerable inline with an identifying payload"

# --- (e) self-contained ------------------------------------------------------
# Every external reference must be an absolute https CDN URL; a relative src/href
# would break criterion 5 (opening the file directly with no server running).
locals=$(printf '%s\n' "$board" | grep -oE "(src|href)='[^']*'" | grep -vE "='(https://|#)" || true)
[ -z "$locals" ] || fail "(e) the board references local assets:"$'\n'"$locals"
assert_not_contains "$board" "fetch(" "(e) the board must not fetch at runtime"
pass "(e) the artifact is self-contained"

# --- (f) full PR URLs, never a bare #number ----------------------------------
assert_contains "$board" "https://github.com/o/r/pull/42" "(f) a recorded PR URL is not rendered in full"
assert_contains "$board" "https://github.com/o/r/pull/41" "(f) a landed PR artifact is not rendered in full"
assert_contains "$board" "https://github.com/o/r/pull/43" "(f) a gated item's PR URL is not rendered in full"
bare=$(printf '%s\n' "$board" | grep -oE '(^|[^/[:alnum:]])#[0-9]+' || true)
[ -z "$bare" ] || fail "(f) the board renders a bare #number PR reference:"$'\n'"$bare"
pass "(f) every PR renders as a full https URL"

# --- (g) the board never writes fleet state ----------------------------------
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"
printf 'backlog baseline\n' > "$HOME_DIR/data/backlog.md"
printf 'status baseline\n' > "$HOME_DIR/state/alpha-ship.status"
before=$(find "$HOME_DIR/data" "$HOME_DIR/state" -type f -exec shasum {} \; | sort)
FM_HOME="$HOME_DIR" "$BOARD" --from-json "$FIXTURE" --no-open >/dev/null \
  || fail "(g) rendering into a fixture home failed"
after=$(find "$HOME_DIR/data" "$HOME_DIR/state" -type f -exec shasum {} \; | sort)
[ "$before" = "$after" ] || fail "(g) the board mutated fleet state:"$'\n'"$before"$'\n'"vs"$'\n'"$after"
assert_present "$HOME_DIR/.lavish/fleet-board.html" "(g) the default artifact path is not under \$FM_HOME/.lavish"
pass "(g) the board renders without writing any fleet state"

# --- (h) light and dark ------------------------------------------------------
assert_contains "$board" "prefers-color-scheme: dark" "(h) the board ignores the viewer's colour scheme"
assert_contains "$board" "data-theme" "(h) no theme is applied"
assert_contains "$board" "fm-theme-toggle" "(h) the viewer cannot switch theme"
# Semantic surfaces only: a hardcoded light background would break dark mode.
assert_contains "$board" "bg-base-100" "(h) the board does not use theme-aware surfaces"
assert_not_contains "$board" "bg-white" "(h) a hardcoded light surface breaks dark mode"
pass "(h) the board renders in both light and dark"

# --- (i) lavish-axi is invoked by default, skipped under --no-open -----------
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/lavish-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$TMP_ROOT/lavish-calls"
exit 0
SH
chmod +x "$FAKEBIN/lavish-axi"

: > "$TMP_ROOT/lavish-calls"
PATH="$FAKEBIN:$PATH" "$BOARD" --from-json "$FIXTURE" --out "$TMP_ROOT/opened.html" --no-open >/dev/null \
  || fail "(i) --no-open render failed"
[ ! -s "$TMP_ROOT/lavish-calls" ] || fail "(i) --no-open still invoked lavish-axi"

PATH="$FAKEBIN:$PATH" "$BOARD" --from-json "$FIXTURE" --out "$TMP_ROOT/opened.html" >/dev/null \
  || fail "(i) default render failed"
assert_grep "$TMP_ROOT/opened.html" "$TMP_ROOT/lavish-calls" \
  "(i) the default run did not hand the artifact to lavish-axi"
pass "(i) lavish-axi opens the board by default and is skipped under --no-open"

# --- (j) a non-bearings document is refused ----------------------------------
printf '{"schema":"fm-fleet.v1","tasks":[]}\n' > "$TMP_ROOT/wrong.json"
wrong_out=$("$BOARD" --from-json "$TMP_ROOT/wrong.json" --out "$TMP_ROOT/wrong.html" --no-open 2>&1)
wrong_rc=$?
[ "$wrong_rc" -ne 0 ] || fail "(j) a foreign schema rendered instead of being refused"
assert_contains "$wrong_out" "fm-bearings.v1" "(j) the refusal does not name the expected contract"
assert_absent "$TMP_ROOT/wrong.html" "(j) a refused render still wrote an artifact"

printf 'not json at all\n' > "$TMP_ROOT/bad.json"
"$BOARD" --from-json "$TMP_ROOT/bad.json" --out "$TMP_ROOT/bad.html" --no-open >/dev/null 2>&1
bad_rc=$?
[ "$bad_rc" -ne 0 ] || fail "(j) invalid JSON rendered instead of being refused"
pass "(j) a document that is not fm-bearings.v1 is refused"

# --- (k) help and stdout contract --------------------------------------------
help_out=$("$BOARD" --help)
expect_code 0 "$?" "(k) --help"
assert_contains "$help_out" "usage: fm-fleet-board.sh" "(k) --help does not print usage"
assert_contains "$help_out" "lavish-axi poll" "(k) --help does not document how answers come back"
"$BOARD" --nonsense >/dev/null 2>&1
bad_flag_rc=$?
expect_code 2 "$bad_flag_rc" "(k) an unknown flag"
pass "(k) --help and the stdout path contract hold"

printf 'ok - fm-fleet-board: all cases passed\n'
