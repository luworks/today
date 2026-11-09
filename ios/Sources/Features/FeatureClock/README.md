# FeatureClock integration contract

Extracted from clean base `a33cc1d1696bd67d64a1430da888c315e8ed40dd`.
The real World Clock, city picker and Stopwatch implementations live here; the app-owned originals are removed.
The integration owner must link this directory as the `FeatureClock` product and update app imports/source membership.
No manifest, configuration or app assembly changes are included in this lane.

## Required composition

See `docs/engineering/clock-health-consumers-integration.md` for the exact consumer signatures and development seeds.

`WorldClockView(store:now:showUndo:)`, `CityPicker(store:now:)` and `StopwatchView(model:)` require explicit root-owned values. Reuse the same store/model for the Clock tab, standalone presentations and city picker. Root loads the bundled `cities.json` into `CityDatabase`; the feature no longer owns a bundle-backed singleton.

`WorldClockStore(database:defaults:homeZoneIdentifier:homeCity:initialKeys:)` and `StopwatchModel(defaults:now:initialState:initialPage:)` load their existing preference keys when explicit initial values are absent. Development composition selects launch-argument scenarios; feature models do not read process arguments or clear preferences.

Scrub acceleration, inertia, date picking and the pill text are plain Swift in `TodayCore/WorldClockScrub.swift`; `WorldClockView` only feeds it touches and display frames. The existing card/overlap/city-reorder and stopwatch face/lap algorithms and accessibility identifiers remain in their real views. Stopwatch actions, rendered faces and current lap all use the injected clock. Deleting cities retains the caller's actual Undo action.
