# Today CI

One workflow, `.github/workflows/today.yml`. The repo has no UI tests (owner decisions, 2026-11-08 and 2026-11-09). The merge gate runs no simulator. The install-smoke lane
(a Simulator usability run before phone installs) was removed on 2026-11-02 by the owner's
decision; a phone install now needs the green merge gate on the exact `main` SHA.

## Merge gate (every pull request, merge group and push to `main`)

Two parallel hosted jobs, no simulator:

| Job | What it runs |
| --- | --- |
| `checks` | `./dev format --check`, `./dev lint`, `./dev test helpers`, `./dev test unit` (all logic tests on the macOS host) |
| `today-required` | `python3 scripts/ci/job.py --build`: one `TodayCI` build-for-testing (App, Widget, Share, Mock and the iOS unit and snapshot test bundles) and an identity check of `One.app`, `TodayWidgets.appex` and `ShareExtension.appex` |

On a pull request `today-required` restores the DerivedData of the newest green `main` and builds
incrementally (`scripts/ci/mtimes.py` makes each file's modification time a function of its
content, so only changed files recompile). Pushes to `main` and merge groups build clean; `main`
then saves the cache, so a problem a warm cache could mask turns `main` red. A change to
`ios/project.yml`, `ios/Config/`, `ios/Package.swift`, the package lock or the runner image picks a
different cache and builds cold. `xcodebuild` runs in a minimal environment (`HOME`, `PATH`,
`DEVELOPER_DIR`) because per-job runner variables would otherwise invalidate SwiftPM's manifest
cache (saved with DerivedData) and the link tasks.

Pushes to `main` and merge groups also upload `TodayMock-sim-<sha>` (7 days): the arm64 simulator `TodayMock.app`,
zipped. Simulator only (never a phone, never next to `One.app`); launch it with `-uiTesting -dataset <path>`.

On a pull request that only changes prose, images or the prototype (`*.md`, `docs/**` images
and HTML/CSS, `src/**`, `backend/luna/**`, which has its own workflow), `scripts/ci/scope.py`
makes both jobs skip their steps and report green under the same names (~20 s instead of
~3 min). On a pull request that changes only Swift in modules no SwiftPM test target depends on
(`ios/Sources/Features/`, `TodayDesignSystem`, `TodayPlannerUI`, `TodayShell`, except a file a test
reads), `checks` runs format and lint and skips `helpers`, `qa` and `unit`; `today-required`
still compiles it. `tests/ci/test_scope.py` fails if a test target starts to depend on one of those
modules. Any other file, a list of 300+ files or an API error runs everything. Pushes to
`main` always run everything, so a failure there is visible on `main`.

Merge elapsed time is the time for both jobs to turn green. Measured from push on real pull
requests on 2026-11-08: a one-line view edit 53–84 s (median 62, n=5), a docs change 17 s, a change
to shared or core code about 130 s. A green merge gate does **not** mean the app opens or stays
responsive.

## Release build on main

`.github/workflows/today-release.yml` runs on every push to `main`: `job.py --release` compiles
the app, widget and share extension for a device in Release, unsigned. A red run is visible on
the commit; it is a separate workflow so it does not gate a Debug phone install. Entitlements and
Release permission prompts are checked statically by `tests/ci/test_app_config.py`.

## Phone install gate

`./dev release preflight-local --for-install --commit <main-sha> [--main-run <push-run>]
--build-receipt <path> …` installs nothing; `./dev build Debug --device <UDID> --install` runs
the same check right before `devicectl` installs. An omitted `--main-run` is the newest `main`
push run on the SHA. It blocks unless all of the following hold:

- `<main-sha>` is current `main` (read before and after the other checks);
- that push run of `today.yml` is completed and successful, with `checks` and
  `today-required` successful, and its attempt did not change while the gate was reading;
- the local checkout is exactly `<main-sha>` with no changes;
- the local signed device build receipt matches the SHA, tree, toolchain and product
  identities, and its provisioning-updates choice matches `--allow-provisioning-updates`
  ([release integration](release-integration.md)).

CI never installs a phone or calls the Luna Worker. A CI pass does not establish physical
Health, hosted AI or AlarmKit behaviour.

## Manual full coverage

**Run workflow** (`workflow_dispatch`, no inputs) runs `full`: `./dev test unit`, `ios-unit`, `integration` and `snapshot`, one step each, in one job.
Not part of either gate: path-based risk selection, wrapper receipts,
provenance and secret scans, the main acceptance artifact and the routine full suites. They
were removed in PR #125.
