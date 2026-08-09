import Foundation

// WHICH BUILD MAY ANSWER THE MACHINE'S PICKS. Split from pickerchecks.swift for file size, the way
// pickgracechecks.swift already is.
//
// THE INCIDENT this closes (2026-08-09), because the shape of it is the point: the exclusivity that
// keeps two panels off the screen (`takePickClaim`, asserted in pickerchecks 36c4) is decided by the
// file system, and the file system has no opinion about which of the two copies deserves to win. A
// dev build left running overnight, built before the panel's self-cancelling defect was fixed, took
// every request the installed 0.42.0 was there to answer and cancelled it 147ms later. Winning was
// not an accident either: doing less before claiming is exactly what makes a stale build faster.
//
// So there are two rules about one claim now, and they answer different questions. HOW MANY may
// claim is exclusivity. WHO may claim is this file.
func runPickClaimChecks() {

    // MARK: - 36c5. A build nobody installed does not answer for the machine

    check("the app somebody installed claims, which is the whole point of the panel",
          pickMayBeClaimed(isUnshipped: false, overridden: false))
    check("a build nobody installed stands down instead",
          !pickMayBeClaimed(isUnshipped: true, overridden: false))
    // The escape hatch, for the one person the rule above costs anything: a developer driving the
    // picker end to end has to be able to claim, or the path can only ever be tested by shipping it.
    check("…until the launch asks for it back, which is what the override is for",
          pickMayBeClaimed(isUnshipped: true, overridden: true))
    check("and the override changes nothing for a build that was claiming anyway",
          pickMayBeClaimed(isUnshipped: false, overridden: true))

    // MARK: - 36c6. And the gate is asked BEFORE the claim, not beside it

    // The controller needs AppKit, so the wiring is carried by the source the way the follow dead
    // end and the self-update fold carry theirs. Run from the repo root (run-supervisor-tests.sh cds
    // there), and a missing file FAILS rather than quietly passing.
    let controller = (try? String(contentsOfFile: "Tally/MenuBar/PickPanelController.swift",
                                  encoding: .utf8)) ?? ""
    check("the panel controller is readable from this suite", !controller.isEmpty)
    check("the controller asks the stand-down question at all",
          controller.contains("guard pickMayBeClaimed(isUnshipped: BuildVariant.isUnshipped,"))
    check("…reading the override from the flag that is classified, not a second spelling of it",
          controller.contains("overridden: CaptureLaunch.carries(CaptureLaunch.pickClaimOverride))"))

    func at(_ needle: String) -> Int? {
        controller.range(of: needle).map {
            controller.distance(from: controller.startIndex, to: $0.lowerBound)
        }
    }
    // ORDER IS THE INVARIANT, not presence. A gate that runs after the claim has already been
    // written would leave the stale build holding the request it then declines to draw, which is the
    // incident with an extra step: the CLI waits out its deadline instead of falling back.
    if let gate = at("guard pickMayBeClaimed("), let claim = at("takePickClaim(id: request.id") {
        check("…and it is asked before the claim is taken", gate < claim)
    } else {
        check("…and it is asked before the claim is taken", false)
    }

    // The preview path is deliberately on the other side of this: it shows the panel directly and
    // writes no answer, so a build that may not answer a real request can still be looked at.
    check("the dev preview does not come through the gate at all",
          controller.contains("shared.show(request, prompted: false)"))
}
