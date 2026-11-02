# Historical axe preview workflow (development only)

The linked-module reconstruction supersedes the executable commands below. The former One.xcodeproj/ios/One preview entry is archival, not a supported current workflow. Use ./dev ui open, ./dev ui capture or ./dev ui gallery against the real Workbench registry. The axe accelerator has not been revalidated against the linked graph and is outside this frozen batch's acceptance claim. Do not run the historical commands as current instructions.

## Adopted scope

Today adopts axe as a development-only fast visual feedback path for supported
pages: layout, text and color tweaks, plus agent screenshot inspection. Prefer it
when suitable; if preview support fails, fall back to the full Simulator. Do not
restructure production logic solely to accommodate axe.

The static gallery does not replace interactive, data or system-integration
acceptance. Functional verification still follows AGENTS.md's proportionate
checks. Coordinate actual shared-resource use directly with the performance owner.
Ordinary-file and structural edits, World Clock watch and 20-screen concurrency
remain unverified here; the known Reminders watch failure and all existing
evidence boundaries below remain in effect. No project-wide speedup is claimed.

## Start the workflow

Run from any directory after obtaining the host's heavy-work window:

```sh
python3 /path/to/worktree/scripts/swiftui_preview.py --budget 540 --port 49731
```

Use `--plan` for a read-only ownership/command listing. `--watch world` or
`--watch reminders` selects another individual screen (see the known Reminders
watch limitation below). `--once` captures the
three-screen report and shuts down. Port `0` (the default) asks the OS for a free
loopback port. The command prints the gallery URL and persistent evidence path.
Ctrl-C or SIGTERM stops the session; its budget includes download, build, render,
watch and server time. Keep a cleanup allowance in the coordinator's window.

The first run downloads checksummed **axe v0.0.14** and **idb 1.7.6** from their
official GitHub releases into `.preview-tools/`. No remote setup script or
Homebrew install is executed. Apple's selected Xcode must already be installed;
the script does not change Xcode selection, signing or user settings. axe may
populate its own versioned parser/index-reader cache from its official release.
Licenses: axe MIT; idb MIT. Both upstream origins, versions and checksums are in
the script. Source-verified alternatives are in
[the tool comparison](research/swiftui-preview-tools.md).

## Architecture

The three `#Preview` declarations render the existing production
`RemindersView`, `WorldClockView` and `HealthMetricDetail`. Reminders uses a
throwaway in-memory SwiftData container; World Clock uses a separate store
instance with versioned city identifiers; Health uses the existing
`HealthSampleSeries` algorithm at a fixed date. Fixture locations are catalogued
in `tests/fixtures/README.md`. There is no HTML implementation of these screens.

The DEBUG-only axe bootstrap recognizes `AXE_PREVIEW_SOCKET_PATH`, leaves a blank
host for axe's injected preview, and bypasses `OneStore`, normal HomeView startup
and background-refresh registration. The Reminders preview bypasses its
first-run sync request. The app's model/schema and Activity database are unchanged.
axe stages a separate `axe.com.luworks.today` app; it does not replace the original
simulator app. There is no added Swift package, linked framework or app resource.

`axe preview report --concurrency 1 --device <owned UDID>` captures three screens
sequentially. The HTML report remains available intact; a thin local viewer adds
one watched screen whose actual simulator PNG is refreshed after axe reports a
successful render. The browser gallery is **static captures**, not touch-forwarded
SwiftUI. For interaction use the owned simulator's T3 Device panel or the upstream
axe editor extension. The watched view requires no navigation through HomeView.

axe's body edits can compile and inject replacement thunks; stored-property and
other structural edits rebuild. Initial full builds, reuse-build startup and
screenshot polling must not be called hot reload. `--reuse-build` is used only
immediately after this command's successful report build. A failed watch leaves
the last frame on disk; `watch.log` is authoritative. Stop and rerun after a broken
build or unsupported structural change; do not present a stale PNG as success.

## Ownership and cleanup

Each resolved worktree project path hashes to its own lane. That lane owns:

- `Today-Preview-POC-<hash>` and the exact persisted UDID;
- axe's `~/Library/Caches/axe/preview-<hash>/build` DerivedData;
- a nonblocking advisory process lock in the primary checkout's results folder;
- its child process groups, a loopback HTTP port, and timestamped outputs.

One command per lane is allowed. Separate worktrees have distinct simulator and
DerivedData lanes; this is collision isolation, not permission to run multiple
heavy lanes. Coordinate host resources before starting. Share the same lane/cache
for a short batch whenever possible. Do not run axe independently against the
same simulator while this script owns it. Report concurrency must remain **1**:
axe's parallel report path ignores `--device` and allocates pooled devices.
Sequential report passes the specified UDID to `ResolveAxeSimulator`, whose
explicit-UDID branch errors if it cannot find that exact device.

Shutdown stops the report/watch process groups, closes the server and shuts down
only the owned simulator. It retains the simulator and incremental build cache
for reuse; no branch, data or evidence deletion is part of cleanup. After abnormal
host termination, read `ownership.json` and the lane's `device.json`, check process
identity, stop only that lane's processes, and `xcrun simctl shutdown <owned UDID>`.

Runtime data is stored under the primary checkout's
`tests/results/swiftui-preview/<hash>/<session>/`, including `ownership.json`,
source hashes, command logs, complete xcodebuild output/stage durations, report
assets and `timings.jsonl`. Files are indexed by path and SHA-256 through
`tests/qa/journal.py` in the separate QA SQLite journal. App user Activity data is
never the QA journal. Keep evidence after closing/removing a worktree.

## Measurement and acceptance

Local measurements and visual evidence are recorded in the companion QA summary.
Only measured steps count as accepted. This POC does not measure 20 simultaneous
screens, production app performance, real-device sensors or system integrations.
Snapshot appearance does not prove gestures, persistence or accessibility journeys.

The default watched screen is Health detail. `--strict` makes axe fail on an
unsupported replacement instead of silently disabling hot reload. In v0.0.14,
watching `RemindersView.swift` currently fails because its generated replacement
for `SmartListLayout.reorderVisible` omits `mutating`; report capture still works.
The POC deliberately retains this diagnostic instead of restructuring production
logic solely to accommodate the preview parser.

For ordinary-app verification, add `--verify-release`. This is a distinct Release
build with no axe compiler flags, limited to the owned simulator architecture and
`-jobs 2`. It verifies Release compile inputs exclude `PreviewFixtures.swift`, and
checks the built executable for fixture/bootstrap symbols and the axe environment
marker. This proves build/exclusion, not a physical-device or Release UI journey.

A focused rerun can pass `--reuse-report <previous-run-directory>` to retain the
already accepted static captures when every Swift source hash still matches.
This mode does not refresh the static catalog and is not a warm full-gallery
measurement. Regenerate the report after changes to non-Swift resources.

To reproduce the recorded source-edit experiment after `watch.captured` appears:

```sh
python3 scripts/measure_preview_edits.py /path/to/current-run
```

It changes the production Health navigation title three times, waits for each axe
reload and actual PNG, then restores the original bytes and captures the restored
screen. Run it within the same host window and stop after a concrete failure.
Inspect `edit-1.png`, `edit-2.png`, `edit-3.png` and `edit-reverted.png`; frame hashes
alone cannot prove that the expected title became visible. The measurements cover
edit → axe render event → a 0.5-second settling delay → PNG capture, plus up to one
second for browser polling; they do not claim arbitrary Swift edits are supported.
