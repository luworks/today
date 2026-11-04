# Live sample isolation (#316)

Baseline: clean platform worktree at 79b8922bc, safely fast-forwarded to origin/main 6c5a9418132ba5affa44c516d8f1e7895351be4a before edits.

## Source findings

- `HomeView.bootstrap` used its absent development callback as a signal to call `SampleData.insertIfNeeded`. Live has no callback, so this inserted six events and six reminders independent of Calendar/Reminders authorization, and `ListActions.ensureLists` derived Work/Home lists.
- `OneStore.session` itself does not seed planner records. Its recovery and restore ordering are untouched. App Intents use this same store.
- Historical SampleData creates random UUIDs and relative dates, with no per-record provenance, original snapshot, or modification marker. `today.sampleData.v1` proves only that seeding was attempted, not ownership of any current row. No automatic historical cleanup is safe. Titles, list names and dates must never classify user data for deletion. Existing samples can remain; this change does not claim to clear a user's database or remove anything from Apple sources.
- Health uses HealthKitSource in Live; weather is empty in Live. World Clock's home is the device time zone, a useful product default, not a fictional saved city. Timer presets are actions, not fabricated running timers or user history. These defaults remain.
- Calendar/Reminders first-run permission and real-source import paths remain unchanged. `RemindersSync` gates work on authorization and links imported records by external ID. No sample fallback is needed on denial, unavailable services or offline startup.

## Change and evidence

SampleData now compiles only under TODAY_MOCK in Development/Support. Live shell has no sample call. Share/reminder/system-calendar debug injections use composition arguments (empty for Live), retaining explicit Mock fixtures. No migration, backup write, restore change, signing, installation or phone access occurs.

`./dev test unit --only LiveSeedBoundaryTests`: passed, 1 test, 39.6 seconds. Durable log: `/Users/yuanlu/code/today/tests/results/devtools/logs/5c80e3983e10470388ff15c699823bf9.log`.

Added an iOS integration test checking zero tasks/events/alarms/lists/chats after two openings of a persistent empty store through the remaining list-bootstrap operation. Execution is left to CI. The source boundary contract protects the actual shell call site and the Mock-only compilation boundary.

Not verified locally: simulator permission prompts/empty-state navigation, granted EventKit source import and deduplication, physical device behavior. Historical owner-phone rows have not been inspected or classified. No user database is claimed cleaned.
