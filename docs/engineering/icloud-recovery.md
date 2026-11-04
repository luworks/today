# User-owned iCloud recovery — implementation status

Issue #317. This is an incomplete foundation, not an enabled backup feature.

## Verified baseline and capability

The isolated platform worktree started at `79b8922bc06c29289dd31cc9389c1d5232b22aad`
and fast-forwarded cleanly to `6c5a9418132ba5affa44c516d8f1e7895351be4a`.
The app entitlements currently contain HealthKit and App Groups, with no ubiquity
container or iCloud service. Locally installed app/share/widget profiles for team
`J2T2UBD49R` expire November 9, 2026 and contain no iCloud/ubiquity entitlement.
Membership status has not been verified through the account portal. No account,
profile, signing configuration, phone or production data was changed.

Apple's [configuration guide](https://developer.apple.com/documentation/xcode/configuring-icloud-services/)
and [capability reference](https://developer.apple.com/help/account/reference/supported-capabilities-ios)
require provisioning the appropriate service. Native Documents requires these
reviewed entitlement values after the owner provisions the container (identifier
below is proposed, not a claim that the container exists):

```xml
<key>com.apple.developer.icloud-services</key><array><string>CloudDocuments</string></array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array><string>iCloud.com.luworks.today</string></array>
```

Do not add these to the active signing configuration until the selected team can
provision them. Do not enable CloudKit/SwiftData automatic synchronization.

Apple's [directory picker](https://developer.apple.com/documentation/uikit/providing-access-to-directories)
supports a user-selected iCloud Drive folder and security-scoped bookmark for later
access. This is a viable subsequent automatic-write transport without the app's
own ubiquity container. Reinstallation removes the locally stored bookmark; the
user must select the folder again. It cannot promise zero-interaction recovery.
Whole-device iCloud Backup does not implement this application's reinstall flow.

## Data inventory and activation contract

- SwiftData default store: OneTask, OneEvent, OneAlarm, OneList, ChatThread and
  ShareImportReceipt (including source identifiers and chat cards).
- ActivityStore: separate Application Support/Activity/activity.sqlite, including
  snapshots, content and historical reconstruction inputs. Preserve the history
  owner's schema; use SQLite backup API, not raw copying of an open WAL database.
- Preferences: explicit allowlist from SettingsKey, plus user-owned world-clock
  choices and required local state. Never serialize the entire defaults domain.
- Exclude Keychain/API keys, AI account tokens, login sessions, Health metric
  values/caches, active timers, current authorization decisions and device IDs.
- Restored alarm configurations require new system reconciliation. Clear old
  AlarmKit identities; leave scheduling disabled pending permission and explicit
  user review. Never replay historical ring events or schedule overdue alarms.
- Apple Calendar/Reminders remain authoritative. Restore associations before
  source reads, avoid treating restored records as new local writes, and reconcile
  missing identifiers without creating replacement system entries.

`RecoveryArchive` provides a versioned hashed envelope, atomic staging into a new
directory, account binding, SQLite backup snapshots and fail-closed publication
policy. `UbiquityRecoveryTransport` provides coordinated access through the native
container API. Neither is called by OneStore yet. Payload content hashes detect
accidental corruption; they are not signatures or an authenticity guarantee.

Remaining required work before enabling or claiming acceptance:

1. Typed allowlist exporter/importer and payload schema migrations, including chat
   cards, Activity snapshots, preferences and safe alarm reconciliation.
2. Startup discovery/download/recovery before opening OneStore or starting source
   sync. Nonempty local stores require a user decision; retain both generations.
3. Account-token binding checked before and after every operation. Switching
   accounts must suspend publication rather than publish another account's data.
4. Metadata discovery, conflict detection under coordination, immutable generation
   retention and last-good pointer. Current transport is an adapter, not a safe
   concurrent multi-device publisher; do not activate it as-is.
5. Foreground/background debounce, bounded backoff and retry, clear/retention
   tombstones, upload completion/error observation and truthful Settings status.
6. Picker/bookmark transport if the team cannot provision Documents. State the
   reauthorization requirement after reinstall in the UI.
7. Product-level save/clean-rebuild/restore, retry, retention, alarm and source
   deduplication tests. Existing archive tests cover only the storage primitives.

No app integration, real iCloud upload, simulator UI, uninstall/reinstall, or
physical-device recovery has been validated. Do not change the product's current
local-data claim until the supported recovery path is integrated and enabled.

## Continuation: coordinated folder transport

`FolderRecoveryTransport` now accepts the bookmark obtained from a system directory
picker and coordinates the entire directory transaction using the coordinator's
returned URL. Stale grants fail closed. The caller supplies an account identity
reader, checked before, within and after the operation; this transport does not
prove membership or enable an entitlement.

`RecoveryGenerations` stores immutable validated archives and advances `head.json`
only after reading the new generation back successfully. Publication compares the
observed head with the acknowledged generation under directory coordination.
Conflicts retain the remote head. A missing head alongside archives or an iCloud
placeholder is unresolved, not an empty folder. Recovery reads only the current
head: corruption never silently falls back to an older pre-clear generation.
Old immutable generations are retained; automatic retention/deletion is not enabled.

These additions still require the typed application payload, startup orchestration,
settings directory picker and change observation described above. They are not an
active automatic backup feature. Targeted `RecoveryArchiveTests` passed five tests
using local temporary files; this is not iCloud upload or reinstall evidence.
