import Foundation

/// Whether a login that just landed in a config home is the account that home was MEANT for
/// (B-4530). The vendor's own CLI writes the credential into the home no matter whose browser
/// session answers the OAuth round trip, so a renewal started for Claude 4 (albert2) while the
/// browser was signed in as albert4 left Claude 4 holding albert4, with nothing noticing.
///
/// Tally cannot stop that write (it never touches the credential), so the check is the last thing
/// that can: read who the home says it now is and compare with who it was. Foundation-only and
/// pure apart from the injected reader, so tests/renewlogin drives it against stub CLIs that write
/// a `.claude.json` of their own.
///
/// An email and an account uuid are identities. They are compared in memory and the verdict carries
/// at most the email back out (it is what the notification names); the uuid never leaves.
enum RenewalIdentity {
    struct Who: Equatable {
        var email: String?
        var uuid: String?
        var isEmpty: Bool { (email ?? "").isEmpty && (uuid ?? "").isEmpty }
    }

    enum Verdict: Equatable {
        /// The home is signed into the account it was meant for.
        case match
        /// A different account: `signedIn` is the address that landed, when it said one.
        case mismatch(signedIn: String?)
        /// The home never said who is in it, so the login can be neither accepted nor refused.
        case unconfirmed
    }

    /// uuid first (an address can be renamed, the account cannot), email second, case-insensitive.
    /// Nothing expected (a home nobody had named) accepts any login: there is no one to be wrong
    /// about. Two sides that share no field (a uuid on one, only an email on the other) cannot be
    /// compared and are `unconfirmed`, never a guess.
    static func verdict(expected: Who?, landed: Who?) -> Verdict {
        guard let expected, !expected.isEmpty else { return .match }
        guard let landed, !landed.isEmpty else { return .unconfirmed }
        if let a = expected.uuid, !a.isEmpty, let b = landed.uuid, !b.isEmpty {
            return a == b ? .match : .mismatch(signedIn: landed.email)
        }
        if let a = expected.email, !a.isEmpty, let b = landed.email, !b.isEmpty {
            return a.caseInsensitiveCompare(b) == .orderedSame ? .match : .mismatch(signedIn: b)
        }
        return .unconfirmed
    }

    /// Who the home says it is, and when its state file last changed.
    typealias Reading = (who: Who?, modifiedAt: Date?)

    /// The identity the home carries once the login has had time to write it. `oauthAccount`
    /// lands AFTER the credential (B-1702: the Keychain item and the profile fetch fell in the same
    /// second), and the file still holds the PREVIOUS login's identity until then, so a single read
    /// right after the credential appears answers for whoever was there before. Hence the retry,
    /// and hence two ways out: an answer that disagrees with `expected` AND is not the identity the
    /// home held before the login (`profileBefore`: stale data cannot disagree with itself, but it
    /// can disagree with `expected`, which is the remembered address and may differ from the file
    /// after a wrong login), or one from a file written since `before`. Out of attempts, the last
    /// reading stands (a same-account login that rewrote nothing looks exactly like a stale one,
    /// and `.match` is the only answer that does not strand the user). `profileBefore` nil: nothing
    /// is known to be stale, so any disagreement stands (a caller whose expectation IS the file).
    static func landedIdentity(
        expected: Who?, before: Date?, profileBefore: Who? = nil, attempts: Int = 10,
        interval: Duration = .milliseconds(500), read: @Sendable () -> Reading
    ) async -> Who? {
        var last: Who?
        for attempt in 0 ..< max(attempts, 1) {
            let reading = read()
            if let who = reading.who, !who.isEmpty {
                last = who
                let stale = profileBefore.map { verdict(expected: $0, landed: who) == .match } ?? false
                if !stale, case .mismatch = verdict(expected: expected, landed: who) { return who }
                guard let before else { return who }
                if let modified = reading.modifiedAt, modified > before { return who }
            }
            if attempt < attempts - 1 { try? await Task.sleep(for: interval) }
        }
        return last
    }

    /// The whole check for one landing.
    static func confirm(
        expected: Who?, before: Date?, profileBefore: Who? = nil, attempts: Int = 10,
        interval: Duration = .milliseconds(500), read: @Sendable () -> Reading
    ) async -> Verdict {
        verdict(expected: expected,
                landed: await landedIdentity(expected: expected, before: before,
                                             profileBefore: profileBefore, attempts: attempts,
                                             interval: interval, read: read))
    }

    /// The identity to hold a login to: who Tally already knows the home as (its remembered
    /// address) when it knows one, otherwise what the home itself says. The memory goes first
    /// because after a wrong login the home's own file names the WRONG account, and the second
    /// attempt (the notification's "sign in again") has to be held to the original one. The uuid
    /// only rides along when it belongs to that same address.
    static func expectedIdentity(remembered: String?, profile: Who?) -> Who? {
        let profile = profile.flatMap { $0.isEmpty ? nil : $0 }
        guard let remembered, !remembered.isEmpty else { return profile }
        let sameAddress = profile?.email?.caseInsensitiveCompare(remembered) == .orderedSame
        return Who(email: remembered, uuid: sameAddress ? profile?.uuid : nil)
    }
}
