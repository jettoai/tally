import Foundation

// Follow adoption: deciding whether a launch-default change is a real change for THIS session.
//
// Regression for the 2026-07-27 false positive. The loop's baseline (`followedModel`/
// `followedEffort`) records what FOLLOW set, and the fallback profile and the safeguard restore
// rewrite the launch args without touching it on purpose, so their own change never reads as a
// Settings change. Once the user then set Settings to the pair one of those rewrites had already
// put on the command line, follow compared against the stale baseline, announced "adopting when
// this session goes idle", and spent a relaunch that changed nothing.

func runFollowChecks() {
    // 1. The plain already-satisfied case: the args carry exactly what the policy now asks for.
    check("args already carrying the desired pair need no adoption",
          followAlreadySatisfied(desiredModel: "opus", desiredEffort: "xhigh",
                                 launchArgs: ["--resume", "abc", "--model", "opus",
                                              "--effort", "xhigh"]))

    // 2. Alias equivalence, the reason the comparison cannot be string equality: Settings holds the
    //    alias the user typed, while a safeguard restore writes the full id from the transcript.
    check("an alias in Settings matches the full id on the command line",
          followAlreadySatisfied(desiredModel: "opus", desiredEffort: "high",
                                 launchArgs: ["--model", "claude-opus-4-8", "--effort", "high"]))
    check("and a different family is still a real change",
          !followAlreadySatisfied(desiredModel: "fable", desiredEffort: "high",
                                  launchArgs: ["--model", "claude-opus-4-8", "--effort", "high"]))

    // 3. One notch of depth apart is a genuine change - the whole point of following effort.
    check("a different effort is a real change",
          !followAlreadySatisfied(desiredModel: "opus", desiredEffort: "xhigh",
                                  launchArgs: ["--model", "opus", "--effort", "high"]))

    // 4. Clearing effort in Settings against args that carry it: adopting REMOVES the flag, so this
    //    is a change even though the model side agrees.
    check("no declared effort against args carrying one is a real change",
          !followAlreadySatisfied(desiredModel: "opus", desiredEffort: nil,
                                  launchArgs: ["--model", "opus", "--effort", "high"]))
    check("and the mirror image is too - adopting would ADD the flag",
          !followAlreadySatisfied(desiredModel: "opus", desiredEffort: "high",
                                  launchArgs: ["--model", "opus"]))

    // 5. Neither side declaring anything is agreement, not a change; one side alone is a change.
    check("neither side declaring a model or an effort is satisfied",
          followAlreadySatisfied(desiredModel: nil, desiredEffort: nil, launchArgs: ["--continue"]))
    check("no declared model against args carrying one is a real change",
          !followAlreadySatisfied(desiredModel: nil, desiredEffort: nil,
                                  launchArgs: ["--model", "opus"]))
    check("a declared model against args carrying none is a real change",
          !followAlreadySatisfied(desiredModel: "opus", desiredEffort: nil,
                                  launchArgs: ["--continue"]))
    check("an empty model string is not treated as a declaration that matches",
          !followAlreadySatisfied(desiredModel: "", desiredEffort: nil,
                                  launchArgs: ["--model", "opus"]))

    // 6. Round trip: the same args that make one pair satisfied must still let the NEXT genuine
    //    Settings change through. Silencing the false positive must not silence following itself.
    let settled = ["--resume", "abc", "--model", "opus", "--effort", "xhigh"]
    check("the pair the session runs is satisfied",
          followAlreadySatisfied(desiredModel: "opus", desiredEffort: "xhigh", launchArgs: settled))
    check("and a later real change against the same args is not",
          !followAlreadySatisfied(desiredModel: "opus", desiredEffort: "high", launchArgs: settled))

    // The round trip is only real if the satisfied branch also re-points the baseline: leaving it
    // stale would silence this Settings change and every later one against the same pair. The
    // branch cannot be reached without spawning a child, so the source carries the invariant (the
    // same approach as the follow dead-end check in reloadchecks.swift).
    let source = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    if let start = source.range(of: "followAdoption: if follow {"),
       let end = source.range(of: "// The session's ACTUAL model degraded",
                              range: start.upperBound ..< source.endIndex) {
        let block = String(source[start.upperBound ..< end.lowerBound])
        check("the follow block consults the args, not just its own baseline",
              block.contains("followAlreadySatisfied("))
        var baselineComesFirst = false
        if let rebaseline = block.range(of: "(followedModel, followedEffort) = desired"),
           let firstQueue = block.range(of: "else if pendingSince == nil") {
            baselineComesFirst = rebaseline.lowerBound < firstQueue.lowerBound
        }
        check("and the satisfied branch re-points the baseline before the queueing path",
              baselineComesFirst)
    } else {
        check("the follow block boundaries were found for the baseline check", false)
    }
}
