#!/usr/bin/env bash
# fm-fleet-board.sh - two-way visual fleet board over fm-bearings-snapshot.sh.
#
# A RENDERER, in the same shape as bin/fm-fleet-view.sh: it does not parse fleet
# state and it does not classify anything. It shells out to
# `fm-bearings-snapshot.sh --json`, renders that `fm-bearings.v1` contract as a
# self-contained HTML board under $FM_HOME/.lavish/, opens or refreshes it with
# `lavish-axi`, and prints the artifact path on stdout.
#
# ONE CLASSIFIER. The bearings projection already owns which items are
# captain-actionable, landed, under way, or gated. This board maps its four
# sections straight onto the arrays bearings publishes and never re-derives a
# bucket from bin/fm-fleet-snapshot.sh:
#   Captain's Call  <- decisions_open[]
#   Recently Landed <- landed[]
#   Under Way       <- in_flight[]   (bearings already folds active secondmates in)
#   Charted Next    <- gates[]
# secondmates[], reports[], recorded_prs[], unhealthy_endpoints[] and
# candidate_prs[] are bearings' own reference surfaces and get their own panels,
# so nothing bearings publishes is dropped. The headline counts are display
# roll-ups over fields bearings itself publishes (an item's `state`); they never
# move an item between sections. In that roll-up "parked" is a deliberate stop,
# so it counts as a hold under "Stuck or waiting" (warning badge, not error);
# "done" is finished-but-not-yet-cleaned-up, so it counts in neither headline
# and leaves the "of N under way" denominator - finished work is already
# represented under Recently Landed. Parked and done rows still render under
# Under Way like every other in_flight row. A field this board wants but
# bearings does not expose belongs in the bearings projection, not here.
#
# PULL REQUESTS render as their full https URL, never a bare "#number". That
# governs the board's own PR renderings. A bare number can also arrive inside
# text bearings supplies, such as a backlog title reading "bring PR #4321
# green"; the board holds no repository context for that number, so it renders
# the text as written rather than fabricating a URL from a guessed repository.
#
# THE BOARD NEVER WRITES FLEET STATE. It renders and collects. An answered
# decision is queued back through Lavish and returned by `lavish-axi poll`;
# firstmate reads that response and applies it with bin/fm-decision-hold.sh. The
# artifact touches nothing under data/, state/, or the backlog.
#
# COVERAGE CONTRACT (public, asserted by tests/fm-fleet-board.test.sh): every
# rendered item carries data-fm-item="<surface>:<key>", where <surface> is the
# bearings array name and <key> is the row's `id`, or its 0-based index in that
# array when the row has no `id`. Deriving that set from the JSON and grepping
# the board proves mechanically that nothing was silently dropped.
#
# Read-only: no locks, no mutation. The bearings snapshot is local-only unless
# bearings flags are forwarded after `--`.
#
# Flags:
#   --out <path>        artifact path (default: $FM_HOME/.lavish/fleet-board.html)
#   --from-json <path>  render a saved `fm-bearings.v1` document instead of
#                       generating one (development and tests; "-" reads stdin)
#   --no-open           render only; do not invoke lavish-axi
#   -h,--help           usage
#   -- <args...>        forward the remaining args to fm-bearings-snapshot.sh
#                       (for example: -- --all-queued --all-decisions)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
BEARINGS="$SCRIPT_DIR/fm-bearings-snapshot.sh"

usage() {
  cat <<'EOF'
usage: fm-fleet-board.sh [--out <path>] [--from-json <path>] [--no-open]
                         [-- <fm-bearings-snapshot.sh args...>]

Render a two-way visual fleet board from fm-bearings-snapshot.sh --json, open or
refresh it with lavish-axi, and print the artifact path on stdout.

Sections map one-to-one onto the bearings projection, which owns classification:
  Captain's Call <- decisions_open,  Recently Landed <- landed,
  Under Way      <- in_flight,       Charted Next    <- gates.
secondmates, reports, recorded_prs, unhealthy_endpoints and candidate_prs render
as their own reference panels, and omitted[] is disclosed on the board so a
bounded view never reads as a complete one.

Open decisions are answerable inline. Answers are queued through Lavish and
returned by `lavish-axi poll <html-file>` as a FLEET BOARD DECISION prompt naming
decision_id, decision_key, owner and answer. The board never writes fleet state:
apply an answer with bin/fm-decision-hold.sh.

  --out <path>        artifact path (default: $FM_HOME/.lavish/fleet-board.html)
  --from-json <path>  render a saved fm-bearings.v1 document ("-" reads stdin)
  --no-open           render only; do not invoke lavish-axi
  -h,--help           this help
  -- <args...>        forward the rest to fm-bearings-snapshot.sh, e.g.
                      `fm-fleet-board.sh -- --all-queued --all-decisions`
EOF
}

OUT=""
FROM_JSON=""
OPEN=1
BEARINGS_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) shift; OUT=${1:-} ; [ -n "$OUT" ] || { echo "fm-fleet-board: --out needs a path" >&2; exit 2; } ;;
    --out=*) OUT=${1#--out=} ;;
    --from-json) shift; FROM_JSON=${1:-} ; [ -n "$FROM_JSON" ] || { echo "fm-fleet-board: --from-json needs a path" >&2; exit 2; } ;;
    --from-json=*) FROM_JSON=${1#--from-json=} ;;
    --no-open) OPEN=0 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; BEARINGS_ARGS=("$@"); break ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-board: jq not found" >&2; exit 1; }

if [ -n "$FROM_JSON" ]; then
  if [ "$FROM_JSON" = "-" ]; then
    MODEL=$(cat)
  else
    [ -r "$FROM_JSON" ] || { echo "fm-fleet-board: cannot read $FROM_JSON" >&2; exit 1; }
    MODEL=$(cat "$FROM_JSON")
  fi
else
  [ -x "$BEARINGS" ] || { echo "fm-fleet-board: $BEARINGS not executable" >&2; exit 1; }
  MODEL=$("$BEARINGS" --json ${BEARINGS_ARGS[@]+"${BEARINGS_ARGS[@]}"}) || exit $?
fi

# Fail closed on anything that is not the contract this renderer was written for,
# rather than rendering an empty board that reads like a quiet fleet.
SCHEMA=$(printf '%s' "$MODEL" | jq -er '.schema // ""' 2>/dev/null) \
  || { echo "fm-fleet-board: input is not valid JSON" >&2; exit 1; }
[ "$SCHEMA" = "fm-bearings.v1" ] \
  || { echo "fm-fleet-board: expected schema fm-bearings.v1, got '$SCHEMA'" >&2; exit 1; }

[ -n "$OUT" ] || OUT="$FM_HOME/.lavish/fleet-board.html"
OUT_DIR=$(dirname "$OUT")
mkdir -p "$OUT_DIR" || { echo "fm-fleet-board: cannot create $OUT_DIR" >&2; exit 1; }

read -r -d '' RENDER <<'JQPROG'
def h: (if . == null then "" else tostring end) | @html;
def blank: . == null or . == "" or . == "-";
def dash: if blank then null else . end;
def itemkey($surface; $i): "\($surface):\(if (.id | blank) then ($i | tostring) else .id end)";
# Display roll-up only: reads the `state` bearings already publishes so the
# captain can see at a glance what is moving. It never moves an item between
# sections - every in_flight row still renders under Under Way. "parked" is a
# deliberate stop, so it is a hold (warning badge, not error); "done" is
# finished-but-not-yet-cleaned-up, so it counts in neither headline and leaves
# the under-way denominator - Recently Landed already carries finished work.
def needs_attention: . as $s
  | ["parked","paused","blocked","failed","needs-decision","stale","cancelled","unknown"]
  | index($s) != null;
def state_badge: . as $s
  | if ($s | needs_attention) then
      (if $s == "paused" or $s == "parked" then "badge-warning" else "badge-error" end)
    elif $s == "working" or $s == "active_child_work" then "badge-success"
    else "badge-neutral" end;
def link_or_text($v):
  if ($v | blank) then ""
  elif ($v | tostring | startswith("http")) then
    "<a class='link link-primary break-all' href='\($v | h)'>\($v | h)</a>"
  else "<span class='break-all opacity-70'>\($v | h)</span>" end;
def section_head($title; $n; $sub):
  "<div class='mb-3 flex flex-wrap items-baseline gap-x-3 gap-y-1'>",
  "<h2 class='text-xl font-semibold tracking-tight'>\($title | h)</h2>",
  "<span class='badge badge-neutral badge-sm'>\($n)</span>",
  (if ($sub | blank) then empty else "<p class='text-sm opacity-60'>\($sub | h)</p>" end),
  "</div>";
def empty_note($text): "<p class='rounded-box bg-base-100 p-4 text-sm opacity-60'>\($text | h)</p>";

(.in_flight // []) as $in_flight
| (.secondmates // []) as $secondmates
| (.decisions_open // []) as $decisions
| (.landed // []) as $landed
| (.gates // []) as $gates
| (.reports // []) as $reports
| (.recorded_prs // []) as $recorded_prs
| (.unhealthy_endpoints // []) as $unhealthy
| (.candidate_prs // []) as $candidate_prs
| (.omitted // []) as $omitted
| ($recorded_prs | map({key: (.id | tostring), value: .url}) | from_entries) as $pr_by_id
| ($reports | map({key: (.id | tostring), value: .path}) | from_entries) as $report_by_id
| ([$in_flight[] | select(.state == "done")] | length) as $finished
| (($in_flight | length) - $finished) as $underway
| ([$in_flight[] | select(.state | needs_attention)] | length) as $stalled
| ($underway - $stalled) as $moving
| ($gates | length) as $waiting

| [
"<!doctype html>",
"<html lang='en' data-theme='corporate'>",
"<head>",
"<meta charset='utf-8'>",
"<meta name='viewport' content='width=device-width, initial-scale=1'>",
"<title>Fleet Board - \(.home | h)</title>",
"<link rel='stylesheet' href='https://cdn.jsdelivr.net/npm/daisyui@5.5.19/daisyui.css'>",
"<link rel='stylesheet' href='https://cdn.jsdelivr.net/npm/daisyui@5.5.19/themes.css'>",
"<script src='https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4.2.4/dist/index.global.js'></script>",
"<style>",
"  *, *::before, *::after { box-sizing: border-box; }",
"  html, body { max-width: 100%; overflow-x: hidden; }",
"  :where(.grid, .flex) > * { min-width: 0; }",
"  :where(p, h1, h2, h3, h4, h5, h6, li, dd, dt, blockquote, figcaption, span, a, code, .badge) { overflow-wrap: anywhere; }",
"  :where(img, svg, video, canvas, iframe) { max-width: 100%; height: auto; }",
"</style>",
"<script>",
"(function () {",
"  try {",
"    var t = localStorage.getItem('fm-board-theme');",
"    if (!t) { t = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'business' : 'corporate'; }",
"    document.documentElement.setAttribute('data-theme', t);",
"  } catch (e) {}",
"})();",
"</script>",
"</head>",
"<body class='bg-base-200 text-base-content'>",

"<header class='sticky top-0 z-30 border-b border-base-content/10 bg-base-100/95 backdrop-blur'>",
"<div class='mx-auto flex max-w-7xl flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3 lg:px-8'>",
"<h1 class='text-lg font-semibold tracking-tight'>Fleet Board</h1>",
"<span class='badge badge-soft badge-primary'>\(.home | h)</span>",
"<span class='text-xs opacity-60'>as of \(.generated | h)</span>",
"<div class='ml-auto flex items-center gap-2'>",
"<span class='text-xs opacity-60'>Live pull-request checks: \(.prs | h)</span>",
"<button id='fm-theme-toggle' type='button' class='btn btn-ghost btn-xs'>Theme</button>",
"</div>",
"</div>",
"</header>",

"<main class='mx-auto max-w-7xl space-y-10 px-4 py-6 lg:px-8 lg:py-10'>",

# --- the five-second read -------------------------------------------------
"<section aria-label='Fleet at a glance' class='grid gap-4 sm:grid-cols-2 xl:grid-cols-4'>",
"<div class='rounded-box border-2 border-error bg-error/10 p-5'>",
"<p class='text-xs font-semibold uppercase tracking-wider text-error'>Needs you</p>",
"<p class='mt-1 text-5xl font-bold leading-none'>\($decisions | length)</p>",
"<p class='mt-2 text-sm opacity-70'>open decisions only you can make</p>",
"</div>",
"<div class='rounded-box border border-base-content/10 bg-base-100 p-5'>",
"<p class='text-xs font-semibold uppercase tracking-wider opacity-60'>Moving on their own</p>",
"<p class='mt-1 text-5xl font-bold leading-none'>\($moving)</p>",
"<p class='mt-2 text-sm opacity-70'>of \($underway) under way\(if $finished > 0 then ", \($finished) finished awaiting cleanup" else "" end)</p>",
"</div>",
"<div class='rounded-box border border-base-content/10 bg-base-100 p-5'>",
"<p class='text-xs font-semibold uppercase tracking-wider opacity-60'>Stuck or waiting</p>",
"<p class='mt-1 text-5xl font-bold leading-none'>\($stalled + $waiting)</p>",
"<p class='mt-2 text-sm opacity-70'>\($stalled) held or stalled under way, \($waiting) not started</p>",
"</div>",
"<div class='rounded-box border border-base-content/10 bg-base-100 p-5'>",
"<p class='text-xs font-semibold uppercase tracking-wider opacity-60'>Recently landed</p>",
"<p class='mt-1 text-5xl font-bold leading-none'>\($landed | length)</p>",
"<p class='mt-2 text-sm opacity-70'>finished since the last sweep</p>",
"</div>",
"</section>",

# --- bounded-view disclosure, above the fold ------------------------------
(if ($omitted | length) == 0 then empty else
  ("<div role='alert' class='alert alert-warning'>",
   "<span><strong>This board is a bounded view.</strong> \($omitted | length) surface(s) are not shown - see <a class='link' href='#not-shown'>Not shown on this board</a>.</span>",
   "</div>")
 end),

# --- Captain's Call -------------------------------------------------------
"<section aria-label=\"Captain's Call\">",
"<div class='mb-4 flex flex-wrap items-baseline gap-x-3 gap-y-1 border-l-4 border-error pl-4'>",
"<h2 class='text-3xl font-bold tracking-tight'>Captain's Call</h2>",
"<span class='badge badge-error'>\($decisions | length)</span>",
"<p class='text-sm opacity-70'>answer inline; nothing else on this board costs you anything</p>",
"</div>",
(if ($decisions | length) == 0 then empty_note("No open decisions. Nothing is waiting on you.") else
  ("<div class='grid gap-4 xl:grid-cols-2'>",
   ($decisions | to_entries[] | .key as $i | .value |
     ("<article data-fm-item='\(itemkey("decisions_open"; $i) | h)' class='card border-l-4 border-error bg-base-100 shadow-sm'>",
      "<div class='card-body gap-3 p-5'>",
      "<div class='flex flex-wrap items-start justify-between gap-2'>",
      "<h3 class='card-title text-base leading-snug'>\(.summary | h)</h3>",
      "<span class='badge badge-soft badge-sm shrink-0'>\(.owner | h)</span>",
      "</div>",
      "<p class='font-mono text-xs opacity-50'>\(.id | h)</p>",
      (if ($pr_by_id[.id | tostring] | blank) then empty else
        "<p class='text-sm'>\(link_or_text($pr_by_id[.id | tostring]))</p>" end),
      "<form data-fm-decision-form data-decision-id='\(.id | h)' data-decision-key='\(.key | h)' data-decision-owner='\(.owner | h)' data-decision-summary='\(.summary | h)' data-lavish-question='decision:\(.id | h)' class='mt-1 space-y-2'>",
      "<label class='label px-0 text-xs opacity-70' for='answer-\(.id | h)'>Your call</label>",
      "<textarea id='answer-\(.id | h)' name='answer' rows='2' class='textarea textarea-bordered w-full text-sm' placeholder='Answer this decision...'></textarea>",
      "<div class='flex flex-wrap justify-end gap-2'>",
      "<button type='button' data-fm-defer class='btn btn-ghost btn-sm'>Defer</button>",
      "<button type='submit' class='btn btn-primary btn-sm'>Queue answer</button>",
      "</div>",
      "<p data-fm-queued hidden class='rounded-box bg-success/15 p-2 text-xs'></p>",
      "</form>",
      "</div>",
      "</article>")),
   "</div>",
   "<p data-fm-offline hidden class='mt-3 text-sm opacity-60'>Opened as a plain file: answers cannot be sent from here. Reopen the board through the review surface to answer inline.</p>")
 end),
"</section>",

# --- Under Way + Charted Next --------------------------------------------
"<div class='grid gap-8 lg:grid-cols-2'>",

"<section aria-label='Under Way'>",
section_head("Under Way"; ($in_flight | length); "moving without you"),
(if ($in_flight | length) == 0 then empty_note("Nothing is under way.") else
  ("<ul class='space-y-3'>",
   ($in_flight | to_entries[] | .key as $i | .value |
     ("<li data-fm-item='\(itemkey("in_flight"; $i) | h)' class='rounded-box border border-base-content/10 bg-base-100 p-4'>",
      "<div class='flex flex-wrap items-center justify-between gap-2'>",
      "<span class='font-medium'>\(.id | h)</span>",
      "<span class='flex shrink-0 gap-1'>",
      "<span class='badge badge-ghost badge-sm'>\(.kind | h)</span>",
      "<span class='badge badge-sm \(.state | state_badge)'>\(.state | h)</span>",
      "</span>",
      "</div>",
      (if (.doing | blank) then empty else "<p class='mt-2 text-sm opacity-70'>\(.doing | h)</p>" end),
      (if ($pr_by_id[.id | tostring] | blank) then empty else
        "<p class='mt-2 text-sm'>\(link_or_text($pr_by_id[.id | tostring]))</p>" end),
      (if ($report_by_id[.id | tostring] | blank) then empty else
        "<p class='mt-1 text-xs'>\(link_or_text($report_by_id[.id | tostring]))</p>" end),
      "</li>")),
   "</ul>")
 end),
"</section>",

"<section aria-label='Charted Next'>",
section_head("Charted Next"; ($gates | length); "queued or held, not on you"),
(if ($gates | length) == 0 then empty_note("Nothing is queued.") else
  ("<ul class='space-y-3'>",
   ($gates | to_entries[] | .key as $i | .value |
     ("<li data-fm-item='\(itemkey("gates"; $i) | h)' class='rounded-box border border-base-content/10 bg-base-100 p-4'>",
      "<div class='flex flex-wrap items-center justify-between gap-2'>",
      "<span class='font-medium'>\(.title | h)</span>",
      "<span class='badge badge-soft badge-sm shrink-0'>\(.owner | h)</span>",
      "</div>",
      "<p class='mt-1 font-mono text-xs opacity-50'>\(.id | h)</p>",
      (if (.reason | blank) then empty else "<p class='mt-2 text-sm opacity-70'>Waiting on: \(.reason | h)</p>" end),
      (if (.blocked_by | blank) then empty else "<p class='mt-1 text-xs opacity-60'>Blocked by \(.blocked_by | h)</p>" end),
      (if ($pr_by_id[.id | tostring] | blank) then empty else
        "<p class='mt-2 text-sm'>\(link_or_text($pr_by_id[.id | tostring]))</p>" end),
      "</li>")),
   "</ul>")
 end),
"</section>",

"</div>",

# --- Recently Landed ------------------------------------------------------
"<section aria-label='Recently Landed'>",
section_head("Recently Landed"; ($landed | length); "done; no action"),
(if ($landed | length) == 0 then empty_note("Nothing landed recently.") else
  ("<ul class='grid gap-3 lg:grid-cols-2'>",
   ($landed | to_entries[] | .key as $i | .value |
     ("<li data-fm-item='\(itemkey("landed"; $i) | h)' class='rounded-box border border-success/30 bg-base-100 p-4'>",
      "<div class='flex flex-wrap items-start justify-between gap-2'>",
      "<span class='font-medium'>\(.what | h)</span>",
      "<span class='badge badge-soft badge-success badge-sm shrink-0'>\(.owner | h)</span>",
      "</div>",
      "<p class='mt-1 font-mono text-xs opacity-50'>\(.id | h)</p>",
      (if (.artifact | blank) then empty else "<p class='mt-2 text-sm'>\(link_or_text(.artifact))</p>" end),
      "</li>")),
   "</ul>")
 end),
"</section>",

# --- Secondmate homes -----------------------------------------------------
(if ($secondmates | length) == 0 then empty else
  ("<section aria-label='Secondmate homes'>",
   section_head("Second Mates"; ($secondmates | length); "their active work already appears under Under Way"),
   "<ul class='grid gap-3 lg:grid-cols-2'>",
   ($secondmates | to_entries[] | .key as $i | .value |
     ("<li data-fm-item='\(itemkey("secondmates"; $i) | h)' class='rounded-box border border-base-content/10 bg-base-100 p-4'>",
      "<div class='flex flex-wrap items-center justify-between gap-2'>",
      "<span class='font-medium'>\(.id | h)</span>",
      "<span class='flex shrink-0 flex-wrap gap-1'>",
      (if .contradiction == true then "<span class='badge badge-warning badge-sm'>contradictory evidence</span>" else empty end),
      "<span class='badge badge-ghost badge-sm'>\(.freshness | h)</span>",
      "<span class='badge badge-sm \(.state | state_badge)'>\(.state | h)</span>",
      "</span>",
      "</div>",
      (if (.doing | blank) then empty else "<p class='mt-2 text-sm opacity-70'>\(.doing | h)</p>" end),
      (if (.reason | blank) then empty else "<p class='mt-1 text-xs opacity-60'>\(.reason | h)</p>" end),
      "</li>")),
   "</ul>",
   "</section>")
 end),

# --- reference surfaces ---------------------------------------------------
(if ($unhealthy | length) == 0 then empty else
  ("<section aria-label='Unhealthy endpoints'>",
   section_head("Workers Not Responding"; ($unhealthy | length); "their recorded worker is gone"),
   "<ul class='space-y-2'>",
   ($unhealthy | to_entries[] | .key as $i | .value |
     ("<li data-fm-item='\(itemkey("unhealthy_endpoints"; $i) | h)' class='rounded-box border border-error/40 bg-base-100 p-3 text-sm'>",
      "<span class='font-medium'>\(.id | h)</span>",
      "<span class='ml-2 opacity-60'>\(.backend | h) / \(.target | h)</span>",
      "</li>")),
   "</ul>",
   "</section>")
 end),

(if ($candidate_prs | length) == 0 then empty else
  ("<section aria-label='Open pull requests'>",
   section_head("Open Pull Requests"; ($candidate_prs | length); "live check"),
   "<ul class='space-y-2'>",
   ($candidate_prs | to_entries[] | .key as $i | .value |
     ("<li data-fm-item='\(itemkey("candidate_prs"; $i) | h)' class='rounded-box border border-base-content/10 bg-base-100 p-3 text-sm'>",
      # Identity is the repo plus the task it belongs to, never a bare "#num":
      # every pull request on this board reads as its full https URL below.
      "<div class='flex flex-wrap items-center gap-2'>",
      "<span class='font-medium'>\(.repo | h)</span>",
      (if (.task | blank) then empty else "<span class='badge badge-ghost badge-sm'>\(.task | h)</span>" end),
      "<span class='badge badge-sm \(if .checks == "failing" then "badge-error" elif .checks == "passing" then "badge-success" else "badge-neutral" end)'>checks \(.checks | h)</span>",
      "<span class='badge badge-ghost badge-sm'>review \(.review | h)</span>",
      "</div>",
      "<p class='mt-1'>\(link_or_text(.url))</p>",
      "</li>")),
   "</ul>",
   "</section>")
 end),

(if (($reports | length) + ($recorded_prs | length)) == 0 then empty else
  ("<section aria-label='Reference'>",
   section_head("Reference"; (($reports | length) + ($recorded_prs | length)); "every report and recorded pull request bearings published"),
   "<div class='grid gap-6 lg:grid-cols-2'>",
   "<div>",
   "<h3 class='mb-2 text-sm font-semibold uppercase tracking-wider opacity-60'>Reports (\($reports | length))</h3>",
   (if ($reports | length) == 0 then empty_note("None.") else
     ("<ul class='space-y-2'>",
      ($reports | to_entries[] | .key as $i | .value |
        ("<li data-fm-item='\(itemkey("reports"; $i) | h)' class='rounded-box border border-base-content/10 bg-base-100 p-3 text-sm'>",
         "<p class='font-medium'>\(.id | h)</p>",
         "<p class='mt-1 text-xs'>\(link_or_text(.path))</p>",
         "</li>")),
      "</ul>") end),
   "</div>",
   "<div>",
   "<h3 class='mb-2 text-sm font-semibold uppercase tracking-wider opacity-60'>Recorded pull requests (\($recorded_prs | length))</h3>",
   (if ($recorded_prs | length) == 0 then empty_note("None.") else
     ("<ul class='space-y-2'>",
      ($recorded_prs | to_entries[] | .key as $i | .value |
        ("<li data-fm-item='\(itemkey("recorded_prs"; $i) | h)' class='rounded-box border border-base-content/10 bg-base-100 p-3 text-sm'>",
         "<p class='font-medium'>\(.id | h)</p>",
         "<p class='mt-1 text-xs'>\(link_or_text(.url))</p>",
         "</li>")),
      "</ul>") end),
   "</div>",
   "</div>",
   "</section>")
 end),

# --- omitted disclosure ---------------------------------------------------
"<section id='not-shown' aria-label='Not shown on this board'>",
section_head("Not Shown On This Board"; ($omitted | length); "bearings bounded or dropped these"),
(if ($omitted | length) == 0 then empty_note("Nothing was withheld: this board shows the complete projection.") else
  ("<ul class='space-y-2'>",
   ($omitted | to_entries[] | .key as $i | .value |
     ("<li data-fm-item='\(itemkey("omitted"; $i) | h)' class='rounded-box border border-warning/40 bg-warning/5 p-3'>",
      "<p class='text-sm font-medium'>\(.surface | h)</p>",
      "<p class='mt-1 text-xs opacity-60'>reveal with <code class='rounded bg-base-300 px-1'>\(.reveal | h)</code></p>",
      "</li>")),
   "</ul>")
 end),
"</section>",

"<footer class='border-t border-base-content/10 pt-6 text-xs opacity-50'>",
"<p>Rendered from \(.schema | h) by fm-fleet-board.sh. This board renders and collects; it never writes fleet state.</p>",
"</footer>",

"</main>",

"<script>",
"(function () {",
"  var root = document.documentElement;",
"  var toggle = document.getElementById('fm-theme-toggle');",
"  function label() { if (toggle) { toggle.textContent = root.getAttribute('data-theme') === 'business' ? 'Light' : 'Dark'; } }",
"  if (toggle) {",
"    toggle.addEventListener('click', function () {",
"      var next = root.getAttribute('data-theme') === 'business' ? 'corporate' : 'business';",
"      root.setAttribute('data-theme', next);",
"      try { localStorage.setItem('fm-board-theme', next); } catch (e) {}",
"      label();",
"    });",
"  }",
"  label();",
"",
"  // The review surface injects window.lavish into this frame on its own",
"  // schedule, which can be AFTER these inline scripts run. A load-time probe",
"  // therefore reports 'not live' on a board that is perfectly live by the time",
"  // the captain clicks, and disabling the controls on that probe silently makes",
"  // every decision unanswerable. So resolve the API at submit time instead, and",
"  // never let the probe disable a control.",
"  function lavishApi() {",
"    return (window.lavish && typeof window.lavish.queuePrompt === 'function') ? window.lavish : null;",
"  }",
"  function showOffline() {",
"    Array.prototype.forEach.call(document.querySelectorAll('[data-fm-offline]'), function (el) { el.hidden = false; });",
"  }",
"  // Deciding 'plain file' on a timer raised a false alarm inside the review",
"  // surface: the API had simply not been injected yet, so a board whose answers",
"  // sent perfectly well told the captain they could not be. The protocol is not",
"  // a race - file: IS a plain file - so warn on that, and otherwise let the",
"  // submit path below be the only other thing that reports a dead channel.",
"  try { if (window.location && window.location.protocol === 'file:') { showOffline(); } } catch (e) {}",
"",
"  function queue(form, intent) {",
"    if (!form) { return; }",
"    var box = form.querySelector('[name=\"answer\"]');",
"    var typed = box && box.value ? box.value.trim() : '';",
"    if (intent === 'answer' && !typed) { if (box) { box.focus(); } return; }",
"    var answer = intent === 'defer' ? 'DEFER - leave this decision open for now.' : typed;",
"    var id = form.getAttribute('data-decision-id');",
"    var key = form.getAttribute('data-decision-key');",
"    var owner = form.getAttribute('data-decision-owner');",
"    var summary = form.getAttribute('data-decision-summary');",
"    var prompt = [",
"      'FLEET BOARD DECISION',",
"      'decision_id: ' + id,",
"      'decision_key: ' + key,",
"      'owner: ' + owner,",
"      'question: ' + summary,",
"      'answer: ' + answer",
"    ].join('\\n');",
"    var api = lavishApi();",
"    var note = form.querySelector('[data-fm-queued]');",
"    if (!api) {",
"      showOffline();",
"      if (note) { note.textContent = 'Not connected to the review surface, so this answer was not sent.'; note.hidden = false; }",
"      return;",
"    }",
"    api.queuePrompt(prompt, {",
"      tag: 'fleet-decision',",
"      text: id + ' -> ' + answer,",
"      element: form,",
"      queueKey: 'fleet-decision:' + id,",
"      data: { question: 'fleet-decision', decision_id: id, decision_key: key, owner: owner, intent: intent, answer: answer }",
"    });",
"    if (note) { note.textContent = 'Queued: ' + answer + '  (press Send to Agent to deliver)'; note.hidden = false; }",
"  }",
"",
"  document.addEventListener('submit', function (ev) {",
"    var form = ev.target.closest ? ev.target.closest('[data-fm-decision-form]') : null;",
"    if (!form) { return; }",
"    ev.preventDefault();",
"    queue(form, 'answer');",
"  });",
"  document.addEventListener('click', function (ev) {",
"    var btn = ev.target.closest ? ev.target.closest('[data-fm-defer]') : null;",
"    if (!btn) { return; }",
"    ev.preventDefault();",
"    queue(btn.closest('[data-fm-decision-form]'), 'defer');",
"  });",
"})();",
"</script>",
"</body>",
"</html>"
] | flatten | join("\n")
JQPROG

TMP_OUT=$(mktemp "$OUT_DIR/.fleet-board.XXXXXX") || { echo "fm-fleet-board: cannot create a temp file in $OUT_DIR" >&2; exit 1; }
if ! printf '%s' "$MODEL" | jq -r "$RENDER" > "$TMP_OUT"; then
  rm -f "$TMP_OUT"
  echo "fm-fleet-board: rendering failed" >&2
  exit 1
fi
mv "$TMP_OUT" "$OUT" || { rm -f "$TMP_OUT"; echo "fm-fleet-board: cannot write $OUT" >&2; exit 1; }

OPEN_RC=0
if [ "$OPEN" = 1 ]; then
  if command -v lavish-axi >/dev/null 2>&1; then
    lavish-axi "$OUT" >&2 || OPEN_RC=$?
  else
    echo "fm-fleet-board: lavish-axi not found; the board was written but not opened" >&2
    OPEN_RC=1
  fi
fi

printf '%s\n' "$OUT"
exit "$OPEN_RC"
