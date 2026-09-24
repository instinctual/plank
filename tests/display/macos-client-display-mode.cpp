// CoreGraphics failure injection: no windows, devices or display changes.
#include "macdisplaymode.h"
#include <cassert>
#include <cstdio>
#include <vector>

struct Mode { size_t width, height; uint32_t flags; };
static std::vector<Mode> offered;
static Mode current;
static bool listAvailable = true, currentAvailable = true, builtin = false;
static unsigned currentQueries = 0, currentReleases = 0;

extern "C" CFArrayRef CGDisplayCopyAllDisplayModes(CGDirectDisplayID, CFDictionaryRef)
{
    if (!listAvailable) return nullptr;
    std::vector<const void*> values;
    for (const auto& mode : offered) values.push_back(&mode);
    return CFArrayCreate(nullptr, values.data(), values.size(), nullptr);
}
extern "C" CGDisplayModeRef CGDisplayCopyDisplayMode(CGDirectDisplayID)
{
    ++currentQueries;
    return currentAvailable ? reinterpret_cast<CGDisplayModeRef>(&current) : nullptr;
}
extern "C" void CGDisplayModeRelease(CGDisplayModeRef mode)
{
    assert(mode == reinterpret_cast<CGDisplayModeRef>(&current)); ++currentReleases;
}
extern "C" size_t CGDisplayModeGetPixelWidth(CGDisplayModeRef mode)
{ return reinterpret_cast<const Mode*>(mode)->width; }
extern "C" size_t CGDisplayModeGetPixelHeight(CGDisplayModeRef mode)
{ return reinterpret_cast<const Mode*>(mode)->height; }
extern "C" uint32_t CGDisplayModeGetIOFlags(CGDisplayModeRef mode)
{ return reinterpret_cast<const Mode*>(mode)->flags; }
extern "C" boolean_t CGDisplayIsBuiltin(CGDirectDisplayID) { return builtin; }

int main()
{
    MacDisplayMode::Snapshot result;
    // An unflagged list can omit the active mode entirely. Never infer the
    // panel from the biggest or first advertised size, or switch OS modes.
    offered = {{512, 1080, 7}, {640, 1350, 3}, {960, 540, 3}, {640, 480, 1}};
    current = {3420, 2146, 3};
    assert(MacDisplayMode::snapshot(1, result));
    assert(!result.native && result.width == 3420 && result.height == 2146 && result.safeHeight == 2146);
    assert(currentQueries == 1 && currentReleases == 1);
    offered.push_back({8192, 8192, 3});
    assert(MacDisplayMode::snapshot(1, result) && result.width == 3420 && result.height == 2146);
    offered.clear();
    assert(MacDisplayMode::snapshot(1, result) && result.width == 3420);
    listAvailable = false;
    assert(MacDisplayMode::snapshot(1, result) && result.height == 2146);
    listAvailable = true;
    offered = {{0, 2214, kDisplayModeNativeFlag}};
    assert(MacDisplayMode::snapshot(1, result) && !result.native && result.width == 3420);
    offered = {{3420, 2214, kDisplayModeNativeFlag}, {3420, 2146, 3}, {3420, 2400, 3}};
    const auto previousQueries = currentQueries;
    assert(MacDisplayMode::snapshot(1, result) && result.native && result.height == 2214 && result.safeHeight == 2214);
    assert(currentQueries == previousQueries);
    builtin = true;
    assert(MacDisplayMode::snapshot(1, result) && result.safeHeight == 2146);
    offered.clear(); currentAvailable = false;
    assert(!MacDisplayMode::snapshot(1, result) && result.width == 0 && !result.native);
    currentAvailable = true; current.width = 0;
    assert(!MacDisplayMode::snapshot(1, result) && result.height == 0);
    current.width = static_cast<size_t>(INT_MAX) + 1;
    assert(!MacDisplayMode::snapshot(1, result) && result.width == 0);
    assert(currentQueries == currentReleases + 1); // missing mode has nothing to release
    std::puts("Mac Client display mode: native/current selection, missing lists, invalid modes and ownership passed");
}
