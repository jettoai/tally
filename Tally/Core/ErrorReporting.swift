import CoreGraphics
import Foundation
import os
import Sentry

/// Opt-in crash and error reporting through Sentry.
///
/// Off by default, and off means the SDK is never started: no SentrySDK call runs, so nothing
/// is sent and nothing is written. The Settings switch (SettingsErrorReportingRow) is the only
/// way on. When on, events carry stack traces, the app version and the macOS version; no user,
/// no breadcrumbs, no screenshots, and the home directory path is folded to `~` before sending.
enum ErrorReporting {
    static let enabledKey = "errorReportingEnabled"
    /// Dev probe: `-TallySentryTestEvent YES` sends one message at launch, only if the SDK is
    /// running. With reporting off it sends nothing, which is the check that "off" means off.
    static let testEventFlag = "TallySentryTestEvent"

    private static let dsn =
        "https://068b51b0ddcf7de408a8729c79856a11@o4508371539263488.ingest.us.sentry.io/4512147651297280"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// The page the surface last put on screen (`SurfaceTab.rawValue`), for the hang tag below. Kept
    /// here for the reason `HostAlarmMirror` is: the surface writes it on the main thread, and
    /// `beforeSend` reads it on the SDK's queue, where it must not wait on main.
    private static let surfaceTab = OSAllocatedUnfairLock<String?>(initialState: nil)

    static func noteSurfaceTab(_ tab: String) { surfaceTab.withLock { $0 = tab } }

    static func startIfEnabled() {
        guard isEnabled, !SentrySDK.isEnabled else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let bundleID = Bundle.main.bundleIdentifier ?? "ai.jetto.tally"
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        // Every caller runs on main (launch, the Settings switch); off main the tag reads "unknown".
        let mainPort = Thread.isMainThread ? pthread_mach_thread_np(pthread_self()) : nil
        SentrySDK.start { options in
            options.dsn = dsn
            options.sendDefaultPii = false
            options.releaseName = "\(bundleID)@\(version)+\(build)"
            #if DEBUG
            options.environment = "development"
            #else
            options.environment = "production"
            #endif
            options.tracesSampleRate = 0
            options.enableAutoSessionTracking = false
            options.enableAppHangTracking = true
            options.enableCaptureFailedRequests = false
            options.maxBreadcrumbs = 0
            options.beforeSend = { event in
                contextualizeHang(event,
                                  displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
                                  hostAlarmed: HostAlarmMirror.isAlarmed.withLock { $0 },
                                  surfaceTab: surfaceTab.withLock { $0 },
                                  mainPriority: threadPriority(mainPort))
                    .map { scrub($0) }
            }
        }
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on {
            startIfEnabled()
        } else if SentrySDK.isEnabled {
            SentrySDK.close()
        }
    }

    static func sendProbeIfAsked() {
        guard UserDefaults.standard.bool(forKey: testEventFlag), SentrySDK.isEnabled else { return }
        SentrySDK.capture(message: "tally sentry probe \(ISO8601DateFormatter().string(from: Date()))")
        DispatchQueue.global(qos: .utility).async { SentrySDK.flush(timeout: 5) }
    }

    /// One event per stalled update, only when the user opted in. The step is the state machine's
    /// own name for it; nothing about the machine or the account goes along.
    static func reportUpdateStall(step: String) {
        guard isEnabled, SentrySDK.isEnabled else { return }
        SentrySDK.capture(message: "update stalled at \(step)") { scope in
            scope.setLevel(.warning)
            scope.setTag(value: "update-stall", key: "kind")
        }
    }

    /// App Hang events (mechanism type "AppHang", sentry-cocoa 9.29.1 SentryHangTrackingIntegration)
    /// raised while the display sleeps are dropped, whatever the host load: nobody could see the
    /// stall, and sending it only reopens resolved issues (Sentry TALLY-6, 64 such events in 40
    /// minutes; eight issues from TALLY-59 on 2026-10-04, all asleep with the host below its
    /// alarm). Hangs with the display awake carry both readings as tags, and the page the surface
    /// last showed (`surface_tab`, "none" before any surface has appeared), so a layout hang says
    /// which page it was laying out (Sentry TALLY-8Z). Non-hang events pass untouched.
    ///
    /// Hangs raised while the main thread runs below the default QoS priority (31) are dropped
    /// too: that is App Nap throttling a hidden app, and the main thread was queued for a CPU,
    /// not doing slow work (Sentry TALLY-2; on 2026-10-12, 40 hangs in 43 minutes at priority 4,
    /// none after App Nap lifted and the priority returned to 46). Kept hangs carry the reading as
    /// `main_pri`; when it could not be read (nil) the hang is kept and tagged "unknown".
    static func contextualizeHang(_ event: Event, displayAsleep: Bool, hostAlarmed: Bool,
                                  surfaceTab: String? = nil, mainPriority: Int32? = nil) -> Event? {
        guard event.exceptions?.contains(where: { $0.mechanism?.type == "AppHang" }) == true
        else { return event }
        if displayAsleep { return nil }
        if let mainPriority, mainPriority < 31 { return nil }
        var tags = event.tags ?? [:]
        tags["main_pri"] = mainPriority.map(String.init) ?? "unknown"
        tags["display_asleep"] = String(displayAsleep)
        tags["host_alarmed"] = String(hostAlarmed)
        tags["surface_tab"] = surfaceTab ?? "none"
        event.tags = tags
        return event
    }

    /// The current scheduling priority of the thread behind `port`, read from any thread.
    /// `beforeSend` runs on the SDK's queue, so the main thread's port is captured on main at start
    /// (`mach_thread_self()` there would read the SDK's thread, and `pthread_main_thread_np` is not
    /// in the public SDK). nil when there is no port or the read fails.
    static func threadPriority(_ port: mach_port_t?) -> Int32? {
        guard let port else { return nil }
        var info = thread_extended_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_extended_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.pth_curpri : nil
    }

    /// Folds the home directory to `~` in every field a path lands in. The crash converter writes
    /// full binary image paths into `debugMeta[].codeFile` and each frame's `package`, so an app run
    /// from ~/Downloads or ~/Applications would otherwise carry the login name. Field names are the
    /// ones in sentry-cocoa 9.29.1's public headers (SentryDebugMeta.h, SentryFrame.h).
    static func scrub(_ event: Event, home: String = NSHomeDirectory()) -> Event {
        event.user = nil
        func fold(_ text: String) -> String { text.replacingOccurrences(of: home, with: "~") }
        func foldFrames(_ trace: SentryStacktrace?) {
            trace?.frames.forEach { frame in
                frame.package = frame.package.map(fold)
                frame.fileName = frame.fileName.map(fold)
                frame.module = frame.module.map(fold)
            }
        }
        if let message = event.message {
            let folded = SentryMessage(formatted: fold(message.formatted))
            folded.message = message.message.map(fold)
            folded.params = message.params
            event.message = folded
        }
        event.exceptions?.forEach {
            $0.value = $0.value.map(fold)
            foldFrames($0.stacktrace)
        }
        event.threads?.forEach { foldFrames($0.stacktrace) }
        foldFrames(event.stacktrace)
        event.debugMeta?.forEach { $0.codeFile = $0.codeFile.map(fold) }
        return event
    }
}
