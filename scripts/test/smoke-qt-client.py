#!/usr/bin/env python3
"""Exercise the full, uninstalled launcher on an isolated hosted compositor."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--reports', type=Path, required=True)
    args = parser.parse_args()
    args.reports.mkdir(parents=True, exist_ok=True)
    for attempt in range(3):
        with tempfile.TemporaryDirectory(prefix='plank-qt-launcher-') as directory:
            environment = os.environ.copy()
            for kind in ('CONFIG', 'DATA', 'CACHE', 'STATE'):
                path = Path(directory) / kind.lower()
                path.mkdir(mode=0o700)
                environment[f'XDG_{kind}_HOME'] = str(path)
            # An SDL video probe must fail this test instead of silently opening
            # a second native connection. SDL audio/timers remain available.
            environment['SDL_VIDEO_DRIVER'] = 'plank-disabled-for-qt-test'
            report = args.reports / f'launcher-{attempt}.log'
            with report.open('w') as output:
                process = subprocess.Popen([str(args.binary.resolve())], env=environment,
                                           stdout=output, stderr=subprocess.STDOUT)
                try:
                    time.sleep(4)
                    if process.poll() is not None:
                        raise RuntimeError('Qt launcher exited before the shutdown test')
                    process.terminate()
                    if process.wait(timeout=20) != 0:
                        raise RuntimeError('Qt launcher did not shut down cleanly')
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
            # These are exclusively generated test logs from an empty profile.
            with report.open('a') as output:
                for log in sorted((Path(directory) / 'state').rglob('*.log')):
                    output.write(log.read_text(errors='replace'))
            text = report.read_text(errors='replace')
            if 'Qt launcher ready; decoder qualification deferred' not in text:
                raise RuntimeError('Qt launcher did not load its real QML window')
            if re.search(r'SDL_InitSubSystem\(SDL_INIT_VIDEO\)|QQmlApplicationEngine failed|'
                         r'Cannot assign|ReferenceError:|TypeError:|Assertion.*failed|'
                         r'QObject: Cannot create children|QThread: Destroyed while', text):
                raise RuntimeError('Qt launcher reported a lifecycle or QML error')
    print('qt_full_launcher_smoke=pass runs=3 (not a live-stream qualification)')


if __name__ == '__main__':
    main()
