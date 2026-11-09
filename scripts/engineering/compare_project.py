#!/usr/bin/env python3
"""Check source/resource and extension embedding equivalence before project retirement."""
import argparse
import json
from pathlib import Path
import subprocess

RENAMED = {'Today': 'One', 'TodayShare': 'ShareExtension'}


def read(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


def graph(path):
    project = read(path)
    objects = project['objects']
    paths = {}

    def walk(ref, base=Path()):
        item = objects[ref]
        here = base / item.get('path', '')
        if item.get('isa') in {'PBXGroup', 'PBXFileSystemSynchronizedRootGroup'}:
            for child in item.get('children', []):
                walk(child, here)
        else:
            paths[ref] = str(here)

    walk(objects[project['rootObject']]['mainGroup'])
    result = {}
    for target in objects.values():
        if target.get('isa') != 'PBXNativeTarget':
            continue
        sources, resources, embedded = set(), set(), set()
        for ref in target.get('fileSystemSynchronizedGroups', []):
            base = objects[ref]['path']
            for file in (path.parent.parent / base).rglob('*'):
                if not file.is_file() or file.name == '.DS_Store':
                    continue
                relative = file.relative_to(path.parent.parent)
                if file.suffix == '.swift':
                    sources.add(str(relative))
                else:
                    asset = next((p for p in relative.parents if p.suffix == '.xcassets'), None)
                    resources.add(str(asset or relative))
        for phase_ref in target.get('buildPhases', []):
            phase = objects[phase_ref]
            for build_ref in phase.get('files', []):
                build = objects[build_ref]
                file_ref = build.get('fileRef')
                if file_ref is None:
                    continue
                file = paths.get(file_ref, objects[file_ref].get('path', ''))
                if phase['isa'] == 'PBXSourcesBuildPhase':
                    sources.add(file)
                elif phase['isa'] == 'PBXResourcesBuildPhase':
                    resources.add(file)
                elif phase['isa'] == 'PBXCopyFilesBuildPhase':
                    embedded.add(objects[file_ref].get('path', file))
        result[RENAMED.get(target['name'], target['name'])] = {
            'sources': sorted(sources), 'resources': sorted(resources),
            'embedded': sorted(embedded), 'productType': target['productType'],
        }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('old', type=Path)
    parser.add_argument('generated', type=Path)
    args = parser.parse_args()
    left, right = graph(args.old), graph(args.generated)
    changes = {target: {'old': left.get(target), 'generated': right.get(target)}
               for target in left.keys() | right.keys() if left.get(target) != right.get(target)}
    print(json.dumps({'equivalent': not changes, 'differences': changes,
                      'targets': {t: {k: len(v) if isinstance(v, list) else v for k, v in d.items()}
                                  for t, d in right.items()}}, indent=2))
    return bool(changes)


if __name__ == '__main__':
    raise SystemExit(main())
