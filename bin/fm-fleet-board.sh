#!/usr/bin/env bash
# fm-fleet-board.sh - derive the captain-facing fleet board and serve it tailnet-only.
#
# The board is a SNAPSHOT, never a feed. It is regenerated when fleet state
# actually changes and never on a timer, because the canonical snapshot is
# expensive (it reads every task's current state and every registered secondmate
# home) while the fleet changes meaningfully only a handful of times a day.
# `refresh` is the cheap gate: it fingerprints the authoritative inputs without
# running the snapshot, and only pays for a rebuild when that fingerprint moved.
#
# DERIVED, NEVER STORED. Every number and every card comes from one execution of
# bin/fm-fleet-snapshot.sh. This script keeps no task state of its own: the only
# files it writes are the rendered board, the input fingerprint, and the model it
# rendered from. Deleting all three loses nothing but a rebuild.
#
# The four columns are the captain's decision order, and an item lands in exactly
# ONE of them, first match wins:
#   1. needs_you - every live captain-owned thread, from the canonical
#      captain_held predicate (main home) and each secondmate home's
#      captain_threads. Actionable and blocked alike: an inflated needs-you count
#      is annoying, a missing one is invisible, so this column never narrows to a
#      task SHAPE. Blocked entries carry what blocks them.
#   2. moving - a worker is actually running right now. Live work outranks a
#      recorded hold, matching the bearings rule that a working child is underway.
#   3. waiting - held or blocked on someone other than the captain, or queued for
#      dispatch. Every card names who or what it waits on.
#   4. landed - completed, with its artifact link.
#
# AGE HONESTY. tasks-axi stamps `since` when an item is FILED and does not restamp
# it on a state change, so this script never claims "in this column for N days".
# A dedicated decision record (the `<origin>-decision-<key>` identity owned by
# bin/fm-decision-hold.sh) is created at the moment the decision arises, so for
# those the filed date IS when it started needing the captain and the card says
# "waiting on you". Every other card says "open", which is true whatever column it
# is in. Landed cards use the completion date and are exact.
#
# STALENESS. The rendered page computes its own age in the browser from an
# embedded generation timestamp, so a board nobody rebuilt still shows its real
# age instead of a frozen "just now". The age sits in a fixed header that cannot
# be scrolled past, and it escalates through fresh, aging, stale, and expired
# presentations; an expired board dims its own content so it cannot be misread as
# current. With scripting off, the header states the absolute timestamp and says
# plainly that it could not compute the age.
#
# SERVING is tailnet-only. `serve` stages the rendered board alone in its own
# directory, serves that directory from a loopback-bound local server, and points
# `tailscale serve` at 127.0.0.1. Reachable only from the captain's own tailnet.
# It NEVER calls `tailscale funnel`, and it refuses to publish while a funnel is
# configured, because this board carries private fleet and client information.
# The default HTTPS port is 8443 rather than 443; see FM_BOARD_HTTPS_PORT below.
#
# Usage:
#   fm-fleet-board.sh render [--json] [--out <path>]   rebuild unconditionally
#   fm-fleet-board.sh refresh [--detach] [--out <path>]  rebuild only if inputs moved
#                                                      (--detach returns at once)
#   fm-fleet-board.sh fingerprint                      print the current input fingerprint
#   fm-fleet-board.sh serve [--out <path>]             publish tailnet-only over Tailscale
#   fm-fleet-board.sh unserve                          withdraw this board's serve config
#   fm-fleet-board.sh status                           report board age and serve state
#
# Output contract: `fm-fleet-board.v1` (--json). Read-only against fleet state:
# no locks, no wake drain, no backlog mutation, no network except `tailscale`
# under the serve subcommands.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SNAPSHOT="$SCRIPT_DIR/fm-fleet-snapshot.sh"

BOARD_OUT="${FM_BOARD_OUT:-$STATE/fleet-board.html}"
FINGERPRINT_FILE="$STATE/.fleet-board.fingerprint"
MODEL_FILE="$STATE/.fleet-board.model.json"
LOCK_DIR="$STATE/.fleet-board.lock"
WEBROOT="$STATE/.fleet-board-web"
PIDFILE="$STATE/.fleet-board.server.pid"

# The published HTTPS port is NOT 443 by default. Local development tooling
# commonly owns 443 on a working machine (Laravel Herd's nginx and Docker both do
# on the captain's), and a serve config on a contended port answers connection
# refused rather than failing loudly at setup time. 8443 is unclaimed and the
# tailnet reaches it exactly the same way.
FM_BOARD_HTTPS_PORT=${FM_BOARD_HTTPS_PORT:-8443}
FM_BOARD_LOCAL_PORT=${FM_BOARD_LOCAL_PORT:-8099}

# A rebuild reads every task's current state and every secondmate home, so it
# takes minutes on a real fleet. --detach exists so the watcher can drive the
# board from its poll loop without ever waiting on one: the cheap fingerprint
# runs inline, and only the expensive rebuild is handed to a detached
# single-flight child. FM_BOARD_LOCK_STALE reclaims a lock whose child died.
FM_BOARD_LOCK_STALE=${FM_BOARD_LOCK_STALE:-1800}

# Per-column bounds so one runaway column cannot produce an unreadable page.
# Every drop is disclosed in the model's omitted[] and on the page itself.
FM_BOARD_LANDED=${FM_BOARD_LANDED:-12}
FM_BOARD_COLUMN=${FM_BOARD_COLUMN:-60}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { echo "fm-fleet-board: $1" >&2; exit "${2:-1}"; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found"; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

now_epoch() { date -u +%s; }

# --- change detection -------------------------------------------------------
# Cheap enough to run on every watcher poll: it stats the authoritative inputs
# and hashes the small backlog files, and never runs the canonical snapshot.
# Any real fleet change moves at least one of these, because firstmate records
# every dispatch, status event, and metadata write through them.
fingerprint() {
  {
    printf 'home\t%s\n' "$FM_HOME"
    fingerprint_home "$DATA" "$STATE" main
    if [ -f "$DATA/secondmates.md" ]; then
      printf 'secondmates\t%s\n' "$(shasum -a 256 "$DATA/secondmates.md" | awk '{print $1}')"
      while IFS= read -r mate_home; do
        [ -n "$mate_home" ] || continue
        [ -d "$mate_home" ] || continue
        fingerprint_home "$mate_home/data" "$mate_home/state" "mate:$mate_home"
      done <<EOF
$(sed -n 's/.*(home:[[:space:]]*\([^;)]*\).*/\1/p' "$DATA/secondmates.md" 2>/dev/null)
EOF
    fi
  } | shasum -a 256 | awk '{print $1}'
}

# One home's contribution: the backlog's exact content, plus the identity of
# every task metadata and status file. A secondmate's child work shows on the
# board too, so its state has to move the fingerprint exactly as the main home's
# does, or a mate's progress would leave the board silently behind.
fingerprint_home() {  # <data-dir> <state-dir> <label>
  local data=$1 state=$2 label=$3 f
  if [ -f "$data/backlog.md" ]; then
    printf '%s\tbacklog\t%s\n' "$label" \
      "$(shasum -a 256 "$data/backlog.md" | awk '{print $1}')"
  else
    printf '%s\tbacklog\tabsent\n' "$label"
  fi
  for f in "$state"/*.meta "$state"/*.status; do
    [ -e "$f" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$label" "$(basename "$f")" \
      "$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || echo 0)" \
      "$(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f" 2>/dev/null || echo 0)"
  done
}

# --- model ------------------------------------------------------------------
build_model() {  # -> fm-fleet-board.v1 JSON on stdout
  local snap now epoch
  now=$(now_utc)
  epoch=$(now_epoch)
  snap=$("$SNAPSHOT" --json) || die "canonical snapshot failed"
  printf '%s' "$snap" | jq \
    --arg now "$now" \
    --argjson epoch "$epoch" \
    --argjson landed_n "$FM_BOARD_LANDED" \
    --argjson column_n "$FM_BOARD_COLUMN" '
    def trunc($n): if . == null then null else
      (tostring | gsub("\\s+"; " ") | if (length > $n) then (.[:$n] + "…") else . end) end;

    # The decision-record identity owned by bin/fm-decision-hold.sh is
    # <origin-id>-decision-<key>, so the text before the first "-decision-" is the
    # thread every such record belongs to. Anything else is its own thread.
    def thread_of: (tostring | split("-decision-")) as $p
      | if ($p | length) > 1 then $p[0] else tostring end;
    def is_decision_record: (tostring | test("-decision-"));

    # Days between a YYYY-MM-DD stamp and now. Null when there is no stamp, so a
    # missing date renders as "no date" rather than as a fabricated zero.
    def age_days($date):
      if ($date | type) != "string" or ($date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not) then null
      else (($epoch - (($date + "T00:00:00Z") | fromdateiso8601)) / 86400 | floor
            | if . < 0 then 0 else . end)
      end;

    def project_of: if (. // "") == "" then "(no project)" else . end;

    . as $snap
    | ([ $snap.tasks[] | select(.kind != "secondmate") ]) as $tasks
    | ([ $tasks[] | select(.current_state.state == "working") | .id ]) as $working_ids
    | ([ $tasks[]
         | select(.current_state.state == "paused" or .current_state.state == "parked"
                  or .current_state.state == "blocked")
         | {id, state:.current_state.state,
            detail:((.current_state.detail // .current_state.state) | trunc(160))} ]) as $stalled
    | (reduce $stalled[] as $s ({}; .[$s.id] = $s)) as $stalled_by_id
    | ([ $snap.backlog.records[] | select(.structured) ]) as $records
    | (reduce $tasks[] as $t ({}; .[$t.id] = $t)) as $task_by_id
    | (($snap.main_inventory.orphan_in_flight // [])) as $orphans

    # --- column 1: every live captain-owned thread ---------------------------
    | ([ $records[]
         | select(.captain_held == true)
         | {id, title:(.title | trunc(150)),
            detail:((.hold_reason // "captain decision pending") | trunc(300)),
            project:(.repo | project_of), thread:(.id | thread_of),
            owner:"(main)",
            pr_url:(.pr_url // null),
            actionable:(.captain_actionable == true),
            blocked_by:((.unresolved_blocker_ids // []) | if length > 0 then join(", ") else null end),
            age_date:(.since // null), age_days:age_days(.since // null),
            age_kind:(if (.id | is_decision_record) then "waiting on you" else "open" end)} ]
       + [ ($snap.secondmate_current.records // [])[] as $m
           | $m.captain_threads[]?
           | {id:($m.id + "/" + .id), title:(.title | trunc(150)),
              detail:((.reason // "captain decision pending") | trunc(300)),
              project:(.repo | project_of), thread:(.id | thread_of),
              owner:$m.id,
              pr_url:null,
              actionable:(.actionable == true),
              blocked_by:((.unresolved_blocker_ids // []) | if length > 0 then join(", ") else null end),
              age_date:(.since // null), age_days:age_days(.since // null),
              age_kind:(if (.id | is_decision_record) then "waiting on you" else "open" end)} ])
      as $needs_you
    | ([ $needs_you[] | .id ]) as $placed_1

    # --- column 2: a worker is running right now -----------------------------
    | ([ $records[]
         | . as $r
         | select((.captain_held // false) | not)
         | select(.state == "in_flight")
         | select($working_ids | index($r.id))
         | {id:.id, title:(.title | trunc(150)),
            detail:(((($task_by_id[.id].current_state.detail) // "") | select(. != ""))
                    // ($task_by_id[.id].hints.last_event_text // "under way") | trunc(300)),
            project:(.repo | project_of), thread:(.id | thread_of),
            owner:"(main)",
            pr_url:((.pr_url // $task_by_id[.id].pr.url) // null),
            attention:false,
            age_date:(.since // null), age_days:age_days(.since // null),
            age_kind:"open"} ]
       + [ $records[]
           | . as $r
           | select((.captain_held // false) | not)
           | select(.state == "in_flight")
           | select($orphans | index($r.id))
           | {id:.id, title:(.title | trunc(150)),
              detail:"Recorded as under way, but no worker is attached to it.",
              project:(.repo | project_of), thread:(.id | thread_of),
              owner:"(main)", pr_url:(.pr_url // null), attention:true,
              age_date:(.since // null), age_days:age_days(.since // null),
              age_kind:"open"} ]
       + [ ($snap.secondmate_current.records // [])[] as $m
           | $m.active_children[]?
           | {id:($m.id + "/" + .id), title:(.id | trunc(150)),
              detail:((.doing // "under way") | trunc(300)),
              project:$m.id, thread:($m.id), owner:$m.id, pr_url:null, attention:false,
              age_date:null, age_days:null, age_kind:"open"} ])
      as $moving
    | ($placed_1 + [ $moving[] | .id ]) as $placed_2

    # --- column 3: waiting on someone or something other than the captain ----
    | ([ $records[]
         | . as $r
         | select(.state != "done")
         | select($placed_2 | index($r.id) | not)
         | (($stalled_by_id[$r.id]) // null) as $st
         | ((.unresolved_blocker_ids // [])) as $ub
         | {id:.id, title:(.title | trunc(150)),
            waiting_on:(
              if (.hold_reason != null and .hold_kind != null) then ("held: " + .hold_kind)
              elif ($ub | length) > 0 then ("blocked by " + ($ub | join(", ")))
              elif $st != null then $st.state
              else "queued for dispatch" end),
            detail:(
              ((.hold_reason // .blocked_reason
                // (if $st != null then $st.detail else null end)
                // "Filed and waiting for a slot.") | trunc(300))),
            project:(.repo | project_of), thread:(.id | thread_of),
            owner:"(main)", pr_url:(.pr_url // null),
            age_date:(.since // null), age_days:age_days(.since // null),
            age_kind:"open"} ]
       + [ ($snap.secondmate_current.records // [])[] as $m
           | $m.holds[]?
           | {id:($m.id + "/" + .id), title:(.title | trunc(150)),
              waiting_on:(if (.unresolved_blocker_ids | length) > 0
                          then ("blocked by " + (.unresolved_blocker_ids | join(", ")))
                          else "held" end),
              detail:((.reason // "held") | trunc(300)),
              project:$m.id, thread:$m.id, owner:$m.id, pr_url:null,
              age_date:null, age_days:null, age_kind:"open"} ])
      as $waiting_all
    | ([ $waiting_all[] | . as $w | select($placed_1 | index($w.id) | not) ]) as $waiting

    # --- column 4: landed ----------------------------------------------------
    | ([ $records[]
         | select(.state == "done")
         | {id:.id, title:(.title | trunc(150)),
            artifact:((.pr_url // .report_path // .local_note) // null),
            is_pr:((.pr_url // null) != null),
            project:(.repo | project_of), thread:(.id | thread_of), owner:"(main)",
            age_date:((.completion.date // .merged // .done // .reported) // null),
            age_days:age_days((.completion.date // .merged // .done // .reported) // null),
            age_kind:"landed"} ]
       + [ ($snap.secondmate_landed.records // [])[]
           | {id:.id, title:(.title | trunc(150)),
              artifact:((.pr_url // .report_path // .local_note) // null),
              is_pr:((.pr_url // null) != null),
              project:(.home_id // "secondmate"), thread:(.id | thread_of),
              owner:(.home_id // "secondmate"),
              age_date:(.completion.date // null),
              age_days:age_days(.completion.date // null),
              age_kind:"landed"} ]
       | sort_by([(.age_date // ""), .id]) | reverse) as $landed_all
    | ($landed_all[:$landed_n]) as $landed

    # --- grouping: project, then the decision thread inside it ---------------
    | def group_threads:
        [ group_by(.project)[]
          | {project:(.[0].project),
             count:length,
             threads:[ group_by(.thread)[]
                       | {thread:(.[0].thread),
                          shared:((length > 1) or ((.[0].thread) != (.[0].id))),
                          items:(. | sort_by([(0 - (.age_days // 0)), .id]))} ]
                     | sort_by([(0 - ([.items[] | (.age_days // 0)] | max // 0)), .thread]) } ]
        | sort_by([(0 - .count), .project]);

    {
      schema:"fm-fleet-board.v1",
      generated:$now,
      generated_epoch:$epoch,
      home:($snap.fm_home | split("/") | (.[-2:] | join("/"))),
      source:{schema:$snap.schema, generated:$snap.generated},
      counts:{
        needs_you:($needs_you | length),
        needs_you_actionable:([$needs_you[] | select(.actionable)] | length),
        needs_you_blocked:([$needs_you[] | select(.actionable | not)] | length),
        moving:($moving | length),
        waiting:($waiting | length),
        landed:($landed_all | length)
      },
      columns:[
        {key:"needs_you", title:"Needs you",
         blurb:"A decision, an approval, a merge, a credential, or a blocker only you can clear.",
         count:($needs_you | length),
         groups:($needs_you[:$column_n] | group_threads)},
        {key:"waiting", title:"Waiting on someone else",
         blurb:"Blocked on a person or an external run, not on you.",
         count:($waiting | length),
         groups:($waiting[:$column_n] | group_threads)},
        {key:"moving", title:"Moving on its own",
         blurb:"A worker is running this right now.",
         count:($moving | length),
         groups:($moving[:$column_n] | group_threads)},
        {key:"landed", title:"Landed",
         blurb:"Recently completed, with the artifact it produced.",
         count:($landed_all | length),
         groups:($landed | group_threads)}
      ],
      omitted:[
        (if ($needs_you | length) > $column_n
         then {surface:"needs_you", count:(($needs_you | length) - $column_n)} else empty end),
        (if ($waiting | length) > $column_n
         then {surface:"waiting", count:(($waiting | length) - $column_n)} else empty end),
        (if ($moving | length) > $column_n
         then {surface:"moving", count:(($moving | length) - $column_n)} else empty end),
        (if ($landed_all | length) > $landed_n
         then {surface:"landed", count:(($landed_all | length) - $landed_n)} else empty end),
        (if ($snap.main_inventory.valid == false)
         then {surface:"main inventory",
               count:0,
               note:($snap.main_inventory.reason // "main inventory invalid")} else empty end),
        (($snap.secondmate_current.records // [])[]
         | select(.provenance.selected != "structured-home")
         | {surface:("secondmate " + .id),
            count:0,
            note:("current state not readable from its own home: " + (.current.reason // "unknown"))})
      ]
    }
  ' || die "board projection failed"
}

# --- rendering --------------------------------------------------------------
render_html() {  # <model-json-path>
  jq -r '
    def h: (. // "") | tostring | @html;
    def agechip($d; $kind):
      if $d == null then "<span class=\"age none\">no date</span>"
      else "<span class=\"age\"><b>" + ($d | tostring | @html) + "d</b> " + ($kind | @html) + "</span>"
      end;
    def prlink($url):
      if $url == null then ""
      else "<a class=\"pr\" href=\"" + ($url | @html) + "\">" + ($url | @html) + "</a>"
      end;
    def artifact($a; $is_pr):
      if $a == null then "<span class=\"artifact none\">no artifact recorded</span>"
      elif $is_pr then "<a class=\"pr\" href=\"" + ($a | @html) + "\">" + ($a | @html) + "</a>"
      else "<span class=\"artifact\">" + ($a | @html) + "</span>"
      end;

    def card($col):
      "<article class=\"card"
      + (if $col == "needs_you" and (.actionable == false) then " blocked" else "" end)
      + (if .attention == true then " attention" else "" end)
      + "\">"
      + "<div class=\"cardtop\">"
      + "<span class=\"id\">" + (.id | h) + "</span>"
      + agechip(.age_days; .age_kind)
      + "</div>"
      + "<h4>" + (.title | h) + "</h4>"
      + (if $col == "needs_you" and (.actionable == false)
         then "<p class=\"tag\">Cannot be answered yet: blocked by " + (.blocked_by | h) + "</p>"
         elif $col == "needs_you" then "<p class=\"tag ready\">Ready for your answer</p>"
         elif $col == "waiting" then "<p class=\"tag\">Waiting on " + (.waiting_on | h) + "</p>"
         elif $col == "moving" and .attention == true
         then "<p class=\"tag warn\">Nothing is actually running</p>"
         else "" end)
      + "<p class=\"detail\">" + ((.detail // "") | h) + "</p>"
      + (if $col == "landed" then "<p class=\"links\">" + artifact(.artifact; .is_pr) + "</p>"
         elif .pr_url != null then "<p class=\"links\">" + prlink(.pr_url) + "</p>"
         else "" end)
      + (if .owner != "(main)" then "<p class=\"owner\">second mate: " + (.owner | h) + "</p>" else "" end)
      + "</article>";

    def thread_block($col):
      (if .shared
       then "<div class=\"thread\"><div class=\"threadname\">" + (.thread | h)
            + "<span class=\"threadn\">" + ((.items | length) | tostring) + "</span></div>"
       else "<div class=\"thread bare\">" end)
      + ([.items[] | card($col)] | join(""))
      + "</div>";

    def group_block($col):
      "<section class=\"group\"><h3 class=\"groupname\">" + (.project | h)
      + "<span class=\"groupn\">" + (.count | tostring) + "</span></h3>"
      + ([.threads[] | thread_block($col)] | join(""))
      + "</section>";

    def column:
      . as $c
      | "<div class=\"col\" data-col=\"" + ($c.key | h) + "\">"
      + "<header class=\"colhead\"><h2>" + ($c.title | h)
      + "<span class=\"n\">" + ($c.count | tostring) + "</span></h2>"
      + "<p class=\"blurb\">" + ($c.blurb | h) + "</p></header>"
      + (if ($c.groups | length) == 0
         then "<p class=\"empty\">Nothing here.</p>"
         else ([$c.groups[] | group_block($c.key)] | join("")) end)
      + "</div>";

    "<!doctype html>",
    "<html lang=\"en\"><head><meta charset=\"utf-8\">",
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">",
    "<title>Fleet board — " + (.home | h) + "</title>",
    "<style>",
    ":root{--bg:#0e1116;--panel:#161b22;--edge:#262d38;--ink:#e6edf3;--dim:#8b949e;",
    "--accent:#58a6ff;--ok:#3fb950;--warn:#d29922;--bad:#f85149;--needs:#f0883e}",
    "*{box-sizing:border-box}",
    "body{margin:0;background:var(--bg);color:var(--ink);",
    "font:15px/1.5 ui-sans-serif,-apple-system,\"Segoe UI\",Roboto,sans-serif}",
    "#stale{position:sticky;top:0;z-index:20;display:flex;flex-wrap:wrap;gap:.5rem 1.25rem;",
    "align-items:baseline;padding:.7rem 1.1rem;border-bottom:1px solid var(--edge);",
    "background:var(--panel)}",
    "#stale .lead{font-size:1.05rem;font-weight:700}",
    "#stale .abs{color:var(--dim);font-size:.82rem;font-variant-numeric:tabular-nums}",
    "#stale .home{margin-left:auto;color:var(--dim);font-size:.82rem}",
    "#stale.fresh{border-bottom-color:var(--ok)}",
    "#stale.fresh .lead{color:var(--ok)}",
    "#stale.aging .lead{color:var(--ink)}",
    "#stale.stale{background:#3a2d10;border-bottom:2px solid var(--warn)}",
    "#stale.stale .lead{color:var(--warn)}",
    "#stale.expired{background:#4a1518;border-bottom:3px solid var(--bad)}",
    "#stale.expired .lead{color:#ffb4ae;font-size:1.25rem;letter-spacing:.02em}",
    "body.expired main{opacity:.34;filter:grayscale(.7)}",
    "body.expired #stale{opacity:1;filter:none}",
    ".subhead{padding:.55rem 1.1rem;color:var(--dim);font-size:.84rem;",
    "border-bottom:1px solid var(--edge)}",
    "main{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:1px;",
    "background:var(--edge)}",
    "@media(max-width:1100px){main{grid-template-columns:repeat(2,minmax(0,1fr))}}",
    "@media(max-width:680px){main{grid-template-columns:minmax(0,1fr)}}",
    ".col{background:var(--bg);min-width:0;padding:0 0 2rem}",
    ".colhead{position:sticky;top:3.1rem;z-index:10;background:var(--bg);",
    "padding:.9rem 1rem .6rem;border-bottom:1px solid var(--edge)}",
    ".colhead h2{margin:0;font-size:1rem;letter-spacing:.01em;display:flex;",
    "align-items:center;gap:.5rem}",
    ".colhead .n{background:var(--edge);border-radius:999px;padding:.05rem .55rem;",
    "font-size:.85rem;font-variant-numeric:tabular-nums}",
    "[data-col=needs_you] .colhead h2{color:var(--needs)}",
    "[data-col=needs_you] .colhead .n{background:var(--needs);color:#1b1005;font-weight:700}",
    ".blurb{margin:.3rem 0 0;color:var(--dim);font-size:.8rem}",
    ".group{padding:.8rem 1rem 0}",
    ".groupname{margin:0 0 .5rem;font-size:.74rem;text-transform:uppercase;",
    "letter-spacing:.09em;color:var(--dim);display:flex;gap:.45rem;align-items:center}",
    ".groupn{background:var(--edge);border-radius:999px;padding:0 .45rem;",
    "font-size:.72rem;letter-spacing:0}",
    ".thread{border-left:2px solid var(--edge);padding-left:.6rem;margin:0 0 .8rem}",
    ".thread.bare{border-left:0;padding-left:0}",
    ".threadname{font-size:.78rem;color:var(--accent);margin:0 0 .35rem;",
    "display:flex;gap:.4rem;align-items:center;word-break:break-word}",
    ".threadn{color:var(--dim);font-size:.72rem}",
    ".card{background:var(--panel);border:1px solid var(--edge);border-radius:8px;",
    "padding:.6rem .7rem;margin:0 0 .5rem;min-width:0}",
    "[data-col=needs_you] .card{border-left:3px solid var(--needs)}",
    "[data-col=needs_you] .card.blocked{border-left-color:var(--dim);opacity:.82}",
    ".card.attention{border-left:3px solid var(--bad)}",
    ".cardtop{display:flex;gap:.5rem;align-items:baseline;justify-content:space-between}",
    ".id{font:12px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--dim);",
    "word-break:break-all;min-width:0}",
    ".age{white-space:nowrap;font-size:.74rem;color:var(--dim)}",
    ".age b{color:var(--ink);font-variant-numeric:tabular-nums}",
    ".age.none{font-style:italic}",
    ".card h4{margin:.35rem 0 .3rem;font-size:.93rem;font-weight:600;line-height:1.35}",
    ".tag{margin:.15rem 0;font-size:.76rem;color:var(--warn)}",
    ".tag.ready{color:var(--ok)}",
    ".tag.warn{color:var(--bad);font-weight:600}",
    ".detail{margin:.3rem 0 0;font-size:.81rem;color:var(--dim);overflow-wrap:anywhere}",
    ".links{margin:.4rem 0 0;font-size:.78rem;overflow-wrap:anywhere}",
    ".pr{color:var(--accent)}",
    ".artifact{color:var(--dim);font-family:ui-monospace,Menlo,monospace;font-size:.74rem}",
    ".artifact.none{font-style:italic;font-family:inherit}",
    ".owner{margin:.3rem 0 0;font-size:.74rem;color:var(--accent)}",
    ".empty{padding:1rem;color:var(--dim);font-style:italic}",
    "footer{padding:1.1rem;color:var(--dim);font-size:.78rem;border-top:1px solid var(--edge)}",
    "footer code{font-size:.74rem;color:var(--ink)}",
    "footer li{margin:.2rem 0}",
    "</style></head><body>",

    "<div id=\"stale\" class=\"aging\" data-generated=\"" + (.generated | h)
      + "\" data-epoch=\"" + (.generated_epoch | tostring) + "\">",
    "<span class=\"lead\" id=\"agelead\">Age not computed</span>",
    "<span class=\"abs\">snapshot taken " + (.generated | h) + "</span>",
    "<noscript><span class=\"abs\">Scripting is off, so this page cannot compute how old it is. Read the timestamp above.</span></noscript>",
    "<span class=\"home\">" + (.home | h) + "</span>",
    "</div>",

    "<p class=\"subhead\">" + (.counts.needs_you | tostring)
      + " threads are waiting on you — " + (.counts.needs_you_actionable | tostring)
      + " you can answer now, " + (.counts.needs_you_blocked | tostring)
      + " blocked behind other work. "
      + (.counts.moving | tostring) + " moving, "
      + (.counts.waiting | tostring) + " waiting, "
      + (.counts.landed | tostring) + " landed.</p>",

    "<main>",
    ([.columns[] | column] | join("")),
    "</main>",

    "<footer>",
    "<p>This board is a snapshot, not a live feed. It is rebuilt when fleet state actually changes, so the age above is the age of the fleet reading, not of this page load.</p>",
    "<p>Ages are derived from the date each item was filed, which is the only durable date the backlog records; a decision record is filed the moment the decision arises, so those read <em>waiting on you</em>. Landed dates are exact.</p>",
    (if (.omitted | length) > 0 then
      "<p>Not shown:</p><ul>"
      + ([.omitted[]
          | "<li>" + (.surface | h)
          + (if .count > 0 then ": " + (.count | tostring) + " more" else "" end)
          + (if .note then " — " + (.note | h) else "" end) + "</li>"] | join(""))
      + "</ul>"
     else "" end),
    "<p>Derived from <code>" + (.source.schema | h) + "</code> taken at "
      + (.source.generated | h) + ". Nothing here is stored twice: rebuild with <code>fm-fleet-board.sh render</code>.</p>",
    "</footer>",

    "<script>",
    "(function(){",
    "var bar=document.getElementById(\"stale\"),lead=document.getElementById(\"agelead\");",
    "var born=parseInt(bar.getAttribute(\"data-epoch\"),10);",
    "function phrase(s){",
    "  if(s<90)return\"just now\";",
    "  var m=Math.round(s/60);if(m<60)return m+(m===1?\" minute\":\" minutes\")+\" old\";",
    "  var h=s/3600;if(h<48)return(h<10?h.toFixed(1):Math.round(h))+\" hours old\";",
    "  return Math.round(h/24)+\" days old\";",
    "}",
    "function tick(){",
    "  var s=Math.floor(Date.now()/1000)-born;if(s<0)s=0;",
    "  var cls=s<900?\"fresh\":s<7200?\"aging\":s<43200?\"stale\":\"expired\";",
    "  bar.className=cls;",
    "  document.body.classList.toggle(\"expired\",cls===\"expired\");",
    "  lead.textContent=(cls===\"expired\"?\"OUT OF DATE — \":cls===\"stale\"?\"Stale — \":\"\")",
    "    +\"this board is \"+phrase(s)",
    "    +(cls===\"expired\"?\". Do not act on it before rebuilding.\":\"\");",
    "}",
    "tick();setInterval(tick,30000);",
    "})();",
    "</script>",
    "</body></html>"
  ' "$1" || die "board rendering failed"
}

# Single-flight claim. Returns 1 when another rebuild already owns the board, so
# a watcher polling every few seconds can never stack rebuilds on top of a slow
# one. A lock older than FM_BOARD_LOCK_STALE is reclaimed, because a killed child
# must not wedge the board permanently.
claim_rebuild() {
  local age
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    age=$(( $(now_epoch) - $(stat -f '%m' "$LOCK_DIR" 2>/dev/null \
      || stat -c '%Y' "$LOCK_DIR" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$FM_BOARD_LOCK_STALE" ]; then
      return 1
    fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || return 1
  fi
  return 0
}

write_board() {  # <out-path>
  local out=$1 tmp
  mkdir -p "$(dirname "$out")" || die "cannot create $(dirname "$out")"
  tmp=$(mktemp "${out}.XXXXXX") || die "cannot create a temporary file next to $out"
  build_model > "$MODEL_FILE.tmp" || { rm -f "$tmp" "$MODEL_FILE.tmp"; exit 1; }
  render_html "$MODEL_FILE.tmp" > "$tmp" || { rm -f "$tmp" "$MODEL_FILE.tmp"; exit 1; }
  mv "$MODEL_FILE.tmp" "$MODEL_FILE"
  mv "$tmp" "$out"
  chmod 0644 "$out"
  # A board that is currently published must not keep serving the previous
  # rebuild; refresh the published copy in place.
  if [ -d "$WEBROOT" ]; then
    cp "$out" "$WEBROOT/index.html" 2>/dev/null && chmod 0644 "$WEBROOT/index.html" || true
  fi
}

# --- tailscale --------------------------------------------------------------
# Serving is tailnet-only by construction: `tailscale serve` publishes inside the
# tailnet, `tailscale funnel` is what publishes to the public internet, and this
# script never calls funnel. It additionally refuses to publish while any funnel
# is configured, so the board cannot ride along on someone else's public listener.
#
# Tailscale PROXIES a loopback server rather than serving the file itself. Two
# reasons, both load-bearing:
#   - The macOS Tailscale that ships as a sandboxed network extension cannot read
#     files outside its container, so `tailscale serve <file>` answers 500 or 403
#     no matter what the permissions say. Proxy mode needs no filesystem access.
#   - The loopback server is bound to 127.0.0.1, so the board is unreachable from
#     the local network even before Tailscale's own tailnet scoping applies.
# The published directory holds ONLY the rendered board, never the surrounding
# state/ directory, which is full of private fleet records.
assert_no_funnel() {
  local cfg
  cfg=$(tailscale serve status --json 2>/dev/null) || return 0
  if printf '%s' "$cfg" | jq -e '(.AllowFunnel // {}) | to_entries | map(select(.value)) | length > 0' >/dev/null 2>&1; then
    die "refusing to publish: a Tailscale funnel is configured, which would expose this board publicly. Clear it with 'tailscale funnel reset' first."
  fi
}

# Mirror the rendered board into a directory that contains nothing else.
publish_webroot() {  # <board-path>
  rm -rf "$WEBROOT"
  mkdir -p "$WEBROOT" || die "cannot create the publish directory $WEBROOT"
  cp "$1" "$WEBROOT/index.html" || die "cannot stage the board for publishing"
  chmod 0644 "$WEBROOT/index.html"
}

local_server_running() {
  [ -f "$PIDFILE" ] || return 1
  kill -0 "$(cat "$PIDFILE" 2>/dev/null || echo 0)" 2>/dev/null
}

start_local_server() {
  local_server_running && return 0
  command -v python3 >/dev/null 2>&1 \
    || die "python3 not found, and it is what serves the board to Tailscale on 127.0.0.1"
  python3 -m http.server "$FM_BOARD_LOCAL_PORT" --bind 127.0.0.1 --directory "$WEBROOT" \
    >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$PIDFILE"
  local i=0
  while [ "$i" -lt 50 ]; do
    if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$FM_BOARD_LOCAL_PORT/" 2>/dev/null; then
      return 0
    fi
    i=$((i + 1))
  done
  die "the local board server never became reachable on 127.0.0.1:$FM_BOARD_LOCAL_PORT"
}

cmd_serve() {
  local out=$1 dns url
  need tailscale
  need jq
  [ -f "$out" ] || die "no board at $out - run 'fm-fleet-board.sh render' first"
  assert_no_funnel
  publish_webroot "$out"
  start_local_server
  tailscale serve --bg --https="$FM_BOARD_HTTPS_PORT" "127.0.0.1:$FM_BOARD_LOCAL_PORT" >/dev/null \
    || die "tailscale serve failed on port $FM_BOARD_HTTPS_PORT"
  assert_no_funnel
  dns=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//')
  url="https://${dns:-localhost}"
  [ "$FM_BOARD_HTTPS_PORT" = 443 ] || url="$url:$FM_BOARD_HTTPS_PORT"
  echo "served tailnet-only: $url/"
  echo "source: $out"
  tailscale serve status 2>/dev/null | sed 's/^/  /'
}

cmd_unserve() {
  need tailscale
  tailscale serve --bg --https="$FM_BOARD_HTTPS_PORT" off >/dev/null 2>&1 || true
  if local_server_running; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
  rm -rf "$WEBROOT"
  echo "withdrawn"
}

cmd_status() {
  local out=$1 epoch age
  if [ -f "$out" ]; then
    epoch=$(stat -f '%m' "$out" 2>/dev/null || stat -c '%Y' "$out" 2>/dev/null || echo 0)
    age=$(( $(now_epoch) - epoch ))
    echo "board: $out"
    echo "age: ${age}s"
  else
    echo "board: absent ($out)"
  fi
  if [ -f "$FINGERPRINT_FILE" ]; then
    if [ "$(cat "$FINGERPRINT_FILE")" = "$(fingerprint)" ]; then
      echo "inputs: unchanged since the last build"
    else
      echo "inputs: CHANGED since the last build - run 'fm-fleet-board.sh refresh'"
    fi
  else
    echo "inputs: never fingerprinted"
  fi
  if command -v tailscale >/dev/null 2>&1; then
    tailscale serve status 2>/dev/null | sed 's/^/serve: /' || true
  fi
}

# --- entrypoint -------------------------------------------------------------
CMD=${1:-}
[ $# -gt 0 ] && shift
JSON=0
DETACH=0
OUT=$BOARD_OUT
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --detach) DETACH=1 ;;
    --out) shift; OUT=${1:?--out needs a path} ;;
    --out=*) OUT=${1#--out=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

case "$CMD" in
  render)
    need jq
    if [ "$JSON" = 1 ]; then
      build_model
      exit 0
    fi
    # Take the same single-flight claim a refresh does: both write the same
    # model and board files, so a manual render must not race a detached one.
    claim_rebuild || die "another rebuild is already running"
    trap 'rm -rf "$LOCK_DIR"' EXIT
    write_board "$OUT"
    fingerprint > "$FINGERPRINT_FILE"
    echo "rebuilt $OUT"
    ;;
  refresh)
    need jq
    current=$(fingerprint)
    if [ -f "$OUT" ] && [ -f "$FINGERPRINT_FILE" ] \
       && [ "$current" = "$(cat "$FINGERPRINT_FILE")" ]; then
      echo "unchanged"
      exit 0
    fi
    claim_rebuild || { echo "busy"; exit 0; }
    if [ "$DETACH" = 1 ]; then
      (
        trap 'rm -rf "$LOCK_DIR"' EXIT
        write_board "$OUT" && printf '%s\n' "$current" > "$FINGERPRINT_FILE"
      ) >/dev/null 2>&1 &
      echo "rebuilding"
      exit 0
    fi
    trap 'rm -rf "$LOCK_DIR"' EXIT
    write_board "$OUT"
    printf '%s\n' "$current" > "$FINGERPRINT_FILE"
    echo "rebuilt $OUT"
    ;;
  fingerprint) fingerprint ;;
  serve) cmd_serve "$OUT" ;;
  unserve) cmd_unserve ;;
  status) cmd_status "$OUT" ;;
  -h|--help|"") usage; [ -n "$CMD" ] && exit 0; exit 2 ;;
  *) echo "fm-fleet-board: unknown command: $CMD" >&2; usage >&2; exit 2 ;;
esac
