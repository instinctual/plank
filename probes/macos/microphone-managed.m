// SPDX-License-Identifier: GPL-3.0-or-later
// Isolated synthetic qualification of the actual broker/producer components.
// No physical microphone, network, capture, user login or default selection.
#import "../../apps/host/macos/audio-device/microphone-broker.h"
#import "../../apps/host/macos/audio-device/microphone-producer.h"
#import <Security/Security.h>
#include <unistd.h>
#include <math.h>
#include "../../apps/host/macos/audio-device/microphone-format.h"

static NSString *requirement(void) {
    SecCodeRef code = NULL; SecRequirementRef rule = NULL; CFStringRef text = NULL;
    if (!SecCodeCopySelf(kSecCSDefaultFlags, &code) &&
        !SecCodeCopyDesignatedRequirement(code, kSecCSDefaultFlags, &rule))
        SecRequirementCopyString(rule, kSecCSDefaultFlags, &text);
    if (rule) CFRelease(rule); if (code) CFRelease(code);
    return CFBridgingRelease(text);
}
int main(int argc, char **argv) { @autoreleasepool {
    setbuf(stdout, NULL);
    dispatch_queue_t queue = dispatch_get_main_queue();
    if (argc == 3 && !strcmp(argv[1], "--broker") && !geteuid()) {
        char *end = NULL; unsigned long value = strtoul(argv[2], &end, 10);
        if (!end || *end || !value || value >= UINT32_MAX) return 2;
        PLANKMacMicrophoneBroker *broker = [[PLANKMacMicrophoneBroker alloc] initWithQueue:queue
            requirement:requirement() authorize:^BOOL(PLANKMacAgentPeer peer, uint64_t generation) {
                return peer.uid == value && peer.pid > 1 && generation == 7;
            }];
        if (![broker start]) return 2;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90*NSEC_PER_SEC), queue, ^{ [broker stop]; exit(0); });
        puts("managed_microphone_broker=ready");
        dispatch_main();
    }
    if (argc != 2 || (strcmp(argv[1], "--produce") && strcmp(argv[1], "--constant") &&
        strcmp(argv[1], "--automatic") && strcmp(argv[1], "--unauthorized"))) return 2;
    BOOL unauthorized = !strcmp(argv[1], "--unauthorized");
    BOOL constant = !strcmp(argv[1], "--constant");
    PLANKMacMicrophoneProducer *producer = [[PLANKMacMicrophoneProducer alloc] initWithQueue:queue
        generation:unauthorized ? 8 : 7 requirement:requirement()
        automaticInput:!strcmp(argv[1], "--automatic") valid:^BOOL { return YES; }];
    if (!producer) return 2;
    [producer start:^(BOOL ready) {
        printf("managed_microphone_producer_ready=%d unauthorized=%d\n", ready, unauthorized);
        if (!ready || unauthorized) { [producer stop]; exit(!ready && unauthorized ? 0 : 1); }
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        __block uint64_t sampleTime = 0;
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 10*NSEC_PER_MSEC, NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            float samples[480 * PLANKMicChannels];
            for (unsigned i = 0; i < 480; i++) {
                samples[2*i] = constant ? .0625f : .0625f * sin((sampleTime + i) % 48 * 6.283185307179586 / 48);
                samples[2*i+1] = constant ? -.03125f : .03125f * sin((sampleTime + i) % 32 * 6.283185307179586 / 32);
            }
            if (![producer submit:samples count:480 sampleTime:sampleTime]) {
                puts("managed_microphone_submit=failed"); [producer stop]; exit(1);
            }
            sampleTime += 480;
        });
        dispatch_resume(timer);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25*NSEC_PER_SEC), queue, ^{
            dispatch_source_cancel(timer); [producer stop];
            printf("managed_microphone_sent_frames=%llu\n", (unsigned long long)sampleTime); exit(0);
        });
    }];
    dispatch_main();
} }
