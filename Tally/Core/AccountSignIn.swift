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
/// and a second surface must not answer it differently. "In flight" is the STORE's answer, not a
/// window's: it covers the running login and the settling one alike (`RenewalSettling` below), so
/// no surface has to know that a renewal has an afterglow.
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

    /// WHICH SENTENCE that offer tells, which the state above deliberately does not decide (codex
    /// review, 2026-08-24). The click is identical either way, so one state is right; the words are
    /// not. An EXPIRED credential is one the provider stopped accepting. A DORMANT home is one whose
    /// credential is gone from disk entirely (`KnownAccounts`), which is what signing yourself out
    /// looks like, and calling that an expiry names an event that did not happen.
    ///
    /// Dormancy decides, rather than the expiry verdict: the probe runs against every account that
    /// has a config home (`LoginStatusStore.evaluate`), so a dormant one answers "signed out" as
    /// well, and a rule that asked the verdict first would hand it the expiry sentence anyway.
    ///
    /// Returns the catalogue KEY rather than the localized string, so this file stays Foundation
    /// only and both surfaces localize it the one way (`L`).
    static func detailKey(isDormant: Bool) -> String {
        isDormant ? "Not signed in. Click to sign in." : "Login expired. Click to sign in again."
    }
}

/// The accounts whose renewal reported success while discovery still had them signed out.
///
/// The gap is real and it is not small: on success the store drops the in-flight flag and clears the
/// expired verdict at once, but discovery only catches up when the refresh behind it finishes, and a
/// refresh coalesced into one already running returns immediately without having re-discovered
/// anything. In that window every input said "offer a sign-in" about an account that had just been
/// signed in, and a second click fired a second login against the same config home.
///
/// It lives beside the store's in-flight set rather than in any view, because the offer has four
/// entry points (the card's chip, the Settings row's button, both context menus, and the expiry
/// notification's action) and the first version of this fix guarded exactly one of them (codex
/// review, 2026-08-04). One set, one predicate, asked by all of them.
///
/// Pure for the same reason the state rule above is: the lifecycle - who joins, who leaves, and on
/// what evidence - is testable without a login, a timer, or a window.
struct RenewalSettling: Equatable {
    /// How long an account stays settling before the offer comes back. Long enough for a refresh
    /// that was queued behind another to finish (the poll takes 10-20s and a user-initiated one can
    /// be coalesced into the round already running), short enough that a login which silently did
    /// not land is offered again rather than leaving every surface saying "renewing" forever. The
    /// deadline is the safety net; discovery agreeing is the normal way out.
    static let window: TimeInterval = 90

    private var accounts: Set<String> = []

    init(_ accounts: Set<String> = []) {
        self.accounts = accounts
    }

    func contains(_ accountID: String) -> Bool { accounts.contains(accountID) }

    /// A renewal reported success. Only an account discovery STILL calls signed out joins: for any
    /// other one the expired verdict was cleared by the same success, synchronously, so there is no
    /// gap to cover and "renewing" would be an invented state rather than a closed race.
    ///
    /// Answers whether anything changed, so the caller can skip scheduling a deadline it either
    /// already has running or does not need at all.
    @discardableResult
    mutating func begin(_ accountID: String, isDormant: Bool) -> Bool {
        guard isDormant else { return false }
        return accounts.insert(accountID).inserted
    }

    /// Stop settling this one: the deadline ran out (the login reported success but nothing landed,
    /// so the offer has to come back) or the account is gone.
    @discardableResult
    mutating func end(_ accountID: String) -> Bool {
        accounts.remove(accountID) != nil
    }

    /// Discovery spoke. Every settling account it no longer calls dormant has landed, so it stops
    /// settling NOW rather than sitting out the rest of its deadline: the common case is that the
    /// login worked, and a row that keeps saying "renewing" for another minute after the account is
    /// demonstrably back is its own kind of wrong.
    @discardableResult
    mutating func discovered(dormant: Set<String>) -> Bool {
        let next = accounts.intersection(dormant)
        guard next != accounts else { return false }
        accounts = next
        return true
    }
}
