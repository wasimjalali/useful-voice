// Reads the system's Now Playing state for "Pause media while dictating".
//
// Since macOS 15.4, MediaRemote answers "nothing playing" to third-party processes. Apple's own
// /usr/bin/perl (a platform binary, bundle id com.apple.perl) still gets real answers, so the
// app runs uv-nowplaying.pl under perl, and the script loads this library with DynaLoader and
// calls uv_nowplaying_get() for each "get" line on stdin. The technique is the one the
// open-source ungive/mediaremote-adapter (BSD-3-Clause) uses; this file is our own code.
//
// Output, one JSON line per call:
//   {"playing":1,"pid":123,"bundleIdentifier":"com.spotify.client"}
//   pid 0 and an empty bundle id mean no Now Playing app.
//   {"error":"timeout"} when MediaRemote did not answer within 400 ms.
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef void (^BoolCallback)(Boolean);
typedef void (^IntCallback)(int);
typedef void (^ObjectCallback)(CFTypeRef);
typedef void (*GetBool)(dispatch_queue_t, BoolCallback);
typedef void (*GetInt)(dispatch_queue_t, IntCallback);
typedef void (*GetObject)(dispatch_queue_t, ObjectCallback);
typedef CFStringRef (*ClientString)(CFTypeRef);

// A late answer from an earlier call must not overwrite the current call's values.
static volatile unsigned long generation = 0;
static volatile int playing = -1;
static volatile int pid = -1;
static char bundle[256];

void uv_nowplaying_get(void *interpreter, void *cv) {
    static void *framework = NULL;
    static dispatch_queue_t queue = NULL;
    if (!framework) {
        framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        queue = dispatch_queue_create("ai.useful.voice.nowplaying", DISPATCH_QUEUE_SERIAL);
    }
    if (!framework) {
        printf("{\"error\":\"mediaremote\"}\n");
        fflush(stdout);
        return;
    }
    GetBool getIsPlaying = (GetBool)dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    GetInt getPID = (GetInt)dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationPID");
    GetObject getClient = (GetObject)dlsym(framework, "MRMediaRemoteGetNowPlayingClient");
    ClientString bundleOf = (ClientString)dlsym(framework, "MRNowPlayingClientGetBundleIdentifier");
    if (!getIsPlaying || !getPID || !getClient || !bundleOf) {
        printf("{\"error\":\"mediaremote\"}\n");
        fflush(stdout);
        return;
    }

    unsigned long mine = ++generation;
    playing = -1;
    pid = -1;
    bundle[0] = 0;
    __block int bundleDone = 0;
    dispatch_group_t group = dispatch_group_create();

    dispatch_group_enter(group);
    getIsPlaying(queue, ^(Boolean isPlaying) {
        if (generation == mine) playing = isPlaying ? 1 : 0;
        dispatch_group_leave(group);
    });
    dispatch_group_enter(group);
    getPID(queue, ^(int value) {
        if (generation == mine) pid = value;
        dispatch_group_leave(group);
    });
    dispatch_group_enter(group);
    getClient(queue, ^(CFTypeRef client) {
        if (generation == mine) {
            if (client) {
                CFStringRef identifier = bundleOf(client);
                if (identifier) CFStringGetCString(identifier, bundle, sizeof bundle, kCFStringEncodingUTF8);
            }
            bundleDone = 1;
        }
        dispatch_group_leave(group);
    });

    long timedOut = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC));
    if (timedOut || playing < 0 || pid < 0 || !bundleDone) {
        generation++;   // ignore anything that still arrives
        printf("{\"error\":\"timeout\"}\n");
        fflush(stdout);
        return;
    }
    // The bundle id is JSON-escaped by dropping the two characters that would need it.
    char safe[256];
    size_t length = 0;
    for (size_t index = 0; bundle[index] && length < sizeof safe - 1; index++) {
        if (bundle[index] != '"' && bundle[index] != '\\' && (unsigned char)bundle[index] >= 0x20) safe[length++] = bundle[index];
    }
    safe[length] = 0;
    printf("{\"playing\":%d,\"pid\":%d,\"bundleIdentifier\":\"%s\"}\n", playing, pid, safe);
    fflush(stdout);
}
