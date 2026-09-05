import Foundation

// THE ACCOUNT THE PERSON USES IN THEIR BROWSER, and what Tally owes it.
//
// Tally hands sessions out across several paid accounts, and one of them is usually the account the
// user is also signed into on claude.ai. Everything Tally decides by itself - which account a launch
// lands on, which one a running session is moved to when a wall comes down - spends that account's
// quota without ever being asked, and the person only finds out when their own browser says they are
// out of messages. So one account may be MARKED as theirs, and given a water line: a percentage of
// each window it SHARES with that browser which Tally's own choices are not allowed to go below.
//
// THREE WINDOWS: THE WEEKLY ALL-MODELS ONE, THE 5H SESSION ONE, AND THE FLAGSHIP MODEL'S (Albert's
// ruling, 2026-09-05, which supersedes the two-window ruling of 2026-09-02 and the weekly-only one
// of 2026-08-21). The test is whether the browser and Tally spend the same allowance, and for all
// three they do: claude.ai and the CLI draw on ONE 5h session window and on ONE flagship pool, so
// an automatic launch that empties either locks the person out of their own browser until it
// refills - up to five hours for the session window, and until the account's weekly moment for the
// flagship one. Across a fleet of several accounts, declining to spend the last slice of ONE
// account's window costs close to nothing, and it is the difference between the browser answering
// and not.
//
// THE ARGUMENT THAT KEPT THE FLAGSHIP WINDOW OUT DOES NOT SURVIVE A PARTIAL RESERVE. That argument
// was that the flagship pool is a sub-allowance of the same week, so reserving it as well would
// hold the same points back twice. It holds only while the reserve is the whole of the account's
// spending rule. At 50%, holding half the week back says nothing whatever about how the other half
// is spent: Tally may put every point of it through the flagship window and leave its owner a week
// that is half full and a flagship pool at zero, which is the window they would actually have
// noticed. A floor under the week is not a floor under the pool inside it, so the pool needs its
// own.
//
// AND IT CARRIES THE LINE ONLY WHERE IT IS RATED AT ALL. A project whose primary model is another
// tier does not rate the flagship window (the mirrors' `modelWindowCounts`), and it does not spend
// that window either, so there is nothing there for a line to hold back.
//
// ONE NUMBER OVER ALL THREE, rather than a knob per window. The figure is a rough "leave me room to
// work", and it says the same thing about each window the browser and Tally share; a second setting
// would be a second thing to keep in step for a difference nobody can feel.
// `AccountRoles.carriesReserve` below is that rule, asked at the one place each burn-rate mirror
// builds a window.
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
    /// The percentage Tally's own choices must leave standing (0-100) in each window this account
    /// shares with the user's browser: its weekly all-models one, its 5h session one and its
    /// flagship model's, and no other (`carriesReserve`). One number, read against all three.
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

    /// What one cell of the Settings strip is worth, and - divided into the bounds above - HOW MANY
    /// cells it has (`ReserveCellBar` derives the count rather than writing a 10 of its own).
    ///
    /// Coarse on purpose: this is a rough "leave me some room" figure, and the point of a strip is
    /// that the whole scale is visible and any value on it is one click away. Ten cells is a scale
    /// somebody can read at a glance and aim at; a finer step is a row of targets too narrow to hit
    /// for a difference nobody can feel.
    ///
    /// VALUES OFF THE STEP STAY LEGAL - the bounds are the contract, not this - so a 35 written by
    /// the 5-point stepper this replaced, or by a hand-edited state file, is read back and drawn
    /// proportionally (three cells and half of the fourth). The first click snaps it; nothing is
    /// rewritten on disk for the sake of the control.
    static let reserveStep = 10

    /// The account's 7-day all-models pool and its 5h session pool, spelled the way both burn-rate
    /// mirrors label them.
    ///
    /// NAMES RATHER THAN A TYPE THE MIRRORS SHARE, because they build their windows from different
    /// ones (a snapshot row on one side, a `UsageMetric` on the other) and the only thing they have
    /// in common is these labels. The account's flagship pool has no constant here for the reason
    /// `carriesReserve` gives: its label is the provider's, not ours.
    static let weeklyWindowName = "weekly"
    static let sessionWindowName = "session"

    /// Whether a reserve is held back from the window a mirror is building, and the whole of the
    /// ruling at the top of this file said as a rule.
    ///
    /// A RULE RATHER THAN THE SET OF NAMES THIS REPLACED, which the flagship window is what forced:
    /// it is named after whichever model the provider put that tier on, so no set written here can
    /// name it, and a set was exactly how the earlier ruling kept it out of the feature. What both
    /// mirrors can say instead is WHICH of their three windows they are building, and the flagship
    /// one is the one they know by shape rather than by name (`isModelWindow`).
    ///
    /// READ AT THE ONE PLACE EACH MIRROR BUILDS A WINDOW, alongside that site's own opt-in: a
    /// window carries the reserve only when the mirror asked for it AND this rule allows it. Two
    /// conditions rather than one because they fail closed in opposite directions - a mirror that
    /// forgot the opt-in holds nothing back, and a window this rule does not recognise (the `other`
    /// kind the app rates nothing on, a window some later mirror adds) holds nothing back either.
    ///
    /// Everything downstream - the score, the nearly-dry gate, the spent test, the water line a
    /// launch says it crossed, the hatching on the bar - inherits the scope from that one marking
    /// without a rule of its own. A window that carries no reserve is a window this feature does
    /// not exist for.
    /// The three windows as one expression, in the order the rule is stated above: the flagship one
    /// by shape, then the two by name. A nameless window (the `other` kind) matches neither name.
    static func carriesReserve(window name: String?, isModelWindow: Bool) -> Bool {
        isModelWindow || name == weeklyWindowName || name == sessionWindowName
    }

    /// The home holding the personal role, or nil while nobody holds it.
    ///
    /// SORTED, so a document that somehow carries two (a hand edit, two builds writing it) still
    /// answers the same thing on every read rather than following a dictionary's iteration order.
    /// The setter below can only ever leave one.
    static func personalHome(_ accounts: [String: AccountRoleSetting]) -> String? {
        accounts.filter { $0.value.role == personal }.keys.sorted().first
    }

    /// Whether this config home is the marked one.
    ///
    /// ASKED OF THE WINNER ABOVE rather than of this home's own entry, so the three questions over
    /// this block cannot answer a hand-edited document differently from one another: reading each
    /// entry on its own, a file carrying two markings had both rows in Settings badged Personal,
    /// both accounts holding quota back, and the Artifact guard - which asks `personalHome` -
    /// naming exactly one of them. There is ONE marked account by construction, so there is one
    /// here too, and a stray second marking is the leftover the doc above says it is.
    static func isPersonal(_ accounts: [String: AccountRoleSetting], home: String?) -> Bool {
        guard let key = key(accounts, home: home), let marked = personalHome(accounts)
        else { return false }
        return key == marked
    }

    /// How much of each shared window Tally's own choices must leave standing, 0 when there is no
    /// answer. Which windows it is held back from is `carriesReserve` above; this answers only
    /// how much.
    ///
    /// ONLY THE MARKED ACCOUNT HAS ONE, asked here rather than trusted from the document: the
    /// control that writes this lives on the personal row and nowhere else, so a reserve sitting on
    /// an account that does not hold the role is a leftover from a hand edit or an older build. Read
    /// literally it would hold quota back on an account with no surface anywhere saying why.
    ///
    /// THE MARKING IS THE ONE ABOVE, through `isPersonal`: a document carrying two of them holds
    /// quota back on ONE account, the same one every other question about this block answers with.
    /// The number itself is still this home's own, because that is what was asked.
    static func reserve(_ accounts: [String: AccountRoleSetting], home: String?) -> Int {
        guard isPersonal(accounts, home: home), let key = key(accounts, home: home),
              let stored = accounts[key]?.reserve else { return 0 }
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
    /// A NO-OP ON AN ACCOUNT THAT DOES NOT HOLD THE ROLE, and it asks `isPersonal` to find out for
    /// exactly the reason `reserve` does: the writer and the reader have to agree about which
    /// account holds the marking, or the stepper writes a number the reader then ignores - which on
    /// a hand-edited document carrying two markings is what happened, the write landing on the entry
    /// the reader had already decided was the leftover. Zero clears the key rather than storing it,
    /// because absent and zero are the same answer and the shorter one is the one an older reader
    /// cannot misread.
    static func settingReserve(_ accounts: [String: AccountRoleSetting], home: String?,
                               percent: Int) -> [String: AccountRoleSetting] {
        guard isPersonal(accounts, home: home), let key = key(accounts, home: home),
              var entry = accounts[key] else { return accounts }
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
