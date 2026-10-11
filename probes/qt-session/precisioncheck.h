#pragma once

class QQuickWindow;

// Tests only: writes and reads a 1024-level ramp in the real Qt framebuffer.
// This is not a decoder test, panel test, or a production video readback path.
void runQtFramebufferPrecisionCheck(QQuickWindow& window);
