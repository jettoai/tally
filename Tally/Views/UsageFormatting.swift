import SwiftUI

enum UsageFormat {
    /// "90%" - the displayed value for a meter under the current mode.
    static func percent(_ metric: UsageMetric, mode: DisplayMode) -> String {
        let value = mode == .used ? metric.usedPercent : metric.remainingPercent
        return "\(Int(value.rounded()))%"
    }

    /// The trailing mode word, e.g. "used" / "left".
    static func modeWord(_ mode: DisplayMode) -> String {
        mode == .used ? L("used") : L("left")
    }

    /// Bar fill fraction - matches the displayed number (used or remaining) so the bar and the value
    /// always agree. Colour still keys off used-severity, so it never flips with the toggle.
    static func fillFraction(_ metric: UsageMetric, mode: DisplayMode) -> Double {
        let value = mode == .used ? metric.usedPercent : metric.remainingPercent
        return min(1, max(0, value / 100))
    }

    /// Compact duration, e.g. "4d 17h" / "42m" - the body shared by the reset countdown and the
    /// fleet forecast.
    static func durationBody(_ seconds: TimeInterval) -> String {
        let days = Int(seconds) / 86_400
        let hours = (Int(seconds) % 86_400) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(max(1, minutes))m"
    }

    /// Compact countdown to a reset instant, e.g. "resets in 4d 17h" / "resets in 42m".
    static func resetCountdown(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return L("resetting…") }
        return String(localized: "resets in \(durationBody(seconds))", bundle: AppLocale.bundle)
    }

    // Fixed MM/dd HH:mm in the local timezone (POSIX locale keeps it 24-hour and digit-only regardless
    // of the UI language). Reset instants land on a minute boundary, so seconds carry no information.
    private static let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    /// Exact reset instant, e.g. "resets at 07/18 21:36" (local time, fixed MM/dd HH:mm).
    static func resetAbsolute(_ date: Date?) -> String? {
        guard let date else { return nil }
        return String(localized: "resets at \(resetFormatter.string(from: date))", bundle: AppLocale.bundle)
    }

    /// Bare "07/18 21:36" (local time) - for labels that carry their own verb (the fleet refill).
    static func absoluteBody(_ date: Date) -> String { resetFormatter.string(from: date) }

    // Now as MM/dd HH:mm, the same format as the absolute reset times so it reads as their anchor.
    private static let nowFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    /// "07/16 20:45" - the current date and time, an anchor for reading the absolute reset times.
    static func nowShort(_ now: Date = Date()) -> String { nowFormatter.string(from: now) }

    /// The reset label under the user's chosen style.
    static func resetText(_ date: Date?, style: ResetDisplay, now: Date = Date()) -> String? {
        style == .relative ? resetCountdown(date, now: now) : resetAbsolute(date)
    }

    /// The widest strings the countdown can realistically show, for reserving layout width
    /// (hidden templates) so the per-second string changes never push neighboring views around.
    /// Localized, so the reservation is right in every UI language.
    static var updatesInTemplates: [String] {
        [String(localized: "updates in \("59m")", bundle: AppLocale.bundle),
         L("updating…")]
    }

    /// Countdown to the next scheduled poll, e.g. "updates in 42s". Once the deadline passes the
    /// poll is running (the CLIs take a dozen seconds), so it reads "updating…" - a countdown that
    /// sat at zero looked broken.
    static func updatesIn(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now).rounded())
        guard seconds > 0 else { return L("updating…") }
        let body = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
        return String(localized: "updates in \(body)", bundle: AppLocale.bundle)
    }
}
