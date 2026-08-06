import Foundation

// The keyboard half of the quiet bar (KeyboardIdle.swift). Split out of reloadchecks.swift for
// file size; the harness (`check`, `failures`) is shared from main.swift.
//
// Everything here runs on the pure rule, with the terminal's answer passed in as a value, so these
// assertions hold on a machine with no terminal at all (which is what the test harness itself is).
// The stat that reads the real device node is one function, exercised by the last block against
// this process's own terminal if it has one.

func runKeyboardChecks() {
    // MARK: - 24. A prompt being typed is not an idle session

    // Why any of this exists: a user composing the next prompt writes NOTHING to the transcript
    // until they submit it, so the file's own 120s window cannot tell "left alone for two minutes"
    // from "two minutes into typing a long prompt", and the non-urgent relaunch took the half-typed
    // text with it (2026-07-26). The terminal device node's atime is stamped by the child reading
    // each keystroke, so it answers the half the file cannot.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func typed(_ secondsAgo: TimeInterval) -> Date { now.addingTimeInterval(-secondsAgo) }

    check("a key pressed a second ago is a busy keyboard at the follow bar",
          !keyboardIdle(lastInput: typed(1), bar: followIdleSeconds, now: now))
    check("still typing 119s in, one second short of the bar",
          !keyboardIdle(lastInput: typed(119), bar: followIdleSeconds, now: now))
    check("a keyboard untouched for the whole bar is idle",
          keyboardIdle(lastInput: typed(120), bar: followIdleSeconds, now: now))
    check("and plainly idle well past it",
          keyboardIdle(lastInput: typed(600), bar: followIdleSeconds, now: now))
    // The bar is the caller's, not a constant of its own: the short 5s bar forgives a pause that
    // the 120s bar still calls typing, which is what makes each call site keep its own meaning.
    check("the same 10s pause is idle at the urgent bar",
          keyboardIdle(lastInput: typed(10), bar: reloadNowIdleSeconds, now: now))
    check("but busy at the follow bar",
          !keyboardIdle(lastInput: typed(10), bar: followIdleSeconds, now: now))

    // No terminal at all (started from a script, a pipe, CI) or a stat that failed. Absence of a
    // keyboard is evidence of neither typing nor stillness, so it must never be read as "busy":
    // that would freeze every non-urgent relaunch for every unattended session forever.
    check("no terminal is not evidence that someone is typing",
          keyboardIdle(lastInput: nil, bar: followIdleSeconds, now: now))
    check("no terminal is not evidence at the urgent bar either",
          keyboardIdle(lastInput: nil, bar: reloadNowIdleSeconds, now: now))

    // MARK: - 24a. Typing arrives in runs, terminal chatter arrives alone

    // The second defect, and the reason the supervisor no longer asks the rule above directly
    // (measured 2026-07-28, session dd704ccc on /dev/ttys015, its owner working in another window):
    // the node was stamped four times across three minutes, 23 to 60 seconds apart, so its age
    // never passed 61s and the 120s bar was arithmetically unreachable. Every non-urgent relaunch
    // was held for the life of the session while all three FILE gates stood open.
    //
    // Age cannot separate those stamps from typing; spacing can, and spacing needs history. A
    // raw-mode child stamps the node on every keystroke, so composition arrives as a run.
    var unread = KeyboardActivity()
    check("a tracker that has seen nothing is idle at the follow bar",
          unread.idle(followIdleSeconds, now: now))
    check("and at the urgent bar", unread.idle(reloadNowIdleSeconds, now: now))
    unread.observe(stamp: nil)
    check("a terminal that cannot be read is still no evidence of typing",
          unread.idle(followIdleSeconds, now: now))

    // A lone stamp holds the gate only until the window in which a SECOND stamp would have made it
    // typing has passed. This is the whole behaviour change: 16s, not 120s.
    var lone = KeyboardActivity()
    lone.observe(stamp: typed(10))
    check("a lone stamp inside the burst window still holds the follow bar",
          !lone.idle(followIdleSeconds, now: now))
    var loneAged = KeyboardActivity()
    loneAged.observe(stamp: typed(16))
    check("a lone stamp past the burst window releases the follow bar",
          loneAged.idle(followIdleSeconds, now: now))

    // A run of stamps is someone typing, and that holds the caller's FULL bar - the original
    // feature, which must survive all of this: a prompt being composed is not an idle session.
    var typing = KeyboardActivity()
    for age in [12.0, 9.0, 6.0, 3.0] { typing.observe(stamp: typed(age)) }
    check("a prompt actually being typed still blocks the 120s relaunch",
          !typing.idle(followIdleSeconds, now: now))
    var burst = KeyboardActivity()
    burst.observe(stamp: typed(124))
    burst.observe(stamp: typed(119))      // 5s apart: a run, so the bar starts from here
    check("a burst one second short of the bar still holds it",
          !burst.idle(followIdleSeconds, now: now))
    var spentBurst = KeyboardActivity()
    spentBurst.observe(stamp: typed(126))
    spentBurst.observe(stamp: typed(121))
    check("and releases it once the whole bar has passed since the run",
          spentBurst.idle(followIdleSeconds, now: now))

    // THE REGRESSION LOCK: the measured sequence itself, gaps of 23s, 60s and 45s, the last stamp
    // 16s ago. The rule it replaces is asserted alongside it, because the two disagreeing on this
    // input is the entire point - the old one is what held the session forever.
    var chatter = KeyboardActivity()
    for age in [144.0, 121.0, 61.0, 16.0] { chatter.observe(stamp: typed(age)) }
    check("the measured chatter sequence clears the 120s bar",
          chatter.idle(followIdleSeconds, now: now))
    check("where asking only the newest stamp's age would still be holding it",
          !keyboardIdle(lastInput: typed(16), bar: followIdleSeconds, now: now))

    // Chatter arriving after a burst does not extend the burst's hold: the hold is timed from the
    // typing, and a lone stamp carries only its own short window. Otherwise one stamp a minute
    // (which is what the measured terminal produced) would pin the session busy forever again.
    var afterBurst = KeyboardActivity()
    afterBurst.observe(stamp: typed(126))
    afterBurst.observe(stamp: typed(121))
    afterBurst.observe(stamp: typed(61))
    check("a lone stamp after a burst does not extend the hold",
          afterBurst.idle(followIdleSeconds, now: now))

    // The 5s call sites keep the meaning they had: min(burst window, bar) is the bar there, so
    // every answer at that bar is the one the old rule gave.
    var quickIdle = KeyboardActivity()
    quickIdle.observe(stamp: typed(6))
    check("a lone stamp 6s old is idle at the urgent bar, exactly as before",
          quickIdle.idle(reloadNowIdleSeconds, now: now))
    check("which is what the rule it replaced said too",
          keyboardIdle(lastInput: typed(6), bar: reloadNowIdleSeconds, now: now))
    var quickBusy = KeyboardActivity()
    quickBusy.observe(stamp: typed(4))
    check("and 4s old is still mid-stream there", !quickBusy.idle(reloadNowIdleSeconds, now: now))

    // A reading OLDER than the one already held is time moving backwards (a clock adjustment, a
    // terminal replaced under the same path), not a keystroke that arrived quickly. Its gap is
    // negative, so a bare "gap <= 15" reads it as a burst and holds the session for two minutes on
    // no input whatsoever.
    var rewound = KeyboardActivity()
    rewound.observe(stamp: typed(20))
    rewound.observe(stamp: typed(80))     // 60s EARLIER than the stamp already held
    check("a stamp that goes backwards is not a burst", rewound.lastBurstAt == nil)
    check("and does not hold the follow bar", rewound.idle(followIdleSeconds, now: now))
    check("the reading is still taken, so the next gap is measured from it",
          rewound.lastStamp == typed(80))

    // Every 2s tick re-reads the same atime until something arrives. Treating each reading as an
    // event would make any single keystroke look like an endless burst.
    var repeated = KeyboardActivity()
    repeated.observe(stamp: typed(60))
    repeated.observe(stamp: typed(60))
    repeated.observe(stamp: typed(60))
    check("re-reading the same stamp is not a second keystroke", repeated.lastBurstAt == nil)
    check("so a tick that learns nothing new leaves the session idle",
          repeated.idle(followIdleSeconds, now: now))

    // MARK: - 24b. What the gate does with that answer

    // A session the transcript calls quiet, up long enough, with a transcript located: everything
    // the old rule asked for. The keyboard is now the one thing standing between it and a restart.
    check("a half-typed prompt blocks a relaunch the transcript alone would allow",
          !reloadQuiet(transcriptQuiet: true, hasTranscript: true, childAge: 9999,
                       bar: followIdleSeconds, keyboardQuiet: false))
    check("once the keyboard goes still too, the relaunch is allowed",
          reloadQuiet(transcriptQuiet: true, hasTranscript: true, childAge: 9999,
                      bar: followIdleSeconds, keyboardQuiet: true))
    // The keyboard only ever subtracts. It cannot rescue a session that is mid-turn, or one whose
    // transcript has not appeared yet and whose child is too young, so no existing bar is loosened.
    check("a still keyboard does not make a streaming turn interruptible",
          !reloadQuiet(transcriptQuiet: false, hasTranscript: true, childAge: 9999,
                       bar: followIdleSeconds, keyboardQuiet: true))
    check("a still keyboard does not excuse a session too young to have a transcript",
          !reloadQuiet(transcriptQuiet: true, hasTranscript: false, childAge: 3,
                       bar: followIdleSeconds, keyboardQuiet: true))
    // The same gate guards `tally reload` and the supervisor self-update, which is the wave that
    // caused this (13:01, 2026-07-26): the version check hands its verdict to `selfUpdateTarget` as
    // one Bool, so a busy keyboard defers the exec exactly as it defers a reload.
    check("a busy keyboard defers the self-update exec",
          selfUpdateTarget(captured: "0.25.0", installed: "0.26.0",
                           isQuiet: reloadQuiet(transcriptQuiet: true, hasTranscript: true,
                                                childAge: 9999, bar: followIdleSeconds,
                                                keyboardQuiet: false),
                           relaunchPlanned: false, uptime: 300,
                           attempted: nil) == nil)
    check("and lets it through once the typing stops",
          selfUpdateTarget(captured: "0.25.0", installed: "0.26.0",
                           isQuiet: reloadQuiet(transcriptQuiet: true, hasTranscript: true,
                                                childAge: 9999, bar: followIdleSeconds,
                                                keyboardQuiet: true),
                           relaunchPlanned: false, uptime: 300,
                           attempted: nil) == "0.26.0")

    // MARK: - 24c. A machine with no terminal behaves exactly as it did before

    // Not "behaves sensibly": IDENTICALLY. Every case of the old four-argument rule is replayed
    // against the new one carrying what a machine with no terminal reports, and the two must agree
    // on all of them, so an unattended session cannot have been changed by this at all.
    let noKeyboard = keyboardIdle(lastInput: nil, bar: followIdleSeconds, now: now)
    for (transcript, has, age) in [(true, true, 1.0), (false, true, 9999.0), (true, false, 3.0),
                                   (true, false, 121.0), (false, false, 9999.0)] {
        check("with no terminal, transcript=\(transcript) hasFile=\(has) age=\(Int(age)) is unchanged",
              reloadQuiet(transcriptQuiet: transcript, hasTranscript: has, childAge: age, bar: 120)
                == reloadQuiet(transcriptQuiet: transcript, hasTranscript: has, childAge: age,
                               bar: 120, keyboardQuiet: noKeyboard))
    }
    check("omitting the keyboard entirely is the same as having no terminal",
          reloadQuiet(transcriptQuiet: true, hasTranscript: true, childAge: 1, bar: 120)
            == reloadQuiet(transcriptQuiet: true, hasTranscript: true, childAge: 1, bar: 120,
                           keyboardQuiet: noKeyboard))

    // MARK: - 24d. The cap path is deliberately untouched

    // A capped turn is already dead and its owner is most likely staring at the error, so restarting
    // FAST is the point: the cap handoff never consulted the transcript's follow bar and must not
    // start consulting the keyboard either. Its decision takes no keyboard argument at all, which is
    // the real guarantee; these pin the behaviour so a later refactor cannot quietly add one.
    check("a capped session hands off with a target, whatever is being typed",
          capRecoveryAction(mode: "auto", fuseAllows: true, snapshotStale: false,
                            hasTarget: true) == .handoff)
    check("a capped session in manual mode still waits for its own account, not the keyboard",
          capRecoveryAction(mode: "manual", fuseAllows: true, snapshotStale: false,
                            hasTarget: true) != .handoff)

    // MARK: - 24e. The wiring: which paths ask the keyboard and which must not

    // A pure rule cannot hold this. Every assertion above stays green if a call site simply omits
    // the argument and takes the permissive default, so the source carries the invariant: the three
    // non-urgent paths consult the keyboard, and the cap path is left alone. Same technique (and
    // the same repo-root assumption) as the follow-block guard in reloadchecks.swift.
    let source = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the keyboard checks", !source.isEmpty)
    func block(from opening: String, to closing: String) -> String? {
        guard let start = source.range(of: opening),
              let end = source.range(of: closing, range: start.upperBound ..< source.endIndex)
        else { return nil }
        return String(source[start.upperBound ..< end.lowerBound])
    }
    //
    // They ask the per-child TRACKER, and the single-stat form it replaced no longer exists, so the
    // literal way back to the 2026-07-28 freeze is a compile error rather than a green test run.
    // The spelling is still pinned here because the ways back that DO compile are not: a gate that
    // stops asking anything, or one whose tracker is never fed, reads as idle forever and every
    // value assertion above stays green.
    check("the tick feeds the tracker before anything decides on it",
          source.contains("keyboard.observe(stamp: lastKeyboardInput())"))
    if let observed = source.range(of: "keyboard.observe("),
       let firstGate = source.range(of: "keyboard.idle(") {
        check("the reading is taken before the first gate reads it",
              observed.lowerBound < firstGate.lowerBound)
    } else {
        check("both the reading and a gate that uses it are present", false)
    }
    // The pin switch moved to SessionSwitch.swift, where it shares its decision with the
    // `tally switch` a user types inside the session; its half of this is now asserted the way the
    // follow adoption's below is - the rule asks the keyboard it was handed, and the tick hands it
    // the tracker (the second half is the shared `keyboardIdle: { keyboard.idle($0) }` check).
    let manualMoveSource = (try? String(contentsOfFile: "TallyCLI/SessionSwitch.swift",
                                        encoding: .utf8)) ?? ""
    check("the manual-move source is readable from the keyboard checks", !manualMoveSource.isEmpty)
    check("the pin adoption waits for the keyboard too",
          manualMoveSource.contains("keyboardIdle(manualMoveIdleSeconds)"))
    check("and so does an explicit switch",
          manualMoveSource.contains("keyboardQuiet: keyboardIdle(manualMoveIdleSeconds)"))
    check("neither reads a keyboard of its own",
          !manualMoveSource.contains("lastKeyboardInput")
              && !manualMoveSource.contains("keyboardIdleNow"))
    // The follow adoption moved to a file of its own, so its half of this is asserted the way the
    // reload and safeguard gates already are: the decision asks the keyboard it was handed, and the
    // tick hands it the tracker. Splitting the assertion is what keeps a call site that stopped
    // passing the tracker from passing silently.
    let followSource = (try? String(contentsOfFile: "TallyCLI/FollowAdoption.swift",
                                    encoding: .utf8)) ?? ""
    check("the follow adoption source is readable from the keyboard checks", !followSource.isEmpty)
    check("the follow adoption waits for the keyboard too",
          followSource.contains("keyboardIdle(followIdleSeconds)"))
    check("and it reads no keyboard of its own", !followSource.contains("keyboardIdleNow"))
    check("the tick hands the follow adoption the same tracker",
          source.contains("keyboardIdle: { keyboard.idle($0) }"))
    // The gate now guards the PLAN a lone upgrade makes rather than an exec of its own (the exec
    // moved to the single relaunch site so a pending update can fold into a restart already
    // happening), which changes nothing here: an upgrade nobody else is restarting for still has to
    // find the keyboard still.
    if let update = block(from: "if selfUpdateDue(",
                          to: "RelaunchPlan(target: account, reason: \"self-update\"") {
        check("the self-update gate hands the keyboard answer to reloadQuiet",
              update.contains("keyboardQuiet: keyboard.idle(followIdleSeconds)"))
    } else {
        check("the self-update block boundaries were found", false)
    }
    // The one that must NOT have it: that turn is already dead and its owner is waiting on an
    // error, so the handoff is the opposite of an interruption. Nothing between the cap block's
    // opening and the follow block may consult the keyboard, by either spelling.
    if let cap = block(from: "// Cap handoff / wait:", to: "// Follow the launch default:") {
        check("the cap handoff never waits on the keyboard",
              !cap.contains("keyboardIdleNow") && !cap.contains("keyboard.idle"))
    } else {
        check("the cap block boundaries were found", false)
    }
    // `tally reload` takes the answer as an argument (the tracker lives with the supervisor), so
    // the invariant is in two halves: the supervisor hands the tracker over, and Reload.swift asks
    // what it was handed rather than reading a stat of its own.
    check("the reload gate is given the supervisor's tracker",
          source.contains("keyboardIdle: { keyboard.idle($0) }"))
    let reloadSource = (try? String(contentsOfFile: "TallyCLI/Reload.swift", encoding: .utf8)) ?? ""
    check("the reload source is readable from the keyboard checks", !reloadSource.isEmpty)
    check("`tally reload` passes that answer through",
          reloadSource.contains("keyboardQuiet: keyboardQuiet"))
    check("and reads no keyboard of its own", !reloadSource.contains("keyboardIdleNow"))
    // The safeguard restore has the same shape and the same reason: the API left this session on a
    // fallback model and the declared depth goes back at an idle moment, which is a relaunch nobody
    // asked for right now, so it waits like the rest. It held out on the single stat until
    // 2026-07-28, when it was the SECOND path found frozen behind an unreachable 120s bar.
    check("the supervisor hands the safeguard restore the same tracker",
          source.contains("keyboardIdle: { keyboard.idle($0) }"))
    let safeguardSource = (try? String(contentsOfFile: "TallyCLI/SafeguardDrift.swift",
                                       encoding: .utf8)) ?? ""
    check("the safeguard source is readable from the keyboard checks", !safeguardSource.isEmpty)
    check("the restore gate waits on the keyboard it was handed",
          safeguardSource.contains("keyboardIdle(followIdleSeconds)"))
    check("and reads no keyboard of its own",
          !safeguardSource.contains("keyboardIdleNow"))
    // The single-stat form is gone entirely: while it existed, every gate above could be reverted to
    // it one call site at a time and only the one assertion naming that site would notice.
    check("nothing in the CLI reads the keyboard through the retired single-stat form",
          !source.contains("keyboardIdleNow") && !reloadSource.contains("keyboardIdleNow")
              && !safeguardSource.contains("keyboardIdleNow"))

    // MARK: - 24f. The stat glue, against this process's own terminal

    // The pure rule above is only worth anything if the reader underneath it works. This cannot
    // assert a timestamp (the harness usually runs with no terminal, and when it does have one
    // nobody is typing into it), so it asserts the contract the callers depend on: a path is either
    // resolved and readable, or absent, and absent always answers "idle" rather than "busy".
    //
    // Driven through the tracker, which is the composition the supervisor actually runs: a reading
    // taken off the real device node and handed to `observe`, then asked.
    var live = KeyboardActivity()
    live.observe(stamp: lastKeyboardInput())
    if let path = controllingTTYPath {
        check("a resolved terminal path names a device that can be read",
              lastKeyboardInput(path: path) != nil)
        // Nothing was typed in the last instant, whatever else is true of this terminal, so a zero
        // bar always clears. Anything longer would be asserting on the person running the tests.
        check("a real terminal clears a zero bar", live.idle(0))
    } else {
        check("with no terminal, the reader reports nothing", lastKeyboardInput() == nil)
        check("and the gate is therefore open", live.idle(followIdleSeconds))
    }
    check("a path that is not a device reads as no evidence",
          lastKeyboardInput(path: "/dev/tally-no-such-terminal") == nil)
    check("and a missing device leaves the gate open",
          keyboardIdle(lastInput: lastKeyboardInput(path: "/dev/tally-no-such-terminal"),
                       bar: followIdleSeconds, now: now))
}
