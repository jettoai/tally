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
                           relaunchPlanned: false, capPending: false, uptime: 300,
                           attempted: nil) == nil)
    check("and lets it through once the typing stops",
          selfUpdateTarget(captured: "0.25.0", installed: "0.26.0",
                           isQuiet: reloadQuiet(transcriptQuiet: true, hasTranscript: true,
                                                childAge: 9999, bar: followIdleSeconds,
                                                keyboardQuiet: true),
                           relaunchPlanned: false, capPending: false, uptime: 300,
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
    if let pin = block(from: "// Live pin switch:", to: "// Cap handoff / wait:") {
        check("the pin adoption waits for the keyboard too", pin.contains("keyboardIdleNow()"))
    } else {
        check("the pin block boundaries were found", false)
    }
    if let follow = block(from: "followAdoption: if follow {",
                          to: "// The session's ACTUAL model degraded") {
        check("the follow adoption waits for the keyboard too",
              follow.contains("keyboardIdleNow(followIdleSeconds)"))
    } else {
        check("the follow block boundaries were found here too", false)
    }
    // The gate now guards the PLAN a lone upgrade makes rather than an exec of its own (the exec
    // moved to the single relaunch site so a pending update can fold into a restart already
    // happening), which changes nothing here: an upgrade nobody else is restarting for still has to
    // find the keyboard still.
    if let update = block(from: "if selfUpdateDue(",
                          to: "RelaunchPlan(target: account, reason: \"self-update\"") {
        check("the self-update gate hands the keyboard answer to reloadQuiet",
              update.contains("keyboardQuiet: keyboardIdleNow(followIdleSeconds)"))
    } else {
        check("the self-update block boundaries were found", false)
    }
    // The one that must NOT have it: that turn is already dead and its owner is waiting on an
    // error, so the handoff is the opposite of an interruption. Nothing between the cap block's
    // opening and the follow block may consult the keyboard.
    if let cap = block(from: "// Cap handoff / wait:", to: "// Follow the launch default:") {
        check("the cap handoff never waits on the keyboard", !cap.contains("keyboardIdleNow"))
    } else {
        check("the cap block boundaries were found", false)
    }
    check("`tally reload` passes the keyboard answer through",
          ((try? String(contentsOfFile: "TallyCLI/Reload.swift", encoding: .utf8)) ?? "")
              .contains("keyboardQuiet: keyboardIdleNow(bar)"))

    // MARK: - 24f. The stat glue, against this process's own terminal

    // The pure rule above is only worth anything if the reader underneath it works. This cannot
    // assert a timestamp (the harness usually runs with no terminal, and when it does have one
    // nobody is typing into it), so it asserts the contract the callers depend on: a path is either
    // resolved and readable, or absent, and absent always answers "idle" rather than "busy".
    if let path = controllingTTYPath {
        check("a resolved terminal path names a device that can be read",
              lastKeyboardInput(path: path) != nil)
        // Nothing was typed in the last instant, whatever else is true of this terminal, so a zero
        // bar always clears. Anything longer would be asserting on the person running the tests.
        check("a real terminal clears a zero bar", keyboardIdleNow(0))
    } else {
        check("with no terminal, the reader reports nothing", lastKeyboardInput() == nil)
        check("and the gate is therefore open", keyboardIdleNow(followIdleSeconds))
    }
    check("a path that is not a device reads as no evidence",
          lastKeyboardInput(path: "/dev/tally-no-such-terminal") == nil)
    check("and a missing device leaves the gate open",
          keyboardIdle(lastInput: lastKeyboardInput(path: "/dev/tally-no-such-terminal"),
                       bar: followIdleSeconds, now: now))
}
