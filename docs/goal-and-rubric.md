# Today — goal, eval and hill-climbing plan

*(Formerly "one.". Renamed in October 2026; bundle id `com.luworks.one` and the Xcode target names are unchanged. Log rows before round 19 use the old name.)*

## Goal

A minimal, AI-native planner for iPhone that puts calendar, reminders and alarms in one app, so people need fewer apps.

- **Data:** local. Apple Calendar and Apple Reminders are the source of truth, read and written live through EventKit. Alarms use AlarmKit. (Status, October 2026: Apple Calendar events are read and written through EventKit, and reminders and lists sync both ways with Apple Reminders through EventKit (`RemindersSync`; Apple wins on conflict). The app keeps a local SwiftData copy. Reminders have one date, the deadline; the separate planned time was retired in October 2026.)
- **Roadmap (Yuan's words):** first **aggregate** (calendar + reminders + alarms in one place, with a very good Today tab that keeps people focused on now), then **optimize**, then **surpass**. Gestures and screens match Apple Calendar / Reminders as closely as possible before we improve on them.
- **Information architecture (4 tabs):** Today · Calendar · Reminders · Clock. No habits. Calendar is 2 Day (default; two days on a time grid, one day per swipe), Month and Year (Year day taps open Month with that date selected and its agenda below; 2 Day headers and selected Month day taps open Today). Alarms lists real alarms (AlarmKit) plus items marked "Ring as alarm", with a kitchen timer on top. The bottom-right button is a **+** that opens the same menu on every page: New alarm / New reminder / New event (built). Top left is a menu button that opens the sidebar: Search, AI chat history, New chat, Settings.
- **Gestures follow Apple:** tap the circle to complete; swipe left for Delete (with Undo) and Flag, with one shared look for swipe actions in every list; long-press menu (Show Details / Flag / Today / Tomorrow / Delete); system events open in Apple's own event viewer. Events are never moved by drag; only flexible tasks move.
- **Next phase after aggregation (optimize):** an AI agent turns what the user types into reminders, events and alarms, edits existing items and tidies overdue reminders, always as a preview the user confirms. A rules-only fast lane (`FastLane`) handles the clear cases on the phone; everything else goes to one agent loop on the hosted Luna model with typed tools whose writes are only proposals (`docs/engineering/ai-agent-architecture.md`). Capture, edit and Tidy overdue are built (P4, November 2026).
- **Style:** Notion / Linear / ChatGPT mobile. Calm, dense, monochrome with one accent, system semantic colors, Dynamic Type.
- **Coverage:** what people use Apple Calendar, Apple Reminders and Clock for, without their complexity.
- **AI-native:** one typed or spoken line is the fastest way to do anything. AI prepares, the user decides: every AI change is a preview the user confirms (product principles in `CLAUDE.md`).

Vocabulary: the product says "reminder"; the code and older claims say "task" (`OneTask`). They are the same thing.

Target: **10/10 on every dimension.**

## How we measure (eval design)

Method adapted from Anthropic's posts on [eval design and hill-climbing](https://claude.dev/blog/automating-eval-design-and-hillclimbing/) and [making claude.ai faster](https://claude.dev/blog/how-we-made-claude-ai-faster/):

1. **Score checkable claims, not vibes.** Each dimension is 10 yes/no claims. Score = number of claims that pass. A claim passes only when it is demonstrated in the running app (simulator screenshot or test), not when the code "should" work.
2. **Cheapest grader that fits.**
   - *Programmatic* where possible: unit tests for logic (parser, repeat rules, scheduling), an NL-capture eval with expected outputs, and UI tests for core journeys.
   - *Judge with a checklist* for design: screenshots of every screen in light, dark and the largest Dynamic Type size, checked against the design claims below.
3. **Claims mirror real use.** They come from what people actually do in Apple Calendar, Reminders, Clock, OmniFocus and Due, plus Yuan's feedback. No claim is added just because it's easy to pass.
4. **Hold-out set for the AI parser.** NL-capture cases are split into `train` (failures may be read while fixing) and `test` (never read while fixing). A parser change is kept only if both go up.
5. **Core journeys and tap counts** (from the "faster" post: pick the few journeys that cover most use, measure them, ratchet):
   - J1 Add a reminder with a time from one line
   - J2 See what's left today
   - J3 Complete a reminder
   - J4 Add an event
   - J5 Add a reminder to a list: 3 taps (Reminders tab → list → New Reminder row) plus typing; measured in round 21, budget 3
   - J6 Get reminded at the right time and act from the notification (or add an alarm)
   - J7 Find something
   Each journey records taps from the home screen; the budget can only go down.

## Hill-climbing loop

Each round:

1. Run the eval (build, simulator walkthrough of J1–J7, screenshots, tests) and fill the claim checklist.
2. Pick the **weakest dimension**, read its failing claims, and find the root cause.
3. Make **one focused change** aimed at that root cause (not per-case hacks).
4. Re-run. **Keep** if the target dimension goes up and nothing else goes down; otherwise **revert**. For the parser: keep only if train and test both improve.
5. Ratchet: a passing claim, test or tap budget may never regress afterwards.
6. Log the round below and push to PR #1.
7. If the score stalls for 2–3 rounds, stop and audit the eval itself (ambiguous claim, broken test, wrong grader) before changing the app again.

Humans set direction: Yuan decides product questions (what a claim should mean, priorities between dimensions). Claude asks only then.

## Claim checklists (10 per dimension)

### 1. Calendar (benchmark: Apple Calendar)
1. Day timeline with a "now" line
2. Day picker / week strip
3. Multi-day view (2 Day time grid)
4. Month view
5. Create an event
6. Edit an event
7. Delete an event
8. All-day and multi-day events
9. Recurring events
10. Reads and writes the system calendar (EventKit)

### 2. Tasks (benchmark: Reminders, OmniFocus)
1. Create a task from one line
2. Edit title, notes, deadline
3. Complete and un-complete, with undo
4. One date per reminder, its deadline, like Apple Reminders (the separate planned time was retired in October 2026)
5. Inbox of unscheduled tasks
6. Lists / projects
7. Tags
8. Repeating tasks
9. Subtasks / checklist
10. Flag or priority

### 3. Alarms & reminders (benchmark: Clock, Apple Reminders alerts)
Re-scoped in round 19: the Alarms page lists real alarms only; reminders live on the Reminders tab. Claims 1, 4 and 8 changed (marked below); claim 9 is unchanged.
1. The Alarms page lists real alarms (time, label, repeat) plus items marked "Ring as alarm" *(rewritten; was "upcoming timed items listed in one place")*
2. Local notification fires at the task/event time
3. Notification actions: Done and Snooze
4. An alarm repeats on its chosen weekdays and skips the other days *(replaces the retired "Due-style nag: repeats until done"; the nag is dropped from the product direction; its code still exists but it is no longer a claim)*
5. Snooze presets (5 min, 1 h, tomorrow)
6. Per-item reminder offset (e.g. 10 min before)
7. Alarms that ring through Silent (AlarmKit)
8. Create, edit, delete and switch an alarm on/off from its row *(rewritten; was "turn a reminder on/off from the list" via per-item bell toggles, which are retired)*
9. App badge shows overdue count
10. Clear permission prompt with a reason, and a recovery path if denied

### 4. Reminders parity (benchmark: Apple Reminders)
Replaces "Habits (benchmark: Streaks)", retired in round 19: habits were removed from the product (no tab, chips or streaks; the `Habit` SwiftData model stays in the schema, unused, so existing installs migrate without data loss).

Status after round 21 (full UI suite run in the iOS simulator, see the log). "Demonstrated" = seen working on screen or covered by a UI test. "Built" = in the code, not yet demonstrated, so it does not count in a score yet.

1. Smart lists Today, Scheduled, All, Flagged and Completed, each with a live count. **Demonstrated** (screenshot: 16 / 71 / 78 / 0 / 201 on real imported data)
2. My Lists, each with a color and an icon. **Demonstrated** (screenshot; lists from Apple get the nearest palette color; the icon is Today-only because EventKit has no list icon)
3. Create, rename and delete a list. **Demonstrated** (`CRUDTests.testListCreateRenameDelete`, `RemindersListsTests.testAddListIsVisibleAndCreatesAList` and `testLongPressDragReordersLists` pass; lists can also be pinned)
4. New reminder with date and time, notes, flag and repeat. **Partly demonstrated** (`CRUDTests.testReminderCreateEditFlagCompleteDeleteUndo`, `testReminderQuickAddWithPlus`, J1 and J5 pass; `InlineNewReminderTests` fails reaching the inline row's date menu, which may sit behind the keyboard; not yet diagnosed)
5. Swipe left on a row shows Delete (full swipe, with Undo toast) and Flag. **Demonstrated** (`RowActions.swift`, one look in every list; `CRUDTests.testReminderSwipeFlagShowsInFlagged` and `testReminderCreateEditFlagCompleteDeleteUndo` pass)
6. Long-press menu: Show Details, Flag, Today, Tomorrow, Delete. **Built** (`Rows.swift`; it also has Unschedule; events get the same menu, `EntryActionsTests`)
7. Completed section, collapsed by default, with a count. **Built** (list screen: "N Completed · Show")
8. Search reminders by title. **Demonstrated** (`SearchView`, UI test J7)
9. Reads and writes real Apple Reminders (EventKit, live, two-way). **Demonstrated** (`RemindersSyncTests` round trip; `RemindersSyncBothWaysTests`: complete, rename, delete and repeat from the app reach Apple, complete, rename and delete in Apple reach the app, and completing a repeating reminder on either side rolls the same Apple reminder forward with one open copy left; a refused Apple delete is retried, not dropped). Not covered: many lists at scale
10. List order and colors match Apple Reminders. **Built** (colors map to the nearest of 12 palette colors; Apple's own order is not exposed by EventKit, so lists are ordered by creation)

Round 20 count: 4 demonstrated (1, 2, 8, 9), 6 built (3, 4, 5, 6, 7, 10).
Round 21 count: 6 demonstrated (1, 2, 3, 5, 8, 9), 1 partly (4), 3 built (6, 7, 10). Reminders parity scores 6/10.

### 5. AI (benchmark: ChatGPT, Todoist natural language)
1. Understands day words (today, tomorrow, 明天…)
2. Understands times (3pm, 15:00, 下午3点)
3. Preview card; nothing is created without a tap
4. English and Chinese input
5. Weekdays and dates ("Friday", "Oct 20")
6. Repeat ("every day", "weekly")
7. Decides reminder vs. event (habit detection retired in round 19)
8. Answers questions about your day
9. Suggests a plan for the day (preview, user applies)
10. Voice input

Since P4 (2026-11-01) the AI page is the on-phone agent (`docs/engineering/ai-agent-architecture.md`): `FastLane` rules first (local, offline), then the agent with typed tools; every write is a card the user confirms. Its evaluation is the P3 blind set (§4.3 targets), not the retired NL-capture rounds.

### 6. Visual design (benchmark: Notion, Linear) — judged on screenshots
1. One accent color; everything else semantic system colors
2. Dark mode looks right on every screen
3. Largest Dynamic Type: no truncation or overlap on Today and Reminders
4. Consistent 20 pt horizontal margins and row rhythm
5. Every list has a designed empty state
6. No duplicated or redundant labels
7. App icon
8. Top pills and bottom bar match the reference spec
9. Editors and sheets feel native and uncluttered
10. Typography scale is consistent (one title, one body, one caption style)

### 7. Interaction (benchmark: Linear)
1. Tap the circle to complete, as in Apple Reminders *(was "swipe to complete")*
2. Swipe left for Delete and Flag *(was "swipe to defer"; the leading swipe and +30 min are gone)*
3. Long-press menu on every item
4. Haptics on key actions
5. Undo after complete / delete
6. Add a timed task in ≤ 3 taps plus typing (J1)
7. Sidebar like ChatGPT/Claude: swipe right from the left edge (or tap the menu button) slides the page over to a drawer
8. Drag to reschedule on the timeline
9. Home Screen quick actions or widget
10. No dead ends: every sheet closes, every tab can return to today

### 8. Reliability
1. Builds with no warnings in app code
2. Data persists across relaunch
3. Unit tests for the capture parser
4. Unit tests for repeat rules, recurrence and scheduling
5. UI tests for core journeys
6. No crash walking J1–J7
7. Schema changes migrate without data loss
8. One command runs all tests
9. Cold start measured and under budget
10. Eval runner prints the scores

**Overall** = average of the 8 dimensions (dimension 4 is now Reminders parity). Done when every dimension is ≥ 9 and J1–J7 meet their tap budgets.

## Scoring log

| Round | Cal | Tasks | Alarms | Habits (to r18), Reminders (from r19) | AI | Design | Interact | Reliab | Avg | Change |
|-------|-----|-------|--------|--------|----|--------|----------|--------|-----|--------|
| 0 | 3 | 3 | 1 | 0 | 4 | 5 | 5 | 2 | 2.9 | Notion-style shell (1609475) |
| 1 | 5 | 4 | 1 | 5 | 5 | 6 | 6 | 3 | 4.4 | English UI, habits, task/event editors (0d78750) |
| 2 | 5 | 4 | 1 | 5 | 5 | 6 | 6 | 6 | 4.8 | Eval harness: `ios/Eval/run-eval.sh`, logic unit tests, NL-capture eval. Capture train 6/15, test 5/14 |
| 3 | 5 | 4 | 6 | 5 | 5 | 6 | 6 | 6 | 5.4 | Reminders: local notifications (verified firing in simulator), Due-style nags, Done/Snooze/Tomorrow actions, per-item offset, bell toggle, badge, permission card. Actions not yet demonstrated, so claims 3–5 not counted |
| 4 | 5 | 4 | 6 | 5 | 5 | 8 | 7 | 6 | 5.75 | Sidebar (Yuan's ask), app icon "one." (C) and brand orange accent |
| 5 | 5 | 9 | 6 | 5 | 5 | 8 | 7 | 7 | 6.5 | Tasks: lists, tags, flag, repeat (next occurrence on complete, verified), checklist, filter chips, undo toast. Undo not yet demonstrated end-to-end (tool latency), so Tasks 3 / Interaction 5 not counted. RepeatRule unit tests |
| 6 | 9 | 9 | 6 | 5 | 5 | 8 | 7 | 7 | 7.0 | Calendar: Day / Week (time grid) / Month views, all-day and multi-day events, repeating events (occurrences expanded everywhere), event editor with all-day/repeat. Recurrence unit tests. EventKit still missing |
| 7 | 9 | 9 | 6 | 5 | 8 | 8 | 7 | 7 | 7.4 | AI parser rewrite (prepositions, weekdays, dates, repeat, noon, bare hours, time ranges) and task/event/habit detection with a switch on the preview card. NL eval v1: train 6→15/15, test 5→14/14. v2 cases (kind, duration) written before the code: train 24/24, test 22/22. Eval now saturated: next cases should come from Yuan's real inputs |
| 8 | 9 | 9 | 6 | 9 | 8 | 8 | 7 | 7 | 7.9 | Habits: editor (name, 20 icons, weekly target, reminder time), 5-week history, current/best streak, "x/3 this week" for weekly goals, habit chips on Today, habit reminders with Check in action. weekCount/bestStreak tests |
| 9 | 9 | 10 | 6 | 9 | 8 | 8 | 8 | 9 | 8.4 | XCUITest journeys J1–J7 + sidebar, all 8 pass on a fresh in-memory store (`run-eval.sh --ui`). Undo now demonstrated (J3). Taps: J1 2, J2 0, J3 1, J7 1. New-item editors and search open with the keyboard ready. Dev region set to English |
| 10 | 9 | 10 | 6 | 9 | 8 | 9 | 8 | 9 | 8.5 | Design pass: dark mode checked on Today; largest accessibility text size: checkbox overlap and truncated details fixed, top/bottom chrome capped at XXXL; fade under the floating bar. Habits empty state still plain |
| 11 | 9 | 10 | 6 | 9 | 8 | 9 | 8 | 9 | 8.5 | AlarmKit "Ring as alarm" on tasks/events (iOS 26+), usage string via OneInfo.plist, denied-state copy. Simulator always answers .denied, so ringing must be verified on a device: AlarmTests skips on simulator. Not counted yet |
| 12 | 9 | 10 | 8 | 9 | 8 | 9 | 9 | 9 | 8.9 | Reminder plan (first fire + 5/10/20-min nags, snooze 10 min / 1 h) moved to Logic.swift with unit tests (Alarms 4, 5). Home Screen quick actions Ask AI / New task / New event, verified in the simulator (Interaction 9) |
| 13 | 10 | 10 | 8 | 9 | 8 | 9 | 9 | 9 | 9.0 | EventKit: sidebar toggle "Show Apple Calendar"; system events appear in Today / Week / Month; events created in one. are saved to the system calendar (with repeat) and deduplicated. CalendarSyncTests round-trips an event through the system calendar. Full suite: 10 UI tests pass, 1 device-only skipped |
| 14 | 10 | 10 | 8 | 9 | 9 | 10 | 9 | 9 | 9.25 | AI "Plan my day": first-fits overdue / due-today / flagged tasks into free time around fixed events (incl. system calendar), shown as a preview card; Apply with Undo. DayPlanner unit tests + testPlanMyDay UI test. Habits empty state |
| 15 | 10 | 10 | 8 | 9 | 9 | 10 | 9 | 10 | 9.4 | Cold start measured in-app (process start → first frame): 2981 ms → 575 ms median by deferring EventKit store creation and only building the sidebar when open. `Eval/cold-start.sh` enforces < 1000 ms; LaunchTests guards regressions under automation. 12 UI tests pass, 1 device-only skipped |
| 16 | 10 | 10 | 8 | 9 | 9 | 10 | 10 | 10 | 9.5 | Week grid: long-press and drag a planned task to a new time (15-min steps) or day; events stay fixed; deadline untouched. testDragTaskInWeekGrid passes |
| 17 | 10 | 10 | 8 | 10 | 9 | 10 | 10 | 10 | 9.6 | Habit reminder schedule moved to Logic with tests (skips checked-in days and past times) on the same notification pipeline verified in round 3 (Habits 8). Dictation (Speech, on-device when possible) wired to the AI input; the simulator's CoreAudio input deadlocks, so it is device-only and not counted yet |
| 18 | 10 | 10 | 8 | 10 | 9 | 10 | 10 | 10 | 9.6 | Real data (debug-only `-importData`, Yuan's Calendar + Reminders export, never committed): 458 events, 277 reminders, mostly Chinese titles. Fixed what it exposed: noisy task details (deadline first, repeat as ↻, no duplicate "Overdue"), numbered list names shown without the number, Overdue collapsed to 3 + "Show N more" and sorted oldest first, redundant "All day" labels, empty built-in Inbox chip hidden, Unscheduled sorted by deadline. CalendarSyncTests made robust to leftover simulator events |
| 19 | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | Re-scope, no new measurement. (1) App renamed **Today** (bundle id and targets unchanged). (2) Direction: AI-native, local data, Apple Calendar/Reminders as the source of truth via EventKit, AlarmKit alarms; roadmap aggregate, then optimize, then surpass; Apple Intelligence (on-device) later, always as a preview. (3) 4 tabs Today / Calendar / Reminders / Alarms; Habits removed (model kept in schema); Calendar is Week/Month; Alarms lists real alarms only; the nag-until-done reminder is dropped; the bottom-right button becomes a + (tap adds what fits, hold for the menu). (4) Gestures follow Apple (tap the circle, swipe left Delete + Flag, long-press menu, system events in Apple's viewer). (5) HTML prototype simplified the same way (the iOS app is now ahead of it). Dimensions were re-scoped (Habits retired for Reminders parity; Alarms, AI, Interaction and Reliability claims reworded), so scores restart at the next full eval and round 18 numbers are not comparable. Reminders parity by code read: 1 demonstrated, 4 built, 5 not met |
| 20 | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | Aggregation step. (1) Reminders tab modeled on Apple Reminders: smart-list cards with counts, My Lists with color and symbol, Add List sheet, list screens with an inline New Reminder row. (2) Two-way sync with Apple Reminders through EventKit (`RemindersSync`): lists and reminders, Apple wins on conflict, nothing written before the user connects, only items created after connecting are uploaded, a pass never deletes more than 10 Apple items, "Delete all data" forgets the link first, planned time stays local. Verified in the simulator both ways; a same-value write looped the sync and was fixed. (3) Alarms page lists real alarms (AlarmKit, new `OneAlarm`), alarms also appear in Today's schedule; + button adds what fits the page. (4) Apple Intelligence (on-device) capture with the rule parser as fallback, compile-checked only. Known: the simulator's Apple Calendar accumulates the test events UI tests create |
| 21 | n/a | n/a | n/a | 6 | n/a | n/a | n/a | n/a | n/a | First full UI run since the re-scope, on the merged branch, simulator Today-Docs (machine heavily loaded by parallel builds). 112 tests: 89 passed, 2 skipped, 21 failed; re-running the 21 alone: 18 pass (launch-time flakes under load: "Failed to get launch progress"), 3 fail for real: `InlineNewReminderTests` (inline date menu not reached), `RemindersListsTests.testSwipePinsAListToTheTop` (stale: Pin moved to the trailing swipe; test fixed), `SidebarTests.testSidebarHasNoTabRowsAndShowsTheEmptyState` (a Today button is on screen with the sidebar open; not diagnosed). J1–J7 all pass; J5 measured at 3 taps. New this round: Reminders sync both ways (`RemindersSyncBothWaysTests`), Tidy overdue (`OverdueTidyTests`, `TidyOverdueTests`), Share extension (`ShareInboxTests`, `ShareImportTests`, `ShareSheetTests` end to end through Safari). Logic tests and NL-capture eval pass (train 44/44, test 22/22). Only Reminders parity is scored; the other dimensions need the screenshot checklist |

Round 1 failing claims, weakest first: Alarms (2–10), Reliability (3–5, 8–10), Calendar (3, 4, 8–10), Tasks (3 undo, 6–10).

## How to run the eval

```bash
./dev test unit                                  # logic tests, including the NL-capture ratchet
./dev test ui --only TodayUITests/<Suite>/<Method>  # one UI journey on a simulator
```

The NL-capture cases live in `ios/Eval/Tests/OneLogicTests/capture-cases.json` (split fixed; never read test failures while fixing). The ratchet is `CaptureEvalTests.ratchet`. The agent is measured on frozen dev/holdout cases (`tests/fixtures/agent-p3-dev.json`, `agent-p3-holdout.json`) against the targets in `docs/engineering/ai-agent-architecture.md` §4.3; the first run and how to repeat it are in `docs/qa/agent-p3-eval-20261101.md`.

## Plan

- ~~Round 2 — eval harness~~ done.
- ~~Round 3 — Alarms~~ done (AlarmKit and demonstrating notification actions still open).
- ~~Round 4 — Sidebar + icon~~ done. Tab swiping was dropped so the edge swipe can open the sidebar.
- ~~Round 5 — Tasks~~ done.
- **Next — UI tests (XCUITest)** for J1–J7 so undo, notification actions and journeys are demonstrated by a program, not by hand.
- ~~Round 6 — Calendar~~ done (EventKit still open).
- ~~Round 7 — AI parser~~ done. Saturated; needs new real-world cases.
- ~~Round 8 — Habits~~ done, then retired in round 19 (removed from the product).
- ~~Round 9 — UI tests~~ done.
- ~~Round 10 — Design~~ done.
- ~~Round 11 — AlarmKit~~ built; needs a device run (blocked on the iPhone's Verify App step).
- ~~Round 12 — reminder logic tests, quick actions~~ done.
- ~~Round 13 — EventKit~~ done.
- ~~Round 14 — Plan my day~~ done.
- **Remaining (device-only):** dictation (AI 10), AlarmKit ringing (Alarms 7), notification Done/Snooze actions (Alarms 3). All built; they need the iPhone run.
- **Round 19 — re-scope** (docs only): rename to Today, 4-tab IA, Habits retired, Alarms and gesture claims rewritten.
- ~~**Aggregate**~~ mostly done (rounds 20+): Reminders tab like Apple Reminders (smart lists with counts, pinned cards, My Lists with color/symbol, create/rename/delete/reorder/pin, Edit, inline New Reminder row), two-way EventKit sync with Apple Reminders, the + button (tap adds what fits, hold for the menu), Due-style quick add with local suggestions, sidebar with Search and chat history (auto-archive), shared swipe actions, tabs that keep their place, AlarmKit alarms and a kitchen timer, a shared test dataset (`tests/fixtures/today-dataset.json`) on one simulator (Today-Dogfood).
- ~~**Still open in Aggregate**~~ done in round 21: Reminders sync tested both ways (complete / rename / delete / repeat), full UI suite run, J5 measured (3 taps). Left: Reminders claims 4 (inline date menu test), 6, 7 and 10.
- **Optimize (in progress):** done: the AI agent (FastLane plus the hosted Luna agent loop, P4 shipped 2026-11-01; P3 eval in `docs/qa/agent-p3-eval-20261101.md`) behind the one-line capture, multi-item capture, follow-ups and edits of existing items; "Tidy overdue" preview (new reminder date per row, Apply, Undo); Next Up widgets with background refresh; Live Activities for the timer and snoozing alarms; Siri / Shortcuts (App Intents); Share extension. Next: fill the full claim checklist (screenshots for design) and score every dimension.
- **Then — Surpass:** improve on Apple's screens only after parity is demonstrated.
- Then run a full eval, restart the score log from the new dimensions, and keep climbing whatever is weakest.
