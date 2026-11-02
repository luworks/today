#!/usr/bin/env python3
"""One bounded real HTTPS account→Luna agent step→revocation smoke; synthetic data only.
The server enforces the cumulative evaluation cap. Never prints tokens/passwords.
"""
import argparse
import json
from pathlib import Path
import secrets
import time
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default='https://today-luna-api.1031luy.workers.dev')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit('Existing smoke receipt; refusing a duplicate paid run')
    events = []

    def request(path, body=None, token=None, method='POST'):
        headers = {'Content-Type': 'application/json', 'User-Agent': 'TodayAPISmoke/1.0'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        req = urllib.request.Request(args.base + path, data=json.dumps(body).encode() if body else None,
                                     headers=headers, method=method)
        start = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                status, raw = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, raw = error.code, error.read()
        events.append({'path': path, 'method': method, 'status': status, 'seconds': time.monotonic()-start})
        try:
            result = json.loads(raw)
        except ValueError:
            result = {'error': 'non_json_response'}
        return status, result

    result, cleanup_token = {}, None
    try:
        assert request('/health', method='GET')[0] == 200
        assert request('/v1/responses', {})[0] == 401
        username, password = 'qa-' + secrets.token_hex(8), secrets.token_urlsafe(32)
        status, session = request('/auth/register', {'username': username, 'password': password})
        assert status == 200, (status, session.get('error'))
        cleanup_token = session['token']
        status, login = request('/auth/login', {'username': username, 'password': password})
        assert status == 200, (status, login.get('error'))
        second = login['token']
        assert second != cleanup_token and len(second) == 64
        # One agent step (agent mode is the only mode): one new run, plain-text reply, no tools.
        payload = {'tools_version': 'v1', 'run_id': 'qa-smoke-' + secrets.token_hex(8),
                   'input': [{'role': 'user', 'content': '[QA] smoke test: reply with the single word OK. Do not call any tools.'}]}
        status, response = request('/v1/responses', payload, cleanup_token)
        assert status == 200, (status, response.get('error'))
        assert response['status'] == 'completed' and response['model'] == 'gpt-6-luna'
        assert request('/auth/session', token=cleanup_token, method='GET')[1]['runsUsed'] == 1
        assert request('/auth/logout', token=cleanup_token)[0] == 200
        assert request('/auth/session', token=cleanup_token, method='GET')[0] == 401
        cleanup_token = second
        result.update(response=response, distinct_sessions=True, model='gpt-6-luna', effort='low')
    finally:
        if cleanup_token:
            status, _ = request('/auth/account', token=cleanup_token, method='DELETE')
            result['test_account_deleted'] = status == 200
            result['deleted_session_rejected'] = request('/auth/session', token=cleanup_token, method='GET')[0] == 401
        result['events'] = events
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({'events': events, 'model': result.get('model'),
                      'usage': result.get('response', {}).get('usage'),
                      'test_account_deleted': result.get('test_account_deleted')}))


if __name__ == '__main__':
    main()
