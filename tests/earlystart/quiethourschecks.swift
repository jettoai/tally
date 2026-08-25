import Foundation

// The silence window: the one clock the relay still reads (Tally/Core/EarlyStartQuietHours.swift).
//
// It replaced the 07:00 alarm the feature shipped with, and it is off by default, so most of what
// is asserted here is what happens when nobody has touched it. The comparisons are made in
// minutes-of-day rather than on Dates, which is why the daylight saving check at the end can be
// stated as "the answer does not move" rather than as a tolerance.

func runQuietHoursChecks() {
    // 3. QUIET HOURS: IS NOW ONE OF THEM. Every cell that exists - off, a daytime stretch, an overnight
    //    one, both boundary minutes of each, and the empty stretch.
    do {
        let overnight = EarlyStartQuietHours(isEnabled: true, startHour: 23, startMinute: 0,
                                             endHour: 7, endMinute: 0)
        let daytime = EarlyStartQuietHours(isEnabled: true, startHour: 9, startMinute: 30,
                                           endHour: 17, endMinute: 45)

        expect(!loud.contains(at("2026-08-24 03:00"), calendar: taipei),
               "with quiet hours off, 3am is not quiet (the shipping default is 24 hours loud)")
        var offButSet = overnight
        offButSet.isEnabled = false
        expect(!offButSet.contains(at("2026-08-24 03:00"), calendar: taipei),
               "…and a stretch left configured but switched off silences nothing")

        // Overnight: two intervals on any given day, which is why `contains` branches rather than
        // normalizing. 03:00 is inside; 12:00 is not.
        expect(overnight.contains(at("2026-08-24 03:00"), calendar: taipei),
               "overnight: the small hours are quiet")
        expect(overnight.contains(at("2026-08-24 23:30"), calendar: taipei),
               "…and so is the evening on the other side of midnight")
        expect(!overnight.contains(at("2026-08-24 12:00"), calendar: taipei),
               "…while midday is not")
        expect(overnight.contains(at("2026-08-24 23:00"), calendar: taipei),
               "the start minute is INSIDE the stretch")
        expect(!overnight.contains(at("2026-08-24 22:59"), calendar: taipei),
               "…and the minute before it is not")
        expect(!overnight.contains(at("2026-08-24 07:00"), calendar: taipei),
               "the end minute is OUTSIDE it, so the feature is live at exactly 07:00")
        expect(overnight.contains(at("2026-08-24 06:59"), calendar: taipei),
               "…and the minute before that is still quiet")

        // Not crossing midnight: the same rule read the other way round.
        expect(daytime.contains(at("2026-08-24 12:00"), calendar: taipei),
               "a daytime stretch is quiet in the middle of the day")
        expect(!daytime.contains(at("2026-08-24 03:00"), calendar: taipei),
               "…and loud at night, which is the opposite of the overnight case")
        expect(daytime.contains(at("2026-08-24 09:30"), calendar: taipei)
                 && !daytime.contains(at("2026-08-24 09:29"), calendar: taipei),
               "…with the same inclusive start, minutes included")
        expect(!daytime.contains(at("2026-08-24 17:45"), calendar: taipei)
                 && daytime.contains(at("2026-08-24 17:44"), calendar: taipei),
               "…and the same exclusive end, minutes included")

        // Both ends equal: read as NO quiet time. Dragging a picker past its partner is a slip; "stop
        // the whole feature" is what the switch above does, plainly.
        let empty = EarlyStartQuietHours(isEnabled: true, startHour: 22, startMinute: 0,
                                         endHour: 22, endMinute: 0)
        expect(!empty.contains(at("2026-08-24 22:00"), calendar: taipei)
                 && !empty.contains(at("2026-08-24 03:00"), calendar: taipei),
               "a stretch that ends where it starts is empty, not the whole day")

        // Out-of-range components are clamped on the way IN, so a hand-edited defaults file cannot
        // schedule a 25th hour and leave a stretch that never ends.
        let wild = EarlyStartQuietHours(isEnabled: true, startHour: 99, startMinute: -5,
                                        endHour: -1, endMinute: 90)
        expect(wild.startHour == 23 && wild.startMinute == 0 && wild.endHour == 0
                 && wild.endMinute == 59,
               "hour and minute are clamped into range by the initializer")
    }

    // 4. QUIET HOURS: WHEN DOES THE NEXT ONE END - the only thing left for a timer to be punctual
    //    about, now that everything else rides the refresh loop.
    do {
        let overnight = EarlyStartQuietHours(isEnabled: true, startHour: 23, startMinute: 0,
                                             endHour: 7, endMinute: 0)
        expect(overnight.nextEnd(after: at("2026-08-24 23:30"), calendar: taipei)
                 == at("2026-08-25 07:00"),
               "from inside the stretch, the next end is the coming morning")
        expect(overnight.nextEnd(after: at("2026-08-24 07:00"), calendar: taipei)
                 == at("2026-08-25 07:00"),
               "at the end itself, the next one is tomorrow's (strictly after)")
        expect(overnight.nextEnd(after: at("2026-08-24 06:30"), calendar: taipei)
                 == at("2026-08-24 07:00"),
               "before it, the next end is today's")
        expect(loud.nextEnd(after: at("2026-08-24 23:30"), calendar: taipei) == nil,
               "with quiet hours off there is nothing to wait for, so no timer is set")
        let empty = EarlyStartQuietHours(isEnabled: true, startHour: 22, startMinute: 0,
                                         endHour: 22, endMinute: 0)
        expect(empty.nextEnd(after: at("2026-08-24 12:00"), calendar: taipei) == nil,
               "…and neither is there for an empty stretch")

        let minutes = EarlyStartQuietHours(isEnabled: true, startHour: 23, startMinute: 0,
                                           endHour: 7, endMinute: 45)
        expect(minutes.nextEnd(after: at("2026-08-24 07:00"), calendar: taipei)
                 == at("2026-08-24 07:45"),
               "the minute is part of the end, not ignored")
    }

    // 5. …across a daylight saving jump, where a naive "add 86400" would drift by an hour. New York
    //    springs forward on 2026-03-08 at 02:00; 07:00 exists on both sides of it.
    do {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let overnight = EarlyStartQuietHours(isEnabled: true, startHour: 23, startMinute: 0,
                                             endHour: 7, endMinute: 0)
        let eve = at("2026-03-07 23:30", calendar: newYork)
        let next = overnight.nextEnd(after: eve, calendar: newYork)
        expect(next == at("2026-03-08 07:00", calendar: newYork),
               "quiet hours still end at 07:00 local across a spring-forward night")
        let parts = newYork.dateComponents([.hour, .minute], from: next ?? eve)
        expect(parts.hour == 7 && parts.minute == 0, "…and that reads as 07:00 in that calendar")
        // The clock-time comparison is unaffected by the jump for the same reason: it never touches a
        // Date arithmetic path at all.
        expect(overnight.contains(at("2026-03-08 01:30", calendar: newYork), calendar: newYork),
               "…and the hour before the jump is still inside the stretch")
    }
}
