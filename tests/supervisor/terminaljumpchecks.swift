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
    let script = TerminalJump.script(directory: "/Users/u/code/tally", tty: nil, nonce: nil)
    check("the script matches on the working directory",
          script.contains("working directory of t) is equal to \"/Users/u/code/tally\""))
    // THE FIRST SURFACE IN THE CHECKOUT IS THE ANSWER, and nothing about a tab's NAME is consulted
    // after it. The rule that used to follow read as a free tie-break and was not one: a session's
    // own tab is titled by whatever Claude Code last wrote to it, while a plain shell tab in the
    // same checkout carries the repository's name far more reliably - so "prefer the name" reached
    // the right tab first and then overwrote it with the shell (reported twice, 2026-08-15).
    check("the first surface standing in the checkout ends the search",
          script.components(separatedBy: "set matched to t").count == 2
              && script.components(separatedBy: "exit repeat").count == 2)
    check("…and no tab's name can overrule it", !script.contains("name of t"))
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
    let exact = TerminalJump.script(directory: "/Users/u/code/tally", tty: "/dev/ttys001",
                                    nonce: nil)
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
          TerminalJump.script(directory: "", tty: "/dev/tty\"s\\1", nonce: nil)
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
    // The one assignment the pass now makes carries both the marker and the surface it landed on:
    // without the second, two clicks that both answer `dir` read identically in the log whether
    // they reached two tabs or the same tab twice - which is the complaint that line exists for.
    check("the directory pass's one assignment carries the marker and the surface it took",
          script.components(separatedBy: "set matched to t").count
              == script.components(separatedBy: "set hit to \"dir\"").count
              && script.contains("set found to ((id of t) as text)"))
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
    // AND THE FOCUS IS THE LAST THING THE SCRIPT DOES. `focus` raises the surface's own window, so
    // an `activate` made after it is a second, vaguer instruction to the same app: come forward on
    // the TERMINAL's terms, which is whichever window it had in front last - the tab somebody just
    // said they did not want, put back on top by this app's own hand (reported twice, 2026-08-15).
    guard let activateAsk = exact.range(of: "\n    activate\n") else {
        check("the script brings the terminal forward", false)
        return
    }
    check("the terminal is brought forward before the exact surface is focused",
          activateAsk.upperBound < focusCall.lowerBound)
    check("…and nothing brings it forward again afterwards",
          !exact[focusCall.upperBound...].contains("activate"))
    // And the words the script can return are exactly the ones Swift parses back. `ok` is in here
    // because it is what a build of this app that had drifted from its script would still send.
    check("the markers round-trip into the type the caller switches on",
          TerminalJump.SurfaceMatch(rawValue: "tty") == .tty
              && TerminalJump.SurfaceMatch(rawValue: "dir") == .directory)
    check("…and nothing else does",
          TerminalJump.SurfaceMatch(rawValue: "ok") == nil
              && TerminalJump.SurfaceMatch(rawValue: "") == nil)

    // MARK: the mark written to the session's own device

    // How the surface is asked its own identity on a Ghostty that publishes no device: a name
    // nobody else can be carrying is written to the session's tty, and the surface that comes to
    // be called it IS the session's. Everything here is the pure half of that - the name, the two
    // scans it needs, and the escape it travels in.
    var marks = Set<String>()
    for _ in 0 ..< 500 { marks.insert(TerminalJump.nonce()) }
    check("no two marks are the same", marks.count == 500)
    check("…and each one says what wrote it",
          marks.allSatisfy { $0.hasPrefix("tally-jump-") })
    // The prefix is written once and read twice - by the name that carries it and by the scan that
    // has to recognise a mark it did not write. Spelled twice, the two would be free to drift, and
    // the drifted half would hand a mark back to a tab as though it were somebody's own title.
    check("…in the one spelling the scan filters on",
          TerminalJump.markPrefix == "tally-jump-"
              && marks.allSatisfy { $0.hasPrefix(TerminalJump.markPrefix) })

    // WHICH JUMPS MAY RENAME A TAB AT ALL, as a value: none of the three refusals can be reached
    // through `focusGhostty` without a Ghostty to talk to, and each of them ends in a tab left
    // called `tally-jump-…` for good.
    check("a session whose Ghostty publishes no device is found by writing to one",
          TerminalJump.shouldMark(device: "/dev/ttys001", tty: nil, inFlight: false))
    // 1.4.0 and later: the device pass is built, stands above the marked one and wins the script,
    // and only the MARKED answer carries the surface a title is put back on - so a mark written
    // here is one nothing names and nothing removes.
    check("a Ghostty that can simply be asked is asked rather than written to",
          !TerminalJump.shouldMark(device: "/dev/ttys001", tty: "/dev/ttys001", inFlight: false))
    check("a session with no device has nothing to mark and nothing to put back",
          !TerminalJump.shouldMark(device: nil, tty: nil, inFlight: false))
    // Two clicks on one card inside the grace: the second stands its own mark down and takes the
    // checkout pass rather than writing over a mark whose real title only the first jump holds.
    check("a device with a mark already out on it is left to the jump that wrote it",
          !TerminalJump.shouldMark(device: "/dev/ttys001", tty: nil, inFlight: true))
    // A mark goes into the script through `literal` and into the terminal inside an escape ended
    // by BEL, so a mark carrying either delimiter would close its own sequence.
    check("a mark carries nothing that could end a literal or an escape",
          marks.allSatisfy { mark in
              !mark.contains("\"") && !mark.contains("\\")
                  && mark.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
          })

    // The scan that precedes the write is what the old title is restored from, so it has to carry
    // the identity as well as the name.
    let scan = TerminalJump.surfaceScanScript()
    check("the scan reads every surface's identity and its title",
          scan.contains("repeat with t in terminals") && scan.contains("(id of t) as text")
              && scan.contains("(name of t)"))
    // NOT the word `tab`: inside `tell application "Ghostty"` that is the terminal's own term for a
    // tab and comes back as the LETTERS "tab", which would leave every line of the scan without a
    // separator - every surface dropped, and the pass standing itself down while looking exactly
    // like a Ghostty with nothing to report.
    check("…separated by a character the terminal cannot read as one of its own words",
          scan.contains("(character id 9)") && !scan.contains(" & tab & "))
    check("…and a dictionary that answers neither raises out of it",
          scan.components(separatedBy: "try").count - 1 >= 3)
    let surfaces = TerminalJump.parseSurfaces("12\tclaude · tally\n13\t~/code/tally\n14\t\n")
    check("the scan's answer is read as identity to title",
          surfaces["12"] == "claude · tally" && surfaces["13"] == "~/code/tally")
    check("…including a surface titled with nothing, which is still a title to put back",
          surfaces["14"] == "" && surfaces.count == 3)
    check("a line that names no surface is dropped rather than guessed at",
          TerminalJump.parseSurfaces("no tab on this line\n\tnameless\n").isEmpty)
    // And the table the RESTORE is made from is that scan minus every mark. A name beginning
    // `tally-jump-` was written by this app and is owed back to whoever wrote it: put back here, it
    // would become the tab's permanent name while the jump holding the real title fell through to
    // the checkout pass and restored nothing.
    let scanned = "12\tclaude · tally\n13\ttally-jump-ab12cd34\n14\t\n"
    check("a surface already carrying a mark is not a title anybody may be given back",
          TerminalJump.restorableTitles(scanned) == ["12": "claude · tally", "14": ""])
    // Which leaves an empty table when every surface is marked, and an empty table is exactly what
    // stands the next mark down - the same refusal a Ghostty that answered nothing gets.
    check("…so a scan that is nothing but marks answers nothing at all",
          TerminalJump.restorableTitles("13\ttally-jump-ab12cd34\n").isEmpty)

    // The pass itself, in the one place its precedence can be read: below the device, because that
    // one is answered by a property rather than by renaming somebody's tab, and above the checkout,
    // because it names one surface where the checkout names one repository.
    let marked = TerminalJump.script(directory: "/Users/u/code/tally", tty: "/dev/ttys001",
                                     nonce: "tally-jump-ab12cd34")
    guard let deviceAsk = marked.range(of: "(tty of t) is equal to"),
          let markAsk = marked.range(of: "(name of t) is equal to \"tally-jump-ab12cd34\""),
          let checkoutAsk = marked.range(of: "(working directory of t) is equal to")
    else {
        check("the script asks about the device, the mark and the checkout", false)
        return
    }
    // Short-circuited on the order, so a script with the passes the wrong way round reports the
    // line below rather than tearing the harness down on a backwards range.
    let markInOrder = deviceAsk.upperBound < markAsk.lowerBound
        && markAsk.upperBound < checkoutAsk.lowerBound
    check("the mark is asked about after the device and before the checkout", markInOrder)
    check("…standing down for a device match already found",
          markInOrder && String(marked[deviceAsk.upperBound ..< markAsk.lowerBound])
              .contains("if matched is missing value then"))
    check("…while the checkout stands down for the mark",
          markInOrder && String(marked[markAsk.upperBound ..< checkoutAsk.lowerBound])
              .contains("if matched is missing value then"))
    check("the marked pass marks itself", marked.contains("set hit to \"nonce\""))
    // The mark was WRITTEN to somebody's tab, so the surface it named has to travel out of the
    // script with the marker: a mark placed and never taken off is a tab left renamed.
    check("…and answers with the surface it found, which is what the title is put back on",
          marked.contains("set found to ((id of t) as text)")
              && marked.contains("return hit & linefeed & found"))
    check("the marked answer carries both the pass and the surface",
          TerminalJump.parseFocus("nonce\n42\n").match == .nonce
              && TerminalJump.parseFocus("nonce\n42\n").surface == "42")
    check("a vaguer pass answers with no surface, having renamed nothing",
          TerminalJump.parseFocus("dir\n\n").match == .directory
              && TerminalJump.parseFocus("dir\n\n").surface == nil)
    check("no match at all stays no match rather than becoming an empty surface",
          TerminalJump.parseFocus("").match == nil && TerminalJump.parseFocus("\n").match == nil
              && TerminalJump.parseFocus("").surface == nil)
    check("the marker round-trips into the type the caller switches on",
          TerminalJump.SurfaceMatch(rawValue: "nonce") == .nonce)
    // With no device to write to there is no mark, and the script is exactly what it was before
    // this pass existed. Not worse anywhere is the whole licence for adding it.
    check("a session with no device to mark is asked about its checkout alone",
          !script.contains("set hit to \"nonce\"") && !script.contains("(name of t) is equal to")
              && script.contains("set hit to \"dir\""))

    // The escape a terminal reads as a rename, and the one thing it must not let through.
    check("a title is written as OSC 2, ended by BEL",
          TerminalJump.titleEscape("tally") == "\u{1B}]2;tally\u{07}")
    // A title comes back off another app, so a BEL or an ESC inside one would end this escape early
    // and hand everything after it to the terminal as a command of its own.
    check("a title cannot end its own escape early",
          TerminalJump.titleEscape("a\u{07}b\u{1B}]0;rm\u{07}") == "\u{1B}]2;ab]0;rm\u{07}")
    let device = NSTemporaryDirectory() + "tally-jump-device-\(getpid())"
    FileManager.default.createFile(atPath: device, contents: nil)
    check("a title written to a device arrives as that escape",
          TerminalJump.write(title: "tally · cart", to: device)
              && (try? String(contentsOfFile: device, encoding: .utf8))
                  == "\u{1B}]2;tally · cart\u{07}")
    try? FileManager.default.removeItem(atPath: device)
    // A device that cannot be opened is an ordinary answer, not an error: the session's terminal
    // may have gone, or may belong to another user, and the pass below simply answers instead.
    check("a device that cannot be opened is a refusal rather than a crash",
          !TerminalJump.write(title: "x", to: device + "-gone"))

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
    // Ghostty is ASKED ABOUT a device only when it publishes one, so an old dictionary costs no
    // scan at all rather than a scan that raises on every surface.
    check("the device is asked about only for a Ghostty that publishes one",
          jumpSource.contains("readsSurfaceTTY(terminal)"))
    // …but the device itself is read whatever the version, because the pass that answers TODAY
    // writes to it rather than asking about it. ONLY FOR A SESSION GHOSTTY OWNS, though: the mark
    // renames whatever terminal holds that device, and the only titles this app can put back are
    // the ones it read off Ghostty a moment earlier.
    check("the device is read whatever the dictionary says",
          jumpSource.contains("return controllingTTY(of: pid_t(childPid))"))
    check("…but only for a session running in the terminal about to be marked",
          jumpSource.contains("owner.processIdentifier == ghostty.processIdentifier else { return nil }"))
    // One line per click has to tell "the wrong tab" from "the wrong repository", and those read
    // identically without the checkout. The LAST COMPONENT of it, because the path itself is the
    // one value this line has always refused to carry.
    check("the line says which checkout was aimed at, by its last component alone",
          jumpSource.contains("let folder = (directory as NSString).lastPathComponent")
              && jumpSource.contains("dir=\\(directory.isEmpty ? \"none\" : directory"))
    // …and WHICH SURFACE it reached, which is the field that tells two clicks apart. A pass name
    // says how a surface was found and nothing about which one it was, so two cards that both
    // answered `dir` read identically whether they reached two tabs or the same tab twice.
    check("…and which surface the pass actually landed on",
          jumpSource.contains("sid=\\(surface ?? \"none\""))
    // A JUMP THAT FOUND ITS SURFACE ASKS FOR NOTHING MORE FROM THIS SIDE. The script has already
    // activated the app and focused the one surface; an activation made here afterwards brings the
    // window GHOSTTY considers frontmost, which is the tab that was in front before the click - the
    // wrong tab arriving on top after the right one had been focused.
    check("an exit that focused a surface does not bring the app forward over it",
          jumpSource.contains("if matched == nil { bringForward(target) }"))
    // …and the ask that IS still made reorders nothing: `activateAllWindows` is documented to bring
    // ALL of an app's windows forward, which is a request to put every other tab over the one this
    // click picked out. Asserted as an absence, because it was there and read as harmless.
    check("no activation asks for every window the terminal has",
          !jumpSource.contains("activateAllWindows"))
    // Every exit is still JUDGED, including the two that no longer ask for anything: the script's
    // own `activate` is as declinable as this side's, and an outcome nobody read is the defect the
    // grace exists for.
    check("dropping the ask did not drop the looking",
          jumpSource.contains("try? await Task.sleep(for: activationGrace)")
              && jumpSource.contains("let (front, landed) = frontmost(is: target)"))

    // The order of the marked pass, which cannot be read off its result: the titles are read
    // BEFORE one of them is replaced, because that scan is the only record the old title survives
    // in, and the surface is asked for only after the mark has been written.
    let scriptSource = jumpCode(of: "Tally/Core/TerminalJumpScript.swift")
    guard let titlesRead = scriptSource.range(of: "restorableTitles(await osascript(surfaceScanScript())"),
          let markWritten = scriptSource.range(of: "write(title: candidate, to: marking)"),
          let surfaceAsked = scriptSource.range(of: "await osascript(script(directory: directory")
    else {
        check("the marked pass was found to read", false)
        return
    }
    // The name that used to break the checkout pass's tie is gone from the chain rather than merely
    // unused: a value still threaded from the card through the jump to the script is one an edit
    // can start consulting again without passing any assertion here.
    check("no tab's name is carried down the chain to break a tie with",
          !cardSource.contains("hint") && !jumpSource.contains("hint")
              && !scriptSource.contains("hint"))
    check("the titles are read before one of them is replaced",
          titlesRead.upperBound < markWritten.lowerBound)
    check("…and the surface is asked for only after the mark has been written",
          markWritten.upperBound < surfaceAsked.lowerBound)
    // NOTHING IS WRITTEN THAT CANNOT BE PUT BACK. A scan that answered nothing carries no title to
    // restore from, so the mark is never placed at all rather than being placed and abandoned.
    check("a scan that answered nothing stands the mark down",
          scriptSource.contains("if !titles.isEmpty, write(title: candidate, to: marking) {"))
    // The live path asks whether it may mark at all, rather than marking whenever a device exists:
    // the value assertions above are worth nothing if the flow never consults them.
    check("the jump asks whether it may mark before it writes",
          scriptSource.contains("shouldMark(device: device, tty: tty, inFlight: inFlight)"))
    // …and the table it restores from is the scan minus every mark, so no jump can hand another
    // jump's mark back to a tab as that tab's own title.
    check("…and restores only from titles that are not themselves marks",
          scriptSource.contains("titles = restorableTitles("))
    // The claim is what makes the second click stand down, and it is released on EVERY exit -
    // including the one that never got an answer out of osascript. Left behind, it would stand
    // every later jump to that device down for as long as the app ran.
    check("the device is claimed for as long as the mark is out, and released whatever happens",
          scriptSource.contains("markingDevices.insert(marking)")
              && scriptSource.contains("defer { if let marking { markingDevices.remove(marking) } }"))
    // The mark is given time to reach the dictionary before it is looked for; without the wait the
    // pass would report a miss for a rename that simply had not arrived yet.
    check("the mark is given time to arrive before it is looked for",
          scriptSource.contains("try? await Task.sleep(for: titleGrace)"))
    // And it is taken off the surface it named, using the title read before it went on. A pass
    // that did not answer left no mark here to remove.
    check("the title is put back on the surface the mark named",
          scriptSource.contains("if answer.match == .nonce, let marking, let id = answer.surface,")
              && scriptSource.contains("write(title: title, to: marking)"))
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
    // …AND NEVER OVER SOMEBODY WHO HAS MOVED ON. The retry runs a grace after the press, and
    // LaunchServices reaches activation by an authorisation the first ask does not have - so a
    // person who spent that grace switching to their browser would have the screen taken back for a
    // trip they had already abandoned. Asserted as a value, because the rule is over pids.
    let ours: pid_t = 501
    let ghostty: pid_t = 909
    check("a third-party app in front stops the second road",
          !TerminalJump.retryMayTakeForeground(front: 777, ours: ours, previous: 601,
                                               target: ghostty))
    check("…while this app still holding the foreground it took does not",
          TerminalJump.retryMayTakeForeground(front: ours, ours: ours, previous: 601,
                                              target: ghostty))
    check("…nor does whatever the click borrowed it from",
          TerminalJump.retryMayTakeForeground(front: 601, ours: ours, previous: 601,
                                              target: ghostty))
    check("…nor the terminal being aimed at",
          TerminalJump.retryMayTakeForeground(front: ghostty, ours: ours, previous: 601,
                                              target: ghostty))
    // A front nobody can read names no third party to interrupt, so it fails open: that is the
    // behaviour that stood before this guard, which is the safe direction for a wrong guess here.
    check("a foreground that cannot be read leaves the retry as it was",
          TerminalJump.retryMayTakeForeground(front: nil, ours: ours, previous: nil,
                                              target: ghostty))
    // A click that started from this app borrowed nothing, so there is no previous app to allow
    // back in - and `nil == nil` must not become a match that lets any unreadable front through.
    check("nothing was borrowed, so no third party inherits the permission",
          !TerminalJump.retryMayTakeForeground(front: 777, ours: ours, previous: nil,
                                               target: ghostty))
    // And the live path consults it: a value assertion cannot see whether `land` asks, and the
    // guard is worth nothing if it is only a function that exists.
    guard let retryAsk = jumpSource.range(of: "retryMayTakeForeground(front: settled.app?"),
          let secondRoad = jumpSource.range(of: "NSWorkspace.shared.openApplication(at: bundle,")
    else {
        check("the retry guard was found on the landing path", false)
        return
    }
    check("the second road is taken only after the guard has answered",
          retryAsk.upperBound < secondRoad.lowerBound)

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
