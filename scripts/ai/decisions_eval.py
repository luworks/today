#!/usr/bin/env python3
"""Synthetic, frozen Decisions evaluation. Runs once; never overwrites evidence."""
import hashlib
import json
import math
import os
from pathlib import Path
import secrets
import statistics
import sys
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'tests/fixtures/ai-chat-capability-eval.json'
LABELS = ROOT / 'tests/fixtures/ai/decisions-spike-labels.json'
RESULTS = Path('/Users/yuanlu/code/today/tests/results/decisions-spike-20261031')
URL = 'https://today-luna-api.1031luy.workers.dev'
THRESHOLDS = (.80, .90, .95, .98)


def request(path, data=None, token=None, method='POST'):
    headers = {'User-Agent': 'TodayDecisionsEval/1.0', 'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(URL + path, data=json.dumps(data).encode() if data is not None else None, headers=headers, method=method)
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.status, json.loads(response.read()), time.monotonic() - start
    except urllib.error.HTTPError as error:
        raw = error.read().decode('utf-8', 'replace')
        try:
            body = json.loads(raw)
        except ValueError:
            body = {'body': raw}
        return error.code, body, time.monotonic() - start


def questions(items):
    choice = lambda value: {'value': value}
    return [
        {'type': 'choice', 'name': 'kind', 'instructions': 'Classify the current user turn in context: reminder, event, alarm, edit_existing (a change to a saved item), question, chat, or other. Corrections to an unsaved preview retain its kind. A question about doing something is a question, not permission.', 'choices': list(map(choice, ['reminder','event','alarm','edit_existing','question','chat','other']))},
        {'type': 'choice', 'name': 'cardinality', 'instructions': 'Does the current contextual request concern one action or several distinct actions? For non-actions choose one.', 'choices': list(map(choice, ['one','several']))},
        {'type': 'choice', 'name': 'target', 'instructions': 'For a request to edit an existing saved item, select its uniquely identified item id; otherwise or if ambiguous select none_or_unclear.', 'choices': [dict(value=item['id'], description=item['description']) for item in items] + [choice('none_or_unclear')]},
        {'type': 'predicate', 'name': 'missing_info', 'instructions': 'Does the request lack the time or object required to perform the requested action? Undated or date-only reminders can be created without a clock time. Alarm time and an unambiguous edit target are required. For questions and chat answer false.'},
    ]


def percentile(values, q):
    values = sorted(values)
    return values[math.ceil(len(values) * q) - 1]


def input_cost(usage):
    details = usage.get('input_tokens_details', {})
    cached = details.get('cached_tokens', 0)
    writes = details.get('cache_write_tokens', 0)
    ordinary = usage['input_tokens'] - cached - writes
    if min(ordinary, cached, writes) < 0:
        raise ValueError('Invalid token usage breakdown')
    return (ordinary * .10 + cached * .01 + writes * .125) / 1_000_000


def report(rows):
    print('question n correct accuracy | threshold: correct/covered accuracy coverage')
    for name in ('kind', 'cardinality', 'target', 'missing_info'):
        observations = []
        for row in rows:
            gold = row['gold']
            if name == 'target' and 'target' not in gold:
                continue
            answers = {a.get('name'): a for a in row['response'].get('answers', [])}
            a = answers.get(name, {})
            if name == 'missing_info':
                p = a.get('probability')
                predicted = p >= .5 if isinstance(p, (int, float)) else None
                confidence = max(p, 1-p) if isinstance(p, (int, float)) else 0
            else:
                predicted = a.get('choice')
                confidence = a.get('confidence', 0)
                if not isinstance(confidence, (int, float)):
                    confidence = 0
            observations.append((predicted == gold[name], confidence))
        n = len(observations)
        if not n:
            print(name, 'n=0'); continue
        correct = sum(ok for ok, _ in observations)
        chunks = []
        for t in THRESHOLDS:
            eligible = [ok for ok, confidence in observations if confidence >= t]
            chunks.append(f'{t:.2f}: {sum(eligible)}/{len(eligible)} {sum(eligible)/len(eligible):.1%} {len(eligible)/n:.1%}' if eligible else f'{t:.2f}: 0/0 n/a 0.0%')
        print(f'{name} {n} {correct} {correct/n:.1%} | ' + ' | '.join(chunks))
    if rows:
        latency = [r['latency_seconds'] for r in rows]
        print(f'latency seconds p50={statistics.median(latency):.3f} p90={percentile(latency,.9):.3f}')
        print('tokens input=',sum(r['response']['usage']['input_tokens'] for r in rows),'output=',sum(r['response']['usage'].get('output_tokens',0) for r in rows))
        print(f'usage-priced cost ${sum(input_cost(r["response"]["usage"]) for r in rows):.6f}')


def main():
    fixture_bytes = FIXTURE.read_bytes()
    fixture, labels = json.loads(fixture_bytes), json.loads(LABELS.read_text())
    assert hashlib.sha256(fixture_bytes).hexdigest() == labels['fixture_sha256']
    assert [(c['id'],len(c['turns'])) for c in fixture['cases']] == [(c['id'],len(c['turns'])) for c in labels['cases']]
    RESULTS.mkdir(parents=True, exist_ok=True)
    rows=[]; conservative=0.0; actual=0.0; last_call=0.0
    with (RESULTS / 'answers.jsonl').open('x', encoding='utf-8') as output:
        for run in range(1,4):
            token=None
            try:
                username=f'decisions-eval-{run}'
                password=secrets.token_urlsafe(24)
                status, response, _ = request('/auth/register', {'username':username,'password':password})
                if status != 200: raise RuntimeError(f'register {username}: {status} {response}')
                token=response['token']
                status, response, _ = request('/auth/login', {'username':username,'password':password})
                if status != 200: raise RuntimeError(f'login {username}: {status} {response}')
                token=response['token']
                for case, labeled in zip(fixture['cases'], labels['cases']):
                    for index, (turn, gold) in enumerate(zip(case['turns'], labeled['turns'])):
                        if conservative + .01 > .100000001:
                            raise RuntimeError('Spike budget reservation would exceed $0.10')
                        delay=11-(time.monotonic()-last_call)
                        if delay>0: time.sleep(delay)
                        items=[i for i in labeled['seeded_items'] if i['id'] != 'medicine_reminder' or index>0]
                        messages=[{'role':'user','content':t['input']} for t in case['turns'][:index+1]]
                        messages[-1]['content'] += '\nSynthetic existing items: ' + json.dumps(items,ensure_ascii=False)
                        body={'model':'gpt-6-luna','input':messages,'questions':questions(items)}
                        conservative += .01
                        last_call=time.monotonic()
                        status, response, latency=request('/v1/decisions',body,token)
                        row={'run':run,'case':case['id'],'turn':index+1,'gold':gold,'http_status':status,'latency_seconds':latency,'response':response}
                        output.write(json.dumps(row,ensure_ascii=False)+'\n');output.flush();os.fsync(output.fileno())
                        if status!=200:
                            raise RuntimeError(f'decision HTTP {status}: {json.dumps(response,ensure_ascii=False)}; reservation retained $0.01')
                        usage=response.get('usage',{})
                        if not isinstance(usage.get('input_tokens'),int) or not isinstance(usage.get('output_tokens'),int):
                            raise RuntimeError('Missing usage; reservation retained $0.01')
                        cost=max(math.ceil(usage['input_tokens']*.1+usage['output_tokens']*.5)/1_000_000,input_cost(usage))
                        conservative += cost-.01
                        actual += input_cost(usage)
                        rows.append(row)
            finally:
                if token:
                    status, response, _=request('/auth/account',token=token,method='DELETE')
                    print(f'cleanup {username}: HTTP {status}',flush=True)
                    if status!=200: raise RuntimeError(f'account cleanup failed: HTTP {status} {response}')
    report(rows)
    print(f'usage-priced cost ${actual:.6f}; conservative spend bound ${conservative:.6f}')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'STOP: {exc}',file=sys.stderr)
        sys.exit(1)
