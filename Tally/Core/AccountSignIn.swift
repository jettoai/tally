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

    static func state(isRenewing: Bool, isExpired: Bool, isDormant: Bool) -> State {
        if isRenewing { return .renewing }
        return isExpired || isDormant ? .needsSignIn : .signedIn
    }
}
