import os

/// `HostHealthMonitor.isAlarmed`, readable off the main thread. The monitor is main-actor; Sentry's
/// `beforeSend` runs on the SDK's own queue and must not block on main, so the monitor writes its
/// alarm state here every time its tracker changes and the hang filter reads this copy.
enum HostAlarmMirror {
    static let isAlarmed = OSAllocatedUnfairLock(initialState: false)
}
