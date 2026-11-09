# Native visual tests

## Integration contract

This lane starts at `3b3a9bfaed35fbbfa6fc425b13690c2966cfe165`. It owns only
`ios/TodaySnapshotTests/` and this document.
Package/project configuration, the shared scene registry and command adapters remain integration-owned.
At this revision the legacy `ios/Package.swift` does not include these tests or extracted feature products.
A successful parse is not target compilation or test execution.

Integration must pin the public package
`https://github.com/pointfreeco/swift-snapshot-testing.git` with `exact: "1.19.6"`.
The observed tag resolves to `28e5de025e3fd98991791bfbf83023ab3708da03` (2026-10-18).
Only the iOS-hosted `TodaySnapshotTests` test target may depend on its `SnapshotTesting` product.
Link `FeatureHealth`, `FeatureClock`, `TodayCore` and `TodayDesignSystem` to that target;
never add SnapshotTesting to app/extension/Release production dependencies.
Use the integrated target/scheme names discovered from the generated project rather than inventing them.

Primary source references at the exact pin:

- [SwiftUI image strategy](https://github.com/pointfreeco/swift-snapshot-testing/blob/1.19.6/Sources/SnapshotTesting/Snapshotting/SwiftUIView.swift)
- [View controller image strategy](https://github.com/pointfreeco/swift-snapshot-testing/blob/1.19.6/Sources/SnapshotTesting/Snapshotting/UIViewController.swift)
- [Recording semantics](https://github.com/pointfreeco/swift-snapshot-testing/blob/1.19.6/Sources/SnapshotTesting/AssertSnapshot.swift)

The library's default is `.missing`, which writes absent references. These tests always pass an explicit
`.never`, except when `TODAY_RECORD_SNAPSHOTS=1` and the `CI` environment key is absent.
Any presence of `CI` (including an empty value or `false`) forces `.never`.
`SNAPSHOT_TESTING_RECORD` and the deprecated global recording switch cannot override that explicit argument.
Recording intentionally reports test failures asking for a comparison rerun; recording is not acceptance.

## Deterministic native coverage

`NativeSnapshotTests` imports exported production views directly, without `@testable`, copied screens,
private fake screen implementations or HTML render substitutes:

- `testHealthStepsLight`: real `FeatureHealth.HealthMetricDetail`, 35 inline fictional daily samples.
- `testHealthEmptyDarkLargeType`: real empty detail, dark and accessibility3.
- `testStopwatchStoppedAnalog`: real `FeatureClock.StopwatchView` with injected `StopwatchModel`,
  5.75-second current lap and three finished laps, isolated defaults.
- `testStopwatchRunningDigitalDark`: real running model whose injected clock freezes elapsed time at 5.75 seconds.
- `testNativePillSwitcherLargeType`: native `TodayDesignSystem.PillSwitcher`, selected 30 Days, accessibility3.
- `testHealthDataPerturbationChangesPixels`: captures populated detail twice and empty detail once;
  asserts identical frozen inputs match exactly and removing samples produces a real image diff.
  It uses SnapshotTesting's image diffing pipeline, writes no baselines and must be executed by integration.

Versioned small inline fixtures live with these tests and require no external dataset file.
No required input is held only in `/tmp`.

Snapshot host launch arguments must include `-AppleLocale en_US_POSIX -AppleLanguages (en)`;
setup rejects another process locale because existing production formatters consult `Locale.current`.
The harness fixes UTC (restoring the prior process default after each test), a Gregorian calendar,
first weekday Sunday, date `2026-10-18 15:41 UTC`, metric units, explicit sample data, fresh UUID-named
UserDefaults suites, English POSIX locale, left-to-right layout, light/dark appearance and exact type category.
Rendering uses a 393 × 852 pt phone container, 3× display scale, safe area 59 pt top / 34 pt bottom,
compact horizontal and regular vertical traits and disabled SwiftUI transactions.
A mounted host waits 200 ms for the real Stopwatch pager's initial 50 ms scroll task before capture.
This settling choice has not yet been validated at runtime; inspect the analog/digital pages in recorded images.
Tests change process timezone and must run serially within their test host.

Both pixel precision and perceptual precision are **1**. Freeze one simulator/runtime/Xcode combination
for recording and comparison and preserve its actual identifiers in the evidence. Do not lower precision
to hide a failing test. Diagnose font, scale, chart layout, safe area, locale or pager settling differences first.
The repeated-input perturbation assertion is also a determinism check, not just proof that any two images differ.

## Shared scene registry handoff

The integration-owned full scene registry is pending at this base. These focused production-view tests
are component/feature coverage, not complete Today/Calendar/Reminders/Clock scene acceptance.
Once the registry is integrated, add tests in this directory importing its actual public entries and renderer;
reuse its scene IDs, dependency construction and deterministic configuration for Workbench and snapshots.
Do not introduce a second scene enumeration or replacement screen catalog in the test target.
Keep the focused perturbation check against a real feature even after broader registered coverage is added.

## Baseline lifecycle and pending acceptance

References belong in version control under `ios/TodaySnapshotTests/__Snapshots__/NativeSnapshotTests/`.
SnapshotTesting derives PNG filenames from the method and explicit variant name.
The baseline folder's README is a pending-state marker, not an image or successful comparison.

| State | Required evidence | Current state |
| --- | --- | --- |
| Missing | No reference PNG exists; strict comparison fails without writing one | All five variants |
| Recorded | Root runs real iOS capture locally with explicit recording; retains PNGs and environment/log evidence | Pending |
| Reviewed | A human/reviewer inspects actual PNGs, checks intended state/layout, and records reviewer, SHA, environment and image hashes | Pending |
| Compared | Recording off; all selected comparisons and the perturbation test actually pass against reviewed references | Pending |

The integration root owns initial rendering, baseline recording and review coordination.
Do not create illustrative PNGs or reuse unrelated preview images as baselines.
After recording, turn the flag off and run the focused tests once. Missing baselines always remain failures in CI.
Set `SNAPSHOT_ARTIFACTS` to a durable run subdirectory so reference/actual/diff artifacts can be retained;
retain complete xcresult and source/environment metadata through the canonical QA journal.
Use the existing E2E runner's durable output and archive only after a completed command with its actual exit status.

## Evidence for this implementation lane

Source/SDK declaration inspection and Swift syntax checks only; see the canonical journal session
`today-reconstruction-visual-tests-20261018` under the primary checkout's `tests/results/`.
No package resolution, Xcode build, simulator, image capture, baseline recording/comparison, logic suite,
UI audit or physical-device run was authorized or performed in this lane.
