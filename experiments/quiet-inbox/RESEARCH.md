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

## Follow-up research: AI value and iOS product boundaries (2026-11-04)

### Provenance and confidence

This follow-up extends rather than replaces the phase-1 evidence above. Actual
starting HEAD and fetched `origin/main` were both
`f477f81fdcc48f5e5842decff03cdbe3c2c4613a` (PR #314); the worktree was clean.
The 60 synthetic character-bigram samples establish an engineering experiment,
not production accuracy, semantic understanding, or physical-device usability.
This pass reads public Apple documentation, App Store descriptions, vendor sites
and public repositories only. No competitor installation, SMS upload, account,
purchase, phone interaction, signing change or app logic change was performed.
Sources were accessed on 2026-11-04. Store listings and privacy labels are developer
statements, not audits; availability, checkout prices and real filtering remain
unverified. UNKNOWN below means public evidence did not establish the fact.

### What Apple permits, and what “cleaning” does not mean

The [IdentityLookup overview](https://developer.apple.com/documentation/identitylookup/sms-and-mms-message-filtering)
describes incoming unknown-sender SMS/MMS queries, local decisions or system-mediated
server analysis. It excludes Contacts and iMessage; the extension cannot directly
access the network or write the host's shared container. Treat shared App Group
configuration as host-written, extension-read input, not an outgoing message log.
The [extension setup guide](https://developer.apple.com/documentation/identitylookup/creating-a-message-filter-app-extension)
requires an associated server/domain and configured network URL for deferral;
this is not permission to make arbitrary LLM API requests from the extension.

The newer [Apple filtering privacy notice](https://www.apple.com.cn/legal/privacy/data/zh-cn/sms-filtering/)
includes unknown RCS/SMS/MMS and warns that content can contain sensitive codes.
It says adding a contact or replying three times stops unknown-sender filtering.
The [current iPhone guide](https://support.apple.com/en-gb/guide/iphone/iph203ab0be4/27/ios/27)
also includes RCS. These conflict in scope with the older API overview's SMS/MMS
wording. RCS is therefore documented at the user/privacy level, but this prototype's
RCS extension routing on a particular OS/carrier is UNKNOWN. System screening of
unknown iMessage senders does not imply third-party iMessage content access.

| Requested behavior | Supported boundary |
| --- | --- |
| Classify a newly arriving eligible message | Yes, when the system invokes the enabled extension; actual routing still needs validation |
| Put it in a chosen app-defined folder | No arbitrary folder API: map to Apple's fixed actions/categories |
| Scan/reclassify the existing Messages archive | No history enumeration API in this filtering contract |
| Delete spam, archive old conversations or remove expired OTPs | No deletion/archive/history mutation API in this contract |
| Explain every past automatic decision in the host app | Cannot promise a durable per-message trail through the read-only shared-container boundary |

[Actions](https://developer.apple.com/documentation/identitylookup/ilmessagefilteraction)
are none/allow/junk/promotion/transaction; [subactions](https://developer.apple.com/documentation/identitylookup/ilmessagefiltersubaction)
cover fixed finance, orders, reminders, health, weather and other transaction types,
and offers/coupons/other promotions. Internal labels must map into those enums;
visible categories also depend on system support. Filtering is routing, not erasure.
The history/deletion conclusions above are inferences from this bounded public API,
not a claim about every private Apple or future messaging API.

Apple already supplies Screen Unknown Senders, selectable time-sensitive
notifications and transaction/promotion organization in the current guide
(options vary by country). [Apple's spam guidance](https://support.apple.com/en-bw/125068)
describes spam filtering and moving messages back. Do not sell “all unknown senders
are hidden” as novel scam detection. Apple also offers
[Delete After Use](https://support.apple.com/en-ca/guide/iphone/ipha6173c19f/27/ios/27):
it removes codes after AutoFill use. This is not general expiration-based deletion
of every unused OTP, and a third-party filter cannot extend it into inbox cleanup.

### Where AI can add value

The following is an engineering hypothesis to test, not measured Quiet Inbox behavior.
Number lists miss rotating senders. Keywords/regex match explicit strings well but
struggle with paraphrases, mixed Chinese/English, inserted separators, lookalike
characters and messages combining legitimate vocabulary with a fraudulent request.
A trained classifier may combine payment urgency, credential requests, impersonation
and URL shape with intent instead of reacting to a single word. Neither a model nor
an apparent bank sender proves authenticity. URL presence alone is not spam; URL
lexical features do not establish the destination's reputation, and live link visits
would add privacy and security exposure.

Apple documents [Create ML text classifiers](https://developer.apple.com/documentation/CreateML/MLTextClassifier)
and [Natural Language](https://developer.apple.com/documentation/NaturalLanguage),
including language identification, tokenization and custom models. This establishes
a supported model toolchain, not an accuracy guarantee for Chinese SMS or an
extension resource allowance. A compact character/subword classifier or distilled
encoder is the first candidate: bounded labels, predictable cold-start footprint,
no per-message service charge and offline use. Core ML is execution infrastructure;
NaturalLanguage preprocessing must match training and mixed-language evaluation.

| Approach | Benefit | Costs and unresolved risks |
| --- | --- | --- |
| Rules + compact on-device classifier | Private content processing; bounded work and offline decisions | Dataset/model maintenance; cold load, RAM, CPU/energy and calibration must be measured |
| On-device generative LLM | Potential richer context/explanation | Larger memory/startup/energy cost; nondeterminism; device/language/model availability; no extension reliability evidence here |
| Apple-mediated remote classifier | Larger model and centrally updated knowledge | Sensitive content leaves device; network latency/outage; service and inference cost; server retention/security obligations |
| LLM in offline development or user-initiated analysis | Candidate labels, adversarial paraphrases, difficult-case review and explanations | Human adjudication required; synthetic contamination, hallucinated labels and privacy remain risks |

No FoundationModels-in-IdentityLookup compatibility or reliability is claimed.
Do not make it the critical path without explicit API/availability checks and
extension cold-start, memory and lifecycle evidence. Cloud or large models are
better considered for legally sourced offline training/teacher distillation and
human-reviewed hard cases first. User-requested explanation could operate on a
pasted message, with explicit separate consent before any remote processing.
This does not grant background access to Messages history.

### Seven products worth studying

Prices below describe public listings on 2026-11-04, not checkout offers. US store
unless noted; Chinese UI availability is separate from Chinese model quality.
All accuracy claims, including Filtera's advertised 99%, remain vendor claims.
No shared evaluation or independent accuracy ranking was performed.

| Product / original source | Processing and Chinese evidence | Controls, categories and inspectability | Charging / privacy / lesson |
| --- | --- | --- | --- |
| [Panda SMS 2 / 熊猫吃短信2](https://apps.apple.com/us/app/熊猫吃短信2-垃圾短信拦截/id1642682818) ([CN listing](https://apps.apple.com/cn/app/熊猫吃短信2-垃圾短信拦截/id1642682818)) | Claims offline Core ML; explicit Chinese finance/order/carrier/weather examples; bilingual robustness UNKNOWN | Fine classification, blacklist priority mentioned in release notes; user-submitted correction samples; exact rule testing/explanations UNKNOWN | Free + IAP (CN/US); exact active price UNKNOWN. Automatic filtering claims no upload; voluntary feedback collects desensitized text and label. Learn Chinese taxonomy and distinguish inference from feedback collection |
| [SMS Filter, Iurii Mozharovskyi](https://apps.apple.com/us/app/sms-filter/id1271159042) | Rule engine plus community spam database/statistical similarity; release notes add offline checking. Current server data flow UNKNOWN; Chinese model quality UNKNOWN | Keywords/patterns/regex, allow/deny rules, test-message facility; category options in release history | Free + annual Spam Protection; description says US $2.99/year, current checkout UNKNOWN. Learn detector bench and rule testing; do not infer zero upload from offline mode |
| [Junkman](https://junkman.app/) / [store](https://apps.apple.com/us/app/junkman-ai-spam-sms-blocker/id1591815272) | Local Core ML; site names English/French/Turkish models; Chinese quality UNKNOWN (UI languages are not model languages) | Normal/junk/transaction/promotion, regex, schedules, threat database, attack mode; store describes configuration testing | Free + Pro subscription or one-time purchase; exact current price UNKNOWN. Claims no message/sender collection or analytics. Learn model + rules + test console and accessibility; attack-mode false positives need scrutiny |
| [VeroSMS](https://apps.apple.com/us/app/verosms/id1269693537) | Claims no SMS sent to servers; premium ML and regional crowdsourced keywords; Chinese model quality UNKNOWN | Allow/deny keywords, URL blocking, iCloud keyword sync; India-only TRAI reporting; rich categories and explanation console UNKNOWN | Free + premium IAP; exact price/term UNKNOWN. Crowdsourced keywords/sync are separate data flows. Learn explicit exceptions; avoid broad URL blocking as default |
| [Bouncer](https://github.com/afterxleep/Bouncer) | Open-source local rule decisions, not evidence of an AI classifier; Chinese words can be rules, Chinese semantic model absent from cited description | Words/PCRE regex, import/export, fixed categories/subcategories; source is inspectable, installed behavior untested | Store price UNKNOWN; MIT source. Current README explicitly says rule creation/change/deletion sends phrase, region and time to developer server; sender phrase may be a phone number. Learn rule portability, but never equate local decisions with zero telemetry |
| [Filtera](https://apps.apple.com/us/app/spam-text-blocker-filtera/id6741700342) | Claims on-device AI/no message upload; English and German in release notes; Chinese UNKNOWN | Sender/keyword/regex, Bouncer imports/exports; claims SMS/RCS filtering; explanation bench UNKNOWN | Free + Pro; US listing shows $1.49/month, $9.99/year and lifetime $11.99/$14.99 variants (eligibility UNKNOWN). Learn migration and low setup burden; do not repeat 99% or “never miss OTP” without evidence |
| [Truecaller SMS support](https://support.truecaller.com/support/solutions/articles/81000406341-how-do-i-enable-sms-filtering-on-iphone) | [2020 vendor article](https://www.truecaller.com/blog/features/sms-filtering-on-iphone-just-got-better-with-ios-14) describes offline SMS processing; current architecture/privacy beyond that claim UNKNOWN; Chinese SMS quality UNKNOWN | Support lists finance/orders/reminders/coupons/offers in India, Nigeria, South Africa, Kenya, Bangladesh, Sri Lanka; older categories in US/UK/Canada/Australia and named additional regions. China not listed. SMS rule console UNKNOWN | Exact SMS entitlement/price by region UNKNOWN; do not use caller-ID Premium price as SMS price. Learn region-specific onboarding and taxonomy; phone identification, Android inbox features and iOS SMS are distinct |

“SMSFilter” is not a unique product identifier. This report identifies SMS Filter
by developer and App Store ID `1271159042`, not every similarly named project.
A related Chinese source alternative is
[ios-sms-guard](https://github.com/boommanpro/ios-sms-guard): it describes a local
Chinese rule engine based on IdentityLookup and inspired by Bouncer. It is useful
for preset-rule study, not evidence of App Store distribution, audited privacy or
semantic AI performance. No source was copied or third-party rule feed imported.

### Product recommendation and safety design

Use host-managed precise exceptions and bounded rules, then a compact on-device
classifier with calibrated conservative thresholds. Keep model score distinct
from actual probability until calibration is demonstrated. Model/rule load errors,
unsupported languages, low confidence and conflicting high-risk signals should
return no filtering decision rather than guess junk. High-confidence legitimate
transactions can map to system transaction categories; only high-confidence spam
should map to junk. An OTP keyword must neither universally allow nor universally
block: scams can include codes, banks can contain links, logistics can request
legitimate payment, and medical reminders can resemble marketing.

Define deterministic rule priority and show conflicts in a local test bench before
a rule is saved. Precise sender exceptions are user choices, not authenticated
sender identity. Do not add broad bank-name, prefix or OTP bypasses. Normalize
Unicode/zero-width/spacing for model features while retaining original structure
for tests; test confusables and over-normalization. Bound regex/input work, detect
poisoned updates, keep versioned model/rule rollback and never execute message
instructions as LLM instructions. Do not download links to decide eligibility.

Three credible differentiation hypotheses (none demonstrated yet):

1. Chinese/mixed-language scam detection at a measured low important-message
   false-positive rate, including adversarial paraphrases and rotating senders.
2. A local detector bench that shows matched rule, model/rule version, category,
   uncertainty and conflict resolution on user-provided text. Do not fabricate
   token-level causal explanations for a model score. Do not promise retrospective
   per-message logs: the shared-container write prohibition prevents that design.
   Without stored real SMS, automatic decisions cannot all be replayed later;
   pasted-text diagnosis may also differ after model/rule updates.
3. Safe recovery and honest system guidance: precise exceptions, uncertainty
   fallback, activation troubleshooting, category mapping, and instructions for
   Apple's own unknown-sender/spam and used-code cleanup settings. A visible test
   result is separate from proof that the system actually routed a carrier SMS.

Avoid positioning privacy or AI alone as unique, copying aggressive URL/prefix
blocking, silently transmitting rule phrases, promising historical cleanup or
claiming superiority from vendor marketing and the current synthetic regression.

### Minimum next step and acceptance design

The next authorized work should be an evaluation specification and lawful data
inventory, before replacing the experiment's model. No new app implementation or
real-message collection is authorized by this research. Define a rule-only baseline,
current bigram baseline and one compact model candidate on identical examples.
Use human-adjudicated labels, deduplicate templates and split by campaign, sender
and time; freeze a separate untouched holdout before threshold tuning. LLM-created
variants belong to regression/adversarial development, not an independent natural
holdout. Public corpus licenses, recency and consent need review before use.

Report spam precision TP/(TP+FP), recall TP/(TP+FN), legitimate false-positive
rate FP/(FP+TN), and the absolute number of important messages wrongly sent to
junk, with denominators and uncertainty intervals. Break out Chinese, English,
mixed/unsupported languages, OTP, bank, medical and logistics strata with sample
counts; zero observed mistakes in a small sample does not establish safety.
Choose thresholds/cost tradeoffs on validation data before opening holdout; do not
hide abstentions or class imbalance in overall accuracy. Measure abstention rate
and comparison at the same false-positive budget as well.

A later separately authorized device gate must measure extension cold/warm p50/p95
latency, peak RAM, CPU/energy and model size on named hardware/OS versions, including
locked/restarted/offline operation, missing/corrupt model, long/obfuscated text and
bounded regex behavior. Actual SMS/MMS and separately RCS routing, notifications,
fixed categories, contact/replied-sender exclusions, update activation and recovery
require named OS/carrier/device evidence. UI/model tests and green CI cannot replace
these checks. No numeric latency, memory budget or safety rate is established here.

### Chinese owner summary

AI 有帮助的方向是识别换号后的相似诈骗意图、中英混合和变形表达；收益仍须与规则基线
在独立数据上比较。优先学熊猫吃短信2的中文离线分类、Junkman的检测台与规则组合、
Bouncer的规则可检查性，同时注意它现在披露会上传规则内容；Filtera可学导入迁移，
VeroSMS可学例外控制，SMS Filter可学测试规则，Truecaller可学地区差异。
第三方扩展不能扫描历史收件箱、自动归档或删除过期短信；Apple已有未知发件人筛选、
垃圾信息筛选和AutoFill用后验证码删除。下一步先定义误杀约束、合法数据和独立holdout，
比较规则与小模型；暂不把LLM接进实时过滤链路，也不把60条合成样本当效果证明。
