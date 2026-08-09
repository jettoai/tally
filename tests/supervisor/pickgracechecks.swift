import Foundation

// THE GRACE, AND EVERYTHING IT HAS BEEN WRONG ABOUT. Split from pickerchecks.swift for file size,
// the way switchrequestchecks.swift is split from switchchecks.swift.
//
// One judgement, four rounds, each failing in a direction the last one had just closed:
//
//   v1  every lost key window was a dismissal          -> every pick answered itself in 147ms
//   v2  the ones inside the grace were swallowed       -> a person who really left was never answered
//   v3  the expiry had three answers, two of which
//       stopped the clock without settling             -> claimed request stuck to the CLI's deadline
//   v4  the retry had no grace of its own              -> v1 reappeared on the retry path
//   v5  a background preview walked into the retry     -> an accessory app took the foreground 0.6s
//                                                         after a deliberately background launch
//
// So the rule is a state machine and this file asserts it exhaustively, which is the only form that
// could have caught any of the five: each was a combination nobody had written down.

func runPickGraceChecks() {
    let controller = (try? String(contentsOfFile: "Tally/MenuBar/PickPanelController.swift",
                                  encoding: .utf8)) ?? ""
    check("the panel controller is readable from the suite", !controller.isEmpty)

    // MARK: - 36e2. A panel losing key is not always a person putting it down

    // THE 0.41.0 INCIDENT, as an assertion. Every pick came back instantly with "nothing was
    // changed" and no panel was ever seen; the files say the app claimed in 11ms and wrote an EMPTY
    // answer 147ms later, with nobody having touched anything. Raising the panel asks an accessory
    // app for the foreground, the ask settles after the panel is made key, and AppKit takes the key
    // window back in between - which the delegate read as a dismissal and answered on the person's
    // behalf.
    let raised = Date(timeIntervalSince1970: 1_800_000_000)
    check("a key window lost while the foreground ask is still settling is NOT a dismissal",
          !pickDismissalIsFromPerson(shownAt: raised,
                                     now: raised.addingTimeInterval(0.147)))
    check("…nor is one lost in the same instant the panel went up",
          !pickDismissalIsFromPerson(shownAt: raised, now: raised))
    check("a panel that was never raised cannot have been dismissed",
          !pickDismissalIsFromPerson(shownAt: nil, now: raised.addingTimeInterval(60)))
    check("…while a person clicking away from a panel they have been looking at still is",
          pickDismissalIsFromPerson(shownAt: raised,
                                    now: raised.addingTimeInterval(pickPanelActivationGrace + 0.01)))
    check("…and so is one seconds later, which is what clicking away actually looks like",
          pickDismissalIsFromPerson(shownAt: raised, now: raised.addingTimeInterval(30)))
    // The controller asks that question rather than answering it inline, which is the half that
    // made the defect invisible: the judgement used to live only in a delegate callback.
    check("…and it decides a resign-key through the shared rule",
          controller.contains("pickDismissalIsFromPerson(shownAt: shownAt)"))
    // An empty answer is what the app wrote in the incident, and it has to keep reading as a
    // cancellation rather than as a row nobody named.
    check("an empty answer object is a cancellation",
          decodePick(PickAnswer.self, from: Data("{}".utf8))?.isCancelled == true)

    // MARK: - 36e2b. The other half of the grace: what its expiry means

    // THE DEFECT THE FIRST FIX INTRODUCED. Swallowing a resign inside the grace stopped the panel
    // answering itself in 147ms, and opened the opposite hole: a person who clicks away DURING the
    // grace has their resign dropped, and AppKit sends no second one because the window is already
    // not key. Nothing was watching, so the panel sat there and the CLI waited out its five-minute
    // deadline. So the expiry is an event of its own, and it has three answers.
    // EXHAUSTIVE, because this judgement has now been wrong in three different rounds and each time
    // the wrong answer lived in a combination nobody had written down: v1 answered every lost key
    // window, v2 answered none of the ones inside the grace, v3 STOPPED THE CLOCK on two states that
    // had not settled. Sixteen rows, written out rather than computed - an expectation derived from
    // the same rule it is checking would agree with any bug the rule has.
    let table: [(sawResign: Bool, isKey: Bool, active: Bool, retried: Bool,
                 expected: PickGraceVerdict, why: String)] = [
        // The panel holds the key window: the ordinary resign path takes over, whatever else is true.
        (false, true, false, false, .settled, "key, nothing seen"),
        (true, true, false, false, .settled, "key again after a resign: the ask had simply settled"),
        (false, true, true, false, .settled, "key and ours"),
        (true, true, true, false, .settled, "key and ours after a resign"),
        (false, true, false, true, .settled, "key after a retry"),
        (true, true, false, true, .settled, "key after a retry that saw a resign"),
        (false, true, true, true, .settled, "key and ours after a retry"),
        (true, true, true, true, .settled, "key and ours, retried, resign seen"),
        // Our own foreground with another of our windows on top: nobody left the app, and the panel
        // is still reachable by hand. Watch, do not answer and do not give up.
        (false, false, true, false, .keepWatching, "ours, not key"),
        (true, false, true, false, .keepWatching, "ours, not key, resign seen"),
        (false, false, true, true, .keepWatching, "ours, not key, after a retry"),
        (true, false, true, true, .keepWatching, "ours, not key, retried, resign seen"),
        // Not key and not ours: ask once more before believing it, because an ask that never landed
        // is indistinguishable from somebody walking away until the second ask separates them.
        (false, false, false, false, .retryActivation, "gone, never resigned, first doubt"),
        (true, false, false, false, .retryActivation, "gone after a resign, first doubt"),
        // Asked twice and still out of reach. A resign says it was in their hands; none says it was
        // never reachable at all.
        (true, false, false, true, .dismissed, "retried, they had it and left"),
        (false, false, false, true, .abandoned, "retried, never reachable"),
    ]
    check("the grace machine has an answer for all sixteen states", table.count == 16)
    for row in table {
        check("grace: \(row.why)",
              pickGraceVerdict(sawResign: row.sawResign, isKey: row.isKey, appIsActive: row.active,
                               alreadyRetried: row.retried) == row.expected)
    }
    // AND THE OTHER SIXTEEN, which all collapse to one answer - that collapse IS the claim. A panel
    // raised by a launch flag for a look has no waiting CLI behind it and was launched deliberately
    // into the background, so nothing about its key window or the foreground can make it worth
    // taking the screen: without this it walked into `.retryActivation` and an accessory app stole
    // the foreground 0.6s after a background launch, handing nothing back afterwards.
    var previewStates = 0
    for sawResign in [false, true] {
        for isKey in [false, true] {
            for active in [false, true] {
                for retried in [false, true] {
                    previewStates += 1
                    check("preview never takes the foreground: resign=\(sawResign) key=\(isKey) "
                          + "active=\(active) retried=\(retried)",
                          pickGraceVerdict(prompted: false, sawResign: sawResign, isKey: isKey,
                                           appIsActive: active, alreadyRetried: retried)
                              == .settled)
                }
            }
        }
    }
    check("…over all sixteen of them", previewStates == 16)
    check("a prompted panel in the very same state still asks for the foreground, which is what "
          + "makes that a property of being ASKED FOR rather than of the state",
          pickGraceVerdict(prompted: true, sawResign: false, isKey: false, appIsActive: false,
                           alreadyRetried: false) == .retryActivation)
    check("and the controller judges with the flag it was shown under",
          controller.contains("pickGraceVerdict(prompted: prompted,"))
    // THE INVARIANT ALL THREE ROUNDS BROKE, asserted directly rather than left implicit in the rows:
    // the only reading that stops the clock is the one where the panel really is in the person's
    // hands. Everything else either watches again, asks again, or answers.
    // ASKED OF THE RULE, not of the table above: an invariant checked against my own hand-written
    // expectations only proves I wrote them consistently, which is not what is in danger here.
    func verdict(_ row: (sawResign: Bool, isKey: Bool, active: Bool, retried: Bool,
                         expected: PickGraceVerdict, why: String)) -> PickGraceVerdict {
        pickGraceVerdict(sawResign: row.sawResign, isKey: row.isKey, appIsActive: row.active,
                         alreadyRetried: row.retried)
    }
    check("nothing stops watching a panel that is not key",
          table.allSatisfy { verdict($0) != .settled || $0.isKey })
    // And it terminates: out of reach twice over is always an answer, never another lap.
    check("a panel that is unreachable after a retry is always answered",
          table.filter { !$0.isKey && !$0.active && $0.retried }
              .allSatisfy { [.dismissed, .abandoned].contains(verdict($0)) })
    check("…including the one nobody ever touched, which is cancelled rather than left as a zombie",
          pickGraceVerdict(sawResign: false, isKey: false, appIsActive: false, alreadyRetried: true)
              == .abandoned)
    check("a click away inside the grace is still answered from the expiry, not the CLI deadline",
          pickGraceVerdict(sawResign: true, isKey: false, appIsActive: false, alreadyRetried: false)
              != .settled)

    // The controller has to run that machine, and the retry needs a grace of its own: the second
    // `NSApp.activate` resigns asynchronously exactly as the first did, so judging it against the
    // ORIGINAL start put the very first defect back on the retry path.
    let retryBody = controller.range(of: "case .retryActivation:").flatMap { start in
        controller.range(of: "case .dismissed").map { end in
            String(controller[start.lowerBound ..< end.lowerBound])
        }
    } ?? ""
    check("the retry branch is readable", !retryBody.isEmpty)
    check("…and it restarts the grace it will be judged against",
          retryBody.contains("shownAt = Date()"))
    check("…and starts a fresh observation window with it",
          retryBody.contains("sawResignInGrace = false"))
    check("…and arms the next judgement", retryBody.contains("armGrace()"))
    let watchBody = controller.range(of: "case .keepWatching:").flatMap { start in
        controller.range(of: "case .retryActivation:").map { end in
            String(controller[start.lowerBound ..< end.lowerBound])
        }
    } ?? ""
    check("a panel that is merely being watched keeps its clock", watchBody.contains("armGrace()"))
    check("…and both terminal readings answer the pick",
          controller.contains("case .dismissed, .abandoned:"))
}
