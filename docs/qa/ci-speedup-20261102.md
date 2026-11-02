# CI speed-up, 2026-11-02

Owner's request: fully automatic CI, no pointless work, faster. Measured on hosted `xcode-27`
runners (3 CPU, public repo, free minutes) over the last 80 `today.yml` runs before the change
(2026-11-02 01:59–18:40 UTC). Times are job times (start → completion); runner queue was a
median 2–3 s in every lane.

## Before → after

| Lane | Before: median / p90 | Before: failures | After |
| --- | --- | --- | --- |
| PR gate, `checks` | 2.2 / 2.7 min | 4/32, all real (format 1, helpers 1, unit 2) | unchanged for code PRs; docs-only PRs skip (see below) |
| PR gate, `today-required` | 3.0 / 4.4 min | 3/32, all real compile errors | same |
| Push gate, `checks` / `today-required` | 2.4 / 2.7 and 3.2 / 4.7 min | 0 (4–5 cancelled by newer pushes) | unchanged |
| install-smoke | 11.6 / 14.8 min, **started by hand** after each merge | 10/29 (34%) | runs by itself in every `main` push run: first run 11.7 min, green, run 41505221613 (#300) |
| Install readiness after a merge | merge + a person dispatching + 11.6 min + 34% reruns | | merge + ~12 min, no human step; `./dev build Debug --device <UDID> --install` finds the runs |
| Docs/prototype-only PR gate (23% of `main` commits) | ~3 min | | `checks` 17 s, `today-required` 17 s, 31 s from push to green (#301, measured on #302) |

## Where install-smoke's 11.6 min go (median warm run)

| Phase | Seconds |
| --- | --- |
| Set-up, checkout, SPM cache, simulator-device cache restore (hit every run) | ~35 |
| `xcodegen` + generate | ~9 |
| `build-for-testing` (same build as `today-required`) | 120–270 |
| `simctl bootstatus -b` | ~30 |
| first `simctl install` after boot (device settling) | 60–130 |
| `test-without-building`: test host launch ~60, then tests | ~190 |
| Tests: `populatedDayAgenda…` 3–5, `testTabsAndChatInBothModes` 87–264, `testPreconnectedImportedTimeline…` 36–51 | |
| Post-job | 10–30 |

## Flakes

All 10 smoke failures were `testPreconnectedImportedTimelineStaysResponsive`:
- 8 were the `apple:` waiter timeout (Reminders/Calendar granted before the test host was
  installed). This is fixed by #298; none since.
- 2 were the `response_s < 10` editor open+cancel limit: 24.6 s (a real stall, `cancel_response_s`
  21 s) and 10.06 s (marginal). Across 19 logged runs: normal 4.6–7.1 s, one 9.5 s.

## Left, ranked by expected saving

1. Self-hosted runner on the Mac for install-smoke: −4 to −7 min (warm build, booted simulator,
   no cache restore). Risk: shares the owner's machine and simulators.
2. Decide the 10 s editor-response limit (the remaining flake source, ~1 in 10 runs). Raising
   it weakens the PR120 guard, so it is the owner's decision; alternatively measure in-app time
   instead of XCUITest round-trips (~2.4 s of each leg is XCUITest).
3. `-jobs 3` instead of `-jobs 2` on the 3-CPU runner for both builds: maybe −20 to −40 s;
   needs ≥5 runs to beat the 120–270 s build variance.
4. Shorten `testTabsAndChatInBothModes` (87–264 s, the largest test): fewer relaunches between
   Light and Dark. Touches a pinned smoke leaf, so it needs the gate and docs updated together.
5. Not worth it now: sharding (3 tests, each shard rebuilds ~200 s), reusing `today-required`'s
   products in the smoke (`needs:` serializes, about break-even), DerivedData cache (fresh
   checkout mtimes force a full rebuild), dropping `full` (1 run in 80, manual only, costs nothing
   unless dispatched).
