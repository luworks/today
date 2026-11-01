# Today — iOS app (SwiftUI)

The native app (formerly "one."). It puts calendar, reminders and alarms in one place. Direction: AI-native, planner and health records stay on the device; GPT assistance sends messages and bounded relevant context to the configured AI service; Apple Calendar and Apple Reminders are the source of truth (EventKit), alarms use AlarmKit. The HTML prototype in `src/` is the older design reference; the iOS app is now ahead of it. See [the goal and rubric](../docs/goal-and-rubric.md) for the goal, roadmap and eval.

## Development entry

Run `./dev` from the repository root for all local/CI engineering operations. The executable parser in [cli.py](../scripts/devtools/cli.py) is the command authority; underlying scripts are adapters, not alternative workflows. The generated project is `ios/Today.xcodeproj`, specified by [project.yml](project.yml) and `Config/*.xcconfig`; do not hand-edit generated project files. The display name remains **Today**. Production identity remains `com.luworks.one`, model/intent module `One`, products `One.app`, `TodayWidgets.appex` and `ShareExtension.appex`.

```sh
./dev help
./dev doctor
./dev inventory
./dev bootstrap
./dev generate
./dev resolve
./dev plan --scheme Today --configuration Debug
./dev build Debug
./dev build Debug --scheme TodayMock
./dev build Debug --scheme TodayMock --for-testing --timeout 180
./dev build Debug --scheme TodayWorkbench
./dev build Release
./dev test unit
./dev test ui --only TodayUITests/<Suite>/<Method>
./dev format --check
./dev lint
```

Replace selector placeholders with discovered method IDs; repeat `--only` for a small representative set. Legacy `OneUITests/...` selectors are translated to `TodayUITests/...`. `test ios-unit`, `test integration` and `test snapshot` route to the actual Xcode test targets; `test core` and `test accessibility` select bounded UI journeys. The source inventory and expected/executed reconciliation belong to [the test contract](../scripts/testing/contract.py) and [groups.json](../tests/testing/groups.json). Missing execution, missing baselines and parser errors are failures, not passes. Only an explicitly authorized frozen final revision uses `./dev test release --full` for the complete collection, alone. Do not infer that collection ran from a Debug build.

`build --for-testing` uses the same test-product provenance as the test adapters, without booting a device or executing tests. Set the existing synthetic CI environment when diagnosing its compiler mode. Native build logs retain elapsed phase markers and a read-only CPU/RSS process-tree sample every 30 seconds, including before a timeout; diagnostics do not change the build deadline or compiler settings.

CI is described in [CI](../docs/engineering/ci.md): `./dev` checks plus one native smoke (`scripts/ci/smoke.py`). Local success does not establish hosted CI acceptance. Without a Mac, run the `install-smoke` lane and download its Light/Dark TodayMock screenshots (`smoke-screens-<sha>`, see CI).

## Pinned tools and host ownership

Xcode **27.1 / 27A9275** supplies Swift **6.4** and Apple swift-format; Swift language mode is **6**, deployment iOS **27.0**. The [tool pins](../docs/engineering/tool-pins.json) own downloaded CLI versions/checksums: XcodeGen 2.46.0, SwiftLint 0.65.1, mise 2026.10.14, Ruff 0.17.1 and actionlint 1.7.12. [.mise.toml](../.mise.toml) and [mise.lock](../mise.lock) pin Ruby 3.3.12 and Python 3.14.8; [Gemfile.lock](../Gemfile.lock) owns Bundler 4.0.16 and fastlane 2.241.1. [Package.resolved](Dependencies/Package.resolved) is the SwiftPM lock authority; SnapshotTesting 1.19.6 is test-only. Pins describe requirements, not proof that tools are installed. `./dev bootstrap` verifies/downloads local tools and installs locked runtimes; do not substitute global versions.

Debug/Release controls optimization. Mock/Live selects a separate dependency graph: Today is live in both configurations; TodayMock and TodayWorkbench link TodayTestSupport. UI journeys use TodayMock. TodayMock shares the production bundle ID for compatibility and must only use its owned simulator; never install both variants together or put Mock on a phone. Workbench has its own development identity.

`./dev inventory` reports shared host and worktree derived-data locks. The adapter owns one named simulator and reuses its cache under the primary checkout's `tests/results/devtools/`. Coordinate with the integration/performance host owner before heavy work; a lock is mutual exclusion, not permission to kill another owner's process or delete its lock. Reuse the owned simulator/cache, then shut down the simulator after the related batch. Do not use a hard-coded shared UDID or cold-boot extra runners.

## Troubleshooting

- Missing or mismatched tools: read `./dev doctor`, then use `./dev bootstrap`; keep the exact Xcode build and locked runtime selection. Do not install a global fallback.
- Busy host/cache: inspect `./dev inventory`, coordinate with the current owner and continue independent work. Do not delete lock files, kill a runner or reuse its simulator.
- Dependency or generated-project drift: use `./dev generate` and `./dev resolve` against the tracked pins. A workspace lock copy must match `Dependencies/Package.resolved`; do not update dependencies to hide a mismatch.
- Unknown selector, no tests or missing snapshot baseline: check current source discovery and the selected group in the shared test contract. Preserve the failure and fix selection or record/review the actual baseline; a successful build cannot replace execution.
- Native capture failure: use a registered scene/scenario and a new `.png` path with no existing adjacent `.json` receipt. Retain the failed command evidence; do not relabel stale output as a current capture.

`./dev report <retained-report-path>` reads existing evidence. Generated logs, screenshots and complete finished xcresults belong in the primary checkout's `tests/results/`, indexed through `tests/qa/journal.py`. This is the existing QA history, separate from app Activity. Preserve raw artifacts and distinguish build, logic, simulator and device results in handoff.

## Test environment

The test dataset lives in `tests/fixtures/today-dataset.json`: lists, reminders (flagged, overdue, completed, repeating,
one that rings), events (repeating, all-day, across the week), alarms (on, off, repeating, once) and chats (one archived).
Dates are relative to the day it loads. TodayMock's test composition loads it into an isolated store with live sync off. Use the `./dev test` adapters to select and launch journeys on the owned simulator.

UI tests use it with `app.launchArguments = TestData.launchArguments`. The launch arguments below belong to TodayMock test composition, not to Live dependency selection.

Tests that need Apple Calendar (`CalendarSyncTests`, `CalendarDeleteSyncTests`, `CalendarRecurringDeleteTests`) add
`-uiTestingCalendarSync` and use the simulator's own calendar, never a real one. Debug-only launch hooks for them
(routed by development composition to the explicit calendar adapter):

- `-debugCreateSystemEvent <title>` — a one-off event at the top of the current hour, as if made in the Calendar app.
- `-debugCreateRepeatingEvent <title>` — a daily event at the top of the current hour, starting yesterday.
- `-debugDeleteSystemEvent <title>` — deletes every event with that title (a whole series too), as if deleted in the
  Calendar app. Tests also use it to clean up.
- `-uiTestingStore <name>` — keeps the test store in a file, so a second launch sees what the first saved.

## Native visual development

```sh
./dev ui open --scene clock.stopwatch --scenario normal
./dev ui capture --scene clock.stopwatch --scenario normal --output /absolute/fresh/capture.png
./dev ui gallery
```

The [scene registry](Sources/TodayScenes/SceneRegistry.swift) owns valid scene/scenario pairs. Workbench, previews and native captures use the real feature constructors through `SceneSession`; unsupported states fail validation. See [gallery](../docs/engineering/gallery.md), [visual testing](../docs/engineering/visual-testing.md) and [scene session boundaries](../docs/engineering/scene-session-integration.md). The older [axe workflow](../docs/swiftui-preview-workflow.md) retains measured history and limitations; use the `./dev ui` entry for current work. Functional acceptance still requires the focused native journey.

## Weather on Today

Weather is not available in the live app: its setting is hidden and requests are disabled even if
an old preference is on. Mock and Workbench retain the opt-in summary with fixed offline sample data.
The implementation is retained for later: live use requires Apple Developer Program membership,
the WeatherKit capability on the App ID, a matching entitlement and provisioning profile, and a
verified live request. Once enabled, the feature requests foreground location and sends it to Apple
Weather; forecasts and location stay in memory. A simulator sample is not evidence of a live request.

## Release and physical-device states

`./dev release preflight-local --commit <full-sha> --version <version> --build <integer>` checks unsigned local readiness. `./dev release archive-local` forwards fastlane key/value options (`commit:`, `version:`, `build:`, `archive:`, `derived_data:`); `./dev release validate-local` uses the preflight options plus `--archive <path>`. Use a fresh archive outside the checkout and the owned cache. See [release integration](../docs/engineering/release-integration.md) and [release tooling](../scripts/release/README.md) for exact arguments and retained maps/provenance.

Unsigned source readiness, an unsigned device archive, signed archive validation, export/upload and Apple acceptance are separate states. Local readiness reports `signing=not_checked` and `distribution=not_authorized`. Signed commands require existing matching signing material and release-specific authorization enforced by the tooling. Current automatic signing settings do not establish signed readiness; missing manual distribution prerequisites remain blocked. Do not change accounts, certificates, profiles or signing settings as troubleshooting.

Phone installation and capability checks require an explicit device task. Without an authorized device, trust/signing prerequisites and a completed run, report device verification as blocked or not run. Simulator builds do not prove real AlarmKit ringing, Health permissions, Apple Intelligence, installed Shortcuts or old-install upgrade behavior. This guide records no final-collection or device pass; retain actual results in the existing QA journal rather than adding a status ledger here.

Phone delivery acceptance must record the exact source/artifact, device/OS and Live versus Mock composition. Signed installation and a launch PID establish installation/launch only. Before claiming the installed app is usable, observe actual taps change the screen: Today item → editor → Cancel, Calendar/Reminders/Clock → Today, and Chat → type an unsent synthetic draft → Close. Check cold startup and return from the background with existing permissions and data intact. Screenshots alone do not prove input response. If physical touch automation is unavailable, install the fixed Live build first and request this short check from the owner; mark physical interaction acceptance pending until the owner confirms it. Report unverified Health permissions/data, Foundation Models and real alarm behavior separately. Never install TodayMock on the phone or reset its data to obtain a pass.

## What's in the app

Four tabs: **Today · Calendar · Reminders · Clock** as pills on top (swipe sideways on the top or bottom bar to switch tabs) with the current device month at their right (`MonthLabel` in TodayCore, e.g. "Oct 2026", across all tabs including Year; independent of browsed dates and refreshed on time/foreground changes), a menu button top left that opens the sidebar, and an "Ask AI or add anything" bar with a **Today** button and **+** at the bottom. Each tab keeps its place when you switch away and back; the tab and the Calendar view survive a restart.

- **Today** — one day, with a week strip above it (tap any day; arrows move a week; first day of the week follows Settings): a red "N overdue" line above the timeline (tap to show the rows; **Tidy** beside it opens the Tidy overdue preview in a sheet, Apply with Undo), all-day events, due today, and the timeline with a "now" line. Tapping a Week day header or the selected day in Month opens it here; the bottom bar's **Today** button (the word, not an icon) always returns to today, from any tab or day. Overdue always shows (never hidden or moved silently); Settings can hide alarms and turn off scrolling to now. On today, a quiet health line sits on top ("6,240 steps · slept 7 hr 12 min", read-only from Apple Health; Settings → Today → Health summary; HealthKit access is asked the first time it would show, for the metrics the line uses; sample data under `-uiTesting` and on the simulator). Tap it for the **Health sheet**: a compact list of the metrics you chose in groups (Activity, Sleep & Recovery, Body), each row the latest value with a quiet date label and a 7-day sparkline; tap a row for a 7 / 30 / 90 day chart with average, low, high and the change against the days before (facts only, no generated text). Defaults are steps, sleep and weight; **Manage Metrics** lists every supported metric with a visibility toggle (shown metrics start on, hidden metrics off); Done or dismissing the sheet saves the choice, preserving existing row order and asking Health only for newly shown types; swipe a row to **Hide** it (nothing is deleted from Health), long-press for Hide / Move Up / Move Down, press-hold-drag reorders inside a group. The choice and order is the only thing saved (`today.health.metrics`); Health values stay in memory. If steps or sleep is hidden, the Today line uses the first two shown metrics. Settings → Today → Health metrics opens the same sheet. Today is the simplest entry, not a replacement: the sheet, every metric detail, Manage Metrics and Settings → Today each have a quiet **Open Health** button (`health.open`) that opens Apple's Health app (`HealthLauncher.url`, `x-apple-health://`, its home page; no per-metric deep link exists); if iOS refuses, the label says "Couldn't open Health" for a moment. UI tests: `-uiTestingHealthMetrics steps,weight` seeds the choice, `-uiTestingKeepHealthMetrics` keeps it across a relaunch. To view tomorrow, select its day in the week strip or Calendar; there is no Tomorrow disclosure in the Today timeline. A reminder on Today has the usual long-press menu (Flag / Today / Tomorrow / Unschedule) plus Settle, and a Tomorrow swipe. Settle hides an item only in the selected current or future day in Today; its source is unchanged, each day has its own choices, and the choice expires after that local day ends. Files: `TodayHealthLine.swift`, `HealthView.swift`, `OpenHealthButton.swift` (+ `HealthLauncher.swift`), `HealthMetricDetail.swift`, `HealthMetricPicker.swift`, `HealthSparkline.swift`, `HealthModel.swift`, `HealthSource.swift` (+ `HealthKitSource.swift`), `HealthMetrics.swift` (catalog, selection, formatting, sparkline and range math, unit-tested), `HealthSampleSeries.swift`, `HealthLogic.swift`. Tests: `HealthReviewTests`, `HealthMetricsTests`; design note `docs/health/metrics-and-density.md`; screenshots in `docs/qa/health-review/` (`TEST_RUNNER_HEALTH_SHOTS=1`).
- **Calendar** — modeled on Apple Calendar: 2 Day (default; a time grid of two days that starts today, or on the day picked in Month or Year, and moves one day per swipe), Month (grid with the selected day's events below) and Year. Tapping any day in Year opens Month with that exact date selected and its items below the grid; tapping a month title keeps the usual landing day (today in the current month, otherwise the first). 2 Day headers and a second tap on a selected Month day open the Today tab. One control row: the view switcher; the month is named only in the top bar. Which calendars show is chosen in Settings. With Calendar access on, + opens Apple's own event editor and system events open in Apple's viewer. Events are fixed, and nothing is dragged in 2 Day. Events are blocks: ones that start together share the width, one that starts while another is on is indented and drawn over it (Apple's stagger). Reminders with a time and alarm rings are one-line chips at their time (circle or alarm symbol and the title; tap opens, long-press has the usual menu); on a crowded hour the extra ones fold into a "+N" menu, and beside an event the chip takes the right half (`CalendarLayout.timedDay`, unit-tested). Days that are over show in light grey in Month and 2 Day (and the selected day's list fades finished events) unless Settings → Calendar → Dim past days is off. Weekends have no tint or colour of their own. First day of the week follows the iPhone's region unless Settings picks Sunday or Monday (`Calendar.app`, used by `CalendarMath`); Show week numbers adds a column in Month and "W43" over the hours in 2 Day (the week of the first column); Open Calendar on picks the view at app start.
- **Reminders** — modeled on Apple Reminders: small wrapping pills for the smart lists (Today, Scheduled, All, Flagged, Completed) with counts, then pinned lists (long-press a pill: Hide, or the list menu); My Lists with color and symbol, Add List. No Edit button: press and hold a list for Rename / Color & Icon / Pin / Delete, press, hold and drag to reorder, swipe from the right for Delete / Info / Pin. Settings picks and orders the smart lists (a pill's long-press menu can also hide one). A list screen has a big colored title, a collapsed Completed section and an inline **New Reminder** row (note, date, flag and repeat buttons, suggestions). Two-way sync with Apple Reminders through EventKit (`RemindersSync`): Apple wins on conflict, nothing is written before you connect, a pass never deletes more than 10 Apple items, planned time stays local.
- **Clock** (tab; its first section is Alarms, then World Clock, Stopwatch, Timer) — the Alarms section is modeled on the Alarms tab of Apple Clock: big light times with AM/PM, green switches, "Next alarm in …", Add/Edit Alarm sheet (wheel, Repeat, Label, Sound from bundled tones, Snooze, Snooze Duration). Every alarm is a real AlarmKit alarm that rings through Silent and Focus; items you marked "Ring as alarm" follow in their own section. AlarmKit only shows alarms this app scheduled: Apple's own Clock alarms cannot be read. The first time the tab opens, a card says alarms are set in Today now (+, "Hey Siri, set an alarm in Today", the chat) and how to bring Clock alarms over once: the user's own Shortcut runs Clock's "Get All Alarms" and Today's **Import Alarm** (`AlarmImportIntent.swift`), which only stages them (`AlarmImport`, unit-tested); they show under "From the Clock app" to Add one by one or all, or Skip. Shown once (`Preferences.alarmIntroSeenKey`; UI tests opt in with `-uiTestingAlarmIntro` and seed staged alarms with `-uiTestingStagedClockAlarms`). Nothing syncs with Clock afterwards. A quiet switcher under the top bar splits the tab like Clock: **Alarms · World Clock · Stopwatch · Timer** (the last one is kept across tab switches and restarts). **World Clock** is modeled on the app Overlap: home (the device's time zone, starred) first, then your cities as cards tinted by the time of day there (night indigo, morning/evening blue, working hours 9–18 green) with "+N hrs · weekday, date"; drag sideways to move every clock in 15-minute steps (the capsule at the bottom says "3 hours from now", tap it for Now); Overlap shows a wave of who is working and the hours everyone overlaps; no Edit button: long-press a city for Move Up / Move Down / Delete, or press, hold and drag to reorder; + adds a city from a searchable list. **Stopwatch** like Clock's (Lap/Reset, Start/Stop, best lap green, worst red) keeps running across tabs and relaunches (it stores its start date). **Timer** uses Apple-style Timers with three wheels, Recents and running timer rings. On World Clock the + menu also offers Add city. Logic: `ClockLogic.swift` (unit-tested).
- **Timers** — the Timer section of the Clock tab: a large Timers title, hours/minutes/seconds wheels (timer limit 23 h 59 min), round Clear and Start buttons, Label and Sound, Recents (tap a row to load its duration, play to start immediately, swipe to delete), and running timers with Pause / Resume and Cancel. Multiple timers run side by side. Before you have your own recents, Focus 25 / Short break 5 / Long break 15 appear as presets; a matching Focus countdown counts a round only when it runs out. One Focus/break timer runs at a time alongside other timers. A quiet "Focus rounds today" caption appears after a completed round and resets at midnight. The Pomodoro dial, chips and next-step controls are replaced by these rows. Logic: `TimerRecents.swift`, `TimerList.swift`, `Pomodoro.swift` (unit-tested).
- **+ (bottom right)** — the same menu on every page: New alarm / New reminder / New event (plus Add city on World Clock). A new reminder opens the Due-style quick add: type what, set when with one tap on the grid (times of day, +/− nudges, days), with guesses from your own past reminders (on the device). Editing a reminder opens the full editor.
- **Sidebar** — like ChatGPT / Claude (menu button or a swipe from the left edge): Search at the top (reminders, events in the whole system calendar, alarms), past AI chats grouped by day (swipe Archive / Delete, long-press Rename, an Archived section), New chat and Settings at the bottom, and an **Activity** row under the title. Finished chats archive themselves (a week without a message, or an hour after everything they added is done); off in Settings → "Archive finished chats".
- **Gestures** (follow Apple Reminders / Calendar) — tap the circle to complete; swipe right to left for actions, which look the same in every list (Delete red and rightmost, a full swipe deletes with an Undo toast; Flag, Archive, Pin); long-press for Show Details / Flag / Today / Tomorrow / Unschedule / Delete. Deleting a repeating event asks "this event or the series?" first. Shake to undo.
- **Ask AI** — a full-screen page like ChatGPT: the bottom field starts a new chat every time (menu to past chats top-left, Close top-right, composer at the bottom with the keyboard up). The shell builds the next new chat hidden ahead of time (after launch and after each Close) and warms the keyboard at launch (`KeyboardWarmup`), so opening only reveals the page and the editor focuses on the next frame; an unsent draft is dropped on Close, the conversation stays in the sidebar from its first message. `ChatOpenLatencyTests` reads tap-to-page timings from `PerformanceTrace` (`first_frame_ms`, `keyboard_will_show_ms`). While you type, up to three open reminders and events that match every word appear above the composer (upcoming first, `DraftMatch`); tap one to open it. Ordinary conversation gets a text reply; requests to create planner items become preview cards. Unclear intent stays conversational when the on-device model is unavailable or times out. Chatting preserves pending previews and follow-ups, and records an AI turn according to Activity data settings without creating a change-ledger entry; one line can hold several items, each with Add / Skip, plus Add all. Uses the on-device Apple Intelligence model where available and the rule parser otherwise; follow-ups edit the preview ("make it 4pm", "the second one"), and "move / delete X" on existing items shows a change card. Questions get a local answer. "Tidy overdue" (a chip, or "整理过期") suggests a new date for each overdue reminder: flagged and recent ones first, three a day, then tomorrow and next week; one-offs older than a month lose their date. Change any row (Today / Tomorrow / Next Week / No Date / Keep), Apply writes the reminder date keeping its time of day, and Undo puts it back. A clear submitted one-off reminder is created from the Send tap under the scoped exception in `CLAUDE.md`; no recurrence means once. Other changes require Add / Apply. Direct failures retain a retry/cancel draft; Added requires the local save and connected EventKit commit.
- **Activity** (sidebar) — the ledger of every change: who (You, Today AI, Siri, Share, Apple Reminders / Apple Calendar seen in sync), what, before → after, approved / automatic, grouped by day, filter chips All / AI / You / Agents, and Undo for changes Today can put back on its own: reminders (complete, reopen, new date, rename, add, delete) and alarms (add, delete, edit, on/off; a deleted alarm comes back as a new alarm with the same time, label, repeat, sound, snooze and on/off, scheduled with AlarmKit) and reminder lists (add while still empty, rename, color and icon, delete; a rename or new look of a list in Apple Reminders goes back to the same Apple list; a deleted list comes back with its reminders only when it lived in Today alone, because a list or reminder deleted from Apple Reminders would return with new identifiers, so deleting a list that is in Apple Reminders stays without Undo, and the delete alert says which), and event deletes (a one-off with no attendees comes back as a new event, so the row says "Restores as a new event"; Apple Calendar gives it a new identifier, and Undo runs only while the deleted event is still gone; repeating events, events with attendees, AI moves and invitations stay without Undo, so Undo never sends anything to other people). Each alarm, list or event row keeps the settings before and after in the `snapshot` table (`AlarmChange` / `ListChange` / `EventSnapshot`, `Sources/TodayCore/ActivityUndo.swift`), so Undo is offered for 30 days (the snapshot window) and only while the item is still as that change left it; old rows without a snapshot show no Undo. Undo of an alarm runs from Activity or the delete toast, whichever comes first. Settle and its reverse (Focus choices) have no Undo there. Append-only (an undo is a new entry), kept forever by default (Settings: 90 days / 1 year / forever), 150 rows per page with "Show more". It reads the Activity data store (see below); one line at the bottom says it is stored only on this iPhone.
- **Settings** (from the sidebar) — **Appearance** first (a compact row with the current choice and a native System / Light / Dark menu, default System, saved as `today.appearance`; applies at once to the whole app including sheets and Apple's event editor; widgets and Lock Screen follow the system; files `Appearance.swift`, `AppearanceLogic.swift`, tests `AppearanceTests`, `AppearanceUITests`; screenshots of every screen in both modes: `TEST_RUNNER_APPEARANCE_SHOTS=<folder>`), Apple Calendar and Apple Reminders switches, the calendars list, Today options, Activity (count, Clear with confirmation), chat auto-archive, and Delete All Data (two confirmations; never touches Apple Calendar or Apple Reminders).
- **Settings, continued** — in this order: Appearance; Apple Calendar, Apple Reminders and Alarms (switches, the calendars list, permissions); **Today** (show alarms, scroll to now, Show free time, Travel time, Health summary and metrics); **Calendar** (Dim past days, First day of the week System / Sunday / Monday, Show week numbers, Open Calendar on Last used / 2 Day / Month / Year (an older Week or 3 Day choice is Last used)); **Reminders** (New reminders go to Auto or one list: used by Ask when no list clearly fits, by the + quick add and by Share; existing reminders never move) and Smart Lists; **Alarms** (snooze length and sound a new alarm starts with); **AI** (Suggestions on the Ask page, Archive finished chats, New AI agent (beta): off by default, `today.ai.agent`); Activity → Activity data (what is recorded and where, pause, a switch per category, how long changes are kept, export, clear); About; Delete All Data (two confirmations; never touches Apple Calendar or Apple Reminders). Every default is what the app did before the choice existed. The new choices live in `Preferences.swift` (keys, defaults, plain readers; unit-tested in `PreferencesTests`) and are read with `@AppStorage`; their rows are in `SettingsRows.swift`. UI tests start from the defaults (`-uiTesting` clears these keys; `-uiTestingPrefs dimPastDays=0,firstWeekday=monday` sets some up front; `-uiTestingKeepPreferences` keeps them across a relaunch); `SettingsChoicesTests` flips the real switches and compares screen pixels for the dimming and the missing weekend tint.
- **Habits are gone.** No tab, chips or streaks. The `Habit` model remains in the SwiftData schema, unused, so existing installs migrate without losing data.

Planner list rows in Today, Calendar, Reminders and Search use at most two text lines: a title and detail share one line when they fit, otherwise each gets one truncated line. A title without detail can use two lines. Event travel information shares the detail line; the full item remains available on opening it and through VoiceOver. Text follows Dynamic Type.

## Physical-device delivery

For an explicitly authorized Live Debug installation, use `./dev build Debug --device <UDID> --install --main-run <push-run-id> --smoke-run <install-smoke-run-id>`. Add `--allow-provisioning-updates` only when explicitly authorized. The build, receipt, exact-current-main CI preflight and install share the host and derived-data locks. The receipt and logs are retained under the primary checkout's `tests/results/`. A failed preflight prevents installation. This command does not launch the app or establish usability.

## Source map

[Architecture](../docs/engineering/architecture.md) owns the dependency contract. [Package.swift](Package.swift) owns actual links and source membership; production tests import these same implementations.

- `App/OneApp.swift`: executable assembly; `Sources/TodayShell/`: navigation, destinations and lifecycle.
- `Sources/TodayCore/`: Foundation domain rules, policies, preferences, runtime and contracts. `Sources/TodayShared/`: extension-safe widget/inbox/outbox/speech formats.
- `Sources/TodayData/`: real Activity SQLite, recorder, import/export and retention. `Sources/TodayPlatform/`: model-free system adapters and instrumentation. `Sources/TodayDesignSystem/`: adaptive native components.
- `Sources/One/`: persistent models, model-bound services/actions, ledger/grants, store and intent compatibility bridge. A reminder has one date (`due`); `OneTask.plannedStart` and `AIGrant` stay in the schema, unused, like `Habit` and `LedgerEntry`; those two stay in the schema.
- `Sources/TodayPlannerUI/`: shared model-bound rows/actions presentation. `Sources/Features/Feature{Today,Calendar,Reminders,Clock,Ask,Settings,Activity,Search,Health}/`: actual screens and behavior.
- `Sources/TodayTestSupport/`: deterministic services/Health sources, outside production. `Development/`: Mock/Workbench composition, fixtures and SceneSession. `Sources/TodayScenes/`: Foundation registry metadata.
- `One/`: bundled resources (including cities and sounds), not the old source directory. `TodayWidgets/` and `ShareExtension/`: extension entries. `Sources/One/AlarmActivity.swift` retains explicit identity-sensitive extension membership.
- `Eval/Tests/OneLogicTests/`, `SceneRegistryTests/`, `TodayIntegrationTests/`, `TodaySnapshotTests/` and `OneUITests/`: host logic, registry, iOS disk reader, native snapshots and UI journeys. Run through `./dev test`.

## Widgets (`ios/TodayWidgets/`, `ios/Sources/TodayShared/`)

One widget, **Next Up**: the next three things today (events, reminders with a time, alarms), merged and sorted by time,
all-day first. Lock Screen: rectangular (the next item only, readable at half width: a bold "15:00 · in 24:59" line with a live
timer, "Now · until 16:00", "Leave 14:20" or "All day", and a small "+2" for what else is left, then the title on up to two lines;
words in `Sources/TodayShared/LockScreenNext.swift`; or "Nothing else today" plus tomorrow's first item),
circular (next time in a ring of how much of today is done) and inline (above the clock). Home Screen: small (next item,
"in 2 hr") and medium (next three, each row opens Today on its day via `today://today?day=YYYY-MM-DD`).

- The app writes `widget-snapshot.json` (today, tomorrow and the day after, so "Tomorrow" still has data after midnight)
  into the App Group `group.com.luworks.one` (`WidgetFeed.swift`, called after data changes, when Apple Calendar changes
  and when the app goes to the background), then reloads timelines. It waits until the EventKit store is warm, so the
  first write after launch never drops system events. The snapshot also carries the Apple Calendar on/off switch and
  the hidden calendars.
- The extension never opens SwiftData. When Today has Apple Calendar on and the extension has full calendar access
  (inherited from the app), it reads Apple Calendar itself on every timeline and replaces the snapshot's Apple Calendar
  events (including Today's mirrored ones) with the live ones (`NextItems.merge`); otherwise it shows the snapshot as is.
  Timelines reload hourly and at midnight.
- Background refresh (`com.luworks.one.widgetRefresh`, a `BGAppRefreshTask` booked when the app goes to the background and
  re-booked by each run, about every three hours and never later than just after midnight): pulls Apple Reminders and rewrites the snapshot without the app being opened. iOS decides
  when it actually runs.
- `Sources/TodayShared/WidgetSnapshot.swift` is compiled into both targets (and tested through `./dev test unit` as `TodayShared`): the snapshot model,
  `NextItems` (selection, order, tomorrow fallback, live merge, timeline and reload dates), `WidgetItem.eventRows` and
  `WidgetLink`.
- Add it: long-press the Lock Screen → Customize → Lock Screen → tap the widget area under the clock (or the date line
  above it) → pick **Today** → Next Up. Home Screen: long-press → Edit → Add Widget → Today.

## Share extension (`ios/ShareExtension/`)

Share → **Today** from Safari or any app that shares text: the page title (or the text's first line) becomes the title, the
link and the rest of the text the note; pick No Date / Today / Tomorrow / Next Week; nothing is added until you tap Add.
The extension never opens SwiftData: it appends to `share-inbox.json` in the App Group (`Sources/TodayShared/ShareInbox.swift`, with a
file coordinator), and the app takes everything there when it becomes active, adds the reminders (which sync to Apple
Reminders when that is on) and shows an Undo toast. Tests: `ShareInboxTests` (logic), `ShareImportTests` (the app side,
via `-uiTestingShare <title>`) and `ShareSheetTests` (end to end through Safari's real Share sheet; skips without network).

Debug persistence journeys use `-uiTestingStore <unique-name> -uiTestingShareID <UUID>
-uiTestingShareProbeTitle <title>` together with `-uiTesting`. This isolates the inbox beside that test store,
uses a deterministic share ID, and exposes `shareImport.testState` (committed matching task/receipt and pending-inbox counts).
Only the first launch adds `-uiTestingShare <title>`; later launches use `-uiTestingShareInbox` without reseeding.
`-uiTestingShareFailAcknowledgment` leaves the inbox pending; `-uiTestingShareFailSave` explicitly throws before
SwiftData save and rolls back the import context. Both are developer test injections, not evidence of spontaneous storage failures.


## Activity data (`Sources/TodayData/`, `Sources/One/ActivityCenter.swift`, `Sources/TodayShared/ActivityOutbox.swift`)

One app-private SQLite file, `Application Support/Activity/activity.sqlite` (system `SQLite3`, no dependency, WAL, `PRAGMA user_version` migrations), holds everything Today records about its own use. Research, schema reasons and numbers: `docs/research/activity-data-store.md`. It is the home of the Activity ledger (tier 1) and of the AI, usage and system events around it.

**What is recorded (four tiers).** 1 Changes: the ledger (`change.<action>`, `grant.*`) with before → after, approval, Undo links and Undo snapshots. 2 AI: `ai.turn` (intent, route, language, length; no text unless "Keep the text of my messages" is on), `ai.card.shown` / `ai.card.resolved` (applied, edited, skipped, cancelled, ignored; edited fields by name in `props`, the words before and after in the `content` table), `ai.chips.shown` / `ai.chip.tapped`, `ai.undo`. 3 Usage: `ui.screen.open` (tab changes), `ui.quickadd.commit` (ms). 4 System: `sys.share.import`, `sys.share.add`, `sys.widget.refresh`, `sys.intent.run`, `sys.sync.conflict`. Defaults: all four on; raw events in every tier are kept forever. If 90 days or 1 year is selected, changes follow that period, AI decisions are kept 180 days, usage 30 (counts rolled up per day first), and system 90. Undo snapshots are kept 30 days for every setting. The policy's "you chose this time" look-back stays 90 days whatever the setting.

**Rules.**
- Only the app process opens the file. The Share extension and the widget append one small JSONL file each to the App Group folder `activity-outbox/` (`ActivityOutbox`); the app imports them when it becomes active, in one transaction, then deletes them (same idea as `ShareInbox`). App Intents run in the app process and record normally.
- Personal content stays in its own places: `title` / `before_txt` / `after_txt` columns, the `content` table (edited-card words, optional chat text) and the `snapshot` table; `props` never holds free text. `ActivityEvent.redacted()` drops all of it.
- Rows are immutable and carry a UUID and a device id (Undo is a new row with `undo_of`), so they can be merged by union later. Reads are paged by a `(ts, id)` cursor (the Activity screen loads 150 rows at a time); every query has an index (a test checks the query plan); writes are batched (the recorder buffers about 1.5 s or until the app goes to the background).
- Paused, or a category switched off: events are dropped before they are buffered. Because an automatic change without an Activity entry and an Undo would break "AI prepares, the user decides", nothing applies by itself under a grant while Changes is off or recording is paused.
- The old SwiftData `LedgerEntry` rows are copied into the store once at launch (`LedgerMigration` → `LedgerImport`: batches of 500, keyed on the entry's UUID, so it is idempotent and resumes after a crash; the flag `ledger_migrated` is set only when every old row is in the store). The old rows are deleted only in a later launch than the verified copy. The model stays in the schema, unused, so existing installs migrate. A file SQLite cannot read is moved aside (`.damaged-<time>`), never deleted.
- Settings → Activity → Activity data: what is recorded and where, pause, a switch per category, keep chat text, retention, Export (JSON Lines: every field including snapshots and card diffs; CSV: one flat row per event, RFC 4180) through the share sheet, Clear (names the count; also the old rows). Delete All Data clears it too. The Activity screen carries one line saying it is stored only on this iPhone.

**Tests.** `./dev test unit`: `ActivityStoreTests` (schema and migrations, paging, filters, search incl. Chinese, retention and rollups, snapshots, export formats, query plans, corrupt file), `ActivityRecorderTests` (buffering, settings, event shapes, outbox round trip across the extension/app boundary), `ActivityLedgerTests` (mapping, import, dry run, resume). UI: `ActivityDataTests` (Settings page, pause, Clear, paging 400 rows, export sheet, and the real import of old `LedgerEntry` rows across two launches) and `LedgerTests`. Debug launch hooks: `-uiTestingActivityRows <n>` (n synthetic changes), `-uiTestingLegacyLedgerRows <n>` (n old SwiftData ledger rows, to test the import), `-uiTestingActivityPaused`, and `-uiTestingStore <name>` also keeps `<name>.activity.sqlite` in the temp folder.

**Speed.** `ACTIVITY_BENCH_ROWS=100000 ./dev test unit --only TodayTests/ActivityStoreTests/testBenchmarkLarge` prints insert and query timings on the Mac. On a phone, debug builds have Settings → Activity data → "Run speed test (100,000 rows)", which does the same in a throwaway file and shows SQLite's version, whether FTS5 and the JSON functions exist, and the timings. Mac numbers (Apple Silicon, host debug build, 100,000 rows, including building the events in Swift): insert about 42,000 rows/s (2.4 s, 47 MB file), newest page of 150 in 1.8 ms, a page 10,000 rows down in 1.6 ms, a one-day count in 0.1 ms, a `LIKE` search over titles in 29 ms; SQLite 3.51, FTS5 and the JSON functions present. The research document's release-build figure for raw inserts was 270,000 rows/s. No iPhone number exists yet: it needs a Debug install on a phone.

**Export formats.** One event per JSONL line: `uid, device, ts` (unix ms), `tz` (minutes east), `day`, `tier`, `kind`, `actor`, `channel`, `session`, `thread`, `subject_kind`, `subject_ref`, `approval`, `undo_of`, `title`, `before_txt`, `after_txt`, `before_ts`, `after_ts`, `props` (object), `v`, plus `snapshot` (base64) and `content` (`[{field, before, after}]`). Unknown keys are ignored when reading.

### Later (not built; needs the paid Apple Developer account or our own backend)
- **iCloud / CloudKit sync.** A free Apple ID cannot use CloudKit or push (verified in the research document). The schema is ready: `uid` is the record name, rows are immutable with a `device` id, `sync` (0 = local only) marks what was uploaded, `props` is a JSON string. Plan: `CKSyncEngine` over tiers 1 and 2 into a private zone, encrypted fields for `title` / `before_txt` / `after_txt` / `props` / `content`, tombstones for Clear, zone delete on Delete All Data; usage and system events stay on the device. The JSONL line above is the payload shape.
- **Redacted upload to the product team.** A separate pipeline that does not exist: our own backend, `ActivityEvent.redacted()` (drops titles, text, thread, refs; coarsens time to the hour) shown to the user before sending, explicit opt-in, and a rewording of "data stays local" in `CLAUDE.md`. Decision deferred (document §7.3).
- Phase 3 to 5 of the document: coalescing and a rollup job beyond what prune does, local learning loops (chip ranking from tap history, "Save as eval case" for edited cards), a diagnostics export with preview.

## Alarm wheel lab (debug builds only; `Sources/TodayCore/TimeWheel.swift`, `Sources/TodayCore/WheelLab.swift`, `Sources/Features/FeatureClock/AlarmWheelLab.swift`)

An experiment, not a feature: does a different time wheel make setting an alarm faster? Settings → Developer → Alarm wheel lab (Debug builds, so the Mac's Debug Live install on a phone has it; Release does not). It never creates an alarm.

- **Versions.** A = Apple's wheel `DatePicker` (`AlarmTimePicker`; the alarm editor used it before C was chosen). B = the custom wheel (`TimeWheelPicker`) with fixed spacing. C = the same wheel; only the minute column's spacing follows the finger speed (fast: rows close up and only 00/05/10… are labelled; slowing down opens them again around the selection). B and C share everything else: rows, font, band, touch handling, inertia, haptics and Set. Reduce Motion keeps C at fixed spacing (recorded per trial).
- **Known differences from A.** B and C are flat (no 3D drum), draw short ticks, show AM/PM as a column you tap, and use their own deceleration (`decelerationTau` 0.4 s against UIKit's feel). The hour column runs 0-23, so going past 11 switches AM/PM as in Apple's picker; going past 59 minutes does not change the hour (also as Apple).
- **Practice / Session.** Practice records nothing. A session is 27 trials: the 9 tasks of `WheelLabTask.all` (near, far, exact non-multiple-of-5 and boundary targets) in each of three blocks, one version per block; sessions 1-6 go through all six version orders and each block is shuffled the same way for the same session number. The target is shown to you and used for scoring only; the wheel never sees it. Set on a wrong time plays an error haptic and counts a wrong confirm; the right time plays success and moves on. Each block ends with two 1-5 ratings (easy to stop, in control).
- **Recorded per trial** (`WheelLabTrial`): first touch → right Set, task shown → right Set, wrong confirms, overshoots (landing past the target), in-gesture reversals (B/C only), touches, time waiting for the wheel to stop after a lift (capped at 3 s; for A, lift → the value it lands on), Reduce Motion, VoiceOver, iPhone model, iOS version, app version, build and build date. Saved to Application Support/WheelLab/log.json; Results shows medians and the 90th percentile per version and task kind, first session apart from later ones, and exports CSV and JSON. Clear Results empties it.
- **Tuning.** Every number is in `TimeWheelTuning` (`TimeWheel.swift`), marked experimental; the tests in `Eval/Tests/OneLogicTests/TimeWheelTests.swift` replay synthetic touches at real timestamps (including the fast drag → hold → 2 pt → release trace) and must stay green after a change. Start with `coarseFrom` / `coarseAt` (when C starts and finishes compressing), `coarsePointsPerUnit` (how close rows get), `scaleFallTau` (how fast detail opens again), `decelerationTau` (coast length) and `minFlickSpeed` (what counts as a flick rather than a slow release that snaps).

## Siri, Spotlight and Shortcuts (`Sources/One/AppIntents.swift`)

App Shortcuts, English phrases in code and Simplified Chinese in `One/AppShortcuts.xcstrings`: **Add Reminder**
(a title or one sentence, read by `CaptureParser`; always a reminder), **Start Timer** ("Start a timer in Today", "Set a
Today timer": Siri asks "How long?" and `TimerPhrase` reads "ten minutes", "an hour and a half", "十分钟", "半小时"),
**Start Timer for…** ("Start a timer in Today for 10 minutes": the length is one of a few presets so Siri hears it in one
breath), **What's Next Today** (the Next Up widget's three items, spoken plus a snippet) and
**Open Today** (the `today://today` link). They run in the app's process on the app's store (`OneStore` in `Sources/One/OneStore.swift`).
Pure parts: `Sources/TodayCore/IntentLogic.swift`, `Sources/TodayShared/NextUpSpeech.swift` (tested in `IntentTests`).

**Timers** (`TimerController.swift`, `TimerList.swift`, `TimerRows.swift`, `TimerIntents.swift`): every timer Today starts is a
real AlarmKit countdown, as many as you like (one Focus/break preset timer at a time alongside other timers).
They show on the Today tab as up to two live rows at the top (`Text(timerInterval:)` counts down on its own; swipe for
Pause/Resume/Stop, tap to open the Timer tab, "+N more") and as running ring cards above the Timer picker. End times live in
`TimerStore` (UserDefaults), because AlarmKit has no fire date; `TimerController.refresh()` lines them up with
`AlarmManager.alarms` on launch, foreground and every AlarmKit update (`TimerList.reconcile`), so a timer started by Siri
while the app was closed is there at once. TodayMock UI tests: `-uiTestingTimers 600:Pasta,1500,300:Tea:paused` seeds timers and
uses the development TimerService instead of the live AlarmKit driver; see `TodayTimerTests`. Also adopts the iOS 27 **Clock schema**
(`@AppIntent(schema: .clock.createTimer / pauseTimer / resumeTimer / cancelTimer`, `.clock.timer` entity) so Siri can hand
"set a timer" to Today. What iOS allows and what it does not (timers made in the Clock app or by Siri's built-in "set a
timer" cannot be read by any app): `docs/research/timer-siri-sync.md`.

**Alarms** (`AlarmIntents.swift`): **Set Alarm** ("Set an alarm in Today", "Wake me up with Today": Siri asks "What time?";
`IntentAlarm` reads "7am tomorrow", "weekdays at 6:30", "in 20 minutes", "明早7点" with the chat's parser) sets a real
AlarmKit alarm directly, made like one from Add Alarm or the chat (`OneAlarm.new`, Settings → Alarms sound and snooze;
a one-off must ring within a day, as in the chat). Also adopts the iOS 27 Clock schema for alarms
(`@AppIntent(schema: .clock.createAlarm / updateAlarm / dismissAlarm)`, `.clock.alarm` entity keyed by the AlarmKit id,
which each scheduled alarm carries as `appEntityIdentifier`). Today still can't read or change the Clock app's alarms;
whether Siri's plain "set an alarm" goes to Today rather than Clock can only be checked on a phone. Tests: `AlarmIntentTests`.

Tests: `ios/Eval/Tests/OneLogicTests/` and `ios/OneUITests/`; use `./dev test unit` and focused `./dev test ui --only TodayUITests/<Suite>/<Method>`. Historical eval scripts are not a second entry.

## Next

A full eval run on the rubric (scores restart from the re-scoped dimensions) → climb the weakest dimension.

## Credits

The World Clock city list (`ios/One/cities.json`, built by `scripts/build_cities.py`) is derived from GeoNames data (https://www.geonames.org), licensed CC BY 4.0. The picker footer says so too.
