#!/usr/bin/env python3
"""Compare resolved Xcode settings, allowing only documented developer path/name changes."""
import argparse
import json
import re
from pathlib import Path

RENAMED = {'Today': 'One', 'TodayShare': 'ShareExtension'}


def normalized(key, value):
    if not isinstance(value, str):
        return value
    if key in {'PROJECT', 'PROJECT_NAME', 'TARGET_NAME', 'TARGETNAME', 'TEST_TARGET_NAME'}:
        return RENAMED.get(value, value)
    # Project GUID is generated; it is not a bundle, persistent model or signing identifier.
    if key == 'PROJECT_GUID':
        return '<generated-project-guid>'
    value = re.sub(r'/DerivedData/(?:One|Today)-[^/]+', '/DerivedData/<project>', value)
    value = value.replace('/Today.xcodeproj', '/One.xcodeproj')
    value = value.replace('/Today.dst', '/One.dst')
    for new, old in RENAMED.items():
        value = value.replace('/' + new + '.build', '/' + old + '.build')
    if key == 'VERSION_INFO_STRING':
        value = value.replace('PROJECT:Today-', 'PROJECT:One-')
    return value


def compare(old, new):
    original = {item['target']: item['buildSettings'] for item in old}
    differences = {}
    checked = 0
    seen = set()
    for item in new:
        target = RENAMED.get(item['target'], item['target'])
        if target in seen:
            continue
        seen.add(target)
        if target not in original:
            differences[target] = {'target': 'unexpected'}
            continue
        left, right = original.pop(target), item['buildSettings']
        changes = {}
        for key in sorted(left.keys() | right.keys()):
            checked += 1
            if normalized(key, left.get(key)) != normalized(key, right.get(key)):
                changes[key] = {'old': left.get(key), 'generated': right.get(key)}
        if changes:
            differences[target] = changes
    for target in original:
        differences[target] = {'target': 'missing'}
    return {'settings_checked': checked, 'differences': differences, 'equivalent': not differences}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('old', type=Path)
    parser.add_argument('generated', type=Path)
    args = parser.parse_args()
    result = compare(json.loads(args.old.read_text()), json.loads(args.generated.read_text()))
    print(json.dumps(result, indent=2))
    return 0 if result['equivalent'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
