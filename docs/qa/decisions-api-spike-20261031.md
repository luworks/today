# Decisions API routing spike — 2026-10-31

## Setup

Data only; no app routing or behavior changed. The frozen synthetic fixture
`tests/fixtures/ai-chat-capability-eval.json` has SHA-256
`715c00cdb15bb455321dcaa45536fe5f52fd26d8fe3a9481899aca90cbbacd97`.
Gold labels were committed at `c22eba14d` before any API calls. The deployed
Worker version was `8404a8e6-d54e-44ee-9145-651ac3db215c`. Each of 27 turns
was evaluated three times, for 81 calls, with four questions per call and prior
user turns as context. Target accuracy is measured only for the nine edit-turn
trials. The follow-up saved reminder and the two dentist reminders are synthetic.

The Worker fixes the model, bounds input and question count, and uses the same
authentication, per-user quota and global reservation as Responses. Each decision
consumes one unit of the existing 40/day user quota. The upstream 403/404
passthrough applies only to Decisions: it returns the upstream status with a
sanitized error and retains the unknown-charge reservation. Other upstream failures
remain 502. The three synthetic accounts were deleted via the API.

## Results

Threshold cells show accuracy / coverage among applicable trials; coverage is the
fraction at or above the threshold. A predicate's predicted value is true at
probability >= 0.5 and its confidence is the probability of that predicted value.

| Question (trials) | Overall accuracy | >= 0.80 | >= 0.90 | >= 0.95 | >= 0.98 |
| --- | ---: | ---: | ---: | ---: | ---: |
| kind (81) | 72/81, 88.9% | 91.3% / 85.2% | 100% / 74.1% | 100% / 63.0% | 100% / 51.9% |
| cardinality (81) | 78/81, 96.3% | 100% / 88.9% | 100% / 88.9% | 100% / 77.8% | 100% / 77.8% |
| target (9) | 9/9, 100% | 100% / 100% | 100% / 66.7% | 100% / 33.3% | 100% / 33.3% |
| missing_info (81) | 75/81, 92.6% | 96.2% / 96.3% | 96.2% / 96.3% | 96.2% / 96.3% | 96.0% / 92.6% |

Mac-to-deployed-Worker latency was p50 **0.504 s**, p90 **0.626 s**. The
Responses low-effort baseline in `gpt-luna-effort-20261029.md` was p50 1.78 s,
p90 2.75 s; these are separate measurements, not a controlled paired latency test.
The 58,314 input tokens and zero output tokens cost **$0.0058314** at published
rates, with no cache reads or writes. The Worker's conservatively rounded ledger
charge was $0.005868. The global ledger was $0.312805 of its $0.50 ceiling after
the run; most had been charged before this spike. Billing is calculated from usage,
not a separate invoice. Raw JSONL and summary are retained under the primary
checkout's `tests/results/decisions-spike-20261031/` and indexed in the QA journal.

## Errors and recommendation

The lowest tested thresholds with zero wrong answers on this set are **0.90 for
kind** (74.1% coverage), **0.80 for cardinality** (88.9%), and **0.80 for target**
(100% of nine edit trials). These are observations, not established safety
thresholds: target is supported by only three distinct edit turns. `missing_info`
had wrong answers even at >= 0.98 and is **not safe as a gate**; use deterministic
rules or fall back to the agent. Its wrong turns, each repeated in all three runs:

- `capability-question`, turn 1: predicted missing information for a capability
  question, although the gold label says no action information is needed (0.76
  confidence). The answer appears to treat a question as an incomplete action.
- `ambiguous-edit`, turn 1: predicted no missing information at 1.00 confidence,
  although two dentist items match and a unique target is required. The answer
  appears to overlook target ambiguity despite selecting `none_or_unclear` for target.

Kind was wrong on the same three turns in every run: `reported` (reported speech
classified as reminder, confidence 0.85), `negation` (negated request classified as
reminder, 0.45), and `question-not-action` (capability question classified as
reminder, 0.81). These cases reinforce that classification alone cannot authorize
an action. `missing_info` is not worth asking as a standalone gate on this evidence;
target's small sample does not establish its incremental value.

Current Swift rule routing comparison: **not run**. Existing Swift tests exercise
individual routing examples, but there is no ready harness that runs this frozen
multi-turn fixture with the same synthetic item state and comparable labels; the
spike's no-local-iOS-build constraint excludes building a new harness here. No
comparison or claim of superiority is inferred.

Product principle 1 remains authoritative: a confident decision is only an input
to code policy, never authorization. Only the scoped one-off reminder can be
created directly under the existing policy. Events with attendees, edits and
deletes retain their preview and confirmation; uncertain cases go to the agent.
This is a 27-turn development set, not a blind holdout. Evaluate on an independent
holdout and preserve the existing safety policies before considering integration.
