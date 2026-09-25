// SPDX-License-Identifier: GPL-3.0-or-later
// Included by the HAL implementation. XPC/mapping work stays on one control
// queue. IO sees only the private sample history and two atomic gate values.
#include "microphone-link.h"
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
#include <sys/mman.h>
#include <unistd.h>

static dispatch_queue_t micControlQueue;
static dispatch_source_t micControlTimer;
static xpc_connection_t micControlPeer;
static PLANKMicLink *micLink;
static size_t micLinkBytes;
static uint64_t micLease, micBrokerDeadline, micConnectAt, micCopiedSeed;
static uint64_t micCopiedGeneration;
static _Atomic uint64_t micInputDeadline, micInputLease;

static void micDropLink(void) {
    atomic_store(&micInputDeadline, 0);
    atomic_store(&micInputLease, 0);
    pthread_mutex_lock(&stateLock);
    PLANKMicBufferReset(&micBuffer, 0);
    pthread_mutex_unlock(&stateLock);
    if (micLink) munmap(micLink, micLinkBytes);
    micLink = NULL; micLease = micBrokerDeadline = micCopiedSeed = micCopiedGeneration = 0;
}

static bool micWord(xpc_object_t object, const char *key, uint64_t *value) {
    xpc_object_t item = xpc_dictionary_get_value(object, key);
    if (!item || xpc_get_type(item) != XPC_TYPE_UINT64) return false;
    *value = xpc_uint64_get_value(item); return true;
}

static void micConnect(void) {
    xpc_connection_t peer = xpc_connection_create_mach_service(PLANK_MIC_DRIVER_SERVICE,
        micControlQueue, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    micControlPeer = peer;
    xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
        if (peer != micControlPeer) return;
        if (xpc_get_type(message) == XPC_TYPE_ERROR) {
            micDropLink(); micControlPeer = NULL;
            xpc_connection_cancel(peer); xpc_release(peer); return;
        }
        uint64_t version = 0, operation = 0, lease = 0;
        bool valid = xpc_connection_get_euid(peer) == 0 && xpc_get_type(message) == XPC_TYPE_DICTIONARY &&
            micWord(message, "version", &version) && version == PLANKMicLinkVersion &&
            micWord(message, "operation", &operation) && micWord(message, "lease", &lease) && lease;
        xpc_object_t reply = valid ? xpc_dictionary_create_reply(message) : NULL;
        if (!valid || !reply) { micDropLink(); xpc_connection_cancel(peer); return; }
        bool accepted = false;
        if (operation == 1 && xpc_dictionary_get_count(message) == 4) {
            xpc_object_t memory = xpc_dictionary_get_value(message, "memory");
            if (memory && xpc_get_type(memory) == XPC_TYPE_SHMEM) {
                void *mapping = NULL;
                size_t size = xpc_shmem_map(memory, &mapping);
                if (mapping && size == micLinkBytes && ((PLANKMicLink *)mapping)->version == PLANKMicLinkVersion) {
                    micDropLink(); micLink = mapping; micLease = lease;
                    micLink->ticksPerFrame = ticksPerFrame;
                    micBrokerDeadline = mach_absolute_time() + (uint64_t)(ticksPerFrame * PLANKMicRate * 2);
                    atomic_store(&micInputLease, lease); accepted = true;
                } else if (mapping) munmap(mapping, size);
            }
        } else if (operation == 2 && xpc_dictionary_get_count(message) == 3 && lease == micLease) {
            // Only root control renews admission. Producer PCM cannot extend it.
            micBrokerDeadline = mach_absolute_time() + (uint64_t)(ticksPerFrame * PLANKMicRate * 2);
            accepted = true;
        } else if (operation == 3 && xpc_dictionary_get_count(message) == 3) {
            if (lease == micLease) micDropLink();
            accepted = true;
        }
        xpc_dictionary_set_bool(reply, "accepted", accepted);
        xpc_connection_send_message(peer, reply); xpc_release(reply);
    });
    xpc_connection_activate(peer);
    xpc_object_t hello = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(hello, "version", PLANKMicLinkVersion);
    xpc_connection_send_message(peer, hello); xpc_release(hello);
}

static void micIPCTick(void) {
    uint64_t now = mach_absolute_time();
    if (!micControlPeer && now >= micConnectAt) {
        micConnectAt = now + (uint64_t)(ticksPerFrame * PLANKMicRate);
        micConnect();
    }
    if (!micLink) return;
    if (now >= micBrokerDeadline) { micDropLink(); return; }
    pthread_mutex_lock(&stateLock);
    uint64_t base = atomic_load(&anchor), seed = atomic_load(&clockSeed);
    uint32_t active = atomic_load(&running);
    atomic_fetch_add(&micLink->clockSequence, 1);
    atomic_store(&micLink->anchor, base); atomic_store(&micLink->seed, seed);
    atomic_store(&micLink->running, active);
    atomic_fetch_add(&micLink->clockSequence, 1);
    uint64_t generation = atomic_load(&micLink->samples.generation);
    if (seed != micCopiedSeed || generation != micCopiedGeneration) {
        atomic_store(&micInputDeadline, 0);
        PLANKMicBufferReset(&micBuffer, 0); micCopiedSeed = seed; micCopiedGeneration = generation;
    }
    uint64_t deadline = atomic_load(&micLink->deadline);
    // A producer can supply only bounded samples, not a future admission time.
    if (!active || now < base || deadline <= now || atomic_load(&micLink->producerSeed) != seed) {
        atomic_store(&micInputDeadline, 0);
        pthread_mutex_unlock(&stateLock); return;
    }
    uint64_t frame = (uint64_t)((now - base) / ticksPerFrame);
    frame = frame / PLANKMicPacketFrames * PLANKMicPacketFrames;
    if (frame >= PLANKMicPacketFrames) frame -= PLANKMicPacketFrames;
    for (unsigned block = 0; block < 5; block++) {
        float samples[PLANKMicPacketFrames * PLANKMicChannels];
        PLANKMicBufferRead(&micLink->samples, frame, samples, PLANKMicPacketFrames);
        for (unsigned i = 0; i < PLANKMicPacketFrames * PLANKMicChannels; i++)
            samples[i] = isfinite(samples[i]) ? fminf(1, fmaxf(-1, samples[i])) : 0;
        PLANKMicBufferWrite(&micBuffer, frame, samples, PLANKMicPacketFrames);
        frame += PLANKMicPacketFrames;
    }
    uint64_t cap = now + (uint64_t)(ticksPerFrame * PLANKMicRate / 2);
    if (deadline > cap) deadline = cap;
    if (deadline > micBrokerDeadline) deadline = micBrokerDeadline;
    atomic_store(&micInputDeadline, deadline);
    pthread_mutex_unlock(&stateLock);
}

static void micIPCInitialize(void) {
    if (micControlQueue) return;
    long page = sysconf(_SC_PAGESIZE);
    if (page <= 0) return;
    micLinkBytes = PLANKMicLinkBytes((size_t)page);
    micControlQueue = dispatch_queue_create("la.instinctual.PLANK.Microphone.control",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    micControlTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, micControlQueue);
    dispatch_source_set_timer(micControlTimer, DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(micControlTimer, ^{ micIPCTick(); });
    dispatch_resume(micControlTimer);
}

static void micIPCRead(uint64_t frame, float *samples, uint32_t count) {
    uint64_t lease = atomic_load(&micInputLease);
    if (!lease || mach_absolute_time() >= atomic_load(&micInputDeadline)) return;
    PLANKMicBufferRead(&micBuffer, frame, samples, count);
    if (lease != atomic_load(&micInputLease) || mach_absolute_time() >= atomic_load(&micInputDeadline))
        memset(samples, 0, count * PLANKMicChannels * sizeof(*samples));
}
