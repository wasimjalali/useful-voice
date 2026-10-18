// Reads the system's Now Playing state for "Pause media while dictating".
//
// Since macOS 15.4, MediaRemote answers "nothing playing" to third-party processes. Apple's own
// /usr/bin/perl (a platform binary, bundle id com.apple.perl) still gets real answers, so the
// app runs uv-nowplaying.pl under perl, and the script loads this library with DynaLoader and
// calls uv_nowplaying_get() for each "get" line on stdin. The technique is the one the
// open-source ungive/mediaremote-adapter (BSD-3-Clause) uses; this file is our own code.
//
// Output, one JSON line per call (the script prints "seq=<n> " before it):
//   {"playing":1,"pid":123,"bundleIdentifier":"com.spotify.client"}
//   pid 0 and an empty bundle id mean no Now Playing app.
//   {"error":"timeout"} when MediaRemote did not answer within 400 ms.
//
// No ARC here: every dispatch object is released by hand. The three MediaRemote callbacks may
// arrive after a call gave up; each one holds its own reference to the group, and writes its
// value only if the call it belongs to is still the current one, under a lock.
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

typedef void (^BoolCallback)(Boolean);
typedef void (^IntCallback)(int);
typedef void (^ObjectCallback)(CFTypeRef);
typedef void (*GetBool)(dispatch_queue_t, BoolCallback);
typedef void (*GetInt)(dispatch_queue_t, IntCallback);
typedef void (*GetObject)(dispatch_queue_t, ObjectCallback);
typedef CFStringRef (*ClientString)(CFTypeRef);

// Shared with the callbacks, which run on the MediaRemote queue: only touched under `lock`.
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned long generation = 0;
static int playing = -1;
static int pid = -1;
static int bundleDone = 0;
static char bundle[256];

static void fail(const char *reason) {
    printf("{\"error\":\"%s\"}\n", reason);
    fflush(stdout);
}

void uv_nowplaying_get(void *interpreter, void *cv) {
    static void *framework = NULL;
    static dispatch_queue_t queue = NULL;
    if (!framework) {
        framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        queue = dispatch_queue_create("ai.useful.voice.nowplaying", DISPATCH_QUEUE_SERIAL);
    }
    if (!framework) { fail("mediaremote"); return; }
    GetBool getIsPlaying = (GetBool)dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    GetInt getPID = (GetInt)dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationPID");
    GetObject getClient = (GetObject)dlsym(framework, "MRMediaRemoteGetNowPlayingClient");
    ClientString bundleOf = (ClientString)dlsym(framework, "MRNowPlayingClientGetBundleIdentifier");
    if (!getIsPlaying || !getPID || !getClient || !bundleOf) { fail("mediaremote"); return; }

    pthread_mutex_lock(&lock);
    unsigned long mine = ++generation;
    playing = -1;
    pid = -1;
    bundleDone = 0;
    bundle[0] = 0;
    pthread_mutex_unlock(&lock);

    dispatch_group_t group = dispatch_group_create();

    // Each callback owns one reference to the group, released when it has left it.
    dispatch_retain(group);
    dispatch_group_enter(group);
    getIsPlaying(queue, ^(Boolean isPlaying) {
        pthread_mutex_lock(&lock);
        if (generation == mine) playing = isPlaying ? 1 : 0;
        pthread_mutex_unlock(&lock);
        dispatch_group_leave(group);
        dispatch_release(group);
    });
    dispatch_retain(group);
    dispatch_group_enter(group);
    getPID(queue, ^(int value) {
        pthread_mutex_lock(&lock);
        if (generation == mine) pid = value;
        pthread_mutex_unlock(&lock);
        dispatch_group_leave(group);
        dispatch_release(group);
    });
    dispatch_retain(group);
    dispatch_group_enter(group);
    getClient(queue, ^(CFTypeRef client) {
        char text[256];
        text[0] = 0;
        if (client) {
            CFStringRef identifier = bundleOf(client);
            if (identifier) CFStringGetCString(identifier, text, sizeof text, kCFStringEncodingUTF8);
        }
        pthread_mutex_lock(&lock);
        if (generation == mine) {
            memcpy(bundle, text, sizeof bundle);
            bundleDone = 1;
        }
        pthread_mutex_unlock(&lock);
        dispatch_group_leave(group);
        dispatch_release(group);
    });

    long timedOut = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC));
    dispatch_release(group);   // this call's own reference

    // Take the values, and retire this call's generation so a late callback cannot write.
    pthread_mutex_lock(&lock);
    int gotPlaying = playing, gotPID = pid, gotBundleDone = bundleDone;
    char text[256];
    memcpy(text, bundle, sizeof text);
    generation++;
    pthread_mutex_unlock(&lock);

    if (timedOut || gotPlaying < 0 || gotPID < 0 || !gotBundleDone) { fail("timeout"); return; }

    // The bundle id is JSON-escaped by dropping the characters that would need it.
    char safe[256];
    size_t length = 0;
    text[sizeof text - 1] = 0;
    for (size_t index = 0; text[index] && length < sizeof safe - 1; index++) {
        if (text[index] != '"' && text[index] != '\\' && (unsigned char)text[index] >= 0x20) safe[length++] = text[index];
    }
    safe[length] = 0;
    printf("{\"playing\":%d,\"pid\":%d,\"bundleIdentifier\":\"%s\"}\n", gotPlaying, gotPID, safe);
    fflush(stdout);
}
