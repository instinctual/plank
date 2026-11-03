// Explicit, temporary LD_PRELOAD diagnostic. Never link into the product.
// Records successful HEVC decoder submissions, not network/authentication data.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <libavcodec/avcodec.h>

#define MAX_RECORDS 8
#define MAX_PACKET (16U * 1024U * 1024U)
#define MAX_BYTES (4ULL * 1024ULL * 1024ULL * 1024ULL)
#define MAX_SECONDS 600

struct recording { const AVCodecContext *context; int fd; };
static struct recording recordings[MAX_RECORDS] = {
    {NULL, -1}, {NULL, -1}, {NULL, -1}, {NULL, -1},
    {NULL, -1}, {NULL, -1}, {NULL, -1}, {NULL, -1}
};
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static int (*send_packet)(AVCodecContext *, const AVPacket *);
static void (*free_context)(AVCodecContext **);
static int directory = -1, stopped;
static uint64_t written;
static unsigned serial;
static struct timespec started;

static void initialize(void)
{
    send_packet = (int (*)(AVCodecContext *, const AVPacket *))dlsym(RTLD_NEXT, "avcodec_send_packet");
    free_context = (void (*)(AVCodecContext **))dlsym(RTLD_NEXT, "avcodec_free_context");
    for (unsigned i = 0; i < MAX_RECORDS; ++i) recordings[i].fd = -1;
    const char *path = getenv("PLANK_VIDEO_RECORD_DIR");
    if (!path || path[0] != '/') return;
    directory = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    struct stat info;
    if (directory < 0) return;
    if (fstat(directory, &info) || info.st_uid != geteuid() || (info.st_mode & 0077)) {
        close(directory);
        directory = -1;
        return;
    }
    clock_gettime(CLOCK_MONOTONIC, &started);
}

static void stop_recording(void)
{
    stopped = 1;
    for (unsigned i = 0; i < MAX_RECORDS; ++i) {
        if (recordings[i].fd >= 0) close(recordings[i].fd);
        recordings[i].fd = -1;
    }
    if (directory >= 0) close(directory);
    directory = -1;
}

static int write_all(int fd, const void *data, size_t size)
{
    const unsigned char *p = data;
    while (size) {
        const ssize_t result = write(fd, p, size);
        if (result < 0 && errno == EINTR) continue;
        if (result <= 0) return 0;
        p += result;
        size -= (size_t)result;
    }
    return 1;
}

static void record_packet(AVCodecContext *context, const AVPacket *packet)
{
    pthread_mutex_lock(&mutex);
    if (stopped || directory < 0) goto done;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (now.tv_sec - started.tv_sec >= MAX_SECONDS ||
            written + (uint64_t)packet->size + 16 > MAX_BYTES) {
        stop_recording();
        goto done;
    }
    struct recording *record = NULL;
    for (unsigned i = 0; i < MAX_RECORDS; ++i)
        if (recordings[i].context == context) { record = &recordings[i]; break; }
    if (!record) {
        for (unsigned i = 0; i < MAX_RECORDS; ++i)
            if (!recordings[i].context) { record = &recordings[i]; break; }
        if (!record) { stop_recording(); goto done; }
        char name[80];
        snprintf(name, sizeof(name), "hevc-%ld-%u.pvr", (long)getpid(), serial++);
        record->fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (record->fd < 0 || !write_all(record->fd, "PLANKV1\n", 8)) {
            stop_recording();
            goto done;
        }
        written += 8;
        record->context = context;
    }
    // Little-endian length/flags, then exact packet bytes. No delimiter insertion
    // or bitstream rewriting. Separate files keep qualification decoders apart.
    unsigned char header[8];
    for (unsigned i = 0; i < 4; ++i) {
        header[i] = (uint32_t)packet->size >> (i * 8);
        header[i + 4] = (uint32_t)packet->flags >> (i * 8);
    }
    if (!write_all(record->fd, header, sizeof(header)) ||
            !write_all(record->fd, packet->data, (size_t)packet->size)) {
        stop_recording();
        goto done;
    }
    written += sizeof(header) + (uint64_t)packet->size;
done:
    pthread_mutex_unlock(&mutex);
}

int avcodec_send_packet(AVCodecContext *context, const AVPacket *packet)
{
    pthread_once(&once, initialize);
    if (!send_packet) return AVERROR(ENOSYS);
    const int result = send_packet(context, packet);
    const int saved_errno = errno;
    if (result == 0 && context && context->codec_type == AVMEDIA_TYPE_VIDEO &&
            context->codec_id == AV_CODEC_ID_HEVC && packet && packet->data &&
            packet->size > 0 && (unsigned)packet->size <= MAX_PACKET)
        record_packet(context, packet);
    errno = saved_errno;
    return result;
}

void avcodec_free_context(AVCodecContext **context)
{
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    if (context && *context) {
        for (unsigned i = 0; i < MAX_RECORDS; ++i) {
            if (recordings[i].context != *context) continue;
            if (recordings[i].fd >= 0) close(recordings[i].fd);
            recordings[i].fd = -1;
            recordings[i].context = NULL;
        }
    }
    pthread_mutex_unlock(&mutex);
    if (free_context) free_context(context);
}

__attribute__((destructor)) static void finish(void)
{
    pthread_mutex_lock(&mutex);
    stop_recording();
    pthread_mutex_unlock(&mutex);
}
