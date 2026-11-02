// Exercise the actual common-c session state machine without devices/network.
// Only its platform/media boundaries are replaced. No production test hooks.
#include "Connection.c"
#include <stdio.h>
#include <stdlib.h>

#define CHECK(x) do { checks++; if (!(x)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static unsigned checks;
static int audioInit, audioStart, audioStop, audioDestroy;
static int inputInit, inputStart, inputStop, inputDestroy;
static int videoInit, videoStart, videoStop, videoDestroy;
static int controlInit, controlStart, controlStop, controlDestroy;
static int failStage, completed, started, wiggles;

static void logMessage(const char* format, ...) { (void)format; }
static void stageStarting(int value) { (void)value; }
static void stageComplete(int value) { completed = value; }
static void stageFailed(int value, int error) { CHECK(value == failStage); CHECK(error == -7); }
static void connectionStarted(void) { started++; }
static void connectionTerminated(int error) { (void)error; CHECK(false); }

int initializePlatform(void) { return 0; }
void cleanupPlatform(void) {}
void PltSleepMs(int ms) { (void)ms; }
int PltCreateThread(const char* name, ThreadEntry entry, void* context, PLT_THREAD* thread) {
    (void)name; (void)entry; (void)context; (void)thread;
    CHECK(false); return -1;
}
void PltDetachThread(PLT_THREAD* thread) { (void)thread; CHECK(false); }
void fixupMissingCallbacks(PDECODER_RENDERER_CALLBACKS* video,
                          PAUDIO_RENDERER_CALLBACKS* audio,
                          PCONNECTION_LISTENER_CALLBACKS* listener) {
    CHECK(*video != NULL && *audio != NULL && *listener != NULL);
}
int initializeAudioStream(void) { audioInit++; return failStage == STAGE_AUDIO_STREAM_INIT ? -7 : 0; }
int startAudioStream(void* context, int flags) {
    (void)context; (void)flags; audioStart++; return failStage == STAGE_AUDIO_STREAM_START ? -7 : 0;
}
void stopAudioStream(void) { audioStop++; }
void destroyAudioStream(void) { audioDestroy++; }
int initializeInputStream(void) { inputInit++; return 0; }
int startInputStream(void) { inputStart++; return failStage == STAGE_INPUT_STREAM_START ? -7 : 0; }
int stopInputStream(void) { inputStop++; return 0; }
void destroyInputStream(void) { inputDestroy++; }
void initializeVideoStream(void) { videoInit++; }
int startVideoStream(void* context, int flags) {
    (void)context; (void)flags; videoStart++; return failStage == STAGE_VIDEO_STREAM_START ? -7 : 0;
}
void stopVideoStream(void) { videoStop++; }
void destroyVideoStream(void) { videoDestroy++; }
int initializeControlStream(void) { controlInit++; return failStage == STAGE_CONTROL_STREAM_INIT ? -7 : 0; }
int startControlStream(void) { controlStart++; return failStage == STAGE_CONTROL_STREAM_START ? -7 : 0; }
int stopControlStream(void) { controlStop++; return 0; }
void destroyControlStream(void) { controlDestroy++; }
int LiSendMouseMoveEvent(short x, short y) { (void)x; (void)y; wiggles++; return 0; }

static PLANK_NATIVE_SESSION_CONFIGURATION configuration(bool linuxSession) {
    PLANK_NATIVE_SESSION_CONFIGURATION c = {0};
    c.structSize = sizeof(c);
    c.sessionPort = 28989;
    c.negotiatedVideoFormat = VIDEO_FORMAT_H265_MAIN10;
    if (linuxSession) {
        c.serviceFlags = PLANK_NATIVE_SERVICE_MASK;
        c.hostFeatureFlags = LI_FF_LOCAL_CURSOR;
        c.audioPacketDurationMs = 5;
        c.opusConfiguration.sampleRate = 48000;
        c.opusConfiguration.channelCount = 2;
        c.opusConfiguration.streams = 1;
        c.opusConfiguration.coupledStreams = 1;
        c.opusConfiguration.mapping[1] = 1;
    }
    return c;
}

static void exercise(bool linuxSession, int failure) {
    PLANK_NATIVE_SESSION_CONFIGURATION c = configuration(linuxSession);
    SERVER_INFORMATION server = {0};
    STREAM_CONFIGURATION stream = {0};
    DECODER_RENDERER_CALLBACKS video = {0};
    AUDIO_RENDERER_CALLBACKS audio = {0};
    CONNECTION_LISTENER_CALLBACKS listener = {0};
    // DNS and route selection belong to the already connected QUIC owner.
    // No socket or resolver stubs are linked into this lifecycle fixture.
    server.address = "must-not-resolve.invalid";
    // Native session setup must work without a legacy application version.
    server.serverInfoAppVersion = NULL;
    server.serverCodecModeSupport = 1;
    stream.width = 1920; stream.height = 1080; stream.fps = 60;
    // No invented audio configuration is needed by the video-only session.
    stream.audioConfiguration = linuxSession ? AUDIO_CONFIGURATION_STEREO : 0;
    listener.logMessage = logMessage;
    listener.stageStarting = stageStarting; listener.stageComplete = stageComplete;
    listener.stageFailed = stageFailed; listener.connectionStarted = connectionStarted;
    listener.connectionTerminated = connectionTerminated;
    audioInit = audioStart = audioStop = audioDestroy = 0;
    inputInit = inputStart = inputStop = inputDestroy = 0;
    videoInit = videoStart = videoStop = videoDestroy = 0;
    controlInit = controlStart = controlStop = controlDestroy = 0;
    started = wiggles = completed = 0; failStage = failure;
    CHECK(LiSetPlankNativeSessionConfiguration(&c) == 0);
    CHECK(LiStartConnection(&server, &stream, &listener, &video, &audio,
                           NULL, 0, NULL, 0) == (failure ? -7 : 0));
    CHECK(!NativeSessionConfigurationPending);
    if (!failure) {
        CHECK(started == 1 && completed == STAGE_INPUT_STREAM_START);
        CHECK(LiSetPlankNativeSessionConfiguration(&c) == -1);
        CHECK(LiGetPlankNativeServiceFlags() == c.serviceFlags);
    }
    LiStopConnection();
    CHECK(stage == STAGE_NONE && LiGetPlankNativeServiceFlags() == 0);
    CHECK(audioDestroy == (linuxSession && completed >= STAGE_AUDIO_STREAM_INIT));
    CHECK(audioStop == (linuxSession && completed >= STAGE_AUDIO_STREAM_START));
    CHECK(inputDestroy == (linuxSession && completed >= STAGE_INPUT_STREAM_INIT));
    CHECK(inputStop == (linuxSession && completed >= STAGE_INPUT_STREAM_START));
    CHECK(videoDestroy == (completed >= STAGE_VIDEO_STREAM_INIT));
    CHECK(videoStop == (completed >= STAGE_VIDEO_STREAM_START));
    CHECK(controlDestroy == (completed >= STAGE_CONTROL_STREAM_INIT));
    CHECK(controlStop == (completed >= STAGE_CONTROL_STREAM_START));
    CHECK(wiggles == (linuxSession && !failure ? 2 : 0));
    if (!linuxSession) CHECK(audioInit + audioStart + inputInit + inputStart == 0);
    LiStopConnection(); // Idempotent cleanup must not repeat destruction.
    CHECK(videoDestroy <= 1 && audioDestroy <= 1 && inputDestroy <= 1 && controlDestroy <= 1);
}

int main(void) {
    PLANK_NATIVE_SESSION_CONFIGURATION c = configuration(true);
    CHECK(LiSetPlankNativeSessionConfiguration(&c) == 0);
    c.serviceFlags = 0;
    CHECK(LiSetPlankNativeSessionConfiguration(&c) == -1);
    CHECK(!NativeSessionConfigurationPending);
    c = configuration(false); c.serviceFlags = 0x80;
    CHECK(LiSetPlankNativeSessionConfiguration(&c) == -1);
    c = configuration(false); c.audioPacketDurationMs = 5;
    CHECK(LiSetPlankNativeSessionConfiguration(&c) == -1);
    c = configuration(true); c.opusConfiguration.channelCount = -1;
    CHECK(LiSetPlankNativeSessionConfiguration(&c) == -1);
    c = configuration(true); c.opusConfiguration.coupledStreams = -1;
    CHECK(LiSetPlankNativeSessionConfiguration(&c) == -1);
    c = configuration(true); c.opusConfiguration.mapping[1] = 2;
    CHECK(LiSetPlankNativeSessionConfiguration(&c) == -1);
    CHECK(LiSetPlankNativeSessionConfiguration(NULL) == -1);
    for (int i = 0; i < 3; i++) {
        exercise(true, 0); exercise(false, 0);
    }
    exercise(true, STAGE_AUDIO_STREAM_INIT);
    exercise(true, STAGE_AUDIO_STREAM_START);
    exercise(true, STAGE_INPUT_STREAM_START);
    for (int i = 0; i < 2; i++) {
        exercise(i != 0, STAGE_CONTROL_STREAM_INIT);
        exercise(i != 0, STAGE_CONTROL_STREAM_START);
        exercise(i != 0, STAGE_VIDEO_STREAM_START);
    }
    printf("native optional services: %u checks passed\n", checks);
    return 0;
}
