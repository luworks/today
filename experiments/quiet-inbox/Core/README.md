# Quiet Inbox experimental local classifier

`QuietInboxCore` is a dependency-free Swift package shared by the containing app
and its IdentityLookup extension. It contains no network calls, persistent message
storage, telemetry, or access to the system inbox.

## What the model does

The package trains a character-bigram evidence model in memory from the bundled
`Sources/QuietInboxCore/Resources/synthetic-training.json` resource: 30 synthetic
spam examples and 30 synthetic ordinary-message examples, written for this
prototype in English and Simplified Chinese. Distinct bigram presence counts,
Laplace smoothing, and log spam/ordinary likelihood ratios provide learned
weights. Each message contributes each feature once. No user message updates
the model. These are real learned text weights, not a keyword ruleset or an LLM.

The score is an experimental evidence sum. It is **not** a calibrated probability,
confidence percentage, or measured accuracy. A wide abstention interval returns
`review`, which the extension must map to leaving the message untouched. The
threshold has not been calibrated against real messages or a representative
holdout set. This model is an implementation prototype, not production protection.

Compatibility normalization folds full-width text and case; feature extraction
removes punctuation, spaces, and invisible separators. This is only basic
obfuscation handling and does not establish robustness to real attacks.

## Decision order and limits

1. A paused policy returns `review` (no filtering decision).
2. An exact normalized sender allow rule wins over a conflicting block rule.
3. An exact normalized sender block rule returns `junk`.
4. Empty or over-4,096-character text, a missing/corrupt training resource, and
   insufficient model evidence return `review`.
5. Multiple learned spam patterns and a sufficiently positive score return
   `junk`; strong ordinary evidence returns `allow`; everything else is `review`.

Phone normalization removes formatting but preserves `+` and country codes. It
does not guess country codes or match number suffixes. Empty senders never match
empty rules. Alphanumeric sender IDs compare without case. Sender strings are
not authenticated identities: a sender can be spoofed.

The presence of “verification code” does not create a blanket allow rule.
The test suite includes ordinary OTP, delivery and medical examples, phishing
that asks for an OTP, Unicode normalization, rule precedence, sender normalization,
unknown text and resource failure. Some regression messages intentionally
resemble training examples to check wiring; **none** of these tests constitutes
an independent quality evaluation or supports an accuracy claim.

Before production, obtain licensed/consented representative data, freeze separate
training/calibration/holdout splits by source and campaign, evaluate legitimate
message false positives by category and language, then measure attack recall,
latency and memory in a real extension. Keep uncertain text unfiltered. Never
use real private messages as test fixtures without explicit consent.

## Build integration

Add this directory as a local Swift package dependency, link `QuietInboxCore` into
both targets, and embed its generated resource bundle in both products. The
default `FilterEngine()` loads resources using `Bundle.module`. Only tests can
inject a missing/corrupt resource through the internal initializer.

CI should run `swift test --package-path experiments/quiet-inbox/Core`. Local
tests were not run during implementation because this repository assigns testing
to CI by default.
