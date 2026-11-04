# Feasibility, competitors and release criteria

Research date: 2026-11-04. Competitor capabilities below are vendor claims, not
independently measured results. Prices and regional availability can change.

## Platform evidence

- [Apple IdentityLookup overview](https://developer.apple.com/documentation/identitylookup/sms-and-mms-message-filtering):
  the system asks an enabled extension about incoming unknown-sender SMS/MMS;
  decisions can be local. No iMessage/Contacts filtering, direct network access or
  writes to the shared host container.
- [Apple extension setup](https://developer.apple.com/documentation/identitylookup/creating-a-message-filter-app-extension):
  separate extension target; remote classification requires Apple's mediated
  network mechanism and associated domain setup. This prototype uses neither.
- [Apple filtering privacy](https://www.apple.com/legal/privacy/data/en/text-message-filtering/):
  newer wording covers RCS/SMS/MMS from unknown senders. Contact senders and senders
  replied to three times are excluded. Verify RCS on the intended device rather
  than extrapolating from the older API overview.

## Competitor comparison

| Product | Publicly described capabilities | Implication |
| --- | --- | --- |
| [Panda SMS 2](https://apps.apple.com/cn/app/id1642682818) | Offline Core ML, Chinese categorization including transactions and orders; claims a large training corpus | Chinese offline classification is already established |
| [Junkman](https://junkman.app/) | On-device ML; English, French and Turkish models; sender threat database, schedules, regex and text-bombing mode | Local AI and sender lists are baseline capabilities |
| [Bouncer](https://github.com/afterxleep/Bouncer) | Private rule and regex filtering, categories, import/export | Transparent rules and user control are useful benchmarks |
| [VeroSMS](https://verosms.com/) | Local filtering and keyword/community lists | Privacy alone is insufficient differentiation |

None of these claims establishes comparative accuracy. No paid product was bought,
no account registered, and no third-party sender data was imported.

## Proposed advantage, to be demonstrated

Prioritize Chinese and mixed Chinese/English scam language, obfuscated characters,
and high recall at a strictly controlled false-positive rate. Protect legitimate
verification, delivery and medical messages without a blanket OTP bypass attackers
can exploit. Provide a private pasted-message explanation and precise sender
exceptions. Never describe all unknown messages or all URL messages as spam.

Do not ship arbitrary harvested number lists. A future reputation feed needs
documented provenance, license, expiry, correction/appeal and poisoning defenses.
Broad prefix blocking is intentionally absent from this preview.

## Evidence needed before production

1. Freeze a legally sourced bilingual dataset and split by sender, campaign and
   time to prevent train/test leakage. Keep a separately labeled untouched
   holdout, including OTP, banks, medical, logistics and hard scam examples.
2. Report false-positive rate, spam precision/recall, important-message misses,
   per-language results, and sample sizes. Synthetic regression tests are not
   estimates of real-world accuracy. Establish thresholds before opening holdout.
3. Measure device extension latency, peak memory, cold launch, locked/restarted
   phone behavior, corrupt/missing model and rules, and offline operation.
4. Validate actual carrier SMS routing, sender rules after edits, system activation
   and updates. Record device, OS, carrier and app version. RCS is a separate gate.
5. Compare competitors on the same frozen cases where legally and technically
   possible. Set measurable superiority targets from that baseline; do not claim
   'best' before collecting evidence.

The current build is phase 1: a runnable engineering path. A production classifier,
reputation feed, imported rules, finer transaction/promotion categories, robustness
study and App Store submission remain later work.
