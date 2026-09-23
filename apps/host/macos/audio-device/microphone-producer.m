// SPDX-License-Identifier: GPL-3.0-or-later
#import "microphone-producer.h"
#include "microphone-link.h"
#include <xpc/xpc.h>
#include <mach/mach_time.h>
#include <sys/mman.h>
#include <unistd.h>

enum { MicQueueFrames = 2880, MicTargetFrames = 960 };
@implementation PLANKMacMicrophoneProducer {
    dispatch_queue_t _queue;
    xpc_connection_t _peer;
    dispatch_source_t _timer;
    PLANKMicLink *_link;
    size_t _bytes;
    uint64_t _generation, _lease, _clockSeed, _nextFrame, _nextSample;
    uint64_t _requestedAt, _acknowledgedAt;
    BOOL _started, _stopped, _pending, _hasSample, _primed;
    BOOL _automaticInput;
    BOOL (^_valid)(void);
    void (^_ready)(BOOL);
    float _samples[MicQueueFrames];
    unsigned _head, _count;
    uint64_t _renderedFrames, _silenceFrames, _resyncs, _discardedFrames;
}
static uint64_t producerNow(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }
- (instancetype)init { return nil; }
- (instancetype)initWithQueue:(dispatch_queue_t)queue generation:(uint64_t)generation
                  requirement:(NSString *)requirement automaticInput:(BOOL)automaticInput
                        valid:(BOOL (^)(void))valid {
    if (!queue || !generation || !requirement.length || !valid) return nil;
    long page = sysconf(_SC_PAGESIZE); if (page <= 0) return nil;
    self = [super init]; if (!self) return nil;
    _queue = queue; _generation = generation; _valid = [valid copy];
    _automaticInput = automaticInput;
    _bytes = PLANKMicLinkBytes((size_t)page);
    _peer = xpc_connection_create_mach_service(PLANK_MIC_PRODUCER_SERVICE, queue, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if (!_peer) return nil;
    __weak typeof(self) weakSelf = self;
    xpc_connection_set_event_handler(_peer, ^(xpc_object_t message) { (void)message; [weakSelf stop]; });
    if (xpc_connection_set_peer_code_signing_requirement(_peer, requirement.UTF8String)) {
        xpc_connection_cancel(_peer); xpc_connection_activate(_peer); _peer = nil; return nil;
    }
    xpc_connection_activate(_peer); return self;
}
- (BOOL)available { dispatch_assert_queue(_queue); return _link && !_stopped; }
- (void)start:(void (^)(BOOL))ready {
    dispatch_assert_queue(_queue);
    if (_started || _stopped || !ready) { if (ready) ready(NO); return; }
    _started = YES; _ready = [ready copy];
    if (!_valid()) { [self stop]; return; }
    __weak typeof(self) weakSelf = self;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 5*NSEC_PER_MSEC, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; });
    dispatch_resume(_timer); [self request];
}
- (void)request {
    if (_pending || _stopped) return;
    if (!_valid()) { [self stop]; return; }
    _pending = YES; _requestedAt = producerNow();
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(message, "version", 1);
    xpc_dictionary_set_uint64(message, "generation", _generation);
    xpc_dictionary_set_bool(message, "automatic_input", _automaticInput);
    __weak typeof(self) weakSelf = self;
    xpc_connection_send_message_with_reply(_peer, message, _queue, ^(xpc_object_t reply) {
        typeof(self) owner = weakSelf; if (!owner || owner->_stopped) return;
        xpc_object_t leaseValue = xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_value(reply, "lease") : NULL;
        if (xpc_connection_get_euid(owner->_peer) != 0 || !leaseValue || xpc_get_type(leaseValue) != XPC_TYPE_UINT64 ||
            !owner->_valid() || producerNow() - owner->_requestedAt >= NSEC_PER_SEC ||
            xpc_dictionary_get_count(reply) != (owner->_link ? 1u : 2u)) { [owner stop]; return; }
        uint64_t lease = xpc_uint64_get_value(leaseValue);
        if (!lease || (owner->_lease && owner->_lease != lease)) { [owner stop]; return; }
        if (!owner->_link) {
            xpc_object_t memory = xpc_dictionary_get_value(reply, "memory");
            if (!memory || xpc_get_type(memory) != XPC_TYPE_SHMEM) { [owner stop]; return; }
            void *mapping = NULL; size_t size = xpc_shmem_map(memory, &mapping);
            PLANKMicLink *link = mapping;
            if (!mapping || size != owner->_bytes || link->version != PLANKMicLinkVersion ||
                !isfinite(link->ticksPerFrame) || link->ticksPerFrame < 1 || link->ticksPerFrame > 1000000) {
                if (mapping) munmap(mapping, size);
                [owner stop]; return;
            }
            owner->_link = link; owner->_lease = lease;
        }
        owner->_pending = NO; owner->_acknowledgedAt = producerNow();
        void (^ready)(BOOL) = owner->_ready; owner->_ready = nil;
        if (ready) ready(YES);
    });
}
- (BOOL)submit:(const float *)samples count:(uint32_t)count sampleTime:(uint64_t)sampleTime {
    dispatch_assert_queue(_queue);
    if (!_link || _stopped || !samples || count != PLANKMicPacketFrames ||
        sampleTime % PLANKMicPacketFrames || sampleTime > UINT64_MAX - count ||
        (_hasSample && sampleTime < _nextSample)) return NO;
    for (unsigned i = 0; i < count; i++) if (!isfinite(samples[i])) return NO;
    if (_hasSample && sampleTime != _nextSample) {
        // Missing packets are silence, never repetitions of old speech. Large
        // discontinuities flush immediately rather than padding a stale queue.
        uint64_t missing = sampleTime - _nextSample;
        if (missing <= 2 * PLANKMicPacketFrames && _count + missing + count <= MicQueueFrames) {
            for (unsigned i = 0; i < missing; i++) _samples[(_head + _count++) % MicQueueFrames] = 0;
        } else { _head = _count = 0; _primed = NO; }
    }
    _hasSample = YES; _nextSample = sampleTime + count;
    if (_count + count > MicQueueFrames) {
        unsigned discard = _count + count - MicQueueFrames;
        _head = (_head + discard) % MicQueueFrames; _count -= discard;
        _discardedFrames += discard;
    }
    for (unsigned i = 0; i < count; i++) _samples[(_head + _count++) % MicQueueFrames] = fminf(1, fmaxf(-1, samples[i]));
    return YES;
}
- (void)tick {
    if (_stopped) return;
    uint64_t ns = producerNow();
    if (_pending && ns - _requestedAt >= NSEC_PER_SEC) { [self stop]; return; }
    if (!_pending && ns - _acknowledgedAt >= 500*NSEC_PER_MSEC) [self request];
    if (!_link || _stopped) return;
    uint64_t sequence = atomic_load(&_link->clockSequence);
    if (sequence & 1) return;
    uint64_t anchor = atomic_load(&_link->anchor), seed = atomic_load(&_link->seed);
    unsigned running = atomic_load(&_link->running);
    if (sequence != atomic_load(&_link->clockSequence)) return;
    uint64_t now = mach_absolute_time();
    if (!running || !anchor || !seed || now < anchor) {
        atomic_store(&_link->deadline, 0); _count = _head = 0; _primed = NO; return;
    }
    uint64_t frame = (uint64_t)((now - anchor) / _link->ticksPerFrame);
    if (_clockSeed != seed || _nextFrame < frame || _nextFrame > frame + PLANKMicRate) {
        atomic_store(&_link->deadline, 0);
        _clockSeed = seed; _nextFrame = ((frame + 959) / 480) * 480;
        PLANKMicBufferReset(&_link->samples, _nextFrame);
        atomic_store(&_link->producerSeed, seed); _primed = NO;
        _resyncs++;
    }
    if (!_primed && _count >= MicTargetFrames) _primed = YES;
    // <=30 ms look-ahead and at most three 10 ms blocks per tick. Adjust one
    // sample per block around the 20 ms target to absorb independent clocks;
    // never enlarge the queue to conceal drift or late network delivery.
    for (unsigned block = 0; block < 3 && _nextFrame < frame + 1440; block++) {
        float output[480] = {0};
        if (_primed && _count >= 479) {
            unsigned consume = _count > MicTargetFrames + 480 ? 481 : _count < MicTargetFrames ? 479 : 480;
            for (unsigned i = 0; i < 480; i++) {
                double offset = (double)i * consume / 480;
                unsigned a = (unsigned)offset, b = MIN(a + 1, consume - 1);
                output[i] = _samples[(_head + a) % MicQueueFrames] * (1 - (offset - a)) +
                    _samples[(_head + b) % MicQueueFrames] * (offset - a);
            }
            _head = (_head + consume) % MicQueueFrames; _count -= consume;
        } else { _primed = NO; _silenceFrames += 480; }
        PLANKMicBufferWrite(&_link->samples, _nextFrame, output, 480);
        _renderedFrames += 480;
        _nextFrame += 480;
    }
    atomic_store(&_link->deadline, now + (uint64_t)(_link->ticksPerFrame * 24000));
}
- (void)silence {
    dispatch_assert_queue(_queue);
    if (_link) {
        atomic_store(&_link->deadline, 0);
        PLANKMicBufferReset(&_link->samples, _nextFrame);
    }
    memset(_samples, 0, sizeof(_samples));
    _count = _head = 0; _primed = _hasSample = NO;
}
- (void)stop {
    dispatch_assert_queue(_queue);
    if (_stopped) return;
    _stopped = YES;
    if (_link) { atomic_store(&_link->deadline, 0); munmap(_link, _bytes); _link = NULL; }
    if (_timer) dispatch_source_cancel(_timer);
    if (_peer) xpc_connection_cancel(_peer);
    memset(_samples, 0, sizeof(_samples)); _count = 0;
    NSLog(@"PLANK microphone producer stopped: frames=%llu silence=%llu resyncs=%llu overflow=%llu",
        (unsigned long long)_renderedFrames, (unsigned long long)_silenceFrames,
        (unsigned long long)_resyncs, (unsigned long long)_discardedFrames);
    void (^ready)(BOOL) = _ready; _ready = nil;
    if (ready) ready(NO);
}
- (void)dealloc {
    if (_link) { atomic_store(&_link->deadline, 0); munmap(_link, _bytes); }
    if (_timer) dispatch_source_cancel(_timer);
    if (_peer) xpc_connection_cancel(_peer);
}
@end
