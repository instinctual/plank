// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

// Owned synthetic gradient; never uses any physical or desktop capture source.
CMSampleBufferRef PLANKCameraFixtureCreate(void) CF_RETURNS_RETAINED;
CVPixelBufferRef PLANKCameraFixtureDecode(CMSampleBufferRef sample) CF_RETURNS_RETAINED;
NSString *PLANKCameraFixtureDigest(CMSampleBufferRef sample);

#define PLANK_CAMERA_PROBE_ID @"la.instinctual.PLANK.NativeCameraProbe"
#define PLANK_CAMERA_EXTENSION_ID @"la.instinctual.PLANK.NativeCameraProbe.Camera"
#define PLANK_CAMERA_DEVICE_ID @"A45AF233-534D-4CDD-B824-CB5525B78B99"
