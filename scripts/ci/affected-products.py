#!/usr/bin/env python3
"""Select product builds from changed paths; unknown changes build everything."""
import json
import os
from pathlib import Path
import subprocess

PRODUCTS = ('linux-host', 'linux-client', 'macos-host', 'macos-client')


def affected(paths):
    result = set()
    for path in paths:
        if path.startswith('docs/') or path.endswith(('.md', '.plan')):
            continue
        if path.startswith('apps/client'):
            result.update(('linux-client', 'macos-client'))
        elif path.startswith(('apps/host/linux', 'packaging/host/linux/')):
            result.add('linux-host')
        elif path.startswith(('apps/host/macos/', 'packaging/host/macos/')):
            result.add('macos-host')
        elif path.startswith('packaging/client/linux/'):
            result.add('linux-client')
        elif path.startswith('packaging/client/macos/'):
            result.add('macos-client')
        else:
            return list(PRODUCTS)
    return sorted(result)


def select(event, event_name, head):
    if event_name == 'workflow_dispatch':
        return list(PRODUCTS)
    base = event.get('pull_request', {}).get('base', {}).get('sha') if event_name == 'pull_request' else event.get('before')
    if not base or set(base) == {'0'}:
        return list(PRODUCTS)
    try:
        paths = subprocess.check_output(['git', 'diff', '--name-only', '-z', base, head], stderr=subprocess.PIPE).decode().split('\0')
    except (subprocess.CalledProcessError, UnicodeError):
        return list(PRODUCTS)
    return affected([path for path in paths if path])


if __name__ == '__main__':
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    products = select(event, os.environ['GITHUB_EVENT_NAME'], os.environ['GITHUB_SHA'])
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('products=' + json.dumps(products) + '\n')
        output.write('macos=' + json.dumps([p.removeprefix('macos-') for p in products if p.startswith('macos-')]) + '\n')
    print('Selected product builds:', ', '.join(products) or 'none (documentation only)')
