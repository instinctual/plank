#!/usr/bin/env python3
"""Guard production wiring of the separately concurrency-tested lifetime gate."""
from pathlib import Path
import sys

app = Path(sys.argv[1]) / 'app/streaming'
source = (app / 'session.cpp').read_text()
for name in ('clRawHidControl', 'clCursorChunk', 'clCursorPosition'):
    body = source.split('void Session::' + name + '(', 1)[1].split('\nvoid Session::', 1)[0]
    assert 'm_QtInputCallbacks.invoke(' in body, name
    assert 'm_InputHandler' not in body, name
runtime = (app / 'qt/sessionruntime.cpp').read_text()
assert 's.m_QtInputCallbacks.publish(m_Input.get())' in runtime
clear = runtime.index('s.m_QtInputCallbacks.clear()')
assert clear < runtime.index('m_Input->shutdown()', clear)
print('client_input_callback_lifetime_wiring=pass')
