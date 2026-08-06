import Foundation

// The names the two launch axes take, in the one place both targets read them from.
//
// The axes are not symmetric, and the asymmetry is the reason this file exists rather than a
// picker holding its own list:
//
//   EFFORT is a closed enumeration. The installed claude CLI publishes it in its own `--help`, so
//   the app parses that at runtime (EffortLevels.swift) and what is here is the fallback for when
//   the parse fails. It is also what the CLI VALIDATES against, because a `--effort` value the
//   child does not recognise is a child that will not start at all.
//   MODEL is open. Anything the provider accepts is legal (`gpt-5.6-sol`, a dated snapshot id, a
//   Bedrock arn), so the aliases below are a picker's suggestions and never a gate.
//
// One copy compiled into both targets (project.yml), for the reason every other shared file in that
// list gives: a second hand-written list is a list that drifts, and the two halves would then
// disagree about which values are safe to write into a launch.

/// The `--effort` levels this repo knows without asking the installed CLI. Claude Code documents
/// them in `--help` as "(low, medium, high, xhigh, max)".
let claudeEffortFallbackLevels = ["low", "medium", "high", "xhigh", "max"]

/// Accepted by the claude CLI's `--effort` parser but absent from its help enumeration:
/// "ultracode" (xhigh plus the CLI's session-scoped multi-agent orchestration mode; alias map and
/// activation path verified in binary 2.1.214). Appended to whatever the help text yields, so a
/// level list parsed at runtime still accepts it.
let claudeUndocumentedEffortAliases = ["ultracode"]

/// A level list with the undocumented aliases appended, in order and without duplicates. The one
/// answer to "what may be typed after `--effort`", whether the levels came from the live `--help`
/// or from the fallback above.
func claudeEffortNames(_ levels: [String] = claudeEffortFallbackLevels) -> [String] {
    levels + claudeUndocumentedEffortAliases.filter { !levels.contains($0) }
}

/// Whether a value names an effort level this repo will write into a launch.
///
/// Case-insensitive, because everything downstream lowercases the axis anyway (`FollowState`,
/// `followAlreadySatisfied`), and a refusal over capitalisation would be a refusal nobody could
/// read. A gate on THIS axis only: see the header for why the model axis has none.
///
/// `levels` is injected for the one caller that has a list of its own to judge against
/// (`modelIntentProblem`, which names the levels back in its refusal and so must test the list it
/// prints). Asked here rather than open-coded there, so the case-insensitivity above is one rule
/// wherever the gate is applied.
func isClaudeEffortName(_ value: String, in levels: [String] = claudeEffortNames()) -> Bool {
    levels.contains(value.lowercased())
}

/// Claude Code documents these aliases in its own `--help` ("an alias for the latest model");
/// aliases track the latest model of each tier, so the list stays valid across releases.
let claudeModelAliases = ["fable", "opus", "sonnet", "haiku"]
