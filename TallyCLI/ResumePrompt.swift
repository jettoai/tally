import Foundation

// Why a supervisor relaunch must not stop at Claude Code's resume prompt.
//
// Claude Code asks before resuming a large conversation ("resume the whole thing, or start from a
// summary?"). Measured on 2.1.220, it asks when three conditions hold at once: the account is on a
// paid plan, the session has been idle past a threshold in minutes, and the transcript is past a
// threshold in tokens. A human who just typed `tally claude --continue` can answer it. A relaunch
// the supervisor performs on its own cannot: nobody is looking, the child sits on a question
// forever, and what the user comes back to is a conversation that stopped rather than one that
// moved account. Every relaunch reason has this failure mode (cap handoff, rebalance, follow
// adoption, fallback profile, reload, and the respawn after a self-update), because every one of
// them resumes by id.
//
// The threshold is an environment variable, so the fix is to hand the child a number no
// conversation reaches. Undocumented, which is the one thing worth being explicit about: if a later
// Claude Code stops reading it, the variable is ignored and the prompt comes back, which is exactly
// today's behaviour. A degradation, not a break, so this needs no version gate.

/// Claude Code's token ceiling for the resume prompt (default 100000). Its sibling
/// `CLAUDE_CODE_RESUME_THRESHOLD_MINUTES` (default 70) gates the same prompt on idle time;
/// deliberately left alone, because the two are ANDed and neutralising one is enough.
let resumeTokenThresholdEnvKey = "CLAUDE_CODE_RESUME_TOKEN_THRESHOLD"

/// A billion tokens: past every context window that exists, so the token condition never holds and
/// the resume runs straight through. Not `Int.max`, which a parser is entitled to reject.
let resumePromptDisabledThreshold = "1000000000"

/// The environment additions that keep an automatic relaunch from stopping at the resume prompt.
///
/// Empty on a FIRST spawn: that one is the user's own `tally claude`, typed seconds ago with their
/// hands on the keyboard, and the prompt there is a real choice (resume it whole, or start from a
/// summary and pay for less). Suppressing it would be Tally overriding a decision nobody asked it
/// to make. A relaunch is the opposite case: it is Tally's own act, on a conversation the user
/// already chose to keep, and the only thing a prompt can do there is strand it.
///
/// A value the environment already carries is never overwritten, whichever direction it points: the
/// variable belongs to whoever exported it, and a user who set it to something did so to change
/// this exact behaviour. An empty export counts as set for the same reason.
func resumePromptSuppression(_ environment: [String: String], relaunch: Bool) -> [String: String] {
    guard relaunch, environment[resumeTokenThresholdEnvKey] == nil else { return [:] }
    return [resumeTokenThresholdEnvKey: resumePromptDisabledThreshold]
}
