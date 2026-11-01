# Today Luna API

Phone clients use `https://today-luna-api.1031luy.workers.dev/v1/responses`.
The app includes this public HTTPS URL, never the shared OpenAI key. Settings → AI →
Luna AI provides account creation/sign-in, explicit cloud-upload consent, daily usage,
cloud-AI disable, sign-out and AI-account deletion. Username/password accounts are
independent of the user's Apple/OpenAI accounts. Password recovery is not implemented;
the initial-rollout screen states this before registration.

The Worker is deployed in the owner's existing Cloudflare account; its dedicated D1
ID is in `wrangler.jsonc`. Existing Workers, account plans, DNS and signing are untouched.
`OPENAI_API_KEY` is a Worker secret uploaded from the authorized local key file using
Wrangler stdin; it is neither a plain-text binding nor a source/config/bundle value.

## Contract

| Route | Method | Authorization / result |
| --- | --- | --- |
| `/health` | GET | Non-secret readiness, model and agent settings |
| `/auth/register` | POST | Username + password ≥12 characters; issues a unique random session |
| `/auth/login` | POST | Valid password; issues a new unique session |
| `/auth/session` | GET | Bearer; username and today's agent runs (`runsUsed`/`dailyRunLimit`) |
| `/auth/logout` | POST | Revokes this bearer |
| `/auth/account` | DELETE | Deletes this AI user and all their sessions; local planner data remains |
| `/v1/responses` | POST | Bearer; agent mode only (below). A body without `tools_version` is refused with `tools_version_required` |

Passwords use per-user random salt + PBKDF2-SHA256 (100,000 iterations). Random
256-bit sessions expire after 30 days; only their SHA-256 hashes are stored server-side.
Mobile sessions use Keychain, WhenUnlockedThisDeviceOnly. A disabled cloud toggle
prevents model authorization but still permits session management. Revoked/expired
sessions return the UI to sign-in; stale usage responses cannot republish an old login.
Offline sign-out clears local credentials and states that remote revocation is unconfirmed.

The strict-JSON mode of `/v1/responses` (client `instructions` + `text.format`, 24 KB)
was removed in P4 (2026-11-01) together with the app's old AI pipeline; the app sends only
agent steps. No model substitution, redirects, automatic retries or Apple fallback.
The Decisions route (`/v1/decisions`, a 2026-10-31 spike) was removed too. D1 stores
account credentials/session hashes, counters and accounting metadata, not chat or planner text.

## Agent mode (`/v1/responses` with `tools_version`)

Phase P0 of `docs/engineering/ai-agent-architecture.md`. A body containing
`tools_version` is an agent step; any other body is refused (P4).

- Body: exactly `{input, tools_version, run_id, stream?}`, at most 256 KB. `input` is 1–256
  replayed items: `message` (roles `user`/`assistant`, text parts only), `function_call`
  (name must be a v1 tool), `function_call_output` and `reasoning`, passed upstream verbatim
  (ids, `phase` and `encrypted_content` included). `system`/`developer` roles,
  `instructions`, client `tools`/`tool_choice`, images/files, other item types and any other
  key (model, reasoning, store, text, service_tier, previous_response_id…) are rejected
  with 400 before any quota or budget is touched.
- The Worker injects the versioned prompt and the 12 strict tools from `agent-v1.mjs`
  (§1.3 table plus a nullable `why` on write tools, §3 O4) and fixes `gpt-6-luna`,
  `reasoning.effort: low`, `store: false`, `include: [reasoning.encrypted_content]`,
  `parallel_tool_calls: true`, `tool_choice: auto` and 4096 output tokens. No `text.format`:
  the final reply is plain text and proposals come only from tool calls.
  `agent-v1.mjs` is the cacheable prefix; change it only as a new `tools_version`.
- `run_id` (8–64 of `[A-Za-z0-9_-]`, one per user message) is counted in the D1 `runs`
  table: at most 6 steps per run (`run_step_limit`), 40 new runs per user per UTC day
  (`run_quota`; an unfinished run may still finish), a run belongs to its creator (409).
  Agent steps have a 20/minute backstop per user. `/auth/session` reports `runsUsed`/`dailyRunLimit`.
- Upstream timeout is 30 s per step; the abort signal is meant to cover a streamed body too (fetch spec behavior, not exercised offline). Responses up to 4 MB.
- `stream: true` passes the upstream SSE through unchanged. The Worker reads the upstream
  stream to its end inside `ctx.waitUntil` even if the phone disconnects or stalls, then
  settles the ledger from the `response.completed`/`incomplete`/`failed` usage; a stream
  without a usage receipt keeps its reservation as `unknown`.
- An upstream 400 (OpenAI rejected the request before generating) releases the
  reservation and returns `upstream_rejected` with OpenAI's code/param/message.

## Quotas and evaluation budget

Atomic D1 counters enforce 40 agent runs/UTC day, 6 steps/run and 20 steps/minute per
user. Signup is limited to 100 active accounts and 3 registrations/day/IP; login is rate
limited per IP and username. Account deletion does not refund global model spending.

The global table started with the exact prior conservative evaluation spend
USD0.023951 and a USD0.50 cumulative ceiling. On 2026-10-31 the owner approved raising
the ceiling to **USD5.00** (architecture doc §4.7): one `UPDATE budget SET ceiling=5000000`,
from used 312805 / ceiling 500000 to used 312805 / ceiling 5000000 (micro-dollars);
`used` was not touched. Before each model request (or agent step), reserve USD0.01
atomically; after a valid usage receipt, replace the reservation with the rounded-up
token cost: uncached input USD0.10/M, cached input (`input_tokens_details.cached_tokens`)
USD0.01/M, output including reasoning USD0.50/M. Unknown outcomes keep their reservation
across restarts. Denied calls never reach OpenAI. Never reset the table, recreate the
database or raise the ceiling beyond an explicit owner budget decision.

## Verification and operations

`npm ci && npm test && npm audit --audit-level=high` runs offline workerd/D1 tests
with no paid API calls. The production module has no npm runtime dependencies.
Pinned dev dependencies and security overrides are in package-lock.json. The local
Miniflare test compatibility date is2026-07-30 (its stable runtime); deployed Worker
compatibility is2026-10-29. No date-specific Worker feature is used.

`python3 smoke.py --output <fresh-private-results>/https-e2e.json` performs one paid
synthetic request after registration/login, verifies usage, logout and deletion,
and always attempts deletion of its synthetic account. It refuses to overwrite a
receipt and never prints passwords/tokens. Requests identify the client honestly as
TodayAPISmoke; the default Python-urllib user agent is rejected by Cloudflare1010.
The app uses Today-iOS as its client identifier. No Cloudflare security setting was widened.

`python3 agent_probe.py --output <fresh-private-results>/probe.jsonl` runs the bounded
P0 real-request checks (synthetic data only; see `docs/qa/agent-p0-20261031.md`).

Deployment uses the existing authorized Wrangler profile, `wrangler d1 execute DB
--remote --file schema.sql` and `wrangler deploy`. Schema is additive/idempotent;
its INSERT OR IGNORE never resets existing accounting. Upload secret values through
private stdin, never command-line literals or committed files. Reapply no schema or
secret unless required by a reviewed change.

Retained evidence: primary checkout tests/results/luna-production-20261029/:
`https-e2e-v2.json`, `https-quota.json`, redacted secret-upload.log. E2E observed distinct
sessions, one real GPT medium response, usage1/40, logout→401, delete→401 and test-user
cleanup. A second synthetic account was saturated through the admin-owned D1 counter;
seven real HTTPS calls returned429, zero paid calls were created and budget stayed
unchanged. Both synthetic users/sessions were deleted. No phone install/UI test was run
by this implementation owner; root owns same-SHA CI/smoke and phone acceptance.
