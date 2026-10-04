import CoreGraphics
import Foundation
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

    static func startIfEnabled() {
        guard isEnabled, !SentrySDK.isEnabled else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let bundleID = Bundle.main.bundleIdentifier ?? "ai.jetto.tally"
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
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
                                  hostAlarmed: HostAlarmMirror.isAlarmed.withLock { $0 })
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
    /// alarm). Hangs with the display awake carry both readings as tags. Non-hang events pass
    /// untouched.
    static func contextualizeHang(_ event: Event, displayAsleep: Bool, hostAlarmed: Bool) -> Event? {
        guard event.exceptions?.contains(where: { $0.mechanism?.type == "AppHang" }) == true
        else { return event }
        if displayAsleep { return nil }
        var tags = event.tags ?? [:]
        tags["display_asleep"] = String(displayAsleep)
        tags["host_alarmed"] = String(hostAlarmed)
        event.tags = tags
        return event
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
