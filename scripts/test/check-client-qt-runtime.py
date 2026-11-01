#!/usr/bin/env python3
"""Require the shared Qt session and retain the Linux package/linkage gates."""
import argparse
from pathlib import Path
import re
import subprocess


def check_source(source):
    app = source / 'app'
    project = (app / 'app.pro').read_text()
    for token in ('linux|macx: CONFIG += plank-qt-session', 'TARGET = plank-client',
                  '!linux:!macx: error(', 'DEFINES += PLANK_QT_SESSION', 'streaming/qt/sessionruntime.cpp',
                  'streaming/qt/sessioninput.cpp', 'streaming/qt/decodedvideorenderer.cpp'):
        if token not in project:
            raise ValueError('Qt runtime build input is missing: ' + token)
    session = (app / 'streaming/session.cpp').read_text()
    entry = session.split('void Session::exec(QWindow* qtWindow)', 1)[1].split('void Session::execInternal()', 1)[0]
    if not re.search(r'#ifdef PLANK_QT_SESSION.*new QtSessionRuntime\(this\);\s*'
                     r'runtime->start\(qtWindow\);\s*return;', entry, re.S):
        raise ValueError('Qt Client still enters the ordinary session loop')
    runtime = (app / 'streaming/qt/sessionruntime.cpp').read_text()
    for token in ('QThread::create', 's.initialize(m_Factory.get())',
                  's.startConnectionAsync()', 's.runPlankReconnect()', 'm_Input->startTablets',
                  's.stopPlankTransportDataPlane()', 'readyForDeletion'):
        if token not in runtime:
            raise ValueError('Qt session lifecycle is incomplete: ' + token)
    for token in ('SDL_CreateWindow', 'SDL_PollEvent', 'SDL_WaitEvent', 'wl_display_dispatch'):
        if token in runtime:
            raise ValueError('Qt runtime owns a second native event loop: ' + token)


def check_binary(binary):
    expected = {'QtSessionRuntime::start(QWindow*)', 'QtSessionRuntime::workerMain()',
                'QtSessionWindow::mouseMoveEvent(QMouseEvent*)',
                'QtVideoPresenter::deliveryFactory() const', 'QtWaylandSessionGuard::refresh()'}
    with subprocess.Popen(['nm', '-C', '--defined-only', str(binary)],
                          stdout=subprocess.PIPE, text=True) as process:
        for line in process.stdout:
            match = re.match(r'^\S+ [Tt] (.+?)\s*$', line)
            if match:
                expected.discard(match[1])
        if process.wait():
            raise ValueError('Could not inspect the Qt Client binary')
    if expected:
        raise ValueError('Qt session owners are missing from binary: ' + ', '.join(sorted(expected)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--binary', type=Path)
    args = parser.parse_args()
    try:
        check_source(args.source)
        if args.binary:
            check_binary(args.binary)
    except (OSError, ValueError, IndexError) as error:
        parser.exit(1, str(error) + '\n')
    print('client_qt_runtime_gate=pass (source/linkage, not hardware acceptance)')
