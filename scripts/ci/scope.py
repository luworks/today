#!/usr/bin/env python3
"""Pull request scope: may the native/test steps be skipped because nothing they read changed?

Prints `app=false` to $GITHUB_OUTPUT only when every changed file is on the skip list below;
any other file, a truncated file list or any error means `app=true` (run everything).
The jobs still run and report green under their required names. Standard library only.
"""
import json
import os
import subprocess
import sys

# Prose, images and the HTML prototype; the Luna backend has its own workflow. Nothing here is
# built, linted or read by ./dev checks (docs/engineering/tool-pins.json is, so docs/*.json runs).
DOC_SUFFIXES = ('.md', '.png', '.jpg', '.jpeg', '.html', '.css', '.svg')
SKIP_PREFIXES = ('src/', 'backend/luna/')
LIMIT = 300  # the compare API lists at most 300 files


def skippable(path):
    return path.endswith('.md') or path.startswith(SKIP_PREFIXES) or (
        path.startswith('docs/') and path.endswith(DOC_SUFFIXES))


def app_changed(files):
    return not files or len(files) >= LIMIT or not all(skippable(f) for f in files)


def main():
    try:
        out = subprocess.run(['gh', 'api', f"repos/{os.environ['GITHUB_REPOSITORY']}/compare/{os.environ['RANGE']}",
                              '--jq', '[.files[].filename]'], capture_output=True, text=True, check=True, timeout=60)
        files = json.loads(out.stdout)
    except Exception as error:  # noqa: BLE001 - any doubt runs everything
        print(f'scope unknown ({error!r}); running everything', file=sys.stderr)
        files = []
    app = app_changed(files)
    print(json.dumps({'files': len(files), 'app': app}))
    with open(os.environ.get('GITHUB_OUTPUT', os.devnull), 'a') as output:
        output.write(f"app={'true' if app else 'false'}\n")
    return 0


if __name__ == '__main__':
    sys.exit(main())
