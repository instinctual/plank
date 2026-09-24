// SPDX-License-Identifier: GPL-3.0-or-later
// In-process CMIO source lifecycle only. No service activation, root broker,
// camera consent, device capture, network or system extension installation.
#import "camera-consumer.h"
#import "camera-signing.h"
#import "native-camera-fixture.h"
#include "plank_transport_camera.h"
#include <stdio.h>
#include <unistd.h>

static void (^admission)(uint64_t);
static void (^frame)(const uint8_t *, size_t, uint64_t);
static BOOL admitted;
@implementation PLANKMacCameraConsumer
- (instancetype)initWithQueue:(dispatch_queue_t)queue requirement:(NSString *)requirement
                        lease:(void (^)(uint64_t))lease frame:(void (^)(const uint8_t *, size_t, uint64_t))frames
                          gap:(void (^)(void))gap {
    (void)queue; (void)requirement; (void)gap;
    if ((self = [super init])) { admission = [lease copy]; frame = [frames copy]; }
    return self;
}
- (BOOL)available { return admitted; }
- (void)start {}
- (void)stop { [self rejectLease]; }
- (void)rejectLease { admitted = NO; admission(0); }
- (void)requestKeyframe {}
@end
NSString *PLANKCameraPeerRequirement(NSString *identifier) { (void)identifier; return @"synthetic-only"; }
#define main PLANKUnusedCameraExtensionMain
#include "camera-extension.m"
#undef main
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"camera_lifecycle_failed line=%d\n",__LINE__); exit(1); } } while (0)

static NSData *record(CMSampleBufferRef sample, uint64_t generation) {
    NSMutableData *payload = [NSMutableData data]; const uint8_t prefix[] = {0,0,0,1};
    CMVideoFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    for (unsigned i = 0; i < 2; i++) {
        const uint8_t *bytes = NULL; size_t size = 0;
        CHECK(!CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &bytes, &size, NULL, NULL));
        [payload appendBytes:prefix length:4]; [payload appendBytes:bytes length:size];
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    NSMutableData *source = [NSMutableData dataWithLength:CMBlockBufferGetDataLength(block)];
    CHECK(!CMBlockBufferCopyDataBytes(block, 0, source.length, source.mutableBytes));
    const uint8_t *bytes = source.bytes;
    for (size_t at = 0; at < source.length;) {
        CHECK(source.length - at >= 4); size_t size = plank_transport_control_read_u32(bytes + at); at += 4;
        CHECK(size && size <= source.length - at);
        [payload appendBytes:prefix length:4]; [payload appendBytes:bytes+at length:size]; at += size;
    }
    PlankCameraHeader header = {.generation=generation, .capture_time_us=1, .codec=PLANK_CAMERA_H264,
        .width=1280, .height=720, .flags=PLANK_CAMERA_KEY_FRAME};
    NSMutableData *result = [NSMutableData dataWithLength:PLANK_CAMERA_HEADER_BYTES];
    CHECK(!plank_camera_header_encode(&header, payload.length, result.mutableBytes, result.length));
    [result appendData:payload]; return result;
}
static void pump(double seconds) { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]]; }
static BOOL until(BOOL (^predicate)(void)) {
    for (unsigned i = 0; i < 200; i++) { if (predicate()) return YES; pump(.005); }
    return predicate();
}
int main(void) {
    @autoreleasepool {
        alarm(15);
        CMSampleBufferRef fixture = PLANKCameraFixtureCreateSized(1280,720); CHECK(fixture);
        CMVideoFormatDescriptionRef format = CMSampleBufferGetFormatDescription(fixture);
        PLANKCameraStream *stream = [[PLANKCameraStream alloc] initWithFormat:format]; CHECK(stream);
        CHECK(stream.formats.count == 2 && CMFormatDescriptionEqual(stream.formats[0].formatDescription, format));
        NSArray *formats = stream.formats;
        CMIOExtensionStreamProperties *properties = [[CMIOExtensionStreamProperties alloc] initWithDictionary:@{}];
        properties.activeFormatIndex = @1;
        CHECK([stream setStreamProperties:properties error:NULL] && stream.active == 1 && stream.formats == formats);
        properties.activeFormatIndex = @2; CHECK(![stream setStreamProperties:properties error:NULL]);
        CHECK([stream startStreamAndReturnError:NULL] && stream.clients == 1);
        [stream retire]; CHECK(![stream startStreamAndReturnError:NULL] && stream.clients == 0);
        PLANKCameraProvider *provider = [[PLANKCameraProvider alloc] init]; CHECK(provider);
        CHECK(provider.provider.devices.count == 0);
        admitted = YES; admission(1);
        CHECK(provider.provider.devices.count == 0); // no fabricated H.264 format
        NSData *one = record(fixture,1);
        frame(one.bytes, one.length, PLANKCameraHostTimeNanos());
        // Revoke before returning to the main queue. A queued decoder/sample
        // completion must never register the retired activation's device.
        admitted = NO; admission(0); pump(.1);
        CHECK(provider.provider.devices.count == 0);
        admitted = YES; admission(2);
        frame(one.bytes, one.length, PLANKCameraHostTimeNanos()); pump(.1);
        CHECK(provider.provider.devices.count == 0); // stale generation
        NSData *two = record(fixture,2);
        frame(two.bytes, two.length, PLANKCameraHostTimeNanos());
        CHECK(until(^BOOL { return provider.provider.devices.count == 1; }));
        admitted = NO; admission(0);
        CHECK(provider.provider.devices.count == 0); pump(.1);
        CHECK(provider.provider.devices.count == 0);
        [provider stop]; CFRelease(fixture);
        puts("camera lifecycle: native-format publication, fixed formats, stale generation and queued revocation passed");
    }
    return 0;
}
