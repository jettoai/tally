import Foundation

// Assertion harness for the early-start relay: the decision layer (Tally/Core/EarlyStart.swift),
// its persisted shapes (EarlyStartState.swift), its silence window (EarlyStartQuietHours.swift) and
// the shape of the spawn it produces (EarlyStartCommand.swift).
//
// Nothing anywhere in this suite starts a process. The spawn is a VALUE (`EarlyStartInvocation`),
// so the flags, the config-home variable and the working directory can be asserted exactly, and a
// fake runner (spawnchecks.swift) stands in for CLIRunner to check a whole fleet's worth of them at
// once. What that leaves for review by eye is the store's single unconditional hand-off of that
// value to `CLIRunner.run`, which is one call site in EarlyStartStore.swift.
//
// THIS FILE HOLDS THE HARNESS, THE FIXTURES AND THE GATE; the rest is four files of checks called
// at the bottom, in the order the feature is decided in: is now a quiet hour, which accounts are
// started, what gets written down, and what one message is. They share the globals declared here,
// which is why they are functions rather than more top-level code (only main.swift may carry any).

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

// A FIXED calendar, not the machine's. Every rule below is about local clock time, and a suite whose
// answers moved with the developer's time zone would be asserting the machine.
var taipei = Calendar(identifier: .gregorian)
taipei.timeZone = TimeZone(identifier: "Asia/Taipei")!

func at(_ text: String, calendar: Calendar = taipei) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    guard let date = formatter.date(from: text) else {
        fatalError("test fixture: unparsable date \(text)")
    }
    return date
}

func metric(_ kind: MetricKind, used: Double, resetsAt: Date?) -> UsageMetric {
    UsageMetric(id: kind.rawValue, kind: kind, label: kind.rawValue, modelName: nil,
                usedPercent: used, severity: .fromUsedPercent(used), resetsAt: resetsAt,
                isActive: false)
}

/// `isStale` and `pollsKeepFailing` are separate knobs here because the app really does set them
/// separately: an account that has never succeeded gets the second without the first, for the
/// reason `foldLastGood` gives, and that account is the whole subject of the never-succeeded check
/// in relaychecks.
func usage(_ id: String, session: UsageMetric?, error: String? = nil,
           lastRefreshFailed: Bool = false, isStale: Bool = false,
           pollsKeepFailing: Bool = false) -> AccountUsage {
    AccountUsage(id: id, providerID: "claude", accountLabel: id, planName: nil,
                 metrics: [session].compactMap { $0 }, refreshedAt: at("2026-08-24 07:00"),
                 error: error, isStale: isStale, lastRefreshFailed: lastRefreshFailed,
                 pollsKeepFailing: pollsKeepFailing)
}

func candidate(_ id: String, provider: String = "claude", home: String? = "/Users/tester/.claude2",
               enabled: Bool = true, readable: Bool = true, keepsFailing: Bool = false,
               windowOpen: Bool = false) -> EarlyStartCandidate {
    EarlyStartCandidate(accountID: id, providerID: provider, home: home,
                        isEnabled: enabled, readingIsUsable: readable,
                        readingKeepsFailing: keepsFailing, windowIsOpen: windowOpen)
}

/// Quiet hours switched off, which is the shipping default and the state most of these checks want.
let loud = EarlyStartQuietHours()

/// Every reason there is, so the two truth tables below can be shown to cover the enum rather than
/// to cover the cases somebody remembered.
let everyReason: [EarlyStartSkip] = [.otherProvider, .accountOff, .notLaunchable, .pollMissed,
                                     .unreadable, .windowOpen, .alreadyStarted, .armedMidEpisode,
                                     .quietHours]

// 1. THE FIRST-RUN GATE. The feature ships on, so the switch alone must not be enough: nothing may
//    be sent before the one-time notice has been answered. All four rows, because the interesting
//    one is "on but never told".
do {
    expect(EarlyStartLogic.isArmed(enabled: true, noticeAcknowledged: true),
           "on and told: armed")
    expect(!EarlyStartLogic.isArmed(enabled: true, noticeAcknowledged: false),
           "on but never told: NOT armed (the default-on gate)")
    expect(!EarlyStartLogic.isArmed(enabled: false, noticeAcknowledged: true),
           "off but told: not armed")
    expect(!EarlyStartLogic.isArmed(enabled: false, noticeAcknowledged: false),
           "off and never told: not armed")
}

// 2. …AND IT CLOSES AGAIN WHEN THE PROMISE CHANGES. Version 1 of the notice said "each morning at
//    07:00"; the relay sends at hours that notice ruled out, so consent to it is not consent to
//    this. Somebody who answered the old one has to be asked again, and somebody who answers the
//    new one is not asked twice.
do {
    expect(EarlyStartLogic.noticeVersion == 2,
           "the notice is on its second telling (morning schedule, then relay)")
    expect(!EarlyStartLogic.noticeIsCurrent(seen: 0),
           "a machine that never saw a notice has not seen this one")
    expect(!EarlyStartLogic.noticeIsCurrent(seen: 1),
           "…and neither has one that only ever answered the morning notice")
    expect(EarlyStartLogic.noticeIsCurrent(seen: 2),
           "answering the current notice opens the gate")
    expect(EarlyStartLogic.noticeIsCurrent(seen: 3),
           "…and a payload from a future build is not read as older than this one")
}

runQuietHoursChecks()
runRelayChecks()
runStateChecks()
runSpawnChecks()

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
