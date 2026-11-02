# Today Focus (Settle)

## What it is

Settle hides one item from **today's** timeline without changing it. It never completes a reminder, changes a date,
moves or cancels a meeting, changes an alarm or notification, or writes EventKit. Settled items sit in a collapsed
"Settled (N)" section under the timeline with Unsettle, Ask AI (#241), Open and Delete. AI has no Settle
capability. Settings → Today → "Show Settle" (`today.setting.showSettle`, default on) hides the action and the section.

Settle exists only on the device's current day (owner, 2026-11-01). `SettleGate.applies(to:now:calendar:)` in
TodayCore is the single check; `DayAgenda` uses it for the swipe and long-press action, the Settled section, the
store error line and the hiding of settled rows. A past or future day offers no Settle, has no Settled section and
shows every row: a past day exactly as `DayHistory` rebuilds it, a future day as planned. A choice belongs to the
local day it was made on and ends with it; the next day the item is a normal row again, with no "returned" history.

Hidden meetings still count as busy time for free gaps and suggestions. Individual overdue reminders can be settled
on today (the owner's explicit exception to "overdue stays visible"); the "N overdue" count leaves them out.

## Data

`TodayFocus` (module One) owns the decisions; `TodayFocusStore` (TodayData) is a typed, versioned (`1`) JSON overlay
written atomically next to the Activity store: `Application Support/Activity/activity.focus-v1.json` (an isolated UI
disk store uses `<store-name>.activity.focus-v1.json`). It holds only source identities (provider, account, calendar,
item, occurrence), the state, the change time, the agenda day and its time zone, and an optional opaque local anchor;
no title, note or other content. Corrupt or newer files fail without being replaced. Activity pause, category
switches, Clear, retention and export do not touch it. Delete All Data clears it first and keeps all local data if
that fails; it never writes Apple sources.

Identities come from EventKit objects (`focusIdentity`, `cachedFocusIdentity`; `CalendarSync.hydrateFocus` imports
the snapshots needed to show Settled Calendar items without opening EventKit on the main thread), never from titles.
Local items use their encoded persistent ID. Repeating events use the occurrence date; repeating reminders use the
current due occurrence, so the next one stays active. A changed or unavailable source never inherits a choice or
synthesizes content; an orphan choice can only be cleared ("Clear choice").

Every Settle and Unsettle is recorded in Activity (`LedgerAction.settled` / `restored`); Activity offers no Undo for
them (the toast Undo and Unsettle are the way back). An older `snoozed` record no longer hides anything.

## Tests

- `SettleGateTests`, `TodayFocusStoreTests` (with `tests/fixtures/settle-day-boundary.json`): the day gate, disk,
  version and failure handling, DST day boundaries.
- `TodayFocusIntegrationTests`: production adapters, hydration, rendering without native lookups, Delete All Data.
- `TodayFocusTests` (UI, `today-focus.json`, `remove-returned-to-today.json`): Settle / Unsettle / Undo, relaunch,
  the next-day release, and today-only Settle (a past and a future day show none).
