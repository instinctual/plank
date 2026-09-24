// SPDX-License-Identifier: GPL-3.0-or-later
// In-process CMIO source lifecycle only. No service activation, root broker,
// camera consent, device capture, network or system extension installation.
#import "camera-consumer.h"
#import "camera-signing.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreMediaIO/CoreMediaIO.h>
// Only the frame factory; the diagnostic bundle identifiers are unrelated.
CMSampleBufferRef PLANKCameraFixtureCreateSized(unsigned width, unsigned height) CF_RETURNS_RETAINED;
NSArray *PLANKCameraFixtureCreateSequence(unsigned width, unsigned height, unsigned count);
#include "plank_transport_camera.h"
#include <stdio.h>
#include <unistd.h>

static void (^admission)(uint64_t);
static void (^frame)(const uint8_t *, size_t, uint64_t, uint64_t);
static BOOL admitted;
static unsigned keyRequests, delivered;
// OS delivery is the fixture boundary. Keep the production sample builder,
// stream callbacks, join handling and asynchronous provider completion intact.
@interface CMIOExtensionStream (DeliveryFixture)
- (void)testSendSampleBuffer:(CMSampleBufferRef)sample discontinuity:(CMIOExtensionStreamDiscontinuityFlags)flags
      hostTimeInNanoseconds:(uint64_t)time;
@end
@implementation CMIOExtensionStream (DeliveryFixture)
- (void)testSendSampleBuffer:(CMSampleBufferRef)sample discontinuity:(CMIOExtensionStreamDiscontinuityFlags)flags
      hostTimeInNanoseconds:(uint64_t)time {
    (void)sample; (void)flags; (void)time; delivered++;
}
@end
@implementation PLANKMacCameraConsumer
- (instancetype)initWithQueue:(dispatch_queue_t)queue requirement:(NSString *)requirement
                        lease:(void (^)(uint64_t))lease frame:(void (^)(const uint8_t *, size_t, uint64_t, uint64_t))frames
                          gap:(void (^)(void))gap {
    (void)queue; (void)requirement; (void)gap;
    if ((self = [super init])) { admission = [lease copy]; frame = [frames copy]; }
    return self;
}
- (BOOL)available { return admitted; }
- (void)start {}
- (void)stop { [self rejectLease]; }
- (void)rejectLease { admitted = NO; admission(0); }
- (void)requestKeyframe { keyRequests++; }
@end
NSString *PLANKCameraPeerRequirement(NSString *identifier) { (void)identifier; return @"synthetic-only"; }
#define main PLANKUnusedCameraExtensionMain
#define sendSampleBuffer testSendSampleBuffer
#include "camera-extension.m"
#undef sendSampleBuffer
#undef main
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"camera_lifecycle_failed line=%d\n",__LINE__); exit(1); } } while (0)

static NSData *recordAt(CMSampleBufferRef sample, uint64_t generation, uint64_t sequence) {
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
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    BOOL dependent = attachments && CFArrayGetCount(attachments) &&
        CFDictionaryGetValue(CFArrayGetValueAtIndex(attachments, 0), kCMSampleAttachmentKey_NotSync) == kCFBooleanTrue;
    PlankCameraHeader header = {.generation=generation, .sequence=sequence, .capture_time_us=sequence+1,
        .codec=PLANK_CAMERA_H264, .width=1280, .height=720, .flags=dependent ? 0 : PLANK_CAMERA_KEY_FRAME};
    NSMutableData *result = [NSMutableData dataWithLength:PLANK_CAMERA_HEADER_BYTES];
    CHECK(!plank_camera_header_encode(&header, payload.length, result.mutableBytes, result.length));
    [result appendData:payload]; return result;
}
static NSData *record(CMSampleBufferRef sample, uint64_t generation) { return recordAt(sample, generation, 0); }
static void clientsChanged(PLANKCameraStream *stream, NSArray *before, NSArray *after) {
    [stream observeValueForKeyPath:@"streamingClients" ofObject:stream.stream
        change:@{NSKeyValueChangeOldKey:before, NSKeyValueChangeNewKey:after} context:&cameraClientsContext];
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
        __block unsigned joins = 0;
        stream.readerJoined = ^{ joins++; };
        CHECK([stream startStreamAndReturnError:NULL] && stream.clients == 1);
        CHECK([stream startStreamAndReturnError:NULL] && joins == 2);
        NSObject *first = [NSObject new], *second = [NSObject new];
        clientsChanged(stream, @[first], @[first,second]); pump(.01); CHECK(joins == 3);
        clientsChanged(stream, @[first,second], @[second]); pump(.01); CHECK(joins == 3);
        clientsChanged(stream, @[first], @[second]); pump(.01); CHECK(joins == 4); // same count, new app
        clientsChanged(stream, @[], @[first]);
        [stream retire]; CHECK(![stream startStreamAndReturnError:NULL] && stream.clients == 0);
        pump(.01); CHECK(joins == 4); // queued notification cannot revive retired media
        PLANKCameraProvider *provider = [[PLANKCameraProvider alloc] init]; CHECK(provider);
        CHECK(provider.provider.devices.count == 0);
        admitted = YES; admission(1);
        CHECK(provider.provider.devices.count == 0); // no fabricated H.264 format
        NSData *one = record(fixture,1);
        frame(one.bytes, one.length, PLANKCameraHostTimeNanos(), PLANKCameraHostTimeNanos());
        // Revoke before returning to the main queue. A queued decoder/sample
        // completion must never register the retired activation's device.
        admitted = NO; admission(0); pump(.1);
        CHECK(provider.provider.devices.count == 0);
        admitted = YES; admission(2);
        frame(one.bytes, one.length, PLANKCameraHostTimeNanos(), PLANKCameraHostTimeNanos()); pump(.1);
        CHECK(provider.provider.devices.count == 0); // stale generation
        NSData *two = record(fixture,2);
        frame(two.bytes, two.length, PLANKCameraHostTimeNanos(), PLANKCameraHostTimeNanos());
        CHECK(until(^BOOL { return provider.provider.devices.count == 1; }));
        PLANKCameraDevice *device = (PLANKCameraDevice *)provider.provider.devices[0].source;
        CHECK([device.source startStreamAndReturnError:NULL]);
        NSArray *gop = PLANKCameraFixtureCreateSequence(1280,720,2); CHECK(gop.count == 2);
        CMSampleBufferRef key = (__bridge CMSampleBufferRef)gop[0], delta = (__bridge CMSampleBufferRef)gop[1];
        // Publish a fresh activation with the GOP's exact parameter sets.
        admission(3);
        NSData *keyRecord = recordAt(key,3,0);
        frame(keyRecord.bytes, keyRecord.length, PLANKCameraHostTimeNanos(), PLANKCameraHostTimeNanos());
        CHECK(until(^BOOL { return provider.provider.devices.count == 1; }));
        device = (PLANKCameraDevice *)provider.provider.devices[0].source;
        CHECK([device.source startStreamAndReturnError:NULL]);
        keyRecord = recordAt(key,3,1);
        frame(keyRecord.bytes, keyRecord.length, PLANKCameraHostTimeNanos(), PLANKCameraHostTimeNanos());
        CHECK(until(^BOOL { return delivered == 1; }));
        unsigned requests = keyRequests;
        NSData *deltaRecord = recordAt(delta,3,2);
        PlankCameraHeader header;
        CHECK(!plank_camera_header_decode(deltaRecord.bytes, deltaRecord.length, &header));
        CHECK(!(header.flags & PLANK_CAMERA_KEY_FRAME)); // actual encoded dependent picture
        frame(deltaRecord.bytes, deltaRecord.length, PLANKCameraHostTimeNanos(), PLANKCameraHostTimeNanos());
        CHECK(until(^BOOL { return delivered == 2; }) && keyRequests == requests);
        clientsChanged(device.source, @[first], @[first,second]); pump(.01);
        CHECK(keyRequests > requests && device.source.active == 0);
        requests = keyRequests;
        deltaRecord = recordAt(delta,3,3);
        frame(deltaRecord.bytes, deltaRecord.length, PLANKCameraHostTimeNanos(), PLANKCameraHostTimeNanos());
        CHECK(until(^BOOL { return delivered == 3; }) && keyRequests > requests);
        // A recovery frame already in flight cannot satisfy a later join.
        keyRecord = recordAt(key,3,4);
        frame(keyRecord.bytes, keyRecord.length, PLANKCameraHostTimeNanos(), PLANKCameraHostTimeNanos());
        [provider readerJoined]; requests = keyRequests;
        CHECK(until(^BOOL { return delivered == 4; }) && keyRequests > requests);
        keyRecord = recordAt(key,3,5);
        frame(keyRecord.bytes, keyRecord.length, PLANKCameraHostTimeNanos(), PLANKCameraHostTimeNanos());
        CHECK(until(^BOOL { return delivered == 5; })); requests = keyRequests;
        deltaRecord = recordAt(delta,3,6);
        frame(deltaRecord.bytes, deltaRecord.length, PLANKCameraHostTimeNanos(), PLANKCameraHostTimeNanos());
        CHECK(until(^BOOL { return delivered == 6; }) && keyRequests == requests);
        admitted = NO; admission(0);
        CHECK(provider.provider.devices.count == 0); pump(.1);
        CHECK(provider.provider.devices.count == 0);
        [provider stop]; CFRelease(fixture);
        puts("camera lifecycle: format publication, late-reader recovery/retry, in-flight joins and revocation passed");
    }
    return 0;
}
