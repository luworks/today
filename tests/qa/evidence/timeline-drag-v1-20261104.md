# Today timeline drag V1 verification — 2026-11-04

Issue #310, PR #311. The owner approved the recurring Reminder split/advance exception; final exact-head CI is required before merge. Phone installation belongs to the coordinating root after both features merge.

## Observed interaction: Mock only

One owned named simulator, `Today-Dev-edd857cf` (`99B96F58-A888-4C17-93A3-207EB0F657F7`), reused its cache. All launches and interaction used the command returned by `device_open`; no owner phone or other simulator session was operated. Fixtures: `tests/fixtures/timeline-drag.json` and `timeline-drag-boundary.json`.

- Reminder changed from 11:50 to 12:10 and Undo restored 11:50; tapping the time handle opened the existing editor.
- Alarm changed from 14:00 to 14:15 and Undo restored 14:00.
- Local daily event changed from 12:00–12:30 to 12:25–12:55 and Undo restored its occurrence. Source-level persistence coverage separately verifies the next instance stays unchanged.
- A 45-minute event clamped at 23:15, ending at midnight; a point alarm clamped at 23:59. The viewed date stayed unchanged. Sideways cancellation left the source unchanged.
- The visible overlay showed original and target date/time, a regularly spaced ruler, lifted copy and original ghost. A parent gesture priority bug and List clipping were reproduced and repaired. Failed attempts remain retained.

Raw videos, screenshots, app logs and filmstrips are in the primary checkout at `tests/results/timeline-drag-v1/`, indexed by SHA-256 in `tests/results/activity.sqlite`, session `timeline-drag-v1`. Representative files: `mock-priority-preview.mp4`, `mock-recurring-preview.mp4`, `recurring-preview-filmstrip.png`, `mock-day-edge.mp4`, `mock-sideways-cancel.mp4`. Mock schedules are synthetic; these recordings do not prove live EventKit/AlarmKit writes, physical haptics, VoiceOver operation or Reduce Motion appearance.

## Native integration: real SwiftData, source service spies

Nineteen focused native cases passed across bounded batches. They cover Reminder move/Undo and failure, stale contexts, canonical Calendar projections, local occurrence persistence, one-off Alarm same-identity/settings restoration, expired original fire refusal, old-store migration, Calendar this-occurrence receipt/stale Undo, read-only failure, Reminder Activity Undo/source failure retry/later-change refusal, paused-Activity Alarm Undo, transient Calendar Undo retry and protected executing alarms. These tests use deterministic source adapters, not live Apple accounts.

Retained report directory IDs under `tests/results/devtools/logs/`: `d570cecf25de425c8a83a516b5c316bd-xcode` (initial Alarm failure retained), `22fc0e195e764e138c1287ff70a8d545-xcode` (Alarm fixes passed), `23f824c96a524161a48a75b111441913-xcode` (migration), `2722628042d543619bcd22305cefd326-xcode` (Calendar), `1bd8fef93f3b42b5b225c4021cd5e855-xcode` (five additional Undo/execution risks). The last batch also compiled the final UI overlay and gesture changes. Earlier compiler and failed-selection evidence remains intact.

`./dev format` and `git diff --check` passed. Regular logic/build verification belongs to CI; the exact final head must pass `checks` and `today-required` before merge. The regular gate does not execute UI journeys. No full UI suite, install-smoke, signing changes or phone installation was run here.

## Calendar mirror consistency follow-up

Verified source moves now update only matching retained mirror times (or one recurring exception), preserving the series anchor and alert settings. Native detached identifiers follow an occurrence across later drags. The same receipt restores the mirror after verified system Undo. A local retry after system restoration never replays the source Undo; it first reads the restored source again. Later local changes block the source write or Undo. Save failures restore only touched mirror fields and retain a retryable state. A forward mirror save failure attempts guarded system compensation and never produces a success toast.

Four additional native cases passed in `tests/results/devtools/logs/cde52a7101b24239a2073ce439982da4-xcode/TodayTests.report.json`: repeated moves of a detached recurring occurrence with exact alert restoration, interrupted Undo retry without another system write, mirror save failure/retry, and cross-context stale mirror rejection. The preceding `7ca7c88bc8154010be397c33fdf40327-xcode` report retains the initial stale-mirror test failure; the source was repaired without relaxing the assertion. Existing stale-source and transient-Undo cases also passed in that batch. Additional pure tests for source-window bounds and backward-compatible detached identifiers belong to CI.

## Approved repeating Reminder exception

The owner explicitly approved atomic split plus series advance and paired exact Undo. `ReminderOccurrenceMoveTests` adds eleven focused native cases: local and connected pair/Undo, source commit failure/retry, local save compensation, source Undo failure/retry, later child/link edits, vanished system child, local Undo save retry without replaying the source, failed compensation fencing, and native repeat-rule fidelity. All eleven passed in `tests/results/devtools/logs/59bc68cf57ad45c48fc215592ac95177-xcode/TodayTests.report.json`. The earlier `ec2b096a9c3f4d51a3000cf8a605c454-xcode` report retains the failed SwiftData deletion/reinsertion retry. The repair uses a separate local Undo context so save failure preserves both displayed identities and unrelated pending edits. Focused repair confirmation: `ef33b55439d04a4fb4db75dcfbc3b780-xcode`.

The compound receipt is session-scoped (toast/shake Undo), with the pair recorded in Activity; Activity does not offer a misleading single-field Undo after a restart. EventKit-visible metadata and the local checklist/settings are preserved. Rich native recurrence rules or date anchors that cannot be represented safely remain explicit editor-only cases. Native AlarmKit weekly single-ring exceptions remain unsupported with a specific explanation. No owner phone operation.

## Real EventKit Reminder observation and final validation

A bounded 811-second recording used **TodayMock shell + the real RemindersSync/EventKit adapter** on the same owned simulator, with `empty-relaunch.json`, `-uiTestingNow 09:41`, `-uiTestingRemindersSync`, and the existing `-uiTestingAppleOp addToday <unique QA title> daily` hook. No account, signing or physical-device setting was changed. The initial permission prompt was accepted only on this owned simulator.

The native daily Reminder at November 4 12:30 became one nonrepeating Reminder at November 4 18:00 and the **same original system identity** at November 5 12:30 with its daily rule intact. Undo removed exactly the new system identity and restored the original start/due, list identifier, note, priority and recurrence metadata. System, app and fresh local-context dumps matched at every stage. This UI composition's local store is in-memory; the separate native disk test below proves SQLite durability. All uniquely tagged native QA reminders were removed, and a broader QA-prefix source dump confirmed cleanup. No other source data was deleted.

Raw evidence in the primary `tests/results/timeline-drag-v1/`: `live-reminder-occurrence.mp4`, `live-reminder-retry-before.json`, `live-reminder-retry-moved.json`, `live-reminder-retry-restored.json`, `live-reminder-restored.png`, and `live-reminder-cleanup-all.json`. These are hash-indexed in the existing QA journal. Video is the complete 1320×2868 HEVC raw recording; the optional touch-overlay export exceeded its 70000ms budget. The first Undo click missed the six-second toast while evidence was inspected. A serial gesture → source dump → Undo sequence passed without changing product timeouts. A plain-ref navigation mismatch was recovered with fresh semantic selectors and inspected frames. Failed attempts and the raw expired-Undo diagnostic remain retained.

The additional regional-workweek native case passed in `60240b6421d247f09ccb63fd776ba199-xcode/TodayTests.report.json`. EventKit's explicit Monday–Friday pattern determines the next occurrence independently of regional weekend definitions. A fresh-disk-container split/Undo case passed in `948ad397718949139c7dc195cebf92f0-xcode/TodayTests.report.json`. Combined with the earlier batches, **32 unique focused native cases passed**; repeated executions are not counted twice. The final native build also compiled the manual-only preflight that rejects unrepresentable native repeat patterns without changing the existing explicit editor/AI write entry points.

No full UI suite or install-smoke ran. Real EventKit Reminder move/Undo was observed; Calendar/AlarmKit system-device behavior, physical haptics, actual VoiceOver operation and Reduce Motion appearance remain unverified here. Compound Reminder Undo is session-scoped; custom/finite native repeat rules and date-anchor changes that cannot be preserved remain explicit editor-only cases. Weekly AlarmKit single-ring exceptions remain an explained V1 limitation. Root owns final-main CI, signing and the combined owner-phone install.
