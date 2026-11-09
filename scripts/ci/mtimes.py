#!/usr/bin/env python3
"""Make every source file's modification time a pure function of its content.

A fresh checkout stamps every file with "now", so a DerivedData restored from an earlier run looks
stale and Xcode and the Swift driver rebuild everything. Here the same bytes always get the same
time, and different bytes a different one, so exactly the changed files are recompiled. This covers
tracked files and the generated Xcode project. Standard library only.
"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
EPOCH = 946684800  # 2000-01-01; every stamp is at or before it, so never "in the future".
SPAN = 1 << 29  # about 17 years of distinct seconds


def stamp_for(data):
    return EPOCH - int(hashlib.sha256(data).hexdigest()[:12], 16) % SPAN


def stamp(root=ROOT):
    tracked = subprocess.run(['git', 'ls-files', '-z'], cwd=root, capture_output=True, text=True, check=True)
    files = [root / name for name in tracked.stdout.split('\0') if name]
    files += [path for path in (root / 'ios/Today.xcodeproj').rglob('*')]
    files = [path for path in files if path.is_file() and not path.is_symlink()]
    for path in files:
        when = stamp_for(path.read_bytes())
        os.utime(path, (when, when))
    # Deepest first: stamping a child's parent must come after the child.
    for folder in sorted({path.parent for path in files}, key=lambda p: len(p.parts), reverse=True):
        os.utime(folder, (EPOCH, EPOCH))
    return len(files)


if __name__ == '__main__':
    print(f'stamped {stamp()} files', file=sys.stderr)
