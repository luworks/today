# Permanent test inputs

These JSON inputs are versioned, read-only assets. UI tests resolve their names through
`TestData.fixturePath` / `TestData.fixtureArguments` in
[`UITestHelpers.swift`](../../ios/OneUITests/UITestHelpers.swift).
`TestData.path` and `TestData.launchArguments` continue to select the canonical
`today-dataset.json`; that dataset is unchanged.

The four images in [`design-refs/due-quick-add-20261030`](design-refs/due-quick-add-20261030/) are the owner's Due quick-add visual references, including its menus and alert sheet.

`PerformanceClimbTests.testTodayWeekResponse`, `testYearWeekResponse` and
`testRepeatedNavigationRetainsCalendarSelection` reuse this canonical dataset at
09:41 for matched navigation response samples; they create no temporary dataset.

| Dataset | Consumers and original generator |
| [`settle-day-boundary.json`](settle-day-boundary.json) | `TodayFocusStoreTests`: controlled Los Angeles midnight, spring-forward and fall-back dates; daily Settle expiry and unchanged absolute Snooze expiry. |
| --- | --- |
| [`populated-history.json`](populated-history.json), [`populated-unsent-draft.txt`](populated-unsent-draft.txt) | `PerformanceClimbTests.testPopulatedHistorySelectedDayNavigation` and `PopulatedHistoryTests`: 800 completed reminders + 200 past events over 90 days, 30 active reminders + 10 events today, two tomorrow anchors, and 100 mixed English/CJK messages. Real calendar selection, old-message position across panel Close/reopen, native multiline paste with exact unsent retention. No live sync or alarms. |
| [`today-density.json`](today-density.json) | `TodayDensityTests`: synthetic bilingual schedule modeled on the owner's density screenshot, two all-day events, timed rows, repeat/list/deadline metadata and multiple gaps. UI time 10:30, auto-scroll off, same viewport and font for before/after; accessibility text checks grow long titles. |
| [`today-reminder-completion.json`](today-reminder-completion.json) | `TodayReminderCompletionTests`: owner-reported Bring the water cup at 12:30, with notes and a due time. Tests namespace the title and seed the simulator EventKit store through `addToday`; no user reminder is used. |
| [`today-disclosure-sections.json`](today-disclosure-sections.json) | `TodayTomorrowTests`: one overdue reminder, current task, daily recurring meeting/alarm and next-day entries. Validates collapsed section order, overdue expansion and week-strip day navigation. |
| [`today-focus.json`](today-focus.json) | `TodayFocusTests`: local 10:00–11:00 meeting, 09:00 invoice, yesterday's overdue reminder and one untimed 60-minute task. Clock pinned to 09:00; four native journeys cover Settle/Restore, Snooze/Undo, source deadline/completion preservation, same-store relaunch and retained busy-time reservations. Relaunch consumes `empty-relaunch.json` without reseeding; no Apple sync, timers or alarms. |
| Snooze timing inline inputs | [`SnoozeSelectionTests.swift`](../../ios/Eval/Tests/OneLogicTests/SnoozeSelectionTests.swift) keeps synthetic absolute instants and a Los Angeles DST boundary beside the pure clock-at-submit regressions. The custom-picker/cancel journey in `TodayFocusTests` reuses `today-focus.json` at 09:00; no generated fixture. |
| Focus logic and integration inline inputs | [`TodayFocusStoreTests.swift`](../../ios/Eval/Tests/OneLogicTests/TodayFocusStoreTests.swift) versions tiny opaque identities, JSON failure inputs and absolute/DST instants beside the tests. [`TodayFocusIntegrationTests.swift`](../../ios/TodayIntegrationTests/TodayFocusIntegrationTests.swift) versions synthetic SwiftData/Activity models and read-only source identity/deletion spies; no private content or EventKit account is used. |
| [`reminder-compact-editor.json`](reminder-compact-editor.json) | `ReminderEditorTests`: reference 10:32 reminder, one deadline field, advanced draft cancellation and undated keyboard save. Production TaskEditor; clock 10:32. |
| [`reminder-time-save.json`](reminder-time-save.json) | `ReminderTimeSaveTests`: real 14:00 -> 13:10 DatePicker save, concurrent independent Apple note edit, native metadata/identity, reopen/refresh/relaunch. |
| [`today-alarm-actions.json`](today-alarm-actions.json) | `TodayAlarmActionsTests`: two independent repeating alarms and one unchanged reminder; native Today tap, long press, swipe, retry draft and persistent deletion. |
| [`calendar-compressed-gaps.json`](calendar-compressed-gaps.json) | Experimental 2 Day compressed-gap design fixture with morning and afternoon gaps. |
| [`today-dataset.json`](today-dataset.json) | Shared UI journeys using `TestData.launchArguments` / `TestData.path`, including `DevDataTests.testDatasetFillsChatsAlarmsAndReminders` and the ordinary `CalendarAlarmTests.launch(pinned:)` setup. This is the canonical multi-screen dataset, not a generated per-run input. |
| Same `today-dataset.json` | `PerformanceBaselineTests` and `tests/performance/launch_probe.py`: small feature-variety performance baseline (17 reminders, 13 events, 4 alarms, 3 lists, 7 chats), application clock pinned to 09:41. Not a large-history fixture. |
| Same `today-dataset.json` | `ChatPanelTests.testPopulatedFirstOpenAndReopenEvidence`: three fresh processes, native first-open draft typing and exact unsent draft retention after Close/reopen; app time 09:41. Layout traces and XCTest input durations are separate evidence. |
| [`calendar-empty-hours.json`](calendar-empty-hours.json) | `CalendarEmptyHoursTests`: sparse 2 Day schedule with timed events on opposite days, clock pinned to 09:00, to exercise an empty-hour gap expanding and collapsing. |
| [`year-day-month-agenda.json`](year-day-month-agenda.json) | `CalendarTabTests.testYearDayOpensMonthWithChosenDateAndItsItems`: an all-day event and a reminder on today and 400 days later. Verifies Year day taps select the exact date in Month and list only its items, including across years. |
| [`week-alarm-overlap-1.json`](week-alarm-overlap-1.json) | `CalendarAlarmTests.testWeekOverlappingEventAndAlarmHaveDisjointFramesAndOpenAlarmEditor` → `assertWeekOverlap(eventCount: 1)`. Replaces that helper's temporary JSON generator: event `Lane overlap event 0`, today at 09:00 for 60 minutes; `Lane overlap alarm` at 09:30. Clock pinned to 09:00; alarms pinned on. |
| [`week-alarm-overlap-8.json`](week-alarm-overlap-8.json) | `CalendarAlarmTests.testWeekDenseOverlapClusterStaysInsideAssignedFramesAndOpensAlarmEditor` → `assertWeekOverlap(eventCount: 8)`. Replaces the same generator with events `Lane overlap event 0` through `7`, all today at 09:00 for 60 minutes, and the same 09:30 alarm. Clock pinned to 09:00; alarms pinned on. |
| [`week-alarm-afternoon.json`](week-alarm-afternoon.json) | `CalendarAlarmTests.testWeekLateAlarmOpensItsEditorWithoutOtherEntries`. Minimal issue #53 reproduction: one Take medicine alarm at 13:00, no events/reminders/chats; clock pinned to 09:00 and alarms on. Distinguishes late-grid touch delivery from event density or task gestures. |
| [`repeating-reminder-daily-home.json`](repeating-reminder-daily-home.json) | `RepeatingReminderTests.setUp()` for `testCompletingARepeatingReminderMovesItToItsNextDay` and `testUndoBringsBackTheSameRowAtTheSameTime`. Replaces its temporary JSON generator: Home list (color 1), daily `Clean the drain filter`, due today at 07:00. Clock pinned to 09:41. |

## Hosted model comparison

`ai/luna-effort-20261029.json` freezes 16 capture and 8 edit cases sampled evenly from the historical r4 suites before calling GPT-6 Luna. `ios/Eval/open/eval_luna_effort.py` runs two repetitions at each of low, medium, high and xhigh. These are synthetic development cases, not a blind holdout or app UI coverage. Raw responses, usage and timings stay in the primary checkout QA results directory.

## Dates, defaults and isolation

Dates are relative: `day: 0` means the local start of the day the fixture loads,
`day: 1` tomorrow, and negative offsets earlier days. `time` is a local `HH:mm`
wall-clock time. `-uiTestingNow` pins the clock time used by these journeys; it
does not turn the relative day into a fixed calendar date. Chats use `hoursAgo`
relative to load time. The loader is [`TestDataset.swift`](../../ios/One/TestDataset.swift).

`-uiTesting -dataset <path>` loads into a fresh in-memory store with Apple Calendar
and Reminders sync off. Mutations affect that store, not the source JSON. Explicit
persistence/sync tests use their own launch hooks instead. Fixtures must never be
deleted in teardown or rewritten during a run, and generated input must not exist
solely in `/tmp`.

The small fixtures preserve the original generators' omitted fields and therefore
the loader defaults. For example, the daily reminder has a 25-minute duration,
empty note/tags/checklist and false flagged/done values by default; overlap alarms
are enabled, snoozable and have no repeating weekdays by default. No explicit
values were added to replace these defaults.

## Other permanent test data

- [`capture-cases.json`](../../ios/Eval/Tests/OneLogicTests/capture-cases.json)
  stays inside the Swift package at `ios/Eval/Tests/OneLogicTests/`. It is already
  versioned, declared as a copied resource in `ios/Package.swift`, and read through
  `Bundle.module` by `CaptureEvalTests`. Moving it here would change package resource
  behavior unnecessarily.
- [`CaptureTitleCleanupTests.swift`](../../ios/Eval/Tests/OneLogicTests/CaptureTitleCleanupTests.swift)
  keeps small Chinese/English title regressions inline: the exact 23:00 sleep
  reminder, dangling temporal connectors, request punctuation, conditions, negation
  and modality, plus model mapping with unchanged date/time/type/repeat fields.
- `NativeSnapshotTests.testUndoToastLongEnglishNarrow` and
  `testUndoToastChineseAccessibilityDark` keep their small synthetic English/Chinese
  toast captions inline beside the native 320pt render checks; no app data is used.
- Small constants and synthetic generators in Swift test files are already
  versioned test inputs. Keep them with their corresponding tests rather than
  duplicating thousands of literals in JSON.
- Activity hydration inputs stay inline in
  [`ActivityStoreTests.swift`](../../ios/Eval/Tests/OneLogicTests/ActivityStoreTests.swift):
  fresh-event defaults, every persisted field with lazy payloads, and a damaged
  nullable schema derived from all migrations while preserving partial indexes.
  [`ActivityReadPerformanceTests.swift`](../../ios/Eval/Tests/OneLogicTests/ActivityReadPerformanceTests.swift)
  owns the deterministic `activity-read-v1` 100000-row generator; opt in with
  `ACTIVITY_READ_BENCH=1 ACTIVITY_READ_SAMPLES=5`. Generated SQLite files are disposable outputs.
- Synthetic large-data configurations live in versioned test code. Examples:
  `ActivityDataTests.testActivityPagesWithShowMore` requests 400 Activity rows with
  `-uiTestingActivityRows`; `testOldLedgerRowsAreImportedOnceAndRetiredInALaterLaunch`
  requests 12 old ledger rows with `-uiTestingLegacyLedgerRows`.
  `ActivityStoreTests.testBenchmarkLarge` takes its row count from
  `ACTIVITY_BENCH_ROWS` (for example 100000). Keep the generator/configuration in
  test code and archive actual run arguments, environment overrides and results
  separately with the run evidence; do not check in 100000 generated rows.

The UI-test input inventory found only the two temporary JSON generators replaced
above. Screenshot writes are run outputs, not dataset inputs. QA/development action
recording and its SQLite storage are a separate concern from these fixtures.

## Pre-receipt SwiftData migration fixture

`migrations/today-55e73d5.store` is a standalone SQLite backup of a fresh synthetic
file store created by baseline `55e73d5`. Its adjacent JSON records the seed, hash
and expected contents. It contains one `Upgrade baseline 20261018` reminder,
Habit/LedgerEntry tables and no ShareImportReceipt table. It contains no user data.

To repeat the migration check, copy this fixture to a **new, named test store** in
the simulator app's temporary directory while the app is closed; never overwrite
a default/user store. Launch the current app with `-uiTesting -uiTestingStore <name>`.
Verify the original reminder remains and the additive receipt table is available.
For a committed-state accessibility probe also pass `-uiTestingShareInbox`,
`-uiTestingShareID <fresh UUID>` and `-uiTestingShareProbeTitle 'Upgrade baseline 20261018'`;
expect `acknowledged;tasks=1;receipts=0;pending=0`. Do not reseed the reminder.
The fixture is intentionally frozen; future schema changes should keep opening it.

## Bilingual semantic title and conversation evaluation

- [`ai-title-rewrite-cases.json`](ai-title-rewrite-cases.json): 38 authored cases,
  46 turns, 25 development / 13 reserved validation (not blind). Consumed by the
  offline [`TitleQuality/score.py`](../../ios/Eval/TitleQuality/score.py); this is
  an evaluation resource, not an app `TestDataset` JSON. Frozen clock, thread
  transitions, route/type/time, semantic facts, note retention and Add/Apply
  expectations are explained in the [rubric/interface](../../ios/Eval/TitleQuality/README.md).
- [`ai-title-rewrite-observed.json`](ai-title-rewrite-observed.json): sparse
  historical owner-screenshot transcription and attributed review. Unknown notes,
  gates and model path are intentionally omitted, not marked passing. The raw
  screenshot and scorer logs stay in canonical `tests/results/`, indexed by QA
  journal session `ai-title-quality-20261018`. This fixture is evidence for the
  scorer and baseline only, not a fresh app/model execution.
- `AskCardStaysTests` keeps three short capture title journeys inline: the owner's
  exact Chinese sleep request, a pending reminder title draft, and an Added alarm
  title Save/Cancel/reopen/creation-Undo journey. These inputs require no external
  dataset beyond the existing `today-dataset.json` used by the suite.

- `CaptureTitleQualityExportTests` consumes the frozen PR #67 fixture selected by
  `AI_TITLE_EVAL_FIXTURES`, exports actual parser/offline-refinement content to
  `AI_TITLE_EVAL_OUTPUT`, and uses only development watch/sleep/peanut cases.
  It does not feed expected answers to the implementation. UI gates and persisted
  writes remain unobserved; reserved cases and Foundation Models stay unmeasured.

## AI context journeys

`ChatRoutingTests.testMonthOnlyBookingRequestPreservesActionWithoutInventingAppointment`
keeps the exact owner input `明年8月 预约医生做 annual check` and its English contrast inline.
A fixed 2030 Los Angeles calendar verifies relative-year anchoring, a booking task,
month retention in title/notes, absent due/planned time, and preview-only follow-up.
Its companion test keeps completed reports, questions and creation refusals conversational.
`AIAnnualCheckTests` reuses `ai-context-ui.json` for native Add/Open/Undo and
follow-up checks; it supplies no scripted model response.

[`ai-context-ui.json`](ai-context-ui.json) is consumed by the three methods in
`AIContextJourneyTests`. Its planner starts empty, so Activity must contain no
change-ledger rows before Add. The text-only `Dinner alarm context` chat uses the
existing `[role, text]` format and has no stored preview or created item. Its
assistant aside names watering plants at 09:00; the relevant user request remains
the dinner alarm at 18:00. The journeys cover the exact Chinese three-turn report,
English alarm/date/time corrections, and New chat isolation plus stored-thread
resumption. They use `-uiTesting` and the simulator's production rule fallback;
they do not inject model output or verify Apple Intelligence. Chinese screenshots
are retained as XCTest attachments inside the eventual xcresult bundle.

- `ios/Eval/Tests/OneLogicTests/conversation-journeys.json` is a copied Swift package resource: thirteen bilingual multi-turn journeys with expected route, title, time/date, preview action and zero writes before Add/Apply. `ConversationJourneyTests` exercises the production context resolver, routing and parser; UI journeys additionally check the real confirmation gate.

## Recurring reminder goals

- `ai-title-rewrite-recurring-cases.json`: 16 cases / 19 turns in the existing
  TitleQuality observation/scoring format; 9 development / 7 reserved validation
  cases (reserved, not blind). Exact owner Sunday and Friday+Sunday requests are
  mandatory development inputs. Route, type, time, actual weekdays, title meaning,
  notes and Add/Apply are independent expectations. No observations are invented.
- `RecurringReminderTests` and `RepeatWeekdayTests` keep small pure inputs inline;
  the three observed-goal regression methods additionally read the unchanged
  development cases from `ai-title-rewrite-recurring-cases.json`;
  `RecurringReminderExportTests` reads the versioned fixture with
  `AI_RECURRING_EVAL_FIXTURES` and writes actual fallback artifacts to
  `AI_RECURRING_EVAL_OUTPUT`. Gates, writes and FM remain unmeasured there.
- `AIRecurringReminderTests` reuses `ai-context-ui.json` as an empty planner and
  keeps three short journey inputs inline: Chinese Sunday preview, Friday+Sunday
  Add/editor Save/reopen, English add-repeat/time-correction. These use production
  simulator fallback, not an injected model. XCTest attachments belong in the
  complete retained xcresult bundle.

## SwiftUI development previews

The small inline fixtures in `ios/One/PreviewFixtures.swift` (DEBUG only) seed
three reminder lists and three reminders in an in-memory SwiftData container.
`WorldClockStore.previewFixture()` in `ios/One/WorldClockView.swift` provides
London, Shanghai and Tokyo with Los Angeles as home in a separate store instance.
`HealthMetricDetail.swift`'s `Weight trend` preview reuses the versioned
`HealthSampleSeries.swift` algorithm and `PreviewFixtures.healthNow` fixed date.
The three corresponding `#Preview` declarations render production views.
No required input lives in a temporary directory; screenshots and timing outputs
belong in the persistent QA results directory, not this fixture catalog.

## Existing event save

`event-save.json` supplies one local timed daily event at 13:45 for 60 minutes
for `EventSaveTests`. Native tests reuse the existing simulator-only
`-debugCreateSystemEvent` hook with a unique title, then reopen after a fresh
in-memory launch to verify persistence. Inputs remain versioned here and inline
in that suite; EventKit writes affect only its named simulator calendar.

Event-save supplemental EventKit metadata is seeded by the versioned DEBUG hooks
`-uiTestingCalendarSaveMetadata` (notes, URL, two alerts) and
`-uiTestingCalendarSaveAllDay` (one current calendar day).
`EventSaveTests` owns these synthetic events and cleanup;
`-uiTestingEventSaveFailure` injects a local save error without user data.

## Actionable reminder recovery

- `ai-reminder-recovery-cases.json`: bilingual suffix-date reminders, exact owner
  mixed object names, one-off next Thursday vs weekly Thursday, full mistaken
  assistant histories, explicit clarification/proceed recovery, acknowledgments,
  ordinary/quoted/reported and unrelated-subject negatives. `ReminderRecoveryTests`
  executes production routing/context/parser and checks a ready date-only Capture.
- `ai-reminder-recovery-ui.json`: empty planner plus three text-only chats containing
  mistaken assistant asides. `AIReminderRecoveryTests` checks actual Add cards,
  exact date/title, no change-ledger writes before Add, persisted editor and Undo.
  Simulator fallback is exercised; no Foundation Models outputs are injected.

## Relative alarm and chat visibility (IMG6815)

- `ai-alarm-context-cases.json`: exact full three-turn Chinese screenshot sequence
  and English equivalent, including the mistaken assistant outputs and elapsed
  follow-up times. `AlarmContextTests` evaluates the production routing, parser,
  original-turn timestamps and truthful question path; no model output is injected.
- `ai-alarm-context-ui.json`: empty planner plus the entire mistaken screenshot
  conversation, first request ten minutes before fixture load. Legacy fixture
  messages have no per-turn timestamp; only the first user uses thread creation.
  `AIAlarmContextTests` checks initial preview, clarification, context question,
  Add/Undo, stored reopening and new-thread isolation on production simulator rules.
- Timestamp round-trip, unknown legacy time, assistant-role rejection, bounded
  model prompt versus full user reference recovery, midnight and spring DST cases
  are small inline inputs in `AlarmContextTests`.

- `empty-relaunch.json`: empty dataset for file-backed relaunch checks; preserves saved list order without reseeding.

`ios/Eval/Tests/OneLogicTests/CaptureEditRoutingTests.swift` keeps its small synthetic context inline: explicit existing-item move versus ordinary time-only recovery, with a fixed UTC clock and no store or model calls.

`ios/TodayIntegrationTests/PlannerSessionTests.swift` includes an inline synthetic local-event delete/Undo fixture and an external-ID refusal case; it never opens EventKit or writes a system calendar.

## CI source inventory and preflight fixtures

Small source/lock/configuration inputs, isolated Git repositories and generated
`.gitignore` FIFOs are defined inline in
`tests/devtools/test_native_provenance.py`; `tests/ci/test_native_execution.py`
provides the synthetic owned-device/build callback lifecycle.
`./dev test helpers` loads these existing authorities.
Temporary material is reconstructed from these versioned inputs; retained raw
logs and closed hosted artifacts belong in the primary QA results directory.
The same native provenance fixture covers compiler-module transport keys,
Swift-source edits that still rebuild products, lock/configuration/toolchain
partitioning, routine-only scope and primary-checkout paths for linked worktrees.

### Health dashboard

- `health-dashboard-ui.json`: deterministic launch scenarios consumed by `HealthMetricsTests`, including cross-category drag/relaunch, no-readable data and large type.
- `health-records.json`: synthetic category events, workout sessions, paired blood pressure and profile values mirrored by the small inline `MockHealthSource` payload. Production never selects this source. These fixtures do not prove live HealthKit authorization, device coverage or every possible record combination.
- `ios/Sources/TodayTestSupport/HealthSampleSeries.swift` (package-bound inline generator): seeded 180-day series for the entire numeric catalog; missing mindful values and stale body-fat readings are deliberate. `HealthCatalogTests` covers canonical units, daily sums versus averages, category codes, overlap union and calendar-day/DST splitting.

- `phone-freeze-navigation.json`: synthetic native Calendar/Reminders import titles and unsent Chat draft for `TodayReminderCompletionTests/testImportedTimelineNavigationAndCancelledEditorsStayResponsive`; production adapters on the owned simulator only.

- `ios/TodayIntegrationTests/TodayFocusIntegrationTests.swift` (small inline inputs): `savedCalendarSnoozeHydratesOutsideOriginalDayAndRejectsStaleImports` persists/reopens a synthetic cross-day Calendar Snooze and injects an exact scalar importer through the production CalendarSync boundary. It covers the shared display/Open snapshot lookup, invalidation, cancellation, permission loss, identity replacements and missing-source preservation. This does not mount DayAgenda or present Apple's editor.

- Same `TodayFocusIntegrationTests.swift` inline fixture: `populatedDayAgendaRenderUsesImportedSnapshotsWithoutNativeLookups` mounts production DayAgenda with connected production RemindersSync/CalendarSync, scalar imported rows and an injected range source. Isolated UserDefaults, in-memory SwiftData/Activity, synthetic permission closures and exact hydration avoid personal/system-store access. The real window PNG and local Vision OCR prove populated Reminder/Calendar and no extra history for an expired cross-day Snooze occurrence. Native store creation must remain zero; this is not live EventKit permission/import acceptance.

- `health-today-sync.json`: Steps A=1111 → B=2222 through one injected source; Health sheet → Today synchronization. Not HealthKit delivery evidence.
- `ios/TodayIntegrationTests/HealthSummaryIntegrationTests.swift` keeps small inline Steps histories (current values and an 80-day-old point) beside the native shared-state/generation tests; no external or private Health data is required.
- `tests/devtools/test_native_provenance.py` keeps paired inline Live/Mock app metadata and sentinel executable fixtures for installation selection/rejection; these synthetic host fixtures are not native build evidence.

## Submitted one-off reminders

`ios/Eval/Tests/OneLogicTests/OneOffReminderTests.swift` versions the small screenshot utterance/dialogue, absolute 2026-10-20 09:11 America/Los_Angeles clock, next-day, ordinary-chat/recurrence exclusions, failed-draft encoding and compensation inputs inline beside the tests. Synthetic identities are not EventKit evidence.

`ai-oneoff-reminder-ui.json` supplies the empty synthetic planner and exact legacy Costco conversation for the three `AIReminderRecoveryTests` journeys. The connected journey uses only the lane-owned simulator EventKit store; the failure journey explicitly injects one synthetic service failure.

## Search Calendar rendering

- `ios/TodayIntegrationTests/SearchCalendarIntegrationTests.swift` keeps one small synthetic Calendar occurrence, fixed UTC clock and mirror inline beside the mounted Search regression. Its production CalendarSync scalar range seam counts repeated reads and verifies rendered text, refresh, mirror deduplication and disable/re-enable without creating a native EventKit store.

QA retention's host-only synthetic cache/run inputs are small inline bytes and
JSON in `tests/qa/test_retention.py`, created in isolated temporary directories.
They are not reusable UI datasets; the production retention policy lives in
`tests/qa/retention.json` and is never taken from a temporary file.

`ask-reading-history.json` contains 36 synthetic long chat messages for `AskReadingPositionTests`. The Mock-only `-uiTestingAskReplyDelay` capability delays replies and capture parsing by twelve seconds so a real history pan can finish before a reply/card arrives. `AskInteractionTests` keeps short native text-input and injected Calendar read fixtures inline beside its tests.

`ChatPanelTests.swift` keeps its small unsent English/Chinese draft and Hello interaction inline. Long-history panel scrolling reuses `ask-reading-history.json`; failed creation and exact Undo/Open reuse `ai-oneoff-reminder-ui.json`. No private data is required.

`remove-returned-to-today.json` supplies synthetic old settled/restored events and a settled reminder,
new-day task/meeting and overdue reminder for
`TodayFocusTests.testCrossDayReleaseUsesOriginalDatesWithoutReturnHistory`.
The test pins local dates using ISO `-uiTestingNow`, which also supplies the Mock
dataset load clock, then relaunches its isolated persistent store on the next day.

## AI chat capability assessment

[`ai-chat-capability-eval.json`](ai-chat-capability-eval.json) defines 24
synthetic bilingual manual Live-app scenarios, with explicit expected outcomes
and a simulator-only setup. [`ai-chat-capability-protocol.md`](../../docs/qa/ai-chat-capability-protocol.md)
defines evidence, attribution and scoring; this authored set is development data,
not a blind holdout or a claim of model execution. It has no automated consumer.

Today button color tests keep small opaque RGB inputs inline in
`ios/Eval/Tests/OneLogicTests/TodayButtonColorTests.swift`; the simulator journey
`ios/OneUITests/TodayIdentityTests.swift` uses the built-in Blue preset and native
custom picker, without personal calendar data.

AI calendar creation retry fixtures are inline in `ios/TodayIntegrationTests/PlannerSessionTests.swift` (`aiCalendarAddFailureRetryRecoveryAndExactUndo`): synthetic Coffee event, chosen writable calendar, injected remote/local save failures and deletion outcomes. They contain no owner calendar data.

Calendar 2 Day DST coordinate cases are small inline ISO-8601 inputs in
`ios/Eval/Tests/OneLogicTests/CalendarDayAxisTests.swift`: Los Angeles rollback,
spring forward, ordinary days, repeated-hour spans and cross-midnight clipping.
They contain no personal planner data.
