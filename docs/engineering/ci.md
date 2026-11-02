# Today CI

One workflow, `.github/workflows/today.yml`. Merging and installing on a phone are separate gates
(Yuan's choice on 2026-10-20: fast free merges, Simulator usability before any install).

## Merge gate (every pull request, merge group and push to `main`)

Two parallel hosted jobs, no simulator:

| Job | What it runs |
| --- | --- |
| `checks` | `./dev format --check`, `./dev lint`, `./dev test helpers`, `./dev test unit` (all logic tests on the macOS host) |
| `today-required` | `python3 scripts/ci/smoke.py --build-only`: one `TodayCI` build-for-testing (App, Widget, Share, Mock and every test bundle) and an identity check of `One.app`, `TodayWidgets.appex` and `ShareExtension.appex` |

`today-required` also uploads `TodayMock-sim-<sha>` (7 days): the arm64 simulator `TodayMock.app`,
zipped. Simulator only (never a phone, never next to `One.app`); launch it with `-uiTesting -dataset <path>`.

On a pull request that only changes prose, images or the prototype (`*.md`, `docs/**` images
and HTML/CSS, `src/**`, `backend/luna/**`, which has its own workflow), `scripts/ci/scope.py`
makes both jobs skip their steps and report green under the same names (~20 s instead of
~3 min). Any other file, a list of 300+ files or an API error runs everything. Pushes to
`main` always run everything.

Merge elapsed time is the time for both jobs to turn green. The measured numbers are in
[the measurements](../qa/ci-under-five-minutes-20261020.md). A green merge gate does **not**
mean the app opens or stays responsive.

## Install gate (automatic on every `main` push, required before any phone installation)

Every push to `main` also runs the `install-smoke` job, in parallel with the merge gate and
in the same run, so a green smoke for the exact `main` SHA is normally ready ~12 min after the
merge with no manual step. It is not a merge gate: pull requests never run it, and a smoke
failure only turns the `main` push run red. It runs on docs-only pushes too, because the
install gate needs the exact SHA (hosted macOS minutes are free on this public repo). A newer
push cancels the older run, smoke included; only current `main` is installable anyway. After a
flake, **Re-run failed jobs** on the push run. A manual run is still possible:
**Actions → Today CI → Run workflow** on `main` with `lane = install-smoke` (or
`gh workflow run today.yml --ref main -f lane=install-smoke`). The `install-smoke` job runs
`scripts/ci/smoke.py`: the same build, then one simulator booted after the build and one
`test-without-building` run of:

- `PlannerSessionTests/populatedDayAgendaRenderNeverOpensTheNativeStore`. The populated Day
  agenda renders with connected Calendar and Reminders sync and never opens EventKit on the
  main thread (the PR120 freeze).
- `TodayReminderCompletionTests/testPreconnectedImportedTimelineStaysResponsive`. The
  script grants Reminders and Calendar with `simctl privacy`. The app launches populated with
  a real EventKit event and both syncs on, opens and cancels the editor within 10 s, taps
  all four tabs, and types an unsent Chat draft. The Settings-connection variant stays in the
  full UI suite.

- `SmokeScreenshotTests/testTabsAndChatInBothModes`. TodayMock on the test dataset, Light then
  Dark: Today, Calendar, Reminders, Clock, Chat with a typed unsent draft, and Today after Close.
  The 12 PNGs are uploaded as `smoke-screens-<sha>` (7 days, also on failure). Fetch them on a
  host without Xcode:

  ```sh
  sha=$(git rev-parse origin/main)
  run=$(gh run list -w today.yml -e push -c "$sha" -L 1 --json databaseId -q '.[0].databaseId')
  gh run download "$run" -n "smoke-screens-$sha" -D "tests/results/ci-screens/$sha"
  ```

The run fails unless exactly those three leaves are in the completed xcresult and all of them
passed. The xcresult is uploaded only on failure. Simulator devices are cached after their
first boot for each runner image (~1.3 GB, synthetic data only). A simulator booting during
the build made the build 4–5× slower on the 3-CPU runner, so boot always follows the build.
The smoke job takes ~10–12 min (median 11.6 min, 2026-11-02).

`./dev release preflight-local --for-install --commit <main-sha> [--main-run <push-run>]
[--smoke-run <run>] --build-receipt <path> …` installs nothing. Omitted run IDs are looked up
for the SHA: the newest `main` push run, and as the smoke that same run, or a green
`lane=install-smoke` dispatch run on the SHA if the push run's smoke did not pass. It blocks
unless `<main-sha>` is current `main` and all of the following hold:

- the push run has `checks` and `today-required` successful;
- that push run, or a dispatch run on the same SHA, has `install-smoke` successful;
- the local signed device build receipt matches the SHA
  ([release integration](release-integration.md)).

CI never installs a phone or calls the Luna Worker. A CI pass does not establish physical
Health, hosted AI or AlarmKit behaviour.

## Manual full coverage

`lane = full` runs `./dev test release --full` (logic, iOS unit, integration 23, snapshots 6,
full UI) in one job. Not part of either gate: path-based risk selection, wrapper receipts,
provenance and secret scans, the main acceptance artifact and the routine full suites. They
were removed in PR #125.
