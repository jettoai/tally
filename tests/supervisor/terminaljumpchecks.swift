import Foundation

// Assertion harness for the click that takes somebody to their session's terminal
// (Tally/Core/TerminalJump.swift), compiled against the real source.
//
// TWO HALVES, because the second cannot be driven from here. The script sent to Ghostty, the
// version gate in front of it and the markers that come back are pure, and are asserted directly;
// the activation half is a fact about a real desktop with a real foreground on it, so what is
// asserted there is the ORDER of the calls that carry it, read off the source. That order is the
// whole of the defect this file grew for: an app that never held the foreground yielded one, and
// yielded it after the terminal had already asked.
func runTerminalJumpChecks() {
    // MARK: the AppleScript the jump sends

    // Both interpolated values are read off disk (a checkout path, a repository name), so neither may
    // end the literal early and turn the rest of the line into script.
    check("a quote in a path cannot close the literal",
          TerminalJump.literal("/Users/u/co\"de") == "\"/Users/u/co\\\"de\"")
    check("…nor can a backslash escape the closing one",
          TerminalJump.literal("/Users/u/code\\") == "\"/Users/u/code\\\\\"")
    let script = TerminalJump.script(directory: "/Users/u/code/tally", hint: "tally · cart",
                                     tty: nil)
    check("the script matches on the working directory and breaks ties on the name",
          script.contains("working directory of t) is equal to \"/Users/u/code/tally\"")
              && script.contains("(name of t) contains \"tally · cart\""))
    // A Ghostty without `terminals`, or without `working directory` on one, RAISES rather than
    // returning nothing, and an unhandled raise is a row that visibly does nothing.
    check("every lookup against another app's dictionary is guarded",
          script.components(separatedBy: "try").count - 1 >= 3)
    // A session with no live child to ask about must not have the older dictionary asked for a
    // property it does not have, so the pass is absent rather than merely guarded.
    check("a session with no device to match on never asks about one",
          !script.contains("tty of t"))

    // MARK: matching the surface rather than the repository

    // The bug this answers: one checkout open in several tabs or splits matches the directory in
    // all of them, the titles rarely carry the repository's name, and the tie-break therefore falls
    // through to whichever surface the enumeration happened to reach first.
    let exact = TerminalJump.script(directory: "/Users/u/code/tally", hint: "tally · cart",
                                    tty: "/dev/ttys001")
    guard let ttyHit = exact.range(of: "(tty of t) is equal to \"/dev/ttys001\""),
          let dirHit = exact.range(of: "(working directory of t) is equal to") else {
        check("the script asks about the device and the directory", false)
        return
    }
    let deviceFirst = ttyHit.upperBound < dirHit.lowerBound
    check("the device is asked about before the directory", deviceFirst)
    // Order alone would not settle it: without the guard, a later directory match overwrites the
    // exact one and the click lands on the wrong tab again. Short-circuited, so an inverted script
    // reports the line above rather than tearing the harness down on a backwards range.
    check("a directory match stands down for a device match already found",
          deviceFirst && String(exact[ttyHit.upperBound ..< dirHit.lowerBound])
              .contains("if matched is missing value then"))
    // A device path comes off the process table, so it gets the same treatment as the two values
    // read off disk rather than being trusted to be free of quotes.
    check("a device path cannot close the literal either",
          TerminalJump.script(directory: "", hint: "", tty: "/dev/tty\"s\\1")
              .contains("is equal to \"/dev/tty\\\"s\\\\1\""))
    // A Ghostty too old to have `tty` RAISES on the lookup, and the whole point of the fallback is
    // that such a version still reaches the directory pass instead of exiting non-zero.
    let beforeTTY = String(exact[..<ttyHit.lowerBound])
    check("the device lookup is inside a guard the older dictionary's raise cannot escape",
          beforeTTY.components(separatedBy: "try").count
              - 2 * (beforeTTY.components(separatedBy: "end try").count - 1) - 1 >= 2)

    // MARK: what the script REPORTS, as opposed to what it found

    // The word it used to return meant three things at once - "a surface was found", "the focus
    // succeeded" and "the terminal has the keyboard" - and the first of them was returned even when
    // `focus` had raised inside its own wrap. That one word then skipped the ancestor walk that
    // existed for exactly the case it was hiding.
    check("the script names the pass that answered rather than saying one word for everything",
          exact.contains("return hit") && !exact.contains("return \"ok\""))
    check("the device pass marks itself", exact.contains("set hit to \"tty\""))
    check("…and the directory pass marks itself as the vaguer answer",
          script.contains("set hit to \"dir\"") && !script.contains("set hit to \"tty\""))
    // Both of the directory pass's answers are marked, not just the first: the tie-break assigns a
    // second time, and a marker left behind by the first would be a pass reporting a hit it no
    // longer holds.
    check("both of the directory pass's assignments carry the marker",
          script.components(separatedBy: "set matched to t").count
              == script.components(separatedBy: "set hit to \"dir\"").count)
    // A refused focus leaves by the SAME door as no match at all, because upstream those are one
    // answer: no surface was focused, so the exits below it are still owed.
    guard let focusCall = exact.range(of: "focus matched"),
          let focusEnd = exact.range(of: "end try", range: focusCall.upperBound ..< exact.endIndex)
    else {
        check("the focus call was found to read", false)
        return
    }
    check("a refused focus reports no match rather than success",
          String(exact[focusCall.upperBound ..< focusEnd.lowerBound])
              .contains("on error\n        return \"\""))
    // And the words the script can return are exactly the ones Swift parses back. `ok` is in here
    // because it is what a build of this app that had drifted from its script would still send.
    check("the markers round-trip into the type the caller switches on",
          TerminalJump.SurfaceMatch(rawValue: "tty") == .tty
              && TerminalJump.SurfaceMatch(rawValue: "dir") == .directory)
    check("…and nothing else does",
          TerminalJump.SurfaceMatch(rawValue: "ok") == nil
              && TerminalJump.SurfaceMatch(rawValue: "") == nil)

    // MARK: which Ghostty may be asked about a device at all

    // `tty` on a surface arrives in 1.4.0 (ghostty-org/ghostty#11592, PR #11922) and exists in no
    // released version, so the pass was dead code on every machine - silently, because the raise it
    // provokes is swallowed by the wraps. The gate is what turns that into an observable fact.
    check("no version yet released can be asked", !TerminalJump.readsSurfaceTTY(version: "1.3.1"))
    check("…including the last one before the change",
          !TerminalJump.readsSurfaceTTY(version: "1.3.9"))
    check("the version that adds it can", TerminalJump.readsSurfaceTTY(version: "1.4.0"))
    check("…as can a later one", TerminalJump.readsSurfaceTTY(version: "1.4.1")
              && TerminalJump.readsSurfaceTTY(version: "2.0.0"))
    // Compared component by component rather than as text, which is the one way this can be wrong
    // without looking wrong: "1.10" sorts BEFORE "1.4" as a string.
    check("a two-digit minor is newer, not older", TerminalJump.readsSurfaceTTY(version: "1.10.0"))
    // Missing components are zero, so a version written short is still answered.
    check("a version written short still compares", TerminalJump.readsSurfaceTTY(version: "1.4")
              && !TerminalJump.readsSurfaceTTY(version: "1"))
    // A version that cannot be read is an OLD one: the device pass is the precision and the
    // directory pass is the floor, so the safe direction of a wrong guess is downward.
    check("a version nobody can read is treated as too old",
          !TerminalJump.readsSurfaceTTY(version: nil)
              && !TerminalJump.readsSurfaceTTY(version: "")
              && !TerminalJump.readsSurfaceTTY(version: "unknown"))

    // MARK: the half of the click that is not about surfaces

    // Assertions from here down match CODE, never comments - a suite that matched raw source would
    // go green on a doc comment that merely describes the rule (the window anchor suite was caught
    // by exactly that, 2026-08-05).
    func jumpCode(of path: String) -> String {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            var quotes = 0
            for index in line.indices {
                if line[index] == "\"" { quotes += 1 }
                if quotes % 2 == 0, line[index] == "/", line.index(after: index) < line.endIndex,
                   line[line.index(after: index)] == "/" {
                    return line[..<index]
                }
            }
            return line
        }.joined(separator: "\n")
    }
    let cardSource = jumpCode(of: "Tally/Views/SessionCardView.swift")
    // THE ONE LINE THAT CANNOT MOVE INTO THE TASK. An app may activate itself while it is handling
    // a user event; the task runs after that event has been answered, and the surface most of these
    // clicks arrive in never made this app active at all. Asserted as an ORDER, because a
    // `prepare()` called inside the task would still be a call to `prepare()`.
    guard let prepared = cardSource.range(of: "let handover = TerminalJump.prepare()"),
          let detached = cardSource.range(of: "Task { await TerminalJump.jump(")
    else {
        check("the card's click was found to read", false)
        return
    }
    check("the foreground is taken in the press's own turn, before anything is awaited",
          prepared.upperBound < detached.lowerBound)
    check("…and what it took is what the jump is given",
          cardSource.contains("childPid: row.childPid, from: handover)"))

    let jumpSource = jumpCode(of: "Tally/Core/TerminalJump.swift")
    guard let prepareStart = jumpSource.range(of: "static func prepare() -> Handover {"),
          let prepareEnd = jumpSource.range(of: "\n    }\n", range: prepareStart.upperBound ..< jumpSource.endIndex)
    else {
        check("the handover was found to read", false)
        return
    }
    let prepare = String(jumpSource[prepareStart.upperBound ..< prepareEnd.lowerBound])
    // THE ORDER IS THE WHOLE OF IT: a yield is what the holder of the foreground does BEFORE the
    // target asks for it, so the app has to have taken one first, and both have to happen before
    // the script's own `activate` goes out.
    guard let took = prepare.range(of: "NSApp.activate()"),
          let gave = prepare.range(of: "NSApp.yieldActivation(to: terminal)")
    else {
        check("the handover takes the foreground and yields it", false)
        return
    }
    check("the foreground is taken before it is yielded", took.upperBound < gave.lowerBound)
    // The device is read only when the running Ghostty can be asked about one, so an old dictionary
    // costs no scan at all rather than a scan that raises on every surface.
    check("the device is read only for a Ghostty that publishes one",
          jumpSource.contains("readsSurfaceTTY(terminal)"))
    // Every exit is judged the same way, one grace later: a request is not an outcome, and a second
    // copy of that judgement is a copy that drifts (`land`).
    check("all three exits are judged rather than assumed",
          jumpSource.components(separatedBy: "await land(on: ").count - 1 == 3)
    // Both exits that can fail hand the borrowed foreground back through ONE statement of it, and
    // that statement refuses when this app no longer holds one - giving a foreground away twice
    // takes the screen from whatever the person moved on to in between.
    check("a click that reached nothing gives the foreground back",
          jumpSource.components(separatedBy: "handover.giveBack()").count - 1 == 2
              && jumpSource.contains("func giveBack() { if NSApp.isActive { previousApp?.activate() } }"))
    // The second road, for the ask that went nowhere: LaunchServices reaches activation by another
    // authorisation than an app-to-app transfer does. Never for an app that has since exited - that
    // call would LAUNCH it, which is the one thing a status board must not do.
    check("an ask that did not land is made again the other way",
          jumpSource.contains("NSWorkspace.shared.openApplication(at: bundle,")
              && jumpSource.contains("!target.isTerminated"))

    // MARK: the device the kernel reports

    // The oracle is `ps`, which reads the same field by another path. Both answers are nil when
    // this harness runs with no controlling terminal (a CI runner, or a spawn from the app), which
    // is itself the case the directory pass exists for.
    func psTTY(_ pid: pid_t) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "tty=", "-p", "\(pid)"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = Pipe()
        guard (try? ps.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let name = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty || name == "??" ? nil : "/dev/" + name
    }
    check("the kernel names this process's own terminal the way ps does",
          TerminalJump.controllingTTY(of: getpid()) == psTTY(getpid()))
    // pid 1 is launchd: owned by root and attached to nothing, so both refusals answer nil rather
    // than a device somebody would then be sent to.
    check("a process with no terminal of its own reports none", TerminalJump.controllingTTY(of: 1) == nil)
}
