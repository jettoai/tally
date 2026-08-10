import Foundation

// Why nothing Tally spawns stops at Claude Code's resume prompt.
//
// Claude Code asks before resuming a large conversation ("resume the whole thing, or start from a
// summary?"). Measured on 2.1.220, it asks when three conditions hold at once: the account is on a
// paid plan, the session has been idle past a threshold in minutes, and the transcript is past a
// threshold in tokens.
//
// A SUPERVISOR RELAUNCH CANNOT ANSWER IT, which is what this started as: nobody is looking, the
// child sits on a question forever, and what the user comes back to is a conversation that stopped
// rather than one that moved account. Every relaunch reason has that failure mode (cap handoff,
// rebalance, follow adoption, fallback profile, reload, and the respawn after a self-update),
// because every one of them resumes by id.
//
// AND THE FIRST SPAWN IS NOW SUPPRESSED TOO, which is a reversal worth recording rather than
// quietly overwriting. The first version deliberately left the prompt alone there, reasoning that
// `tally claude` was typed seconds ago with the user's hands on the keyboard, so the choice between
// resuming whole and starting from a summary was a real one and suppressing it would be Tally
// overriding a decision nobody asked it to make. Measured against the person it was reasoning
// about: the owner hit it live (2026-08-10) and asked for it gone. Typing the command IS the answer
// to "resume this?", and being asked it again is a keystroke between the user and the conversation
// they already named. So the rule no longer asks which spawn this is.
//
// The threshold is an environment variable, so the fix is to hand the child a number no
// conversation reaches. Undocumented, which is the one thing worth being explicit about: if a later
// Claude Code stops reading it, the variable is ignored and the prompt comes back, which is exactly
// the behaviour this replaced. A degradation, not a break, so this needs no version gate.

/// Claude Code's token ceiling for the resume prompt (default 100000). Its sibling
/// `CLAUDE_CODE_RESUME_THRESHOLD_MINUTES` (default 70) gates the same prompt on idle time;
/// deliberately left alone, because the two are ANDed and neutralising one is enough.
let resumeTokenThresholdEnvKey = "CLAUDE_CODE_RESUME_TOKEN_THRESHOLD"

/// A billion tokens: past every context window that exists, so the token condition never holds and
/// the resume runs straight through. Not `Int.max`, which a parser is entitled to reject.
let resumePromptDisabledThreshold = "1000000000"

/// The environment additions that keep a spawn from stopping at the resume prompt.
///
/// Every spawn, the user's own `tally claude` included (owner ruling, 2026-08-10: the header
/// carries what that reverses and why). What is left of the old split is the escape hatch below,
/// which is where somebody who wants the question back gets it.
///
/// A value the environment already carries is never overwritten, whichever direction it points: the
/// variable belongs to whoever exported it, and a user who set it to something did so to change
/// this exact behaviour. An empty export counts as set for the same reason. That is the only way
/// back to Claude Code's own prompt, so it is the one thing here that must not grow a condition.
func resumePromptSuppression(_ environment: [String: String]) -> [String: String] {
    guard environment[resumeTokenThresholdEnvKey] == nil else { return [:] }
    return [resumeTokenThresholdEnvKey: resumePromptDisabledThreshold]
}
