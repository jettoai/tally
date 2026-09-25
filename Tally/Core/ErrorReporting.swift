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
            options.beforeSend = { event in scrub(event) }
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

    private static func scrub(_ event: Event) -> Event {
        event.user = nil
        let home = NSHomeDirectory()
        func fold(_ text: String?) -> String? { text?.replacingOccurrences(of: home, with: "~") }
        if let message = event.message {
            let folded = SentryMessage(formatted: fold(message.formatted) ?? message.formatted)
            folded.message = fold(message.message)
            folded.params = message.params
            event.message = folded
        }
        event.exceptions?.forEach { $0.value = fold($0.value) ?? $0.value }
        return event
    }
}
