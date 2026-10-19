#pragma once

// Diagnostic only: called with the Qt render-thread GL context current. This
// does not import resources or qualify interop, decoding or performance.
void reportQtGpuInteropCapabilities();
