import Foundation

/// The hours somebody would rather Tally stayed silent, and the two questions the schedule asks of
/// them: is now one of them, and when does the next one end.
///
/// OFF BY DEFAULT, which is the shape the whole feature took on 2026-08-25. A closed window is a
/// window whose next reset can be pulled earlier, and the price is one haiku message, so there is
/// no hour of the day where that arithmetic turns against the user. What quiet hours are for is the
/// part arithmetic does not cover: not wanting an app to talk to a vendor on your behalf while you
/// are asleep. That is a preference, so it is a switch, and it starts off.
///
/// A RANGE OF CLOCK TIMES, not of instants. "23:00 to 07:00" is the same eight hours on every day
/// of the year, including the two days a year that are 23 and 25 hours long, so the comparison
/// below is done in minutes-of-day read from the user's own calendar rather than on Dates.
///
/// Foundation only, so `tests/earlystart` compiles it standalone alongside the rest of the rules.
struct EarlyStartQuietHours: Equatable {
    var isEnabled: Bool
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int

    /// Clamps on the way in, so nothing downstream has to ask whether it is holding a 25th hour: the
    /// values come from a defaults file a user can edit by hand, and the minutes-of-day arithmetic
    /// below would happily order a 25:00 after a 24:00 and never end a quiet stretch.
    init(isEnabled: Bool = false, startHour: Int = 23, startMinute: Int = 0,
         endHour: Int = 7, endMinute: Int = 0) {
        self.isEnabled = isEnabled
        self.startHour = Self.clampedHour(startHour)
        self.startMinute = Self.clampedMinute(startMinute)
        self.endHour = Self.clampedHour(endHour)
        self.endMinute = Self.clampedMinute(endMinute)
    }

    /// The proposal the switch turns on with, and the same 23:00 to 07:00 the initializer above
    /// defaults to: overnight, ending at the hour the feature used to fire at. Somebody who liked
    /// the old "each morning at 07:00" behaviour gets the nearest thing to it by turning this on and
    /// leaving it alone.
    static let suggested = EarlyStartQuietHours(isEnabled: true)

    static func clampedHour(_ value: Int) -> Int { min(max(value, 0), 23) }
    static func clampedMinute(_ value: Int) -> Int { min(max(value, 0), 59) }

    var startMinutes: Int { startHour * 60 + startMinute }
    var endMinutes: Int { endHour * 60 + endMinute }

    /// Minutes since local midnight.
    static func minutesOfDay(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Whether `date` falls inside the quiet stretch.
    ///
    /// INCLUSIVE AT THE START, EXCLUSIVE AT THE END, which is what makes the end time the moment
    /// the feature comes back: quiet hours ending at 07:00 means 07:00 itself is loud, so the first
    /// evaluation of the working day can act rather than waiting for the next refresh.
    ///
    /// A stretch that ends where it starts reads as NO quiet time rather than as all of it. Both
    /// readings are defensible from the numbers alone, and only one of them can be reached by
    /// accident: dragging a picker past its partner is a slip, while "silence the whole feature" is
    /// a thing the switch above already does, plainly, with a label that says so.
    func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard isEnabled, startMinutes != endMinutes else { return false }
        let now = Self.minutesOfDay(date, calendar: calendar)
        // Crossing midnight is the ordinary case for this feature, so it is a branch rather than a
        // normalization trick: an overnight stretch is two intervals on any given day.
        if startMinutes < endMinutes { return now >= startMinutes && now < endMinutes }
        return now >= startMinutes || now < endMinutes
    }

    /// The next instant this stretch ends, which is the only thing left for a timer to be punctual
    /// about: everything else the schedule reacts to (a window closing, an attempt ageing out) is
    /// found by the refresh loop that produced the reading in the first place.
    ///
    /// Nil when there is nothing to wait for - the stretch is off, or empty. Asked of the calendar
    /// rather than by adding seconds, so the answer stays at the same clock time across a daylight
    /// saving jump instead of drifting an hour.
    func nextEnd(after now: Date, calendar: Calendar) -> Date? {
        guard isEnabled, startMinutes != endMinutes else { return nil }
        return calendar.nextDate(after: now,
                                 matching: DateComponents(hour: endHour, minute: endMinute,
                                                          second: 0),
                                 matchingPolicy: .nextTime, direction: .forward)
    }
}
