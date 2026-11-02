# Release reconstruction integration

This bounded tooling change starts at `ee0a478f6df481dfbe4b095599837bc1af1f1600`.
It owns `scripts/release/`, `fastlane/Fastfile`, `tests/release/` and this document.
No project, configuration, dependency, tool pin, signing or account changes belong
here. Read with architecture, baseline, adr-shortcut-discovery,
privacy-and-licenses and the release README.

## Identity and graph proof

`ios/Config/Today-Release.xcconfig` declares `PRODUCT_NAME=One`, executable module
`TodayApp`, ID `com.luworks.today` and `One.entitlements`. `ios/Package.swift` keeps
its `One` library target and the persistent models/intent identities it owns.
`TodayMock` uses executable module `TodayMockApp`; it is a separate developer
assembly, never a production archive target. `check_signing` now requires
`TodayApp` for the One product, preserving every existing manual-signing check.

`graph.py` reads the XcodeGen spec through YAML safe loading and evaluates only
`swift package dump-package` (no dependency resolution/build). It walks the
production target/product dependency closure, checks all three source identities,
extension embeds, Release scheme, entitlement paths and source/resource membership.
Source capabilities require App Group on all products and the existing read-only
HealthKit declaration on One. Unknown external/conditional edges fail closed for
review. This is source graph evidence, not generated-project equivalence or actual
archive linkage. Root still owns project generation and integrated build proof.
No source text, comments, UI strings or arbitrary binary strings are searched for
development module names. Membership uses exact path/module components. The
archive check separately inspects resource paths and linker object-file sections,
including static package members, and binds each map UUID to its actual executable.
Symbol/string sections are ignored. Maps are local evidence, not remote attestations.

## Current batch evidence boundary

Xcode 27.1 / 27A9275 emits real linker maps without UUID headers. Release simulator checks bind each map to its completed linker command, exact output path and architecture, and retain map/executable hashes and actual Mach-O UUIDs. They compare linked and embedded extension bytes and inspect object-file paths and app resources. Local Release and hosted main Release use this authority; neither establishes iPhoneOS archive or signing acceptance.

The archive validator's original UUID-header path has only synthetic coverage. An actual unsigned archive has not passed on this host; Xcode 27 map compatibility remains a blocker outside this batch's delivery claim. Do not describe archive-local/validate-local as validated release readiness. Signed archive/export/distribution and physical-device capabilities remain unverified and unauthorized. The optional offline scanner is unavailable, never a successful vulnerability scan.

## Three separate gates

- `preflight-local`: clean exact commit, frozen tools/locks and source graph only.
  JSON carries `readiness=unsigned_local`, `evidence=source_checks_only`,
  `signing=not_checked`, `distribution=not_authorized` even when ready.
- `validate-local`: adds actual archive inventory/receipt, three bundle IDs,
  versions/build numbers, embeds, extension points, iPhoneOS platform, executables,
  Mach-O device UUIDs and exact dSYM coverage, required privacy manifest, licenses,
  resource exclusion and executable-bound link maps. Evidence becomes
  `unsigned_archive_checks_only`. Signed capabilities/profile acceptance is absent.
- Existing `preflight`/`validate`/`beta`/`distribute`: require existing selected
  manual Apple Distribution signing. An unsigned receipt is explicitly rejected
  here. Archive and upload authorization tokens retain their original meanings;
  local readiness never grants them. No certificate/profile creation or rotation,
  account changes, provisioning downloads or uploads occur in local lanes.

`ios/Dependencies/Package.resolved` is the tracked SwiftPM authority. Generated
workspace copies, including ignored duplicates, are compared byte-for-byte with
it but are never required to be tracked. Missing authority or mismatched duplicate
blocks. Checkout/dependency-cache locks are outside this authority comparison.

## Root-owned execution

Only the root integration owner should run the following after integrating and
committing all owned changes, generating the project and preparing the locked
Ruby/Bundler/gems. Use an unused absolute archive path under canonical
`/Users/yuanlu/code/one-app/tests/results/` and the root's existing build cache.
No app build, archive, identity query or Apple service call ran in this subtask.

```sh
COMMIT=$(git rev-parse HEAD)
VERSION=0.1
BUILD=1
# Select a unique unused path; its parent must already exist outside the checkout.
ARCHIVE=/Users/yuanlu/code/one-app/tests/results/reconstruction/release-UNIQUE.xcarchive
DERIVED_DATA=/absolute/path/to/root-owned-existing-derived-data
python3 scripts/release/release.py preflight-local \
  --commit "$COMMIT" --version "$VERSION" --build "$BUILD"
bundle _4.0.16_ exec fastlane ios archive_local commit:"$COMMIT" \
  version:"$VERSION" build:"$BUILD" archive:"$ARCHIVE" derived_data:"$DERIVED_DATA"
python3 scripts/release/release.py validate-local \
  --commit "$COMMIT" --version "$VERSION" --build "$BUILD" --archive "$ARCHIVE"
```

`archive_local` runs `build_app` for Today/Release/generic iOS with dependency
resolution disabled, no IPA packaging and only the command-local signing override
`CODE_SIGNING_ALLOWED=NO`. It enables linker maps, retains raw maps at
`$ARCHIVE.linkmaps/`, copies One/TodayWidgets/ShareExtension maps into
`$ARCHIVE/ReleaseEvidence/`, then invokes `seal-local` and `validate-local`.
Logs are in `$ARCHIVE.logs/`; the completed result bundle is `$ARCHIVE.xcresult`.
The maps, receipt and archive contents are hashed together. `seal-local` is an
internal provenance writer, never an artifact check or bypass. Do not seal while
the archive or linker maps are live. For an independently root-run archive, retain
those same three maps under ReleaseEvidence before sealing; missing maps block.
No source/configuration signing setting is rewritten or globally disabled.

Current integration prerequisites are deliberately visible: Release source signing
is Automatic, so signed readiness remains blocked. Root must include an exact copy
of repository `LICENSE` as `One.app/LICENSE`, and `One.app/ThirdPartyNotices.txt`
with GeoNames attribution, `https://www.geonames.org`, the full
`https://creativecommons.org/licenses/by/4.0/` URL and an explicit transformation
notice containing `transform`. These resources are not currently wired by this
subtask; local archive validation must block until root supplies them. The app's
`PrivacyInfo.xcprivacy` must parse identically to the source manifest. Presence
checks do not certify the complete binary required-reason API inventory, SDK
privacy reports, license compliance or actual permissions. Linked SDK notices or
privacy manifests need separate review when adding external production packages.
The current evaluated production package closure is local only.

Record commands, exit statuses and evidence hashes through canonical
`tests/qa/journal.py` after the root run. Preserve the complete finished archive,
logs/maps/result bundle. Never archive a live result bundle. Real archive,
signed export/distribution, simulator journeys, installed Shortcuts, physical-device
upgrade and on-device capability checks remain root-owned acceptance gates.

Formal release `preflight` also reads the authoritative `tests/testing/groups.json` release pending gates. Three known failed extended `.all` accessibility audits and unverified physical-device acceptance currently block it with `release_acceptance_pending`, with the reasons visible in JSON. Root excluded broad accessibility remediation from PR101 merge acceptance; this does not confer formal release qualification. The unsigned source-only gate retains its separate limited meaning.


## Exact-main manual installation preflight

`./dev release preflight-local --commit <full-main-sha> --version <version>
--build <build> --for-install --main-run <push-run-id> --smoke-run <install-smoke-run-id>
--build-receipt <path>`
is the mandatory check immediately before an explicitly authorized manual
`xcrun devicectl device install app` of a new main build. It installs nothing.
Do not use a source-only preflight or a PID/install success as functional
acceptance. The guarded `./dev build Debug --device <UDID> --install --main-run <push-run-id> --smoke-run <install-smoke-run-id>` also performs this check under the build locks immediately before installation. Add `--allow-provisioning-updates` only with explicit authorization; the receipt and gate must match that choice.

Both runs must be in `.github/workflows/today.yml` for the exact SHA of current `main`:
the `push` run (merge gate) with `checks` and `today-required` successful, and an explicit
`workflow_dispatch` run with `lane=install-smoke` whose `install-smoke` job (the
Simulator usability leaves) succeeded. A green merge gate alone never authorizes an
install. After checking the local device build receipt, the checker rereads current
main and both runs. Offline, branch green, old main, a
failed/skipped/missing job or missing install smoke, a rerun in progress and source/product drift
block installation. An older accepted main is a rollback only when the user
explicitly authorizes that revision. Do not race an approved install against
another source change: use its explicit accepted SHA and rerun this read-only
preflight immediately before installation. CI never cancels a manual install.

The existing authorized device-build receipt (the `build-receipt.json` shape
used for prior manual phone deliveries) must retain `source`, `tree`, `exit: 0`,
`source_after`, empty `dirty_after`, `signing_changes: false`,
`automatic_provisioning_updates: false` by default (or `true` only with matching explicit authorization), absolute `app` ending in
`Debug-iphoneos/One.app`, `toolchain` and `product_identity`. Record the latter
two at the successful build's completion using `scripts.ci.main_gate.tool_identity()`
and `product_identity(app)`; they read Xcode/SDK metadata and only the three
App/Widget/Share executable/Info identities. A historical receipt without these
fields is not upgraded by assumption. Existing signed-build credentials and
signature checks remain a separate authorized device gate; unsigned/simulator
CI cannot prove device signatures or platform behavior. This mode needs no
Ruby/Fastlane archive setup and does not change any signing settings.

The current phone stays on user-accepted rollback9043647. No candidate install
is authorized by implementing this check. After a future authorized install,
actual Today/Calendar/Reminders/Chat-return navigation must still be observed
(user-assisted when tools cannot tap); Health/FM/AlarmKit require their own real
acceptance. PR120's product fix and populated fixture must land before the main
smoke can certify the known freeze path. Missing fixtures block, never skip.
