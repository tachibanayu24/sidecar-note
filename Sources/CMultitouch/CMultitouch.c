// Thin wrapper over the private MultitouchSupport framework (loaded at runtime), listening on *all* devices.
#include "CMultitouch.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stddef.h>

typedef struct { float x, y; } mt_point;
typedef struct { mt_point position, velocity; } mt_vector;

// Per-finger record delivered by MultitouchSupport (layout as documented by the community headers).
typedef struct {
    int frame;
    double timestamp;
    int identifier, state, finger_id, hand_id;
    mt_vector normalized;
    float size;
    int zero1;
    float angle, major_axis, minor_axis;
    mt_vector absolute;
    int zero2[2];
    float unknown;
} mt_touch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, mt_touch *, int, double, int);

static CFArrayRef (*MTDeviceCreateList)(void);
static void (*MTRegisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*MTUnregisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*MTDeviceStart)(MTDeviceRef, int);
static void (*MTDeviceStop)(MTDeviceRef);

enum { kMakeTouch = 3, kTouching = 4 };

static mt_frame_callback frame_callback;
static CFArrayRef devices;

static int contact_callback(MTDeviceRef device, mt_touch *touches, int count, double timestamp, int frame) {
    (void)frame;
    mt_frame_callback cb = frame_callback;
    if (!cb) return 0;
    int down = 0;
    float sx = 0, sy = 0;
    for (int i = 0; i < count; i++) {
        if (touches[i].state != kMakeTouch && touches[i].state != kTouching) continue;
        sx += touches[i].normalized.position.x;
        sy += touches[i].normalized.position.y;
        down++;
    }
    if (down > 0) { sx /= down; sy /= down; }
    cb((uintptr_t)device, down, sx, sy, timestamp);
    return 0;
}

static bool load_symbols(void) {
    static bool loaded;
    if (loaded) return true;
    void *handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (!handle) return false;
    MTDeviceCreateList = dlsym(handle, "MTDeviceCreateList");
    MTRegisterContactFrameCallback = dlsym(handle, "MTRegisterContactFrameCallback");
    MTUnregisterContactFrameCallback = dlsym(handle, "MTUnregisterContactFrameCallback");
    MTDeviceStart = dlsym(handle, "MTDeviceStart");
    MTDeviceStop = dlsym(handle, "MTDeviceStop");
    loaded = MTDeviceCreateList && MTRegisterContactFrameCallback && MTUnregisterContactFrameCallback
        && MTDeviceStart && MTDeviceStop;
    return loaded;
}

int mt_device_count(void) {
    if (!load_symbols()) return 0;
    CFArrayRef list = MTDeviceCreateList();
    if (!list) return 0;
    int n = (int)CFArrayGetCount(list);
    CFRelease(list);
    return n;
}

int mt_start(mt_frame_callback callback) {
    if (!load_symbols()) return 0;
    mt_stop();
    frame_callback = callback;
    devices = MTDeviceCreateList();
    if (!devices) return 0;
    CFIndex n = CFArrayGetCount(devices);
    for (CFIndex i = 0; i < n; i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(devices, i);
        MTRegisterContactFrameCallback(device, contact_callback);
        MTDeviceStart(device, 0);
    }
    return (int)n;
}

void mt_stop(void) {
    if (!devices) return;
    CFIndex n = CFArrayGetCount(devices);
    for (CFIndex i = 0; i < n; i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(devices, i);
        MTUnregisterContactFrameCallback(device, contact_callback);
        MTDeviceStop(device);
    }
    CFRelease(devices);
    devices = NULL;
}
