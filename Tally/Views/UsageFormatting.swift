import SwiftUI

enum UsageFormat {
    /// "90%" - the displayed value for a meter under the current mode, or "?" when the figure is
    /// a held-over one its window's reset has already overtaken (`AccountUsage.resetPassed`).
    static func percent(_ metric: UsageMetric, mode: DisplayMode, resetPassed: Bool = false) -> String {
        if resetPassed { return "?" }
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

    /// Compact token count, e.g. "842" / "12.3K" / "87.7M" / "29.4B". Three significant digits, so
    /// every column stays the same width whatever the magnitude - token counts span six orders of
    /// magnitude between a single turn and a month of agents, and the exact digits carry no
    /// meaning at the top of that range. Digit-only and locale-independent, matching the app's
    /// other figures.
    static func compactCount(_ value: Int64) -> String {
        let units: [(threshold: Int64, suffix: String)] =
            [(1_000_000_000_000, "T"), (1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
        guard let unit = units.first(where: { abs(value) >= $0.threshold }) else { return "\(value)" }
        let scaled = Double(value) / Double(unit.threshold)
        let decimals = abs(scaled) < 10 ? 2 : (abs(scaled) < 100 ? 1 : 0)
        return String(format: "%.\(decimals)f%@", scaled, unit.suffix)
    }

    /// A 0...1 share as a whole percentage. Anything that would round to zero reads "<1%" instead:
    /// a row is only on the table because it produced something, and "0%" next to a real token
    /// count looks like the two disagree.
    static func sharePercent(_ share: Double) -> String {
        let percent = (share * 100).rounded()
        return percent < 1 && share > 0 ? "<1%" : "\(Int(percent))%"
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

    /// The hover form of a reset: how long, then when. "resets in 1d 4h · 10/03 17:59". The
    /// countdown is what every reset label shows; the hover adds the clock beside it.
    static func resetHover(_ date: Date?, now: Date = Date()) -> String? {
        guard let date, let countdown = resetCountdown(date, now: now) else { return nil }
        return countdown + " · " + absoluteBody(date)
    }

    /// Bare "2h 13m" until an instant, floored at a minute, so a passed or imminent one reads "1m".
    static func countdownBody(_ date: Date, now: Date = Date()) -> String {
        durationBody(max(60, date.timeIntervalSince(now)))
    }

    /// "2h 13m (8:00 AM)": the countdown a notification or dialog leads with, then its clock in the
    /// app's language: time alone when the instant is today, date and time otherwise. A banner is
    /// read hours later, so the countdown ages while the clock stays true.
    static func noticeCountdown(_ date: Date, now: Date = Date()) -> (countdown: String, clock: String) {
        let clock = Calendar.current.isDate(date, inSameDayAs: now)
            ? AppLocale.shortTime(date) : AppLocale.shortDateTime(date)
        return (countdownBody(date, now: now), clock)
    }

    /// The widest strings the countdown can realistically show, for reserving layout width
    /// (hidden templates) so the per-second string changes never push neighboring views around.
    /// Localized, so the reservation is right in every UI language.
    static var updatesInTemplates: [String] {
        [String(localized: "refreshes in \("59m")", bundle: AppLocale.bundle),
         L("refreshing…")]
    }

    /// Countdown to the next scheduled poll, e.g. "refreshes in 42s". Once the deadline passes the
    /// poll is running (the CLIs take a dozen seconds), so it reads "refreshing…" - a countdown
    /// that sat at zero looked broken. Deliberately NOT "updates in": the moment the app grew
    /// real Sparkle updates, "updates in 3m" read as "the app updates itself in 3 minutes".
    static func updatesIn(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now).rounded())
        guard seconds > 0 else { return L("refreshing…") }
        return String(localized: "refreshes in \(figure(seconds))", bundle: AppLocale.bundle)
    }

    /// The bare figure of that countdown ("42s", "3m"), for a header too narrow for the sentence
    /// (B-1253). The same token every language's sentence already embeds, so it needs no strings of
    /// its own. Nil once due, where the sentence would say "refreshing…".
    static func updatesInFigure(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now).rounded())
        return seconds > 0 ? figure(seconds) : nil
    }

    private static func figure(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
    }
}
