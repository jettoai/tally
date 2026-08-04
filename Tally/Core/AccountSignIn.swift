import Foundation

/// What an account row should offer about its LOGIN, from the three things the app already knows.
///
/// Two independent sources say an account is signed out, and each knows something the other does
/// not. The login probe (`LoginStatusStore`) asks the provider's own CLI, so it notices a credential
/// that expired under a home still full of config; discovery (`ProviderAccount.isDormant`) notices a
/// home whose login is gone entirely, which is exactly the state the probe cannot ask about because
/// the account is no longer discoverable as signed in. Either one means the same thing to a user
/// looking at the row: this account needs signing in again.
///
/// A renewal in flight outranks both, and that is the rule rather than an ordering accident: the
/// card learned it first (a chip offering to start a sign-in that is already running, 2026-08-03),
/// and a second surface must not answer it differently.
///
/// Pure, so the rule is testable without a store, a CLI, or a window.
enum AccountSignIn {
    enum State: Equatable {
        /// Nothing to say: the account is signed in as far as anything here knows.
        case signedIn
        /// Offer the sign-in. The row shows it inline, in the severity colour, because a signed-out
        /// account is the one state where the row cannot do its job at all.
        case needsSignIn
        /// A sign-in is already running; the row says so instead of offering another.
        case renewing
    }

    /// How long a renewal that already reported success keeps the row from offering another one
    /// while discovery catches up. Long enough for a refresh that was queued behind another to
    /// finish (the poll takes 10-20s and a user-initiated one can be coalesced into the round
    /// already running), short enough that a login which silently did not land is offered again
    /// rather than leaving the row saying "renewing" forever.
    static let settleWindow: TimeInterval = 90

    /// `renewalSucceededAt` is when a renewal last reported success for this account, and it is
    /// here because of a gap the other three inputs cannot see. On success the store drops the
    /// in-flight flag and clears the expired verdict at once, but DISCOVERY - the other source of
    /// "signed out" - only catches up when the refresh behind it finishes. In between, the row had
    /// all three inputs saying "offer a sign-in" about an account that had just been signed in, and
    /// a second click fired a second login against the same config home (codex review, 2026-08-04).
    ///
    /// Only dormancy is bridged: an expired verdict is cleared synchronously by the same success,
    /// so a row still reading "expired" after one is reporting something this does not know about.
    static func state(isRenewing: Bool, isExpired: Bool, isDormant: Bool,
                      renewalSucceededAt: Date? = nil, now: Date = Date()) -> State {
        if isRenewing { return .renewing }
        if isDormant, let succeeded = renewalSucceededAt,
           now.timeIntervalSince(succeeded) < settleWindow {
            return .renewing
        }
        return isExpired || isDormant ? .needsSignIn : .signedIn
    }
}
