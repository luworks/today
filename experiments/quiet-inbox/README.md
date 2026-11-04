# Quiet Inbox — experimental iPhone SMS filter

A standalone native SwiftUI app and IdentityLookup message-filter extension. It is
isolated from Today: separate bundle identifiers, App Group, project and CI. No
Today data, permissions, signing settings or user interfaces are changed.

## What this preview does

- Exact sender allow/block rules, stored by the host app in an App Group file.
  The extension reads that file; it never writes message content or telemetry.
- An experimental on-device text classifier, shared by the extension and the
  manually pasted Message Lab. All inference is local; no network SDK or endpoint.
- Conservative handling of uncertainty: return no filtering decision to iOS.
- Activation instructions, with system activation explicitly unverified.

This is an engineering prototype, not validated anti-fraud protection. Its small
synthetic training corpus is unsuitable for accuracy claims. It does not contain
a live sender reputation feed, a production model or a third-party number list.

## Build and run

From the repository root, install the pinned project generator and generate:

```sh
./dev bootstrap --tool xcodegen
.dev-tools/xcodegen/2.46.0/bin/xcodegen generate --spec experiments/quiet-inbox/project.yml
open experiments/quiet-inbox/QuietInbox.xcodeproj
```

Select the QuietInbox scheme and an iOS 17+ iPhone simulator, then Run. This runs
the setup UI, sender rules and Message Lab. A simulator cannot prove real incoming
carrier SMS filtering. CI runs package regression tests and compiles both targets;
it does not run UI journeys or real SMS tests.

## Phone installation and activation

The project deliberately does not select a signing team or update provisioning.
Before signing, authorize registration/provisioning of these new identifiers
using the owner's existing Apple developer account:

- App: `com.luworks.quietinbox`
- Extension: `com.luworks.quietinbox.filter`
- Shared App Group: `group.com.luworks.quietinbox`

Assign the same authorized team to both targets and enable their matching App
Group. Build/install QuietInbox on the selected iPhone. In Settings → Apps →
Messages → Unknown & Spam (wording varies), select Quiet Inbox. Installation does
not activate the filter. Do not overwrite another app or change its signing.

Verify on a phone with synthetic SMS sent from a controlled unknown number:
normal message, OTP, exact blocked sender, allow/block conflict, synthetic spam,
unknown text, disable preference and rule edits. Inspect Messages' actual folders;
verify the extension can read newly saved rules. Recheck after an app update and
device restart. Treat all of these as unverified until actually executed.

## Boundaries

Messages owns the inbox and Junk folder. This app cannot read history, delete
messages, move old messages back, or filter iMessage/known contacts. iOS may also
stop treating a sender as unknown after repeated replies. Returning `.none` is
not a guarantee of delivery or a notification; system/thread behavior still wins.

Apple's newer privacy page includes unknown RCS messages, while the IdentityLookup
overview still names SMS/MMS. RCS support must be verified for the target iOS,
region and carrier. The host app cannot reliably inspect activation using a
documented public API, so it does not display a fabricated protection badge.

The filter extension cannot directly use networking or write the shared app
container. Consequently there is no real-time interception counter, message
history, automatic training on received SMS, or fabricated inbox here.

See [research and release criteria](RESEARCH.md) before planning production use.
