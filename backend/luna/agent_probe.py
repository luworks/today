#!/usr/bin/env python3
"""Bounded P0 agent-mode probes (docs/qa/agent-p0-20261031.md); synthetic data only.

Worker phase: a synthetic account runs real agent steps through the deployed Worker
(function-call round trip, encrypted reasoning replay with store=false, SSE, cache hits,
cache TTL after waits). Direct phase (needs --key-file): questions the Worker does not
expose on purpose (tools + text.format together, service_tier fast vs default).
Appends one JSON line per request; never prints or stores tokens, passwords or the key.
Encrypted reasoning is stored only as its length.
"""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import time
import urllib.error
import urllib.request

UA = 'TodayAPISmoke/1.0'
HERE = Path(__file__).resolve().parent
CONTEXT = '\n\nContext: now 2026-10-31T10:00-07:00, time zone America/Los_Angeles, language en, tab Today, day 2026-10-31.'
ASK = '[QA] Move my dentist appointment tomorrow to 4pm and remind me to buy [QA] milk.' + CONTEXT
FOUND = {'items': [{'id': 't17', 'kind': 'event', 'title': '[QA] Dentist', 'start': '2026-11-01T14:00-07:00',
                    'end': '2026-11-01T15:00-07:00', 'attendees': 0, 'repeats': False}]}


def http(url, body=None, headers=None, method='POST', timeout=60, stream=False):
    headers = {'Content-Type': 'application/json', 'User-Agent': UA, **(headers or {})}
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None,
                                 headers=headers, method=method)
    start = time.monotonic()
    first = None
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            status = response.status
            if stream:
                chunks, marks = [], {}
                for line in response:
                    now = time.monotonic() - start
                    first = first if first is not None else now
                    text = line.decode()
                    chunks.append(text)
                    if text.startswith('event: '):
                        marks.setdefault(text[7:].strip(), now)
                return status, ''.join(chunks), {'seconds': time.monotonic()-start, 'first_byte': first, 'marks': marks}
            raw = response.read()
    except urllib.error.HTTPError as error:
        status, raw = error.code, error.read()
    seconds = time.monotonic() - start
    try:
        result = json.loads(raw)
    except ValueError:
        result = {'error': 'non_json_response'}
    return status, result, {'seconds': seconds}


def synthetic_login():
    """A fresh random synthetic account; nothing is hardcoded."""
    name = 'qa-agent-' + secrets.token_hex(6)
    return {'username': name, 'password': secrets.token_urlsafe(32)}


def redact(response):
    """Keep structure and usage; replace encrypted reasoning with its length."""
    out = json.loads(json.dumps(response))
    for item in out.get('output', []) if isinstance(out, dict) else []:
        if isinstance(item.get('encrypted_content'), str):
            item['encrypted_content'] = f"<{len(item['encrypted_content'])} chars>"
    return out


class Probe:
    def __init__(self, args):
        self.args = args
        self.log = args.output.open('a')
        self.token = None

    def record(self, name, status, result, timing, **extra):
        usage = result.get('usage') if isinstance(result, dict) else None
        cached = (usage or {}).get('input_tokens_details', {}).get('cached_tokens')
        line = {'probe': name, 'at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'status': status,
                **timing, 'usage': usage, 'cached_tokens': cached, **extra}
        if isinstance(result, dict):
            line['response'] = redact(result)
        self.log.write(json.dumps(line, ensure_ascii=False) + '\n')
        self.log.flush()
        print(json.dumps({k: line.get(k) for k in ('probe', 'status', 'seconds', 'cached_tokens')}
                         | {'input': (usage or {}).get('input_tokens'), 'output': (usage or {}).get('output_tokens')}), flush=True)
        return line

    def worker(self, path, body=None, method='POST', stream=False):
        headers = {'Authorization': 'Bearer ' + self.token} if self.token else {}
        return http(self.args.base + path, body, headers, method, stream=stream)

    def step(self, name, items, run_id, stream=False):
        body = {'tools_version': 'v1', 'run_id': run_id, 'input': items, **({'stream': True} if stream else {})}
        status, result, timing = self.worker('/v1/responses', body, stream=stream)
        if stream:
            events = [json.loads(line[6:]) for line in result.splitlines() if line.startswith('data: ')]
            final = next((e['response'] for e in events if e.get('type') == 'response.completed'), {})
            self.record(name, status, final, timing, event_types=sorted({e.get('type') for e in events}))
            return final
        self.record(name, status, result, timing)
        return result

    def sign_in(self):
        # PROBE_USERNAME/PROBE_PASSWORD: a pre-created synthetic account (signup is 3/day/IP).
        login = {'username': os.environ.get('PROBE_USERNAME'), 'password': os.environ.get('PROBE_PASSWORD')}
        path = '/auth/login' if all(login.values()) else '/auth/register'
        if path == '/auth/register':
            login = synthetic_login()
        status, session, _ = http(self.args.base + path, login)
        assert status == 200, (status, session.get('error'))
        self.token = session['token']

    def worker_phase(self):
        assert http(self.args.base + '/health', method='GET')[0] == 200
        self.sign_in()
        # Rejections are free: they never reach OpenAI.
        for name, body in [('reject_system_role', {'tools_version': 'v1', 'run_id': 'qa-' + secrets.token_hex(8), 'input': [{'role': 'system', 'content': 'x'}]}),
                           ('reject_client_tools', {'tools_version': 'v1', 'run_id': 'qa-' + secrets.token_hex(8), 'input': [{'role': 'user', 'content': 'x'}], 'tools': []})]:
            status, result, timing = self.worker('/v1/responses', body)
            self.record(name, status, result, timing)
        # Run 1: find -> parallel proposals -> final reply, replaying every output item verbatim.
        run = 'qa-' + secrets.token_hex(8)
        items = [{'role': 'user', 'content': ASK}]
        for n in range(1, 5):
            result = self.step(f'run1_step{n}', items, run)
            output = result.get('output', [])
            calls = [o for o in output if o.get('type') == 'function_call']
            items += output
            if not calls:
                break
            for i, call in enumerate(calls):
                if call['name'] == 'find_items':
                    out = FOUND
                elif call['name'].startswith('propose_'):
                    out = {'proposal_id': f'p{n}{i}', 'shown': True, 'parsed': 'synthetic', 'note': 'Card shown; the user decides.'}
                else:
                    out = {'error': 'not available in this probe'}
                items.append({'type': 'function_call_output', 'call_id': call['call_id'], 'output': json.dumps(out)})
        # Tampered encrypted reasoning: expect a sanitized upstream 400 with the reservation released.
        tampered = [dict(i) for i in items[:2]]
        for i in tampered:
            if i.get('type') == 'reasoning' and i.get('encrypted_content'):
                i['encrypted_content'] = i['encrypted_content'][:-8] + 'AAAAAAAA'
        if any(i.get('type') == 'reasoning' for i in tampered):
            self.step('tampered_reasoning', tampered, 'qa-' + secrets.token_hex(8))
        # Streaming step and repeated-prefix cache checks (new first-step runs, varied message).
        self.step('stream_step1', [{'role': 'user', 'content': ASK}], 'qa-' + secrets.token_hex(8), stream=True)
        for n in range(3):
            msg = f'[QA] What do I have tomorrow? (variant {n})' + CONTEXT
            self.step(f'cache_repeat{n}', [{'role': 'user', 'content': msg}], 'qa-' + secrets.token_hex(8))
        last = time.monotonic()
        for wait in self.args.ttl_minutes:
            time.sleep(max(0, last + wait * 60 - time.monotonic()))
            self.step(f'cache_after_{wait}min_idle', [{'role': 'user', 'content': f'[QA] Am I free at 3? (after {wait} min)' + CONTEXT}], 'qa-' + secrets.token_hex(8))
            last = time.monotonic()
        status, session, _ = self.worker('/auth/session', method='GET')
        self.record('session_usage', status, {k: session.get(k) for k in ('used', 'runsUsed', 'dailyRunLimit')}, {})

    def direct_phase(self, replay=False):
        match = re.search(r'^OPENAI_API_KEY\s*=\s*["\']?(sk-[A-Za-z0-9_-]+)', self.args.key_file.read_text(), re.MULTILINE)
        if not match:
            raise SystemExit('No API key in the selected file')
        headers = {'Authorization': 'Bearer ' + match.group(1)}
        contract = json.loads(subprocess.check_output(['node', '-e', "import('./agent-v1.mjs').then(m=>console.log(JSON.stringify({tools:m.tools,instructions:m.instructions})))"], cwd=HERE))
        base = {'model': 'gpt-6-luna', 'instructions': contract['instructions'], 'tools': contract['tools'], 'tool_choice': 'auto',
                'parallel_tool_calls': True, 'reasoning': {'effort': 'low'}, 'store': False, 'include': ['reasoning.encrypted_content'], 'max_output_tokens': 4096}
        fmt = {'format': {'type': 'json_schema', 'name': 'reply', 'strict': True, 'schema': {'type': 'object', 'properties': {'reply': {'type': 'string'}}, 'required': ['reply'], 'additionalProperties': False}}}
        url = 'https://api.openai.com/v1/responses'
        if replay:
            # Low effort emitted no reasoning items, so replay is checked at medium effort:
            # step until an output carries encrypted reasoning, then replay that history.
            medium = {**base, 'reasoning': {'effort': 'medium'}}
            items, output = [{'role': 'user', 'content': ASK}], []
            for n in range(1, 5):
                status, result, timing = http(url, {**medium, 'input': items}, headers)
                self.record(f'replay_step{n}_medium', status, result, timing)
                output = result.get('output', [])
                calls = [o for o in output if o.get('type') == 'function_call']
                outputs = [{'type': 'function_call_output', 'call_id': c['call_id'],
                            'output': json.dumps(FOUND if c['name'] == 'find_items' else {'proposal_id': 'p1', 'shown': True, 'note': 'Card shown; the user decides.'})} for c in calls]
                if any(o.get('type') == 'reasoning' for o in output) and calls:
                    break
                items += output + outputs
            history = items
            status, result, timing = http(url, {**medium, 'input': history + output + outputs}, headers)
            self.record('replay_verbatim', status, result, timing, replayed_reasoning=sum(o.get('type') == 'reasoning' for o in output))
            tampered = [dict(o) for o in output]
            for o in tampered:
                if o.get('type') == 'reasoning' and o.get('encrypted_content'):
                    o['encrypted_content'] = o['encrypted_content'][:-12] + 'AAAAAAAAAAAA'
            status, result, timing = http(url, {**medium, 'input': history + tampered + outputs}, headers)
            self.record('replay_tampered', status, result, timing)
            stripped = [o for o in output if o.get('type') != 'reasoning']
            status, result, timing = http(url, {**medium, 'input': history + stripped + outputs}, headers)
            self.record('replay_without_reasoning', status, result, timing)
            for rep in range(self.args.tier_reps):
                for tier in (['default', 'fast'] if rep % 2 == 0 else ['fast', 'default']):
                    msg = f'[QA] Set an alarm for 6:30 tomorrow (rep {rep}).' + CONTEXT
                    status, result, timing = http(url, {**base, 'service_tier': tier, 'input': [{'role': 'user', 'content': msg}]}, headers)
                    self.record(f'tier_{tier}', status, result, timing, requested_tier=tier)
            return
        for name, msg in [('format_with_tools_toolcall', ASK), ('format_with_tools_reply', '[QA] What kinds of things can you help me with?' + CONTEXT)]:
            status, result, timing = http(url, {**base, 'text': fmt, 'input': [{'role': 'user', 'content': msg}]}, headers)
            self.record(name, status, result, timing)
        for rep in range(self.args.tier_reps):
            for tier in (['default', 'fast'] if rep % 2 == 0 else ['fast', 'default']):
                msg = f'[QA] Remind me to call [QA] Sam on Friday at 9 (rep {rep}).' + CONTEXT
                status, result, timing = http(url, {**base, 'service_tier': tier, 'input': [{'role': 'user', 'content': msg}]}, headers)
                self.record(f'tier_{tier}', status, result, timing, requested_tier=tier)

    def cleanup(self):
        if self.token:
            status, _, _ = self.worker('/auth/account', method='DELETE')
            self.record('delete_synthetic_account', status, {}, {}, rejected_after=self.worker('/auth/session', method='GET')[0] == 401)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default='https://today-luna-api.1031luy.workers.dev')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--phase', choices=['worker', 'direct', 'replay'], required=True)
    parser.add_argument('--key-file', type=Path)
    parser.add_argument('--ttl-minutes', type=int, nargs='*', default=[])
    parser.add_argument('--tier-reps', type=int, default=6)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit('Existing probe receipt; refusing a duplicate paid run')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    probe = Probe(args)
    try:
        if args.phase == 'worker':
            probe.worker_phase()
        else:
            if not args.key_file:
                raise SystemExit('--key-file is required for the direct phase')
            probe.direct_phase(replay=args.phase == 'replay')
    finally:
        probe.cleanup()


if __name__ == '__main__':
    main()
