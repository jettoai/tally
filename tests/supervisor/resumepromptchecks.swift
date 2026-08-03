import Foundation

// The resume-prompt suppression (ResumePrompt.swift): an automatic relaunch has nobody at the
// keyboard, so it must never stop at Claude Code's "resume the whole conversation?" question.
//
// The whole rule is one pure function over the child's environment, which is why it can be tested
// without a supervisor: what a spawn does is merge its answer into the env it hands the child.

func runResumePromptChecks() {
    // MARK: - The first spawn keeps the prompt

    // That one is the user's own `tally claude`, typed seconds ago: choosing between resuming the
    // whole conversation and starting from a summary is theirs to make, and it costs them nothing
    // because they are looking at the terminal.
    check("a first spawn adds nothing",
          resumePromptSuppression([:], relaunch: false).isEmpty)
    check("and adds nothing even with an inherited value",
          resumePromptSuppression([resumeTokenThresholdEnvKey: "5"], relaunch: false).isEmpty)

    // MARK: - Every relaunch suppresses it

    let relaunch = resumePromptSuppression(["PATH": "/usr/bin"], relaunch: true)
    check("a relaunch sets the token threshold",
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

    // Whichever direction it points: they set it to change this exact behaviour.
    check("an exported value is not overwritten",
          resumePromptSuppression([resumeTokenThresholdEnvKey: "200000"], relaunch: true).isEmpty)
    check("an empty export counts as set",
          resumePromptSuppression([resumeTokenThresholdEnvKey: ""], relaunch: true).isEmpty)

    // MARK: - Merged the way the spawn merges it

    // The supervisor's loop does `for (key, value) in ... { environment[key] = value }`, so an
    // empty answer leaves the environment exactly as it was and a non-empty one adds one key.
    var environment = ["TALLY_LAUNCHED": "1"]
    for (key, value) in resumePromptSuppression(environment, relaunch: false) {
        environment[key] = value
    }
    check("a first spawn's environment is untouched", environment == ["TALLY_LAUNCHED": "1"])
    for (key, value) in resumePromptSuppression(environment, relaunch: true) {
        environment[key] = value
    }
    check("a relaunch's environment carries both",
          environment == ["TALLY_LAUNCHED": "1",
                          resumeTokenThresholdEnvKey: resumePromptDisabledThreshold])
}
