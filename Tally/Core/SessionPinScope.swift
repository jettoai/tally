import Foundation

// WHICH SCOPE PINNED THE ACCOUNT A SESSION IS RUNNING ON, in one vocabulary for every surface that
// shows it.
//
// THE PROBLEM IT EXISTS FOR (owner report, 2026-09-01). A pin is invisible. Nothing on the status
// line, and nothing on the session board, said that a session was pinned at all, so a session
// sitting somewhere unexpected - or refusing to be rebalanced off a dying account - looked like
// Tally misbehaving rather than like an instruction being obeyed. The same afternoon produced the
// account ping-pong (SessionSwitch.swift), and the reason it took a log dig to explain is exactly
// this: the pin was the one fact nobody could see.
//
// A SCOPE RATHER THAN A BOOLEAN, because the three answers send a reader to three different places
// to undo it: `tally account --auto` for this conversation, `tally project set --account auto` for
// this repo, and the app's own Accounts pane for the fleet. A mark that only said "pinned" would
// leave the next question unanswered on every surface that drew it.
//
// COMPILED BY BOTH TARGETS (project.yml lists it under TallyCLI as well), which is the point: the
// supervisor decides the scope and publishes it, the status line renders it, and the app's board
// draws it. A second spelling of the precedence below is how two of those three would come to
// disagree about a session neither of them can re-derive.

/// Which scope pinned the account a session runs on. Its `rawValue` is the wire word: it is what the
/// supervisor writes into the session sidecar (`SupervisedSession.pinScope`) and what every reader
/// decodes, so it is a contract rather than a label.
enum SessionPinScope: String, Equatable, Codable, CaseIterable {
    /// `tally account <name>`, which pins THIS conversation and dies with it.
    case session
    /// `tally project set --account`, which pins every session started in this repo.
    case project
    /// The app's own pin, which pins the whole fleet.
    case fleet
}

/// The scope pinning this session, innermost first, or nil when nothing is - which is the ordinary
/// case and the one that draws no mark at all (a smart pick is Tally choosing, and there is nothing
/// to explain about it).
///
/// THE SAME ORDER THE TICK ITSELF FOLDS, and it has to be: the policy every mover is judged by is
/// `sessionPolicy(effectivePolicy(app, project:), sessionPin:)`, so a session pin lies over the
/// project's account and the project's over the fleet's. Deriving the word from the FOLDED policy
/// instead is what cannot be done - by the time the three are one document, `mode == "manual"` no
/// longer says which of them said so, which is the same reason `pinYieldsToSpentAccount` is asked
/// the app's own mode rather than the folded one (DroughtWatch.swift).
///
/// `appMode` and `appPinnedAccountID` are the APP's own document, never an overlaid reading. Taken
/// as two values rather than as a `LaunchPolicy`, which is a type only the CLI target compiles: this
/// file is shared with the app (project.yml), and the vocabulary is worth more shared than the one
/// argument is worth typed.
func sessionPinScope(appMode: String, appPinnedAccountID: String?, projectAccountID: String?,
                     sessionPin: String?) -> SessionPinScope? {
    if sessionPin != nil { return .session }
    if projectAccountID != nil { return .project }
    return appMode == "manual" && appPinnedAccountID != nil ? .fleet : nil
}

/// The mark that leads every rendering of a pin, on every surface. One glyph rather than one per
/// surface, so a reader who has seen it in the terminal recognises it on the board.
///
/// MONOCHROME, AND IN THE CIRCLE FAMILY THIS APP ALREADY PINS WITH. A colour emoji was the first
/// spelling and it was wrong twice over: the status line prints this inside an ANSI dim segment
/// (`Statusline.swift`), and dim does nothing to a colour emoji, so the least important thing on
/// the line rendered as the brightest thing on it, at double width, in a row already fighting for
/// columns. And the app had a pinning vocabulary of its own before this existed: the panel's own
/// onboarding says `The ◯ on a card pins that account` (`PopoverLaunchViews.swift`), so a second
/// symbol for the same idea taught the reader two.
let sessionPinMark = "◉"

/// What the STATUS LINE calls each scope. English, like everything else that line prints (it runs
/// inside Claude Code's own hook and has no catalogue behind it); the app localizes its own copy.
///
/// One word, because the line it joins is already four segments long and the reader's question at
/// that moment is "who decided this", not "how do I undo it" - that answer lives where there is room
/// for it (the board's hover, `tally account`'s own output).
func sessionPinScopeWord(_ scope: SessionPinScope) -> String {
    switch scope {
    case .session: return "session"
    case .project: return "project"
    case .fleet: return "fleet"
    }
}

/// WHAT PUT THIS SESSION ON THIS ACCOUNT, as a sentence. The English text is also the catalogue key
/// the app looks it up under (`L`), which is how one vocabulary serves both surfaces: the terminal
/// prints these words as they stand and the app draws the reader's own language.
func sessionPinOwnerKey(_ scope: SessionPinScope) -> String {
    switch scope {
    case .session: return "Pinned to this account for this session"
    case .project: return "Pinned to this account by this project's profile"
    case .fleet: return "Pinned to this account by the app"
    }
}

/// AND THE WAY OUT, which is the half a mark alone cannot carry and the reason the scope is a word
/// rather than a dot: the three are undone in three different places.
func sessionPinReleaseKey(_ scope: SessionPinScope) -> String {
    switch scope {
    case .session: return "Run `tally account --auto` in it to follow automatic selection again."
    case .project: return "Run `tally project set --account auto` in it to follow again."
    case .fleet: return "Unpin in Settings, Accounts, to follow automatic selection again."
    }
}

/// The status line's whole rendering: the account's name with the pin that holds it there, or the
/// name alone. Kept beside the vocabulary rather than inside Statusline.swift so the assertion about
/// what a pinned line reads like does not have to reach into that file's rendering.
func sessionPinnedLabel(_ label: String, scope: SessionPinScope?) -> String {
    guard let scope else { return label }
    return "\(label) \(sessionPinMark)\(sessionPinScopeWord(scope))"
}
