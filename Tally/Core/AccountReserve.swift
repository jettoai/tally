import Foundation

// THE ACCOUNT THE PERSON USES IN THEIR BROWSER, and what Tally owes it.
//
// Tally hands sessions out across several paid accounts, and one of them is usually the account the
// user is also signed into on claude.ai. Everything Tally decides by itself - which account a launch
// lands on, which one a running session is moved to when a wall comes down - spends that account's
// quota without ever being asked, and the person only finds out when their own browser says they are
// out of messages. So one account may be MARKED as theirs, and given a water line: a percentage of
// its quota that Tally's own choices are not allowed to go below.
//
// TWO FACTS, ONE MARKING. The role also answers the question the Artifact guard asks (which account
// this machine's browser is signed into - Tally/Core/ArtifactHookContract.swift), which is why the
// app writes both when it is set: they are the same sentence about the same account.
//
// WHAT THIS FILE IS, exactly: the pure rules over the `accounts` block of ~/.tally/state.json, with
// no store, no file and no SwiftUI behind them, so every one of them is assertable on its own
// (tests/accountrow). `LaunchPolicyStore` owns the document; the CLI reads it back.
//
// THE SCHEMA ONLY EVER GAINS KEYS: `accounts` is a new top-level block, `version` does not move, and
// a supervisor from a build that predates it decodes the document exactly as it did before.

/// One account's entry in that block, keyed by its config home.
///
/// Both fields optional because this is a document other builds write too: a record carrying only a
/// key this build does not know about must survive a round trip rather than being read as a record
/// that says nothing.
struct AccountRoleSetting: Codable, Equatable {
    /// `AccountRoles.personal`, or nil for an account holding no role.
    var role: String?
    /// The percentage of this account's quota Tally's own choices must leave standing (0-100).
    /// Absent is zero: no reserve at all, which is what every account starts as.
    var reserve: Int?

    /// Nothing left to say about this account, so the entry itself goes rather than sitting in the
    /// file as a key with an empty object under it.
    var isEmpty: Bool { role == nil && reserve == nil }
}

/// The rules over that block. Pure and static, one per question the UI and the store ask.
enum AccountRoles {
    /// The one role there is. A string in the document rather than a bool named `isPersonal`,
    /// because the block is per-account and roles are the kind of thing that gains members.
    static let personal = "personal"

    /// What the reserve may be. 100 is legal and means exactly what it says: Tally never picks this
    /// account by itself. Naming the account explicitly still launches on it (the CLI's rule).
    static let reserveBounds = 0 ... 100

    /// What one press of the stepper moves. Coarse on purpose: this is a rough "leave me some room"
    /// figure, and a percent-at-a-time control would be twenty presses to reach a number the user
    /// cannot feel the difference of anyway.
    static let reserveStep = 5

    /// The home holding the personal role, or nil while nobody holds it.
    ///
    /// SORTED, so a document that somehow carries two (a hand edit, two builds writing it) still
    /// answers the same thing on every read rather than following a dictionary's iteration order.
    /// The setter below can only ever leave one.
    static func personalHome(_ accounts: [String: AccountRoleSetting]) -> String? {
        accounts.filter { $0.value.role == personal }.keys.sorted().first
    }

    /// Whether this config home is the marked one.
    static func isPersonal(_ accounts: [String: AccountRoleSetting], home: String?) -> Bool {
        guard let key = key(accounts, home: home) else { return false }
        return accounts[key]?.role == personal
    }

    /// How much of this account's quota Tally's own choices must leave standing, 0 when there is no
    /// answer.
    ///
    /// ONLY THE MARKED ACCOUNT HAS ONE, asked here rather than trusted from the document: the
    /// control that writes this lives on the personal row and nowhere else, so a reserve sitting on
    /// an account that does not hold the role is a leftover from a hand edit or an older build. Read
    /// literally it would hold quota back on an account with no surface anywhere saying why.
    static func reserve(_ accounts: [String: AccountRoleSetting], home: String?) -> Int {
        guard let key = key(accounts, home: home), let entry = accounts[key],
              entry.role == personal, let stored = entry.reserve else { return 0 }
        return min(max(stored, reserveBounds.lowerBound), reserveBounds.upperBound)
    }

    /// The block with the personal role on this home - or on nothing, when handed nil.
    ///
    /// SINGLE SELECT, so the role leaves wherever it was. AND ITS RESERVE GOES WITH IT: the stepper
    /// only exists on the marked row, so a reserve left behind on an unmarked account is a setting
    /// with no surface that can show it, change it, or explain it. The cost is that re-marking an
    /// account starts it at zero again, which is the honest half of the same sentence.
    static func settingPersonal(_ accounts: [String: AccountRoleSetting], home: String?)
        -> [String: AccountRoleSetting] {
        var updated = accounts
        for (key, value) in updated where value.role == personal {
            var cleared = value
            cleared.role = nil
            cleared.reserve = nil
            updated[key] = cleared.isEmpty ? nil : cleared
        }
        // A home that normalizes to nothing names no account, so it is the same instruction as nil.
        guard let home, artifactAccountHome(home) != nil else { return updated }
        let target = key(updated, home: home) ?? home
        var entry = updated[target] ?? AccountRoleSetting()
        entry.role = personal
        updated[target] = entry
        return updated
    }

    /// The block with this account's reserve set, clamped into range.
    ///
    /// A NO-OP ON AN ACCOUNT THAT DOES NOT HOLD THE ROLE, matching `reserve` above: the two have to
    /// agree, or the stepper would write a number the reader then ignores. Zero clears the key
    /// rather than storing it, because absent and zero are the same answer and the shorter one is
    /// the one an older reader cannot misread.
    static func settingReserve(_ accounts: [String: AccountRoleSetting], home: String?,
                               percent: Int) -> [String: AccountRoleSetting] {
        guard let key = key(accounts, home: home), var entry = accounts[key],
              entry.role == personal else { return accounts }
        let clamped = min(max(percent, reserveBounds.lowerBound), reserveBounds.upperBound)
        entry.reserve = clamped == reserveBounds.lowerBound ? nil : clamped
        var updated = accounts
        updated[key] = entry
        return updated
    }

    /// The block after a config home has been removed from the machine.
    ///
    /// KEYED BY A DIRECTORY, exactly like the Artifact publishing account beside it, so the id-shaped
    /// forgetting cannot reach it (`LaunchPolicyStore.forget` states what that costs). Left standing,
    /// the entry marks a folder in the Trash as the account the user browses on - and a later
    /// `~/.claudeN` created in the same slot inherits a role and a reserve nobody chose for it.
    static func removingHome(_ accounts: [String: AccountRoleSetting], home: String)
        -> [String: AccountRoleSetting] {
        guard let key = key(accounts, home: home) else { return accounts }
        var updated = accounts
        updated.removeValue(forKey: key)
        return updated
    }

    /// Which stored key names this home.
    ///
    /// Through `artifactAccountHome` on BOTH sides - the same normalization the Artifact setting is
    /// compared with, and for the same reason: this key is written from the app's own discovery and
    /// looked up against whatever a caller happens to hold, which on this machine is frequently the
    /// same directory reached through a symlink or carrying a trailing slash. Text rather than a
    /// filesystem identity read, because the removal above asks this about a directory that has
    /// already gone to the Trash.
    ///
    /// Sorted for the reason `personalHome` is: one answer per document, not per iteration.
    static func key(_ accounts: [String: AccountRoleSetting], home: String?) -> String? {
        guard let target = artifactAccountHome(home) else { return nil }
        return accounts.keys.sorted().first { artifactAccountHome($0) == target }
    }
}
