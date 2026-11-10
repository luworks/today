# Today timeline scroll and reading-position work (#375)

Baseline: clean delegated branch `79b8922bc`, fast-forwarded before app edits to
`4f6fbd64b6113e7e16e65842d557507eb98f2e70` (`origin/main`). Other worktrees were untouched.

## Source findings and changes

- The hold recognizer required **every descendant recognizer** to wait. Scope the failure
  relationship to the List pan and UIKit long presses; row swipes and controls stay independent.
  The 350 ms lift, 300 ms menu handoff and movement thresholds remain unchanged.
- UIKit can reset a recognizer without entering its private failure helper. Reset now clears
  any lifted preview; dismantling also invalidates the display link, removes the recognizer
  and ends the local drag model. This writes no source data.
- `onAppear` unconditionally rearmed Now centering. Arm once per viewed day; same-day
  reappearance cannot revive a dismissed request. Native tracking/interacting/decelerating
  phases also dismiss the hold, independently of the custom recognizer's touch delivery.
- Explicit Today taps now carry a separate request, including when the selected date is
  already today. First entry and changing the viewed day retain their navigation behavior.
- Local timeline IDs use persistent model IDs plus occurrence dates instead of object
  addresses, so refetched instances can retain List identity.

These are source-level defects/risks, **not a reproduced causal attribution** of the owner's
symptoms. No card redesign, blanket animation suppression or interaction removal was used.

## Evidence and limits

- `./dev ui prepare --runtime com.apple.CoreSimulator.SimRuntime.iOS-27-2` built the
  unmodified baseline TodayMock successfully (94.206 s) and installed it on the exclusively
  created `Today-Dev-d85dd7b7` / `FB12C88C-B350-439E-9560-B9A26F3D9E9B`.
- Baseline native build log:
  `/Users/yuanlu/code/today/tests/results/devtools/logs/03d2fdacf83d46debbed6a663dbbb4d1.log`.
- Device-panel `open com.luworks.today` succeeded with `-uiTesting -uiTestingNow 09:41`
  and the versioned `tests/fixtures/today-dense-scroll.json` (36 fictional mixed rows).
- Both `device_screenshot` attempts failed with:
  `The device hub could not complete the request. Call device_list to check the device state, and device_open if it needs to be reopened.`
  After the first failure, `device_list` confirmed the owned device booted/open; the second
  attempt returned the same error. UI work stopped as instructed. Only the owned simulator
  was subsequently closed and shut down through `device_close`.
- Raw blocker/launch evidence and QA journal entries are retained in the primary checkout's
  `tests/results/timeline-scroll-375/` and `tests/results/activity.sqlite`.
- No observable scroll stall or mutation jump was reproduced. There are **no** before/after
  visible-row frames, offsets, gesture latency measurements or recordings. Actual delete,
  Settle, completion, Undo/Unsettle, last-card-row removal, context-menu and hold-drag behavior
  remain unverified. Physical-device behavior is UNKNOWN; no phone operation occurred.
- Logic regressions cover dismissed navigation surviving list shrink/growth and same-day
  reappearance, explicit Today rearming, day navigation, and surviving card-row identity after
  removing the last item. Adapter regressions cover install without launch/capture and invalid
  runtime rejection. Required CI runs these through `./dev`; no XCTest UI suite was restored.
- Local Swift formatting passed. Final source compilation and logic results belong to the PR's
  exact-head `checks` / `today-required` runs; baseline build is not final-source evidence.

Issue #375 remains open for the missing observable acceptance. A green merge gate has no
simulator coverage and cannot establish these UI acceptance conditions.
