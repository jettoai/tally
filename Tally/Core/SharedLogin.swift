import Foundation

/// Two config homes signed into ONE Claude account (jettoai/tally#6). Accounts are keyed by their
/// config home, so a re-login that lands somebody else's identity in a home used to read as a second
/// subscription: its quota counted twice in the fleet and the advisor, and offered as a "fresh"
/// launch target that hits the same wall. The identity (`oauthAccount.accountUuid`) and the emails
/// are compared here and never leave: callers hand them in and get account ids back.
enum SharedLogin {
    struct Home {
        var id: String
        /// The login's account uuid; nil or empty matches nothing.
        var identity: String?
        /// Who Tally remembered this home as (`AccountIdentityMemory`), before this round.
        var rememberedEmail: String?
        /// Who this round read it as.
        var currentEmail: String?

        /// The home still names the person it was remembered as: of two homes on one login, this
        /// is the one that was not re-signed into somebody else's account.
        var identityUnchanged: Bool {
            guard let rememberedEmail, !rememberedEmail.isEmpty else { return false }
            return rememberedEmail == currentEmail
        }
    }

    /// duplicate account id → the id of the account kept for that identity. The kept one is the
    /// only home of the group whose identity did not change; when that is not exactly one home
    /// (nothing remembered yet, or every home always held this login) it is the first by account
    /// id, so the answer is stable whatever order discovery or polling ran in. A missing or empty
    /// identity matches nothing: a home whose file predates the field behaves exactly as before.
    static func duplicates(_ homes: [Home]) -> [String: String] {
        var groups: [String: [Home]] = [:]
        for home in homes {
            guard let identity = home.identity, !identity.isEmpty else { continue }
            groups[identity, default: []].append(home)
        }
        var duplicates: [String: String] = [:]
        for group in groups.values where group.count > 1 {
            let sorted = group.sorted { $0.id < $1.id }
            let unchanged = sorted.filter(\.identityUnchanged)
            let kept = unchanged.count == 1 ? unchanged[0].id : sorted[0].id
            for home in sorted where home.id != kept { duplicates[home.id] = kept }
        }
        return duplicates
    }

    /// Every account of one shared login, kept first then the duplicates in id order: the labels
    /// the message names.
    static func group(keptID: String, duplicates: [String: String]) -> [String] {
        [keptID] + duplicates.filter { $0.value == keptID }.map(\.key).sorted()
    }

    /// Whether a row is a seat of its own for the advisor: a duplicate is not.
    static func isSeat(_ sameAccountAs: String?) -> Bool { sameAccountAs == nil }
}
