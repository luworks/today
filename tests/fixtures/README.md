# Permanent test inputs

These JSON inputs are versioned, read-only assets. Load one in TodayMock with
`-uiTesting -dataset <path>`; `today-dataset.json` is the canonical dataset.
Test names in the table below are the removed UI tests that first used a dataset.

The four images in [`design-refs/due-quick-add-20261030`](design-refs/due-quick-add-20261030/) are the owner's Due quick-add visual references, including its menus and alert sheet.

| Dataset | Consumers and original generator |
| --- | --- |
| [`populated-history.json`](populated-history.json), [`populated-unsent-draft.txt`](populated-unsent-draft.txt) | `PerformanceClimbTests.testPopulatedHistorySelectedDayNavigation` and `PopulatedHistoryTests`: 800 completed reminders + 200 past events over 90 days, 30 active reminders + 10 events today, two tomorrow anchors, and 100 mixed English/CJK messages. Real calendar selection, old-message position across panel Close/reopen, native multiline paste with exact unsent retention. No live sync or alarms. |
| [`today-density.json`](today-density.json) | `TodayDensityTests`: synthetic bilingual schedule modeled on the owner's density screenshot, two all-day events, timed rows, repeat/list/deadline metadata and multiple gaps. UI time 10:30, auto-scroll off, same viewport and font for before/after; accessibility text checks grow long titles. |
| [`today-reminder-completion.json`](today-reminder-completion.json) | `TodayReminderCompletionTests`: owner-reported Bring the water cup at 12:30, with notes and a due time. Tests namespace the title and seed the simulator EventKit store through `addToday`; no user reminder is used. |
| [`today-disclosure-sections.json`](today-disclosure-sections.json) | `TodayTomorrowTests`: one overdue reminder, current task, daily recurring meeting/alarm and next-day entries. Validates collapsed section order, overdue expansion and week-strip day navigation. |
| [`settle-day-boundary.json`](settle-day-boundary.json) | `TodayFocusStoreTests`: controlled Los Angeles midnight, spring-forward and fall-back dates; daily Settle expiry. |
| [`today-focus.json`](today-focus.json) | `TodayFocusTests`: local 10:00–11:00 meeting, 09:00 invoice, yesterday's overdue reminder and one untimed 60-minute task. Clock pinned to 09:00; Settle/Unsettle/Undo, source deadline/completion preservation, same-store relaunch (consumes `empty-relaunch.json` without reseeding) and retained busy time. No Apple sync, timers or alarms. |
| [`remove-returned-to-today.json`](remove-returned-to-today.json) | `TodayFocusTests`: yesterday's overdue reminder, today's events and reminder, tomorrow's meeting and task at a fixed 2026-10-20 clock. Today-only Settle (the previous and next day offer none) and the next-day release without "returned" history. |
| Focus logic and integration inline inputs | [`TodayFocusStoreTests.swift`](../../ios/Eval/Tests/OneLogicTests/TodayFocusStoreTests.swift) and [`SettleGateTests.swift`](../../ios/Eval/Tests/OneLogicTests/SettleGateTests.swift) keep tiny opaque identities, JSON failure inputs and absolute/DST instants beside the tests. [`TodayFocusIntegrationTests.swift`](../../ios/TodayIntegrationTests/TodayFocusIntegrationTests.swift) uses synthetic SwiftData/Activity models and read-only source identity/deletion spies; no private content or EventKit account is used. |
| [`reminder-compact-editor.json`](reminder-compact-editor.json) | `ReminderEditorTests`: reference 10:32 reminder, one deadline field, advanced draft cancellation and undated keyboard save. Production TaskEditor; clock 10:32. |
| [`reminder-time-save.json`](reminder-time-save.json) | `ReminderTimeSaveTests`: real 14:00 -> 13:10 DatePicker save, concurrent independent Apple note edit, native metadata/identity, reopen/refresh/relaunch. |
| [`today-alarm-actions.json`](today-alarm-actions.json) | `TodayAlarmActionsTests`: two independent repeating alarms and one unchanged reminder; native Today tap, long press, swipe, retry draft and persistent deletion. |
| [`calendar-compressed-gaps.json`](calendar-compressed-gaps.json) | Experimental 2 Day compressed-gap design fixture with morning and afternoon gaps. |
| [`today-dataset.json`](today-dataset.json) | Canonical dataset; first used by `DevDataTests.testDatasetFillsChatsAlarmsAndReminders` and the ordinary `CalendarAlarmTests.launch(pinned:)` setup. This is the canonical multi-screen dataset, not a generated per-run input. |
| Same `today-dataset.json` | `PerformanceBaselineTests` and `tests/performance/launch_probe.py`: small feature-variety performance baseline (17 reminders, 13 events, 4 alarms, 3 lists, 7 chats), application clock pinned to 09:41. Not a large-history fixture. |
| Same `today-dataset.json` | `ChatPanelTests.testPopulatedFirstOpenAndReopenEvidence`: three fresh processes, native first-open draft typing and exact unsent draft retention after Close/reopen; app time 09:41. Layout traces and XCTest input durations are separate evidence. |
| [`calendar-empty-hours.json`](calendar-empty-hours.json) | `CalendarEmptyHoursTests`: sparse 2 Day schedule with timed events on opposite days, clock pinned to 09:00, to exercise an empty-hour gap expanding and collapsing. |
| [`year-day-month-agenda.json`](year-day-month-agenda.json) | `CalendarTabTests.testYearDayOpensMonthWithChosenDateAndItsItems`: an all-day event and a reminder on today and 400 days later. Verifies Year day taps select the exact date in Month and list only its items, including across years. |
| [`week-alarm-overlap-1.json`](week-alarm-overlap-1.json) | `CalendarAlarmTests.testWeekOverlappingEventAndAlarmHaveDisjointFramesAndOpenAlarmEditor` → `assertWeekOverlap(eventCount: 1)`. Replaces that helper's temporary JSON generator: event `Lane overlap event 0`, today at 09:00 for 60 minutes; `Lane overlap alarm` at 09:30. Clock pinned to 09:00; alarms pinned on. |
| [`week-alarm-overlap-8.json`](week-alarm-overlap-8.json) | `CalendarAlarmTests.testWeekDenseOverlapClusterStaysInsideAssignedFramesAndOpensAlarmEditor` → `assertWeekOverlap(eventCount: 8)`. Replaces the same generator with events `Lane overlap event 0` through `7`, all today at 09:00 for 60 minutes, and the same 09:30 alarm. Clock pinned to 09:00; alarms pinned on. |
| [`week-alarm-afternoon.json`](week-alarm-afternoon.json) | `CalendarAlarmTests.testWeekLateAlarmOpensItsEditorWithoutOtherEntries`. Minimal issue #53 reproduction: one Take medicine alarm at 13:00, no events/reminders/chats; clock pinned to 09:00 and alarms on. Distinguishes late-grid touch delivery from event density or task gestures. |
| [`repeating-reminder-daily-home.json`](repeating-reminder-daily-home.json) | `RepeatingReminderTests.setUp()` for `testCompletingARepeatingReminderMovesItToItsNextDay` and `testUndoBringsBackTheSameRowAtTheSameTime`. Replaces its temporary JSON generator: Home list (color 1), daily `Clean the drain filter`, due today at 07:00. Clock pinned to 09:41. |

## Dates, defaults and isolation

Dates are relative: `day: 0` means the local start of the day the fixture loads,
`day: 1` tomorrow, and negative offsets earlier days. `time` is a local `HH:mm`
wall-clock time. `-uiTestingNow` pins the clock time used by these journeys; it
does not turn the relative day into a fixed calendar date. Chats use `hoursAgo`
relative to load time. The loader is [`TestDataset.swift`](../../ios/Development/Support/TestDataset.swift).

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
  `-uiTestingActivityRows`.
  `ActivityStoreTests.testBenchmarkLarge` takes its row count from
  `ACTIVITY_BENCH_ROWS` (for example 100000). Keep the generator/configuration in
  test code and archive actual run arguments, environment overrides and results
  separately with the run evidence; do not check in 100000 generated rows.

The UI-test input inventory found only the two temporary JSON generators replaced
above. Screenshot writes are run outputs, not dataset inputs. QA/development action
recording and its SQLite storage are a separate concern from these fixtures.

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
resumption. They use `-uiTesting`, which is not signed in to Luna AI, so FastLane's
local previews answer; they inject no model output. Chinese screenshots
are retained as XCTest attachments inside the eventual xcresult bundle.

## Recurring reminder goals

- `ai-title-rewrite-recurring-cases.json`: 16 cases / 19 turns (observation/scoring
  format); 9 development / 7 reserved validation
  cases (reserved, not blind). Exact owner Sunday and Friday+Sunday requests are
  mandatory development inputs. Route, type, time, actual weekdays, title meaning,
  notes and Add/Apply are independent expectations. No observations are invented.
- `RecurringReminderTests` and `RepeatWeekdayTests` keep small pure inputs inline;
  the three observed-goal regression methods additionally read the unchanged
  development cases from `ai-title-rewrite-recurring-cases.json`.
- `AIRecurringReminderTests` reuses `ai-context-ui.json` as an empty planner and
  keeps three short journey inputs inline: Chinese Sunday preview, Friday+Sunday
  Add/editor Save/reopen, English add-repeat/time-correction. These use production
  simulator fallback, not an injected model. XCTest attachments belong in the
  complete retained xcresult bundle.

## SwiftUI development previews

The small inline fixtures in `ios/Development/Support/PreviewFixtures.swift` (DEBUG only) seed
three reminder lists and three reminders in an in-memory SwiftData container.
`WorldClockStore.previewFixture()` in `ios/Sources/Features/FeatureClock/WorldClockView.swift` provides
London, Shanghai and Tokyo with Los Angeles as home in a separate store instance.
`HealthMetricDetail.swift`'s `Weight trend` preview reuses the versioned
`HealthSampleSeries.swift` algorithm and `PreviewFixtures.healthNow` fixed date.
The three corresponding `#Preview` declarations render production views.
No required input lives in a temporary directory; screenshots and timing outputs
belong in the persistent QA results directory, not this fixture catalog.

## Existing event save

`event-save.json` supplies one local timed daily event at 13:45 for 60 minutes
for `EventSaveTests` (the local editor's unchanged Done, and Ask moving an
all-day Apple event). Apple events are made by the simulator-only
`-debugCreateSystemEvent` hook with a unique title; `-uiTestingCalendarSaveAllDay`
makes it one current calendar day. EventKit writes affect only the named
simulator calendar, and the suite deletes what it made.

## Actionable reminder recovery

- `ai-reminder-recovery-cases.json`: bilingual suffix-date reminders, exact owner
  mixed object names, one-off next Thursday vs weekly Thursday, full mistaken
  assistant histories, explicit clarification/proceed recovery, acknowledgments,
  ordinary/quoted/reported and unrelated-subject negatives. `ReminderRecoveryTests`
  executes production routing/context/parser and checks a ready date-only Capture.

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

- `ios/TodayIntegrationTests/PlannerSourceIntegrationTests.swift` (small inline inputs): `populatedDayAgendaRenderNeverOpensTheNativeStore` mounts production DayAgenda with connected production RemindersSync/CalendarSync, scalar imported rows and an injected range source. Isolated UserDefaults, in-memory SwiftData/Activity, synthetic permission closures and exact hydration avoid personal/system-store access. The real window PNG and local Vision OCR prove populated Reminder/Calendar rows. Native store creation must remain zero; this is not live EventKit permission/import acceptance.

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

`ios/Eval/Tests/OneLogicTests/AskRouterTests.swift` keeps the migrated Ask sentence matrix,
English dinner alarm corrections and annual-booking rename inline with a fixed 2026-11-01
09:00 UTC clock. These exercise production AskRouter and FastLane continuation/refinement;
UI persistence, navigation, accessibility and Undo still use the existing Ask/AI fixtures.

| [`timeline-drag.json`](timeline-drag.json) | Same-day adjustment observation: off-grid Reminder, local one-off/repeating event, one-off/repeating Alarm with explicit synthetic system IDs. TodayMock only; no real source access. |

| [`timeline-drag-boundary.json`](timeline-drag-boundary.json) | Same-day upper bounds: 45-minute event and a point alarm at 23:00, explicit synthetic alarm ID. TodayMock observation checks duration-preserving 23:15 event limit and 23:59 point limit, without crossing days. |

## Quiet Inbox experiment

The standalone classifier keeps its 60 author-written synthetic training examples
in `experiments/quiet-inbox/Core/Sources/QuietInboxCore/Resources/synthetic-training.json`,
versioned as a Swift package resource. Small bilingual regression messages remain
inline in `experiments/quiet-inbox/Core/Tests/QuietInboxCoreTests/FilterEngineTests.swift`.
These inputs verify the prototype behavior and do not measure real-world accuracy.

`today-dense-scroll.json`: 36 fictional timed rows (12 each in Morning, Afternoon and Evening, alternating event/reminder/repeating alarm). Device-panel regression for scrolling, Delete, Settle, completion and Undo; launch TodayMock with `-uiTesting -uiTestingNow 09:41 -dataset <absolute-path>`.
