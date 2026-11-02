#!/usr/bin/env python3
"""Sample the existing process-start/onAppear probe outside XCTest on an owned simulator."""
import argparse
import json
from pathlib import Path
import re
import statistics
import subprocess
import time

from simulator_policy import ACTIVE_NAME, require_active


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        require_active(args.simulator)
    except ValueError as error:
        parser.error(str(error))
    if args.output.exists():
        parser.error('output directory must not exist; preserve prior evidence and select a new path')
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices']
    owned = [d for group in devices.values() for d in group
             if d['udid'] == args.simulator and d['name'] == ACTIVE_NAME and d['state'] == 'Booted']
    if len(owned) != 1:
        parser.error('UDID must be the booted Today-Performance simulator')
    args.output.mkdir(parents=True, exist_ok=False)
    fixture = Path(__file__).resolve().parents[1] / 'fixtures/today-dataset.json'
    samples = []
    for i in range(4):
        subprocess.run(['xcrun', 'simctl', 'terminate', args.simulator, 'com.luworks.today'], capture_output=True)
        log = args.output / f'launch-{i}.log'
        with log.open('w') as stream:
            process = subprocess.Popen(['xcrun', 'simctl', 'launch', '--console-pty', args.simulator,
                'com.luworks.today', '-uiTesting', '-dataset', str(fixture), '-uiTestingNow', '09:41'],
                stdout=stream, stderr=subprocess.STDOUT)
            time.sleep(4)
            subprocess.run(['xcrun', 'simctl', 'terminate', args.simulator, 'com.luworks.today'], capture_output=True)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)
        matches = re.findall(r'LAUNCH first frame: (\d+)ms', log.read_text(errors='replace'))
        if len(matches) != 1:
            raise RuntimeError(f'Expected exactly one appearance sample in {log}, got {matches}')
        samples.append(int(matches[0]))
    result = dict(method='kernel process start to HomeView.onAppear; process-cold/OS-warm, Debug simulator',
                  warmup_ms=samples[0], samples_ms=samples[1:], median_ms=statistics.median(samples[1:]), n=3,
                  p95=None, simulator=owned[0], fixture=str(fixture))
    (args.output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
