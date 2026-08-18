import Foundation

// The advisory knock's TICK (TallyCLI/QuotaKnock.swift): the station that reads the fleet, asks the
// same gate `tally session send` asks, and types one sentence into the session's own composer. What
// it says and when it is owed is next door in its own suite (tests/quotaknock), split along the
// seam the source is; this side is the wiring, which is where the ways to get this wrong live.
//
// The two that would be invisible in production, and are the reason several of these assertions
// look repetitive: a knock that is HELD must not be lost (the composer is busy at exactly the
// moment an account crosses a line, because a busy session is what this feature exists for), and a
// knock that was TYPED must not repeat (a supervisor polls every two seconds, forever).
//
// Everything here is pure or pointed at a temp directory: no `~/.tally`, no terminal, and the log
// every branch writes is given a sink of its own, so a machine with live sessions on it can run
// this without one of them being typed into.

func runQuotaKnockChecks() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-quotaknock-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("input.log")
    let t0 = Date(timeIntervalSince1970: 1_786_571_200)

    func acct(_ id: String, label: String, session: Double,
              sessionResetHours: Double = 3) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: label, launchHome: "/tmp/\(id)",
                         sessionRemaining: session, weeklyRemaining: 88, modelRemaining: 88,
                         sessionResetsAt: t0.addingTimeInterval(sessionResetHours * 3600),
                         weeklyResetsAt: t0.addingTimeInterval(90 * 3600),
                         modelResetsAt: t0.addingTimeInterval(90 * 3600), modelWindowName: "fable",
                         resetCreditsAvailable: nil, isStale: false, error: nil)
    }
    let dying = acct("A", label: "Claude", session: 10)
    let healthy = acct("B", label: "Claude 2", session: 95)
    let fleet = Snapshot(version: 2, generatedAt: t0, accounts: [dying, healthy])
    /// The pid these fixtures run under, and deliberately not a number: the last check in this
    /// suite asks whether the USER's own log was written to, and a numeric pid is one a real
    /// supervisor can carry, which would let a live session's line answer for this run's.
    let fixturePid = "qk-test-\(UInt64.random(in: 60_466_176 ..< 2_176_782_336))"
    /// What reached the terminal, so "returned a line" and "wrote those bytes" stay two claims.
    var sent: [String] = []

    /// One tick, with every gate open by default so each check can close exactly one of them.
    func knock(_ state: inout QuotaKnockState, account: Snapshot.Account = dying,
               typedAlready: Bool = false, session: SupervisedState = .idle,
               quiet: SessionQuiet = .quiet, turnEnded: Bool = false, keyboardIdle: Bool = true,
               relaunchPlanned: Bool = false,
               quarantine: [String: (model: String?, until: Date)] = [:],
               sessions: Int = 2, loaded: (Snapshot?, String?) = (fleet, nil),
               at moment: Date = t0, injection: SessionInputInjection = .done) -> String? {
        applyQuotaKnock(&state, pid: fixturePid, provider: "claude", account: account,
                        primaryModel: "fable", typedAlready: typedAlready, session: session,
                        quiet: quiet, turnEnded: { turnEnded }, keyboardIdle: keyboardIdle,
                        relaunchPlanned: relaunchPlanned, quarantine: quarantine,
                        counting: { _ in sessions }, loaded: loaded, now: moment, log: log,
                        inject: {
                            sent.append($0)
                            return injection
                        })
    }

    // MARK: - 51. The knock itself

    var state = QuotaKnockState(forced: false)
    let line = knock(&state)
    check("an idle session on a dying account is told about it", line != nil)
    check("…in one line, typed and sent as any other composer line is", sent == [line ?? ""])
    check("…naming the account, the window that binds it and how long it has",
          line?.hasPrefix("[tally] account Claude is running low: session 10% · resets 3h") == true)
    check("…how many conversations are on that window", line?.contains("2 sessions on it") == true)
    check("…where there is room", line?.contains("Best alternative: Claude 2") == true)
    let audit = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    check("and the line is in the audit log under a word of its own, so a reader can tell it from "
              + "one somebody asked for",
          audit.contains("pid=\(fixturePid) input=quota-knock ")
              && audit.contains("[tally] account Claude"))

    // A supervisor polls every two seconds for the life of a session. Saying this once per drought
    // is the entire difference between an advisory and a nag.
    check("the same drought is not announced again",
          knock(&state, at: t0.addingTimeInterval(60)) == nil)
    check("…nor when the account drains further inside it",
          knock(&state, account: acct("A", label: "Claude", session: 2),
                at: t0.addingTimeInterval(600)) == nil)

    // MARK: - 52. What holds it, and what a hold must not cost

    // Every one of these is the same claim twice: nothing is typed now, and the sentence is still
    // owed. A gate that consumed the announcement would silence exactly the sessions this exists
    // for, since a busy session is what a hold means.
    func heldBy(_ name: String, _ closed: (inout QuotaKnockState) -> String?) {
        var state = QuotaKnockState(forced: false)
        check("\(name) holds the knock", closed(&state) == nil)
        check("…and the sentence is still owed once it lifts",
              knock(&state, at: t0.addingTimeInterval(quotaKnockInterval)) != nil)
    }
    heldBy("a conversation mid-turn") { knock(&$0, session: .working, quiet: .busy) }
    heldBy("a session that reports nothing about itself") { knock(&$0, session: .unknown) }
    heldBy("somebody typing in that terminal") { knock(&$0, keyboardIdle: false) }
    heldBy("a restart this tick is about to perform") { knock(&$0, relaunchPlanned: true) }
    heldBy("a line this tick has already typed") { knock(&$0, typedAlready: true) }

    // The 2026-08-17 correction to the input gate carries in for free, because it IS that gate: a
    // session whose dispatched agents are writing has finished speaking, and is typed into.
    var subagents = QuotaKnockState(forced: false)
    check("a session whose subagents are still writing is told",
          knock(&subagents, session: .working, quiet: .subagentsWriting) != nil)
    var ended = QuotaKnockState(forced: false)
    check("and so is one whose turn Claude Code has reported finished",
          knock(&ended, session: .working, quiet: .busy, turnEnded: true) != nil)
    var blocked = QuotaKnockState(forced: false)
    check("a session waiting on a person is told too: it is not writing anything",
          knock(&blocked, session: .blocked) != nil)

    // MARK: - 53. The reading behind it

    var comfortable = QuotaKnockState(forced: false)
    check("an account with room says nothing",
          knock(&comfortable, account: healthy) == nil)
    // BETWEEN THE TWO LINES, which is the reading that tells the station apart from one that fires
    // on the re-arm threshold: 20% is above the line this speaks at and below the one it re-arms
    // at, and the account is not dying yet. Added because the mutant that raised the trigger line
    // to the re-arm line survived this suite while the pure one killed it.
    var midway = QuotaKnockState(forced: false)
    let hovering = acct("A", label: "Claude", session: 20)
    check("nor does one hovering between the line it speaks at and the line it re-arms at",
          knock(&midway, account: hovering,
                loaded: (Snapshot(version: 2, generatedAt: t0, accounts: [hovering, healthy]),
                         nil)) == nil)
    var refilling = QuotaKnockState(forced: false)
    check("nor does a window minutes from resetting, whatever its percentage",
          knock(&refilling, account: acct("A", label: "Claude", session: 4,
                                          sessionResetHours: 0.1),
                loaded: (Snapshot(version: 2, generatedAt: t0,
                                  accounts: [acct("A", label: "Claude", session: 4,
                                                  sessionResetHours: 0.1), healthy]), nil)) == nil)

    // A snapshot nobody can trust answers nothing, the rule every mover applies: advice built on
    // hours-old numbers is worse than silence.
    var stale = QuotaKnockState(forced: false)
    check("a stale snapshot is not something to advise from",
          knock(&stale, loaded: (fleet, "snapshot is 40m old")) == nil)
    var missing = QuotaKnockState(forced: false)
    check("nor is a snapshot that does not name this account",
          knock(&missing, loaded: (Snapshot(version: 2, generatedAt: t0, accounts: [healthy]),
                                   nil)) == nil)
    var unreadable = QuotaKnockState(forced: false)
    check("nor no snapshot at all", knock(&unreadable, loaded: (nil, "no snapshot")) == nil)

    // The alternative is narrowed exactly as a handoff narrows it, so the sentence never names
    // somewhere a move would refuse to go.
    var quarantined = QuotaKnockState(forced: false)
    let hidden = knock(&quarantined,
                       quarantine: ["B": (model: nil, until: t0.addingTimeInterval(600))])
    check("an account the cap quarantine is holding out is not offered as the alternative",
          hidden?.contains("No account has headroom") == true)
    var alone = QuotaKnockState(forced: false)
    check("and with nothing comfortable anywhere the advice is to pause instead",
          knock(&alone, loaded: (Snapshot(version: 2, generatedAt: t0,
                                          accounts: [dying, acct("C", label: "Claude 3",
                                                                 session: 3)]), nil))?
              .contains("consider pausing until the reset") == true)

    // MARK: - 54. What it costs on an ordinary tick

    // The reading is taken at most once per interval: the poll loop runs every two seconds and the
    // app republishes the snapshot every minute or two, so asking on every tick reads one file
    // thirty times for one new number.
    var throttled = QuotaKnockState(forced: false)
    check("a tick that cannot type still counts as the reading",
          knock(&throttled, keyboardIdle: false) == nil)
    check("…so the next tick two seconds later does not read again",
          knock(&throttled, at: t0.addingTimeInterval(2)) == nil)
    check("…and the reading due after the interval is the one that speaks",
          knock(&throttled, at: t0.addingTimeInterval(quotaKnockInterval)) != nil)

    // MARK: - 55. The forced knock, and the terminal refusing

    // The development flag forces the MOMENT and never the content: what it types is the real
    // sentence built from the real snapshot, which is what makes watching it worth anything.
    var forced = QuotaKnockState(forced: true)
    let demo = knock(&forced, account: healthy,
                     loaded: (Snapshot(version: 2, generatedAt: t0,
                                       accounts: [healthy, dying]), nil))
    check("a forced knock fires on a healthy account", demo != nil)
    check("…with the real numbers in it", demo?.contains("Claude 2 is running low: ") == true)
    check("…and it is spent by that one line",
          knock(&forced, account: healthy,
                loaded: (Snapshot(version: 2, generatedAt: t0, accounts: [healthy, dying]), nil),
                at: t0.addingTimeInterval(quotaKnockInterval)) == nil)

    // A terminal that refuses the write is recorded rather than retried: ENXIO means this
    // supervisor has no controlling terminal, and it will mean that again in two seconds.
    var refused = QuotaKnockState(forced: false)
    check("a refused write types nothing",
          knock(&refused, injection: .failed(ENXIO)) == nil)
    let refusal = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    check("…and says so in the log with the errno that tells the two causes apart",
          refusal.contains("input=quota-knock-failed errno=\(ENXIO)"))
    check("…and the drought is not announced again over and over",
          knock(&refused, at: t0.addingTimeInterval(quotaKnockInterval)) == nil)

    // MARK: - 56. The wiring, which no fixture above can reach

    // The station's placement lives in a `while true` inside a process that spawns children, so the
    // source carries it - the technique the preventive station, the input gate and the self-update
    // fold all use. Everything above stays green with this feature never called at all, which is
    // the failure mode a registration check exists for.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the knock checks", !loop.isEmpty)
    check("the tick runs the knock", loop.contains("applyQuotaKnock("))
    if let input = loop.range(of: "let typed = applySessionInput("),
       let start = loop.range(of: "applyQuotaKnock("),
       let execution = loop.range(of: "\n            if let plan {") {
        check("it speaks after the request station and before the child can go",
              input.lowerBound < start.lowerBound && start.lowerBound < execution.lowerBound)
        let call = String(loop[start.lowerBound ..< execution.lowerBound])
        // The three values only the loop knows, and each of them is a way to type into a
        // conversation that cannot receive it.
        check("…knowing whether this tick already typed somebody's line",
              call.contains("typedAlready: typed != nil"))
        check("…and whether this child is about to be replaced, by the hold-aware answer rather "
                  + "than the bare plan",
              call.contains("relaunchPlanned: replacingChild")
                  && !call.contains("relaunchPlanned: plan != nil"))
        check("…and it asks the gate the same two readings the request station is given",
              call.contains("turnEnded: turnOver") && call.contains("keyboardIdle: composerIdle"))
        check("…about the account this session is on and the model it is really running",
              call.contains("account: account") && call.contains("primaryModel: effectivePrimary"))
    } else {
        check("the knock was found in the tick", false)
    }
    // Per SESSION rather than per child, unlike the window repick beside it: a relaunch must not
    // re-announce a drought this conversation has already been told about, and a relaunch that
    // moves accounts re-arms it by itself (a different account, a different cycle key).
    if let declaration = loop.range(of: "var quotaKnock = QuotaKnockState()"),
       let childLoop = loop.range(of: "\n    while true {") {
        check("the arm outlives the child, because the conversation does",
              declaration.lowerBound < childLoop.lowerBound)
    } else {
        check("the knock's state was found in the supervisor", false)
    }

    // Nothing in this suite may have touched the user's own log.
    check("the knock wrote only to the sink it was given",
          (try? String(contentsOf: sessionInputLog, encoding: .utf8))?
              .contains(fixturePid) != true)
    try? FileManager.default.removeItem(at: dir)
}
