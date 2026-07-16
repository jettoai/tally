import SwiftUI

enum UsageFormat {
    /// "90%" — the displayed value for a meter under the current mode.
    static func percent(_ metric: UsageMetric, mode: DisplayMode) -> String {
        let value = mode == .used ? metric.usedPercent : metric.remainingPercent
        return "\(Int(value.rounded()))%"
    }

    /// The trailing mode word, e.g. "used" / "left".
    static func modeWord(_ mode: DisplayMode) -> String {
        mode == .used ? L("used") : L("left")
    }

    /// Bar fill fraction — matches the displayed number (used or remaining) so the bar and the value
    /// always agree. Colour still keys off used-severity, so it never flips with the toggle.
    static func fillFraction(_ metric: UsageMetric, mode: DisplayMode) -> Double {
        let value = mode == .used ? metric.usedPercent : metric.remainingPercent
        return min(1, max(0, value / 100))
    }

    /// Compact countdown to a reset instant, e.g. "resets in 4d 17h" / "resets in 42m".
    static func resetCountdown(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return L("resetting…") }
        let days = Int(seconds) / 86_400
        let hours = (Int(seconds) % 86_400) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60
        let body: String
        if days > 0 { body = hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        else if hours > 0 { body = minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        else { body = "\(max(1, minutes))m" }
        return String(localized: "resets in \(body)", bundle: AppLocale.bundle)
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

    // Now as MM/dd HH:mm, the same format as the absolute reset times so it reads as their anchor.
    private static let nowFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    /// "07/16 20:45" — the current date and time, an anchor for reading the absolute reset times.
    static func nowShort(_ now: Date = Date()) -> String { nowFormatter.string(from: now) }

    /// The reset label under the user's chosen style.
    static func resetText(_ date: Date?, style: ResetDisplay, now: Date = Date()) -> String? {
        style == .relative ? resetCountdown(date, now: now) : resetAbsolute(date)
    }

    /// Relative "updated 2m ago" for the header.
    static func updatedAgo(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return L("updated just now") }
        let body: String
        if seconds < 60 { body = "\(seconds)s" }
        else if seconds < 3_600 { body = "\(seconds / 60)m" }
        else { body = "\(seconds / 3_600)h" }
        return String(localized: "updated \(body) ago", bundle: AppLocale.bundle)
    }
}
