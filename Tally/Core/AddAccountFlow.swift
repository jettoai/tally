import Foundation

// Where Settings' "Add account" is, and what the sheet may offer from there.
//
// Pure and Foundation-only, split from the store that drives it (Tally/Stores/AddAccountStore.swift)
// so the rule this state machine exists for is testable without a browser, a Keychain or a login:
//
//   ONE login at a time against one config home.
//
// Two logins running against the same home race over the credential they both mean to leave in it,
// and the loser's half of that race is what the user ends up signed in as. Tally can start a login
// two ways (in the background here, or in a Terminal window the user drives), and it can only see
// the end of the first: opening a Terminal window is all `LoginTerminalFallback` waits for. So the
// retry is withheld for as long as a Terminal handoff might still be working, and comes back only
// when the user says that window is done.

/// Who has the unfinished login now. The field that decides whether retrying HERE is safe.
enum AddAccountHandoff: Equatable {
    /// Nobody. Tally's own attempt ended and nothing was started in its place.
    case none
    /// A Terminal window Tally opened, signing in to this very home. Tally cannot see when it
    /// finishes, so it treats the window as live until told otherwise.
    case terminal
    /// Terminal could not be driven (the permission was refused), so the command went to the
    /// clipboard instead. Nothing of Tally's is running.
    case clipboard
}

enum AddAccountPhase: Equatable {
    case idle
    /// Creating the home, linking the share, seeding folder trust.
    case preparing
    /// The provider's login is running against `name`; the browser has the user now.
    case signingIn(name: String)
    /// An account the user now HAS, carrying the preparation report so the sheet can disclose a
    /// share that only partly happened rather than declaring a plain success over it.
    case added(AddedAccountHome)
    /// The home is there, the login is not. Which is a state the CLI already understands (the next
    /// add resumes that same home), not a mess.
    case pending(name: String, reason: String, handoff: AddAccountHandoff)
    /// Nothing was created (no free slot, or the home could not be made).
    case failed(reason: String)
}

extension AddAccountPhase {
    /// Something of Tally's own is working right now.
    var isRunning: Bool {
        switch self {
        case .preparing, .signingIn: return true
        case .idle, .added, .pending, .failed: return false
        }
    }

    /// A Terminal window may still be signing in to the home this flow created.
    var holdsTerminalLogin: Bool {
        if case .pending(_, _, .terminal) = self { return true }
        return false
    }

    /// Whether this flow may be started again, or wound back to the start so it can be. Both are
    /// the same question - either puts a second login on the way to a home that may already have
    /// one - so they are one rule rather than two that can drift apart.
    var allowsNewRun: Bool { !isRunning && !holdsTerminalLogin }

    /// Whether the sheet may offer to hand this login to a Terminal window. Not while one is
    /// already out there: a second window is a second login.
    var allowsTerminalHandoff: Bool {
        if case .pending(_, _, let handoff) = self { return handoff != .terminal }
        return false
    }

    /// Whether the sheet may offer "I finished in Terminal" - the only way out of a live handoff,
    /// and the only thing that can tell Tally the window is done.
    var allowsRecheck: Bool { holdsTerminalLogin }
}
