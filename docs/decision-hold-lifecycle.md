# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records and keeps missing blockers unresolved.
Its `captain_held` predicate turns on the hold rather than the item's shape, so any live row carrying a captain hold qualifies whatever its state or kind, because most decisions arise mid-task rather than as a queued decision record.
`captain_actionable` narrows that set to the rows with no unresolved blocker and keeps its documented "actionable" meaning.
Its secondmate-home summary carries the whole live set as `captain_threads`, each row flagged actionable or blocked with what blocks it, and classifies a home with an actionable captain hold as `captain_decision`.
`captain_threads` survives the drop to the untrusted parent-event fallback whenever the home's own summary was readable, with its untruncated count and drop disclosure, because a captain hold is a backlog fact that does not depend on reconciling live child metadata.
A reader that must not undercount what awaits the captain therefore reads `captain_threads` rather than reassembling it from the other surfaces, and the script header owns the exact field semantics and bounds.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and blocked ones into gates.
For this home it reads the backlog directly, so a blocked hold whose own worker is still running appears only in the `in_flight` projection, where the held row is individually visible anyway.
For a registered secondmate it reads that home's `captain_threads`, so a hold still lands when the record dropped to the untrusted parent-event fallback and `decisions_open` came back empty; every blocked mate hold reaches gates, because a mate's held row is never an `in_flight` row of its own and would otherwise appear nowhere.
Both sections dedupe by id, since a readable home describes the same hold on two surfaces at once and a double count is no more trustworthy than an undercount.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

Bearings and the captain fleet board read the same live captain-owned set and then partition it differently on purpose, so their headline numbers are not meant to match.
Bearings splits it, actionable into Captain's Call and blocked into gates; the board keeps both in its needs-you column and marks the blocked ones unanswerable.
They also diverge under the snapshot's per-home bound on `captain_threads`: the board folds the holds it could not list into its headline needs-you total, while Bearings leaves its sections at what fitted and discloses the drop in `omitted`.
Neither is undercounting silently, which is the only property both surfaces owe the captain.
Each script's header owns its own column contract.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Unreconcilable-home captain-thread projection verification date: 2026-08-08.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - mixed secondmate roles, partial state, and captain readiness project independently
ok - main and secondmate captain actionability use the same blocker readiness

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh
all teardown safety cases passed

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)

$ for test_script in tests/*.test.sh; do bash "$test_script"; done
ALL 71 TEST SCRIPTS PASSED
```

The 2026-08-08 entry covers only the secondmate side of the Captain's Call partition.
All three fixtures were watched failing first: the troubled-home case reported an empty `decisions_open` and an empty `gates` against a snapshot already reporting one `captain_threads` row, the readable-home control was re-run with the id dedupe replaced by an identity so a genuine double count was observed being caught on both sections, and the capped-home case reported two decisions with no drop marker at all against a snapshot already reporting three of five holds omitted.
The cap fixture was then proven non-vacuous from both directions: dropping the "only when something was dropped" guard made the uncapped control fail on a spurious marker, and reporting the bounded array length as the total made the capped case fail on `3 of 2`.

```text
$ bash tests/fm-bearings-snapshot.test.sh
ok - a captain hold inside a troubled mate home still reaches Captain's Call
ok - a readable mate captain hold is counted exactly once in Captain's Call
ok - a mate home's snapshot-capped captain holds are disclosed in bearings omitted[]

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=65 local_links=217
```
