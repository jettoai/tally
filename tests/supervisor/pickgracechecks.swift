import Foundation

// THE PANEL STANDS UNTIL SOMEBODY CLOSES IT, and the little that is left of the focus machine that
// used to close it for them. Split from pickerchecks.swift for file size, the way
// switchrequestchecks.swift is split from switchchecks.swift.
//
// One judgement, five rounds, each failing in a direction the last one had just closed:
//
//   v1  every lost key window was a dismissal          -> every pick answered itself in 147ms
//   v2  the ones inside the grace were swallowed       -> a person who really left was never answered
//   v3  the expiry had three answers, two of which
//       stopped the clock without settling             -> claimed request stuck to the CLI's deadline
//   v4  the retry had no grace of its own              -> v1 reappeared on the retry path
//   v5  a background preview walked into the retry     -> an accessory app took the foreground 0.6s
//                                                        after a deliberately background launch
//
// v6 STOPPED ASKING THE QUESTION. All five rounds were attempts to tell "the person walked away"
// from "the foreground ask never landed", and from inside the app those are the same observation:
// not key, not active. So a lost key window answers nothing at all now - the panel keeps standing,
// which is what Albert wanted from it in the first place (switching away to look something up used
// to cancel the pick and cost him the command again), and a panel nobody comes back to is ended by
// a deadline that reads no intent (`pickPanelDeadline`).
//
// So this file asserts two things: that the rule which remains is small and exhaustively known, and
// that no path back to answering-on-a-lost-focus survives anywhere in the controller.

func runPickGraceChecks() {
    let controller = (try? String(contentsOfFile: "Tally/MenuBar/PickPanelController.swift",
                                  encoding: .utf8)) ?? ""
    check("the panel controller is readable from the suite", !controller.isEmpty)
    let contract = (try? String(contentsOfFile: "Tally/Core/PickContract.swift",
                                encoding: .utf8)) ?? ""
    check("the pick contract is readable from the suite", !contract.isEmpty)

    // MARK: - 36e2. Losing the keyboard is not an answer

    // THE 0.41.0 INCIDENT, and the shape of every round that followed it. Every pick came back
    // instantly with "nothing was changed" and no panel was ever seen; the files say the app claimed
    // in 11ms and wrote an EMPTY answer 147ms later, with nobody having touched anything. Raising
    // the panel asks an accessory app for the foreground, the ask settles after the panel is made
    // key, and AppKit takes the key window back in between - which the delegate read as a dismissal.
    //
    // The delegate is what is gone. Asserted as the ABSENCE of the callback rather than as a
    // property of what it would have decided, because there is nothing left to decide: a controller
    // that is not a window delegate cannot be told the window lost key.
    check("the panel no longer hears about a lost key window at all",
          !controller.contains("windowDidResignKey"))
    check("…which is a fact about the type rather than about one method it happens not to have",
          !controller.contains("NSWindowDelegate") && !controller.contains("panel.delegate"))
    check("…and the rule that used to judge one is gone from the contract with it",
          !contract.contains("pickDismissalIsFromPerson") && !contract.contains("sawResign")
              && !contract.contains("case dismissed") && !contract.contains("case abandoned"))
    // An empty answer is what the app wrote in the incident, and it has to keep reading as a
    // cancellation rather than as a row nobody named: Escape, the ✕ and the deadline all write one.
    check("an empty answer object is a cancellation",
          decodePick(PickAnswer.self, from: Data("{}".utf8))?.isCancelled == true)
    // AND THE PANEL HAS TO SURVIVE THE THING THAT USED TO KILL IT. Not answering on deactivation is
    // only half of standing through it: a window that hides when its app resigns is off the screen
    // whether or not anybody answered for it, and a normal level is buried by whatever they
    // switched to.
    check("the panel stays on screen when the person switches away",
          controller.contains("panel.hidesOnDeactivate = false")
              && controller.contains("panel.level = .floating"))
    // …and is reachable when they come back, which takes both halves of the first-click fix: an
    // inactive app's window otherwise spends the first click on activation, and SwiftUI only tracks
    // a gesture in the KEY window.
    check("…and the click that brings them back is a click on a row, not a click to wake it",
          controller.contains("override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }")
              && controller.contains("if let window, !window.isKeyWindow { window.makeKey() }"))

    // MARK: - 36e2b. What is left of the grace: one ask for the foreground

    // EXHAUSTIVE, which four rounds of defects is the argument for: every one of them lived in a
    // combination nobody had written down. Four states now rather than thirty-two, because the
    // inputs that mattered only to cancellation went with it.
    let table: [(prompted: Bool, isKey: Bool, expected: Bool, why: String)] = [
        // Somebody is waiting on this panel and it does not have the keyboard: the ask either never
        // landed or was taken back while it settled, and one more is what separates them.
        (true, false, true, "asked for, and the keyboard is not here yet"),
        // It has the keyboard. There is nothing to ask for and nothing left to watch.
        (true, true, false, "asked for, and holding the keyboard"),
        // NOBODY ASKED FOR THIS ONE: a panel a launch flag raised to be looked at has no waiting CLI
        // behind it and was launched deliberately into the background, so nothing about its key
        // window can make it worth taking the screen. Without this it walked into the retry and an
        // accessory app stole the foreground 0.6s after a background launch (v5).
        (false, false, false, "a preview, unfocused, must not take the screen"),
        (false, true, false, "a preview that happens to hold the keyboard asks for nothing either"),
    ]
    check("the rule has an answer for all four states", table.count == 4)
    for row in table {
        check("retry: \(row.why)",
              pickShouldRetryActivation(prompted: row.prompted, isKey: row.isKey) == row.expected)
    }
    // THE PROPERTY THE PREVIEW ROWS ARE FOR, asked of the rule rather than of the rows above: an
    // invariant checked against my own hand-written expectations only proves I wrote them
    // consistently, which is not what is in danger here.
    check("nothing that was not asked for ever asks for the foreground",
          [true, false].allSatisfy { !pickShouldRetryActivation(prompted: false, isKey: $0) })
    check("…and a prompted panel in the very same state does, which is what makes that a property "
          + "of being ASKED FOR rather than of the state",
          pickShouldRetryActivation(prompted: true, isKey: false))

    // The controller has to run that rule, with the flag the panel was shown under.
    check("the controller judges the grace with the shared rule, and with that flag",
          controller.contains("pickShouldRetryActivation(prompted: prompted, isKey: panel.isKeyWindow)"))
    // ONCE. There is no second expiry to answer, and that is carried by the schedule rather than by
    // a flag: the grace is armed where the panel goes up and nowhere else. A retry that re-armed
    // would be an accessory app taking the screen again from somebody who has visibly moved on.
    let judgeBody = controller.range(of: "private func judgeGrace()").flatMap { start in
        controller.range(of: "private func armGrace()").map { end in
            String(controller[start.lowerBound ..< end.lowerBound])
        }
    } ?? ""
    check("the retry branch is readable", !judgeBody.isEmpty)
    check("…and it asks for the foreground and the keyboard together",
          judgeBody.contains("NSApp.activate(ignoringOtherApps: true)")
              && judgeBody.contains("panel.makeKeyAndOrderFront(nil)"))
    check("…and arms nothing further, so the second ask cannot exist",
          !judgeBody.contains("armGrace()"))
    check("the grace is armed exactly where the panel is raised",
          controller.components(separatedBy: "armGrace()").count == 3)   // the call, and its own func

    // MARK: - 36e2c. The deadline that replaced the guessing

    // ONE NUMBER, TWO ENDS. The CLI stops waiting at `nativePickDeadlineSeconds` and the panel takes
    // itself off the screen just short of that, so the answer lands while the wait is still reading
    // it: the CLI discards the whole request the moment it gives up, and an answer written after
    // that is a file nobody reads, left in `~/.tally/pick` for good.
    check("the panel closes before the CLI stops waiting, not with it and never after",
          pickPanelDeadline < nativePickDeadlineSeconds)
    check("…by a margin that covers the skew rather than by a whole minute of the person's time",
          nativePickDeadlineSeconds - pickPanelDeadline > 1
              && nativePickDeadlineSeconds - pickPanelDeadline < 30)
    // …and it is one number rather than two that agree today: the wait's own file must not carry a
    // second copy for either end to tune on its own.
    let nativePick = (try? String(contentsOfFile: "TallyCLI/NativePick.swift", encoding: .utf8)) ?? ""
    check("the wait reads the deadline from the contract rather than declaring one of its own",
          !nativePick.isEmpty && !nativePick.contains("let nativePickDeadlineSeconds"))
    let serve = (try? String(contentsOfFile: "TallyCLI/MCPServe.swift", encoding: .utf8)) ?? ""
    check("…which is the one the wait actually gives up on",
          serve.contains("waited > nativePickDeadlineSeconds"))
    check("the panel arms it, and only for a panel somebody is waiting on",
          controller.contains("if prompted { armDeadline() }")
              && controller.contains("withTimeInterval: pickPanelDeadline"))
    // THE FOREGROUND IS NOT HANDED BACK ON THIS PATH, which is the one asymmetry the deadline has.
    // Every other way out is somebody acting on the panel, so putting them back in the terminal they
    // typed into finishes what they started. Five minutes of silence says they are somewhere else,
    // and activating a captured app would take the screen for a panel they had forgotten.
    let expireBody = controller.range(of: "private func expire()").flatMap { start in
        controller.range(of: "private func finish(").map { end in
            String(controller[start.lowerBound ..< end.lowerBound])
        }
    } ?? ""
    check("the deadline path is readable", !expireBody.isEmpty)
    check("…and it drops the borrowed foreground before answering, rather than activating into it",
          expireBody.contains("previousApp = nil") && expireBody.contains("finish(with: .cancelled)"))
    // Both clocks are stopped by an answer, and a panel that has been answered must not be able to
    // answer again five minutes later.
    let finishBody = controller.range(of: "private func finish(with answer: PickAnswer)").flatMap {
        start in
        controller.range(of: "// MARK: - Dev preview").map { end in
            String(controller[start.lowerBound ..< end.lowerBound])
        }
    } ?? ""
    check("the answered panel is readable", !finishBody.isEmpty)
    check("…and answering stops both clocks",
          finishBody.contains("graceTimer?.invalidate()")
              && finishBody.contains("deadlineTimer?.invalidate()"))
    check("…and is idempotent by construction, so a timer that already fired finds nothing to do",
          finishBody.contains("guard let request = current else { return }")
              && finishBody.contains("current = nil"))

    // MARK: - 36e2d. The ways out, and that one of them can be seen

    // A PANEL THAT NO LONGER CLOSES ITSELF HAS TO SHOW HOW IT IS CLOSED. Escape always worked and
    // still does, but nothing on screen said so and the only visible way out was choosing something
    // the person may not have wanted.
    let header = (try? String(contentsOfFile: "Tally/Views/PickPanelHeaderView.swift",
                              encoding: .utf8)) ?? ""
    check("the panel header is readable from this suite", !header.isEmpty)
    check("the header carries a way out that can be clicked",
          header.contains("Button(action: close)")
              && header.contains(#"Image(systemName: "xmark")"#))
    let view = (try? String(contentsOfFile: "Tally/Views/PickPanelView.swift", encoding: .utf8)) ?? ""
    check("…wired to the panel's own cancellation rather than to a second idea of closing",
          view.contains("PickPanelHeaderView(kind: request.kind) { choose(nil) }"))
    check("…which answers a hover before it is clicked, so it reads as a control",
          header.contains(".onHover { hovered = $0 }") && header.contains("hovered ?"))
    check("…is named for a screen reader, in the app's own language",
          header.contains(#".accessibilityLabel(L("Close"))"#))
    // …and is not swallowed by the identity beside it: the header combines its children into one
    // element for the wordmark's sake, and a button inside that group is a button a screen reader
    // cannot reach. TWO CLAIMS, and the second is the one a lone position check misses (a mutant
    // that wrapped the whole row in a SECOND combine passed it): there is exactly one combined
    // group in this header, and the way out stands after it rather than inside it.
    let combines = header.components(separatedBy: ".accessibilityElement(children: .combine)")
    check("the header combines the identity into one element, and only that",
          combines.count == 2)
    var wayOutIsItsOwnElement = false
    if let combined = header.range(of: ".accessibilityElement(children: .combine)"),
       let button = header.range(of: "closeButton") {
        wayOutIsItsOwnElement = button.lowerBound > combined.upperBound
    }
    check("…and the way out is its own element rather than part of the wordmark",
          wayOutIsItsOwnElement && combines.count == 2)
    check("Escape still closes the panel at the AppKit level as well as the SwiftUI one",
          controller.contains("override func cancelOperation(_ sender: Any?) { onCancel?() }")
              && controller.contains("panel.onCancel = { [weak self] in self?.finish(with: .cancelled) }"))
    check("…and choosing a row writes exactly what was submitted",
          controller.contains("finish(with: answer ?? .cancelled)"))
}
