# Today overnight QA — 2026-10-18

Verification is complete for the available automated scope. The frozen baseline was
`55e73d571f57987e5adc57d5d6b710bcec7a998a`; repaired journeys were then checked narrowly.
This report does not claim absolute bug freedom or a full-suite pass on one final revision.

## Results

| Check | Actual result | Retained evidence |
|---|---|---|
| Frozen baseline full simulator UI, once | 265 total: 245 passed, 18 failed, 2 skipped; xcodebuild exit 65; 9105.788 seconds | Complete readable coherent xcresult archive below |
| Unchanged representatives before repairs | 6 methods: 3 passed, 3 failed; 494.496 seconds total | `tests/results/runs/baseline-representatives-20261018/` |
| Final integrated package logic at `bd6053d` | 617 executed, 0 skipped, 0 failures; capture train 46/46, test 22/22 | `tests/results/runs/integrated-logic-20261018/`; package logic unchanged by the later UIKit fix |
| Integrated core acceptance at `00c2b2f` | 9 passed, 1 failed; 620.932 seconds total | `tests/results/runs/integrated-core-acceptance-20261018/`; only Week marker failed |
| Readiness/agenda acceptance at `270d20d` | 17 passed, 1 failed; 764.151 seconds total | `tests/results/runs/integrated-readiness-acceptance-20261018/`; only Week marker failed |
| Final Week fix at `c9b3973` | 6 passed, 0 failed; 165.012 seconds total | `tests/results/runs/week-hit-passthrough-acceptance-20261018/` |
| Runner and journal host contracts | 11 runner checks and 7 SQLite journal checks passed | PR #41/#52 reports and retained prepared evidence |
| Baseline file-store upgrade | Unique task retained; receipt table added; Habit/LedgerEntry retained; committed-state UI probe matched | `tests/results/runs/schema-upgrade/upgrade-proof.json`; permanent synthetic input in `tests/fixtures/migrations/` |

App, UI tests and ShareExtension compiled. The final UIKit change was compiled and exercised by the six-method batch;
no signing changes were made. The simulator runner recorded no journal errors and shut down after each completed batch.
The two final Week regressions open the exact Take medicine editor, while dense overlap, task drag,
empty-slot creation and event context menu remain working.

The [method coverage proof](../../tests/qa/evidence/ui-method-coverage-20261018.json) matches every current source method
against completed baseline/repair logs: **270 observed, 268 with latest passing evidence, 2 skipped,0 unobserved**.
This is evidence across revisions, not another integrated full run. The skipped methods are
`AlarmTests/testRingAsAlarmFires` (physical AlarmKit) and
`EntryActionsTests/testShakeOffersUndoAfterDelete` (unsupported XCTest shake synthesis).
All 18 original failed methods now have passing repair evidence; five newly added UI methods also ran.

The integrated 100k Activity benchmark ran on the Mac: 2.33 seconds insertion, 47 MB,
0.59 ms newest page, 1.55 ms deep page, 0.12 ms count and 29 ms search. These are not iPhone timings.

## Verified defects and fixes

| Issue | Behavior repaired | PR / acceptance |
|---|---|---|
| [#33](https://github.com/luworks/today/issues/33) | A new reminder answered an older event's time question | [#40](https://github.com/luworks/today/pull/40); logic red/green and new interruption UI passed |
| [#34](https://github.com/luworks/today/issues/34) | Old recurrence history exhausted expansion before the visible date | [#43](https://github.com/luworks/today/pull/43); calendar boundary regressions and integrated logic passed |
| [#35](https://github.com/luworks/today/issues/35) | Week/Month added a date to EventKit's exclusive all-day end | [#43](https://github.com/luworks/today/pull/43); production projection seam tested; live EventKit edge not exercised |
| [#36](https://github.com/luworks/today/issues/36) | Corrupt Share inbox was deleted/overwritten; failed submission dismissed as success | [#42](https://github.com/luworks/today/pull/42); file-backed red/green and submit/retry boundary tests; extension compiles |
| [#37](https://github.com/luworks/today/issues/37) | Midnight point alarm leaked into the preceding day | [#43](https://github.com/luworks/today/pull/43); half-open membership/DST tests passed |
| [#38](https://github.com/luworks/today/issues/38) | Share inbox was consumed before successful persistence | [#45](https://github.com/luworks/today/pull/45),[#46](https://github.com/luworks/today/pull/46); all 3 real file-backed SwiftData UI journeys passed |
| [#39](https://github.com/luworks/today/issues/39) | A 90-day Health comparison had insufficient previous-period history | [#44](https://github.com/luworks/today/pull/44); uneven 180-day data regression passed |
| [#47](https://github.com/luworks/today/issues/47) | Leading relative time hid the imperative in “30分钟后关烤箱” | [#48](https://github.com/luworks/today/pull/48); routing/dialogue logic and five-sentence capture UI passed |
| [#49](https://github.com/luworks/today/issues/49) | “Anything left today?” / “What's on today?” missed the read-only agenda route | [#50](https://github.com/luworks/today/pull/50); CRUD chat, MessageCopy and all 7 previously blocked Sidebar bodies passed |
| [#53](https://github.com/luworks/today/issues/53) | Empty-slot long-press layer interfered with late Week alarm taps | [#55](https://github.com/luworks/today/pull/55); source fix `c9b3973`, six targeted UI checks passed |

For issue #53, one diagnostic binary retained the failure when independently removing ViewThatFits, menus or offset
positioning; disabling only the empty-slot layer restored the same in-bounds tap. The final fix rejects occupied points
at UIKit touch selection using the existing current entry rectangles. Free-slot long presses remain enabled.
All temporary switches and unsuccessful candidates are absent from delivery source. One focused review found no findings.

The Share checks explicitly inject a pre-save error and acknowledgment failure; they do not prove spontaneous disk faults.
A persisted receipt prevents replay duplication and Undo resurrection. The schema is additive; Habit/LedgerEntry remain.
The actual Share extension failure/error/retry UI was not exercised; its durable-submit boundary was tested in logic.

## Reusable tests and durable evidence

The coverage matrix (`docs/qa/coverage-matrix.md`, deleted 2026-11-01; in git history) mapped journeys, tests and platform boundaries.
`ios/Eval/run-e2e.py --only Suite/Method` runs narrow journeys with one owned simulator, reused derived data,
command/result recording and final shutdown; `--full` is explicit. No second full UI run was performed.
Logic uses `swift test` from `ios/`, with jobs 2/shared mutex during parallel work.

[PR51](https://github.com/luworks/today/pull/51) made overlap/repeating inputs permanent;
[PR54](https://github.com/luworks/today/pull/54) retained the old-schema fixture, evidence and readiness repairs.
The new late-alarm fixture is also versioned. [The fixture catalog](../../tests/fixtures/README.md) identifies consumers,
relative dates and defaults. Package capture resources and small Swift generators remain versioned with their tests.

The QA Activity journal uses the app's exact v1 SQLite schema, independently of user data:
`/Users/yuanlu/code/one-app/tests/results/activity.sqlite`. PR #41/#52 delivered the serial runner and journal.
Commands, observed XCTest/manual actions, outcomes, issue/PR links and artifact hashes are queryable.
Historical import timestamps mean import time; original execution timing stays in raw logs.
This does not claim every historical agent tool call was recorded.

Runtime files remain in the primary checkout's Git-ignored `tests/results/`; fixtures, code and compact proof are versioned.
The full frozen run was archived only after completion and attachment export:
`tests/results/archives/overnight-20261018/4261dc27c25bac66b796ad22c5f716d22b4e1a02572d93b70857aed1facf4b05/`.
Its 1431 regular files/587406150 logical bytes include the complete xcresult, logs, 40 details/activity JSONs,
failed attachments and source snapshots. Per-file hashes were checked; xcresulttool reopened it with the same counts.
[The archive proof](../../tests/qa/evidence/full-ui-archive-20261018.json) records this. `/tmp` is secondary.
Other completed runs/reports are retained under `tests/results/runs/`; SQLite indexes paths/sizes/SHA-256.
Never copy an active bundle or delete this directory as build output. SQLite backups use its backup API.

## Limits and remaining acceptance

The baseline simulator suite exercised local EventKit Reminders sync/recurrence, native event editor/delete,
Safari Share success, Clock/Timer/Stopwatch, Health charts, Today, Tidy Apply/Undo and single-editor behavior.
A rendered audit inspected 38 available light/dark images; no verified defect was found in that subset.
A missing World Clock NOW allegation was rechecked against the exact image and withdrawn.

Simulator fallback does not verify Apple Intelligence generation, physical AlarmKit ringing/Focus/Silent,
phone HealthKit authorization/data/units/query speed, real account/invitation effects, system widgets,
Siri/Shortcuts, Lock Screen Live Activities or 100k-row phone performance. The live EventKit all-day edge and
Share extension failure UI remain unchecked. Apple/Overlap reference screenshots are unavailable.
The owner was asleep; no overnight phone interaction or real alarm ringing occurred.
The last installed/launched phone revision remains `55e73d5`, not these overnight changes.
