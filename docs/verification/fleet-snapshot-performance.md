# Fleet snapshot performance verification

Audience: maintainer verification.

This record supports two cost-shaped decisions that are otherwise invisible in the code: the blank-line fast path in `bin/fm-classify-lib.sh`, and the bounded concurrent task rows in `bin/fm-fleet-snapshot.sh`.
It records only the measurements those decisions rest on, so they can be re-established when bash, jq, or the fleet shape changes.
Task chronology and delivery evidence stay in private reports or PR evidence.

## Why the blank-line guard is a case glob

Verified 2026-08-02 on macOS 25.5.0 (arm64), stock `/bin/bash` 3.2.57(1)-release.

The whole-stream status fold runs one blank-line test per status line.
Written as a global pattern substitution, that single test dominates the entire fleet snapshot.

Measured against one real 3141-character status line, 20 iterations each:

```
x20 ${line//[[:space:]]/}           35.315s
x20 case-based emptiness             0.004s
x20 status_line_verb (subshell)      0.021s
x20 _fm_decision_key (subshell)      0.021s
x20 status_line_note (subshell)      0.027s
x20 _fm_decision_drop                0.035s
```

That is ~1.77s per 3KB line for the substitution form, against ~0.2ms for the `case` form, while every other construct in the fold costs microseconds.
The cost is superlinear in line length, so it is invisible on short status streams and severe on long ones.

`status_open_decisions` timings across one 12-task fleet, before the change:

```
sample-dompdf-ci.status                          8.486s  bytes=29791
sample-test-isolation-leak.status                2.788s  bytes=7400
web-research.status                              1.053s  bytes=7209
sample-pdf-image-regression-test.status          0.248s  bytes=4129
sample-phpstan-never-loaded.status               0.131s  bytes=2274
```

Total 12.9s of a 23.3s snapshot, from 85 status lines totalling 56KB.

The guard is a fast path only.
A whitespace-only line parses to an empty verb and already matches no arm of either fold, so removing the guard entirely leaves both `status_open_decisions` and `status_open_activities` byte-identical.
It is kept for cost, not semantics, and must not be rewritten as `${line//[[:space:]]/}`.

## Why task rows are gathered concurrently

Verified 2026-08-02 against a 12-task fleet with 2 registered secondmate homes, 18 cores.

A task row's cost is dominated by `bin/fm-crew-state.sh`, which shells out to the validation CLI and git.
One call spawns 43 `git` invocations plus `no-mistakes axi status` and `no-mistakes runs --limit 200`, so rows are IO-bound rather than CPU-bound and gain from overlap:

```
12 sequential fm-crew-state.sh calls   real 6.93s
12 concurrent  fm-crew-state.sh calls  real 1.55s
```

Phase attribution of `--json` before the change, same fleet:

```
backlog_json                0.06s
task_json_lines            20.86s
scout_reports + inventory   0.16s
secondmate aggregation      1.85s
```

Cross-home secondmate reads are not the driver: they are 1.85s of 23.3s, and capping them with `FM_SNAPSHOT_SECONDMATE_TIMEOUT=1` does not materially change the total.

`FM_SNAPSHOT_TASK_JOBS` sweep after both changes, best of two runs each:

```
JOBS=1   9.26s
JOBS=4   3.88s
JOBS=8   3.04s
JOBS=12  3.10s
JOBS=16  3.16s
JOBS=24  3.16s
```

The default of 8 sits at the plateau, so raising it buys nothing while widening the fork burst that each concurrent crew-state read produces.
Slots are refilled one at a time rather than in batches: a batch barrier idles every finished worker until the slowest row in its batch lands, which measured 4.59s at `JOBS=8` on the same fleet.

## Reader cost, before and after

Verified 2026-08-02, same fleet, best of three runs each, before and after measured back to back on an otherwise idle machine.

```
                                 before   after
bin/fm-fleet-snapshot.sh --json  23.60s   3.34s
bin/fm-fleet-view.sh             23.82s   3.60s
bin/fm-bearings-snapshot.sh      24.07s   3.69s
```

Both projections shell out to the snapshot, so they track it.

Cost now sits where it cannot be removed without changing what is reported: the slowest single crew-state read bounds the concurrent phase, and the registered secondmate aggregation remains sequential at roughly 0.75s.

## Scratch space is optional

Concurrency needs a scratch directory, which the snapshot did not previously require.
Taking that as a hard requirement would make this command fail where it used to work, and both `bin/fm-fleet-view.sh` and `bin/fm-bearings-snapshot.sh` depend on it reporting.
When the scratch directory cannot be created, rows are produced serially instead, which needs nothing beyond jq.
Verified 2026-08-02 by running the same fixture through a PATH containing every tool the snapshot uses except `mktemp`: exit 0, empty stderr, and output byte-identical to the same PATH with `mktemp` restored.
An earlier version of that PATH omitted `env` and `ps`, which the registered secondmate aggregation needs, so the nested-home subtree failed identically in both runs and that part of the byte comparison could not fail.
The fixture now provides both, and the test additionally asserts each run reads the registered home through the structured path (`provenance.selected` is `structured-home`) before comparing bytes, so a silently degraded subtree fails the control instead of matching the degraded no-scratch run.

## Output contract

The emitted bytes are unchanged.
Verified 2026-08-02 against the pre-change script on a hermetic fixture with the observation clock pinned and no normalization (88918 bytes `--json`, 7305 bytes `--secondmate-home-summary`, both diffs empty), and on the live 12-task fleet (268556 and 28627 bytes, both diffs empty) with a reference-versus-reference run in the same window confirming the fleet did not drift during the comparison.
`tests/fm-fleet-snapshot-view.test.sh` holds the durable guards: `test_concurrent_rows_match_serial_bytes` compares concurrency levels 2, 3, 8, and 16 against `FM_SNAPSHOT_TASK_JOBS=1` for both `--json` and `--secondmate-home-summary`, and `test_json_contract_shape_is_frozen` pins the ordered key-path shape against `tests/golden/fm-fleet-snapshot-shape.json`.
