# Guarded local release tooling

This continuation owns only `scripts/release/`, `tests/release/`,
`fastlane/Fastfile` and `docs/engineering/release-integration.md`. Existing Gemfile
and tool pins are unchanged. Integration owns generation, package/configuration, production
sources and `dev`. No signing settings, identities, profiles or accounts are created
or changed here. The generated entry point is `ios/Today.xcodeproj`, shared scheme
`Today`, Release, generic iOS device. Compatibility products remain `One.app`,
`TodayWidgets.appex`, `ShareExtension.appex`, executable module `TodayApp`,
model/intent module `One`, bundle identifiers
`com.luworks.today`, `.widgets`, `.share`, app group `group.com.luworks.today`.

## Tool installation and locks

Use a separately managed Ruby **3.3.12**, Bundler **4.0.16**, and Xcode **27.1 / 27A9275**.
The Xcode version was observed on this host; changing it requires an intentional
reviewed update to `tool-lock.json`. No installer or update runs during preflight.
On a separately authorized setup, install Bundler 4.0.16 into that Ruby, then:

```sh
BUNDLE_FROZEN=true bundle _4.0.16_ install
```

`Gemfile` pins Fastlane **2.241.1** exactly. `Gemfile.lock` was actually generated
by Bundler 4.0.16 on Ruby 3.3.12 with `bundle lock`, including RubyGems checksums,
on arm64-darwin-25. It was not manually resolved. The lock is not proof that this
checkout has installed all gems. Preflight requires `bundle check` and verifies
the installed locked Fastlane version. The authoritative `ios/Dependencies/Package.resolved` is tracked and hashed;
generated workspace copies must match exactly without being tracked; package updates/resolution are disabled for builds.
There is no fallback to system/global Fastlane or to an older gem version.

Official research checked 2026-10-19 UTC:

- [Fastlane setup](https://docs.fastlane.tools/getting-started/ios/setup/): Bundler
  and `bundle exec`; Ruby >=3.2, Ruby >=3.3 preferred.
- [RubyGems Fastlane registry](https://rubygems.org/api/v1/gems/fastlane.json):
  stable 2.241.1, published 2026-10-15; MIT; exact gem SHA-256
  `e8e97f3274d678c74d9e473b98d202621262c40dfce2b43b7a05afde7caa2ea5`.
- [build_app](https://docs.fastlane.tools/actions/build_app/): archive/export
  separation and package-resolution controls.
- [upload_to_testflight](https://docs.fastlane.tools/actions/upload_to_testflight/):
  `skip_submission: true` uploads without distributing to testers.
- [Apple requirement language](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html):
  Apple trust anchor, distribution certificate common name and team requirements.

A temporary extracted Homebrew Ruby bottle was used only to execute Bundler's
resolver; no host Ruby installation, global gem or signing state was changed.
That temporary environment is not a runtime prerequisite and is not versioned.

## Unsigned local archive

See [release integration](../../docs/engineering/release-integration.md) for the
separate `preflight-local`, `archive_local` and `validate-local` APIs, root-owned
commands, retained linker maps and current resource blockers. Only the archive
command receives `CODE_SIGNING_ALLOWED=NO`; no signing configuration is changed.
This readiness never authorizes signed export or distribution.

## Read-only preflight

Supply the intended full commit, marketing version, integer build and existing
10-character Apple team. Do not infer a team from another app or account.

```sh
python3 scripts/release/release.py preflight \
  --commit "$(git rev-parse HEAD)" --version "$VERSION" --build "$BUILD" --team "$TEAM"
```

Required existing App Store profiles are selected by absolute file paths in
`TODAY_APP_PROFILE`, `TODAY_WIDGET_PROFILE`, `TODAY_SHARE_PROFILE`. Preflight reads
keychain identity metadata and CMS profiles. It requires a matching **existing**
private Apple Distribution identity, unexpired exact-ID App Store profiles, app
group/capabilities, team and non-debug entitlements. It queries Release build
settings with automatic SwiftPM resolution and repository updates disabled, and
requires existing manual signing settings to select those profiles. It never
repairs signing, downloads profiles, resolves dependencies, generates the project,
builds, archives, purchases, installs, logs into Apple, or uploads.

The Python entry point does not write reports or a journal; the caller can retain
stdout in canonical QA results. `bundle _4.0.16_ exec fastlane ios preflight
commit:... version:... build:... team:...` uses the same checker. Fastlane itself
also writes its standard XML report under the Git common checkout's
`tests/results/`, with automatic Fastlane documentation generation disabled.

JSON schema 1 reports `status: ready|blocked` and independent fixed-code checks:
`release_metadata`, `git_commit_clean`, `locked_tools`, `generated_project`,
`signing_environment`. Exit 0 means every requested local check passed; exit 2
means blocked. Missing actual signing material is **blocked**, never success.
`offline_scanner: unavailable` means no optional offline scanner is installed by
this implementation; it contributes no passing evidence. `evidence:
local_checks_only` and `distribution: not_authorized` prevent readiness being
mistaken for Apple service acceptance or permission to distribute. JSON never
contains environment values, command output, profile content or account names.

## Archive and validate (requires later explicit authorization)

Archive is additionally refused unless the user supplies
`TODAY_ARCHIVE_AUTHORIZATION=archive:<full-commit>`. This task did not grant or set
that token. After authorization, call the locked lane with all metadata and an
absolute unused `.xcarchive` path whose existing parent is outside the checkout:

```sh
bundle _4.0.16_ exec fastlane ios archive commit:"$COMMIT" version:"$VERSION" \
  build:"$BUILD" team:"$TEAM" archive:"$ARCHIVE"
```

The lane runs preflight, archives without an IPA export or automatic provisioning,
and seals a local `release-provenance.json` only after successful archive exit.
Logs and result bundles are retained beside the archive. It then validates:

- Exact release commit, clean tracked/untracked state, tracked tool locks and
  archive inventory hashes. A receipt is local provenance, not remote attestation.
- Archive and all bundle IDs/version/build; device platform; product and executable
  names; exact extension embeds and extension point identifiers.
- Apple Distribution signatures, team trust requirements, embedded profiles,
  source capabilities, non-debug signed entitlements and signing certificate
  membership in each embedded profile. Unexpected capabilities are refused.
- Every app, extension and embedded framework executable has a real device Mach-O
  UUID/architecture set matched exactly by dSYMs; missing, duplicate and orphan
  UUIDs are refused. Simulator architectures and symlinks are refused.

`ios validate` takes the same arguments, or use the Python `validate` action.
Validation requires local readiness too. An arbitrary third-party archive without
this lane's provenance is blocked. Internal `seal` does not bypass signatures or
Mach-O checks. Synthetic test files cannot pass actual Apple tool verification.

## TestFlight upload (default refuses)

Both `ios beta` and `ios distribute` call the same guarded function. Before any
export/upload they require **explicit release-specific user authorization**:

- `TODAY_RELEASE_ENVIRONMENT=testflight`.
- `TODAY_DISTRIBUTION_AUTHORIZATION=upload-testflight:<full-commit>:<version>:<build>`.
- The same release metadata and validated archive as above.
- `export_options:<existing-plist>`: only manual `app-store-connect`, same team,
  all three profile mappings, `destination=export`, and
  `manageAppVersionAndBuildNumber=false`. Extra export controls are refused.
- `TODAY_APP_STORE_CONNECT_API_KEY_PATH`: an existing API key JSON file outside
  source control, supplied by the user; this lane never creates or prints it.

An export goes to a fresh temporary directory, then its bundle signatures,
metadata, dSYM UUIDs, file set and unchanged non-signing resources are checked
against the validated archive. Only that IPA is uploaded. Export logs remain
beside the archive. Temporary IPA data is removed on exit. Upload uses
`skip_submission: true`, no external tester distribution, no App Store submission,
and no install. App Store Connect processing and acceptance remain unverified
until an explicitly authorized real run supplies evidence. Never set authorization
tokens in checked-in files, a scheduled job, a default shell profile or a test.

## Focused verification and evidence

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/release -v
ruby -c fastlane/Fastfile
```

Versioned synthetic fixture builders and their catalog live in
[`tests/release/README.md`](../../tests/release/README.md). No app build, simulator,
physical-device test or real archive is required for this tooling-only lane.
Record development/check actions through the existing `tests/qa/journal.py` and
retain logs in the primary `/Users/yuanlu/code/one-app/tests/results/` checkout.

Formal `preflight` reports `pending_acceptance` from the test authority's release group and fails with `release_acceptance_pending` while known red audits or device acceptance remain unresolved. PR101's broad accessibility remediation is explicitly deferred for merge, and remains a release blocker. `preflight-local` is source-only evidence and does not certify those gates.
