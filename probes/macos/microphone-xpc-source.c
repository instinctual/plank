// SPDX-License-Identifier: GPL-3.0-or-later
// Temporary root launchd fixture: synthetic tone over bounded shared memory.
// XPC authenticates/setup only; no per-block message, physical input or network.
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pwd.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include "microphone-xpc-shared.h"

static xpc_connection_t driver;
static PLANKMicProbeShared *shared;
static uint64_t seed, nextFrame;
static unsigned blocks, resyncs;
static bool connected;
static uint64_t lastTick, maxTickGap;

int main(int argc, char **argv) {
    if (getuid() || argc != 2 || strcmp(argv[1], "--synthetic-microphone-probe")) return 2;
    setbuf(stdout, NULL);
    struct passwd *account = getpwnam("_coreaudiod");
    if (!account) return 2;
    uid_t audioUID = account->pw_uid;
    long page = sysconf(_SC_PAGESIZE);
    if (page <= 0) return 2;
    size_t mappedBytes = (sizeof(*shared) + (size_t)page - 1) / (size_t)page * (size_t)page;
    dispatch_queue_t queue = dispatch_queue_create("la.instinctual.PLANK.Microphone.probe-source",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    xpc_connection_t listener = xpc_connection_create_mach_service("la.instinctual.PLANK.Microphone.probe",
        queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!listener) return 2;
    xpc_connection_set_event_handler(listener, ^(xpc_object_t object) {
        if (xpc_get_type(object) != XPC_TYPE_CONNECTION) return;
        xpc_connection_t peer = (xpc_connection_t)object;
        xpc_connection_set_target_queue(peer, queue);
        // XPC verifies live signing identity; never trust a peer-supplied PID.
        if (xpc_connection_set_peer_code_signing_requirement(peer,
                "anchor apple and identifier \"com.apple.audio.Core-Audio-Driver-Service.helper\"")) {
            xpc_connection_cancel(peer); return;
        }
        xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
            if (xpc_get_type(message) == XPC_TYPE_ERROR) {
                if (driver == peer && shared) {
                    connected = false;
                    atomic_store(&shared->deadline, 0);
                }
                return;
            }
            if (xpc_get_type(message) != XPC_TYPE_DICTIONARY || xpc_connection_get_euid(peer) != audioUID ||
                xpc_dictionary_get_count(message) != 2 || xpc_dictionary_get_uint64(message, "version") != 1 || driver) {
                xpc_connection_cancel(peer); return;
            }
            xpc_object_t memory = xpc_dictionary_get_value(message, "memory");
            xpc_object_t reply = xpc_dictionary_create_reply(message);
            if (!memory || xpc_get_type(memory) != XPC_TYPE_SHMEM || !reply) {
                if (reply) xpc_release(reply);
                xpc_connection_cancel(peer); return;
            }
            void *mapping = NULL;
            size_t size = xpc_shmem_map(memory, &mapping);
            // Fixed layout from an authenticated Apple helper, not arbitrary
            // incoming audio data. Mapping lasts only this 30-second process.
            if (size != mappedBytes || !mapping) exit(2);
            shared = mapping;
            if (shared->version != 1 || !isfinite(shared->ticksPerFrame) || shared->ticksPerFrame < 1 ||
                shared->ticksPerFrame > 1000000) exit(2);
            driver = peer; xpc_retain(driver);
            connected = true;
            xpc_dictionary_set_bool(reply, "accepted", true);
            xpc_connection_send_message(peer, reply); xpc_release(reply);
            puts("microphone_xpc_driver_authenticated=1");
        });
        xpc_connection_activate(peer);
    });
    xpc_connection_activate(listener);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        if (!shared || !connected) return;
        uint64_t before = atomic_load(&shared->clockSequence);
        if (before & 1) return;
        uint64_t anchor = atomic_load(&shared->anchor), clockSeed = atomic_load(&shared->seed);
        bool running = atomic_load(&shared->running);
        if (before != atomic_load(&shared->clockSequence)) return;
        uint64_t now = mach_absolute_time();
        if (lastTick && now - lastTick > maxTickGap) maxTickGap = now - lastTick;
        lastTick = now;
        if (!running || !anchor || now < anchor) { atomic_store(&shared->deadline, 0); return; }
        uint64_t frame = (uint64_t)((now - anchor) / shared->ticksPerFrame);
        if (seed != clockSeed || nextFrame < frame || nextFrame > frame + 2400) {
            atomic_store(&shared->deadline, 0);
            seed = clockSeed;
            nextFrame = ((frame + 479) / 480) * 480;
            PLANKMicBufferReset(&shared->buffer, nextFrame);
            atomic_store(&shared->producerSeed, seed);
            resyncs++;
        }
        // At most four 10 ms blocks; no unbounded catch-up or packet RPC wait.
        for (unsigned n = 0; n < 4 && nextFrame < frame + 1440; n++) {
            float samples[480];
            for (unsigned i = 0; i < 480; i++)
                samples[i] = .0625f * (float)sin((nextFrame + i) % 48 * 6.283185307179586 / 48);
            if (!PLANKMicBufferWrite(&shared->buffer, nextFrame, samples, 480)) exit(2);
            nextFrame += 480; blocks++;
        }
        atomic_store(&shared->deadline, now + (uint64_t)(shared->ticksPerFrame * 24000));
    });
    dispatch_resume(timer);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), queue, ^{
        if (shared) atomic_store(&shared->deadline, 0);
        printf("microphone_xpc_source_done blocks=%u resyncs=%u reads=%llu missing=%llu disabled=%llu steady_missing=%llu steady_disabled=%llu max_tick_frames=%.0f\n", blocks, resyncs,
            (unsigned long long)(shared ? atomic_load(&shared->readFrames) : 0),
            (unsigned long long)(shared ? atomic_load(&shared->missingFrames) : 0),
            (unsigned long long)(shared ? atomic_load(&shared->disabledFrames) : 0),
            (unsigned long long)(shared ? atomic_load(&shared->steadyMissing) : 0),
            (unsigned long long)(shared ? atomic_load(&shared->steadyDisabled) : 0),
            shared ? maxTickGap / shared->ticksPerFrame : 0);
        exit(driver && blocks ? 0 : 1);
    });
    dispatch_main();
}
