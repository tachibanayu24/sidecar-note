#ifndef CMULTITOUCH_H
#define CMULTITOUCH_H

#include <stdbool.h>
#include <stdint.h>

/// Called on a background thread for every frame of every trackpad.
/// `device` identifies the trackpad, `count` is the number of fingers on it and `x` / `y` their average
/// normalized position (0…1, origin bottom-left).
typedef void (*mt_frame_callback)(uintptr_t device, int count, float x, float y, double timestamp);

/// Starts listening on every multitouch device (built-in and Magic Trackpads). Returns the device count.
int mt_start(mt_frame_callback callback);
void mt_stop(void);
/// Number of multitouch devices currently attached (for noticing a trackpad connected later).
int mt_device_count(void);

#endif
