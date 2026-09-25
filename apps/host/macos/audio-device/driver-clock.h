// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

// SDK27 AudioServerPlugIn.h requires at least 10923 frames between zero
// timestamps. This describes the device clock, not an IO buffer or media
// packet: the HAL interpolates intervening sample positions at the fixed rate.
enum { PLANKAudioZeroTimeStampPeriod = 16384 };
_Static_assert(PLANKAudioZeroTimeStampPeriod >= 10923, "Core Audio clock period minimum");
