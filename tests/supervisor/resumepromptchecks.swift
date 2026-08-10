import Foundation

// The resume-prompt suppression (ResumePrompt.swift): nothing Tally spawns stops at Claude Code's
// "resume the whole conversation?" question. An automatic relaunch has nobody at the keyboard to
// answer it, and a first launch was asked for by somebody who typed the command.
//
// The whole rule is one pure function over the child's environment, which is why it can be tested
// without a supervisor: what a spawn does is merge its answer into the env it hands the child.

func runResumePromptChecks() {
    // MARK: - Every spawn suppresses it, the interactive one included

    // THE REVERSAL THIS ASSERTS (owner ruling, 2026-08-10). The first spawn used to keep the
    // prompt, on the reading that the person who typed `tally claude` is at the keyboard and the
    // choice is theirs. They are, and it is not one they want: typing the command IS the answer to
    // "resume this?", and being asked again is a keystroke between them and their conversation.
    let interactive = resumePromptSuppression([:])
    check("the user's own first spawn suppresses the prompt",
          interactive == [resumeTokenThresholdEnvKey: resumePromptDisabledThreshold])
    let relaunch = resumePromptSuppression(["PATH": "/usr/bin"])
    check("and so does a relaunch, which is what this started as",
          relaunch == [resumeTokenThresholdEnvKey: resumePromptDisabledThreshold])
    check("the threshold is past any real conversation",
          (Int(resumePromptDisabledThreshold) ?? 0) > 10_000_000)
    check("and is a plain integer a parser will take",
          resumePromptDisabledThreshold.allSatisfy { $0.isNumber })
    // Nothing else is touched: the sibling minutes threshold is left to Claude Code, since the two
    // conditions are ANDed and neutralising one is enough.
    check("nothing else is added", relaunch.count == 1)
    check("the minutes threshold is left alone",
          relaunch["CLAUDE_CODE_RESUME_THRESHOLD_MINUTES"] == nil)

    // MARK: - The user's own export wins

    // THE ONLY WAY BACK TO THE PROMPT, now that neither kind of spawn leaves it standing: whichever
    // direction the exported value points, they set it to change this exact behaviour. It is the
    // one condition in this rule that must not be lost.
    check("an exported value is not overwritten",
          resumePromptSuppression([resumeTokenThresholdEnvKey: "200000"]).isEmpty)
    check("an empty export counts as set",
          resumePromptSuppression([resumeTokenThresholdEnvKey: ""]).isEmpty)
    check("…and a low one, which is somebody asking to be asked",
          resumePromptSuppression([resumeTokenThresholdEnvKey: "5"]).isEmpty)

    // MARK: - Merged the way the spawn merges it

    // The supervisor's loop does `for (key, value) in ... { environment[key] = value }`, so an
    // answer adds one key and a second pass over the result adds nothing (the value it would write
    // is now the value the environment carries).
    var environment = ["TALLY_LAUNCHED": "1"]
    for (key, value) in resumePromptSuppression(environment) { environment[key] = value }
    check("a spawn's environment carries both",
          environment == ["TALLY_LAUNCHED": "1",
                          resumeTokenThresholdEnvKey: resumePromptDisabledThreshold])
    check("and merging it a second time changes nothing",
          resumePromptSuppression(environment).isEmpty)

    // MARK: - The launches with no supervisor in front of them

    // `tally claude --account X --continue`, `--no-handoff`, the bare fallbacks and every codex
    // launch replace this process with execvp instead of being spawned as a supervised child, so
    // they never reach the assembly above. Left out, "Tally never asks" would be true of
    // `tally claude` and false of `tally claude --account X --continue`, which is the shape a
    // person reads as a bug rather than as a policy (owner ruling, 2026-08-10).
    //
    // LOCKED BY SOURCE because the call never returns: `exec` ends in execvp, so no suite can run
    // it and read back the environment it left behind. What can be asserted is that it asks the
    // one rule, and asks it before the point of no return.
    let unsupervised = (try? String(contentsOfFile: "TallyCLI/Snapshot.swift", encoding: .utf8)) ?? ""
    check("the unsupervised launcher is readable from this suite", !unsupervised.isEmpty)
    check("…and it suppresses the prompt through the same function, not a second copy of the rule",
          unsupervised.contains(
              "for (key, value) in resumePromptSuppression(ProcessInfo.processInfo.environment)"))
    // …ASKED OF THE ENVIRONMENT EXECVP INHERITS, which is this process's own: the exported-value
    // escape hatch lives inside that rule, so handing it anything else would answer for the wrong
    // environment and overwrite what somebody set.
    check("…which is the environment the exec'd process actually inherits",
          unsupervised.contains("setenv(key, value, 1)"))
    func at(_ needle: String) -> Int? {
        unsupervised.range(of: needle).map {
            unsupervised.distance(from: unsupervised.startIndex, to: $0.lowerBound)
        }
    }
    // ORDER IS THE INVARIANT, not presence: nothing after execvp runs, so a suppression written
    // below it is a suppression that never happens.
    if let set = at("resumePromptSuppression(ProcessInfo"), let handover = at("execvp(") {
        check("…and it is set before the exec, past which nothing of ours runs", set < handover)
    } else {
        check("…and it is set before the exec, past which nothing of ours runs", false)
    }
}
