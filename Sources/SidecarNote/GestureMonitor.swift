import AppKit
import CMultitouch
import os

/// Detects a four-finger swipe down on any trackpad (built-in or Magic Trackpad), whichever app is focused.
@MainActor
final class GestureMonitor {
    static let shared = GestureMonitor()

    var onSwipeDown: (() -> Void)?

    private var running = false
    private var deviceCount = 0
    private var rescanTimer: Timer?

    func start() {
        guard !running else { return }
        running = true
        deviceCount = Int(mt_start(gestureFrameCallback))
        DevLog.write("[gesture] listening on \(deviceCount) trackpad(s)")
        // A Magic Trackpad may connect (or reconnect over Bluetooth) at any time: pick it up.
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                let shared = GestureMonitor.shared
                if Int(mt_device_count()) != shared.deviceCount { shared.restart() }
            }
        }
    }

    func stop() {
        rescanTimer?.invalidate()
        rescanTimer = nil
        mt_stop()
        GestureTracker.shared.reset()
        running = false
    }

    func restart() {
        stop()
        start()
    }

    fileprivate func swipedDown() {
        onSwipeDown?()
    }
}

/// Runs on MultitouchSupport's callback thread(s); state is kept per trackpad behind a lock.
private final class GestureTracker: @unchecked Sendable {
    static let shared = GestureTracker()

    private struct Track {
        var tracking = false
        var locked = false
        var origin = CGPoint.zero
        var startTime: Double = 0
    }

    private var tracks: [UInt: Track] = [:]
    private let lock = OSAllocatedUnfairLock()

    private let travel: CGFloat = 0.12      // fraction of the trackpad height
    private let maxDuration: Double = 0.9   // seconds

    func reset() {
        lock.withLock { tracks.removeAll() }
    }

    func handle(device: UInt, count: Int, x: CGFloat, y: CGFloat, time: Double) {
        let fired: Bool = lock.withLock {
            var t = tracks[device] ?? Track()
            defer { tracks[device] = t }
            if count == 0 {
                t = Track()
                return false
            }
            guard !t.locked else { return false }
            guard count == 4 else {
                // A fifth finger, or lifting mid-swipe, cancels until every finger is up.
                if t.tracking || count > 4 { t.locked = true; t.tracking = false }
                return false
            }
            if !t.tracking {
                t.tracking = true
                t.origin = CGPoint(x: x, y: y)
                t.startTime = time
                return false
            }
            let dx = x - t.origin.x, dy = y - t.origin.y
            if time - t.startTime > maxDuration {
                t.locked = true
            } else if dy < -travel && abs(dy) > abs(dx) * 1.4 {
                // Normalized y grows upward, so moving the fingers toward you decreases it.
                t.locked = true
                return true
            } else if dy > travel || abs(dx) > travel {
                // Mission Control / Space switching – not ours.
                t.locked = true
            }
            return false
        }
        if fired {
            DevLog.write("[gesture] four-finger swipe down (device \(device))")
            DispatchQueue.main.async { MainActor.assumeIsolated { GestureMonitor.shared.swipedDown() } }
        }
    }
}

private func gestureFrameCallback(device: UInt, count: Int32, x: Float, y: Float, timestamp: Double) {
    GestureTracker.shared.handle(device: device, count: Int(count), x: CGFloat(x), y: CGFloat(y), time: timestamp)
}

/// Dev builds only: a small log (/tmp/sidecar-dev.log) for checks that can't be observed from outside.
enum DevLog {
    static func write(_ message: String) {
        guard AppInfo.isDevBuild else { return }
        let line = "\(message)\n"
        let url = URL(fileURLWithPath: "/tmp/sidecar-dev.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
