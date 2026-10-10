#!/usr/bin/env python3
"""Guard production wiring of the separately concurrency-tested lifetime gate."""
from pathlib import Path
import sys

source = (Path(sys.argv[1]) / 'app/streaming/session.cpp').read_text()
for name in ('clRawHidControl', 'clCursorChunk', 'clCursorPosition'):
    body = source.split('void Session::' + name + '(', 1)[1].split('\nvoid Session::', 1)[0]
    assert 'm_InputCallbacks.invoke(' in body, name
    assert 'm_InputHandler' not in body, name
cleanup = source.split('void Session::destroyInputHandler()', 1)[1].split('\nvoid Session::', 1)[0]
assert cleanup.index('m_InputCallbacks.clear()') < cleanup.index('delete m_InputHandler')
assert source.count('delete m_InputHandler') == 1
assert source.index('m_InputCallbacks.publish(m_InputHandler)') < source.index('AsyncConnectionStartThread asyncConnThread(this)')
print('client_input_callback_lifetime_wiring=pass')
