// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "native-video.h"
#import "native-audio.h"
#import "quartz-input.h"

BOOL PLANKMacPreviewRequestMatchesTopology(NSDictionary *request, NSDictionary *topology);

// All methods/callbacks run on the supplied serial session queue. stop must
// complete only after capture and encoder callbacks have drained. No UI waits.
@protocol PLANKMacPreviewCapture <NSObject>
// Non-prompting permission check in the current graphical worker. Actual
// capture still checks access at startup; this is not an authorization token.
- (BOOL)available;
- (void)startWithTopology:(NSDictionary *)topology bitrate:(uint32_t)bitrate
                   video:(PLANKMacNativeVideo *)video audio:(PLANKMacNativeAudio *)audio
                   queue:(dispatch_queue_t)queue
                 started:(void (^)(uint32_t peakBitrate))started
                  failed:(void (^)(void))failed;
// At most one replacement outstanding. Completion returns zero on failure;
// stop cancels delivery and must wait for any replacement work to drain.
- (void)setBitrate:(uint32_t)bitrate completion:(void (^)(uint32_t peakBitrate))completion;
- (void)stopWithCompletion:(void (^)(void))completion;
@end

typedef NS_ENUM(unsigned, PLANKMacPreviewState) {
    PLANKMacPreviewPrepared, PLANKMacPreviewConnecting, PLANKMacPreviewStreaming,
    PLANKMacPreviewStopping, PLANKMacPreviewStopped
};

// One-shot authenticated stream owner. Construct only from the bounded auth
// lane, after HTTPS authentication. The administrator, never request JSON,
// supplies bind/certificate configuration. All request-controlled fields are
// validated, and the token is consumed before any endpoint is opened.
// The caller must retain the owner and call stop; no implicit session takeover.
@interface PLANKMacPreviewSession : NSObject
- (instancetype)initWithSessions:(PLANKMacAuthenticationSession *)sessions
                           token:(NSString *)token peer:(NSData *)peer
                         request:(NSDictionary *)request
                        topology:(NSDictionary *(^)(void))topology
                          config:(const PlankTransportConfig *)config
                         capture:(id<PLANKMacPreviewCapture>)capture
                           input:(id<PLANKMacInputDevice>)input
             microphoneGeneration:(uint64_t)microphoneGeneration;
@property(atomic, readonly) PLANKMacPreviewState state;
// First terminal cause, made only from internal labels/numeric status codes.
// Never contains credentials, clipboard contents or input payload values.
@property(atomic, readonly, copy) NSString *stopReason;
@property(readonly) BOOL clipboardEnabled;
@property(readonly) BOOL microphoneEnabled;
// Non-secret identity used to bind explicit takeover consent to this stream.
@property(readonly, copy) NSString *sessionID;
// Secret for the authenticated HTTPS launch reply only; never log/persist.
@property(atomic, readonly, copy) NSString *transportToken;
- (void)start;
- (BOOL)mayBeTakenOverWithToken:(NSString *)token peer:(NSData *)peer;
- (BOOL)reserveTakeoverWithToken:(NSString *)token peer:(NSData *)peer;
- (void)stopWithCompletion:(void (^)(void))completion;
- (void)takeOverWithToken:(NSString *)token peer:(NSData *)peer
                   valid:(BOOL (^)(void))valid completion:(void (^)(BOOL))completion;
@end
