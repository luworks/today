#!/usr/bin/env python3
"""Read-only plan/report API for ./dev and CI; never starts platform runners."""
import argparse
import json
from pathlib import Path
import sys
import contract


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('operation', choices=['plan', 'report', 'inventory'])
    p.add_argument('--group', action='append', choices=list(contract.load_manifest()['groups']))
    p.add_argument('--lane', choices=list(contract.SETTINGS['lanes']))
    p.add_argument('--xcresult-json', type=Path, help='xcresulttool get test-results tests JSON')
    p.add_argument('--log', type=Path)
    p.add_argument('--exit-code', type=int, default=0)
    args = p.parse_args(argv)
    try:
        if args.operation == 'inventory':
            result = contract.inventory()
        else:
            if not args.group:
                p.error('--group is required')
            result = contract.plan(args.group)
            if args.operation == 'report':
                if not args.lane or not result['selectors'][args.lane]:
                    p.error('--lane must select a nonempty lane from the group plan')
                raw = args.log.read_text() if args.log else ''
                if args.xcresult_json:
                    attempts = contract.xcresult_attempts(json.loads(args.xcresult_json.read_text()), args.lane)
                elif args.lane == 'logic' and args.log:
                    attempts = contract.log_attempts(raw)
                else:
                    raise ValueError('Xcode reports require structured xcresult JSON; logic requires log or xcresult JSON')
                result = contract.report(result['selectors'][args.lane], attempts, args.exit_code,
                    (), contract.load_manifest()['skip_rules'], raw, result['pending'])
    except (ValueError, OSError) as error:
        result = {'schema_version': 1, 'status': 'failed', 'errors': ['parser_error'], 'detail': str(error)}
    print(json.dumps(result, indent=2))
    return 1 if result.get('status') == 'failed' else 0


if __name__ == '__main__':
    sys.exit(main())
