import Foundation

/// Who each account is, and how long Tally keeps knowing it.
///
/// Identity arrives with the numbers: an address is whatever this round's login probe or usage poll
/// managed to name. Which means switching an account OFF used to erase it - a disabled account is
/// never polled, so its Settings row lost the one line that answers "which login is Codex 2?", read
/// precisely where somebody goes to decide whether to switch it back on. So the last answer is
/// remembered per account instead of being derived from the live round.
///
/// Not a secret and not a credential: an address is what the app already puts on screen. It stays
/// out of `~/.tally/snapshot.json` - that file is the launcher's, and Tally publishes no identity
/// to it.
enum AccountIdentity {
    /// Who an account is, best answer first. The login probe's is the freshest (it asked the CLI
    /// just now); this round's poll is next (a provider names the account it actually reached);
    /// the memory is last, and only ever speaks when nothing live can. Nil when nothing ever could,
    /// and a caller that renders this shows NOTHING there rather than an empty line.
    ///
    /// The order is the whole point of having one function: a memory that outranked a live answer
    /// would keep showing the previous address after a config home was signed into as somebody
    /// else, which is exactly the staleness the probe exists to correct.
    static func email(probe: String?, polled: String?, remembered: String?) -> String? {
        probe ?? polled ?? remembered
    }

    /// What the Settings row's account column shows: the address when there is one, "Signing in"
    /// for a login that landed this launch and has not named itself yet, otherwise the config home
    /// (B-1702: a just-added account read as a bare folder for a minute).
    enum Column: Equatable { case address(String), signingIn, home(String?) }

    static func column(email: String?, signingIn: Bool, home: String?) -> Column {
        if let email, !email.isEmpty { return .address(email) }
        return signingIn ? .signingIn : .home(home)
    }

    /// The line UNDER the address: what tells two accounts apart when the address cannot.
    ///
    /// One person can hold two logins on ONE address - a Codex account in a personal workspace and
    /// the same address in a team's - and then every surface that identifies an account by its email
    /// says the same thing on both cards. There is nothing to add from the provider: Codex's own
    /// app-server answers `type`, `email` and `planType` and names no organization (measured against
    /// two homes, 2026-08-04), and the file that does is the one Tally promises never to read.
    ///
    /// So the line is built from what Tally already holds and already trusts: the plan the account is
    /// on, and the config home it launches from. The home is the part that always separates them -
    /// two accounts cannot share one directory - and it is also the answer to the question the user
    /// is really asking, which is which of these two a new session would run in.
    ///
    /// Nil when neither is known, and the surfaces then render nothing rather than an empty line.
    ///
    /// The home directory is a parameter for the same reason `homeName` takes one: so a test can
    /// state which paths are inside the user's own directory instead of inheriting the answer from
    /// whichever machine runs it. Callers on screen pass nothing and get this machine's.
    static func detail(plan: String?, home: String?, userHome: String = NSHomeDirectory()) -> String? {
        let parts = [plan, home.map { homeName($0, userHome: userHome) }]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A config home the way its owner refers to it: `~/.codex2`, not `/Users/…/.codex2`. The full
    /// path is both longer than any surface here has room for and the one form of it that carries
    /// the account owner's short name into a screenshot.
    ///
    /// The home directory is a parameter so the rule can be tested against a fixture rather than
    /// against whichever machine runs the test.
    ///
    /// A home that is not under it at all - a `CODEX_HOME` pointed at another volume, which the env
    /// var already allows today - keeps only its last segment (`/Volumes/work/codex-team` →
    /// `…/codex-team`). Returning those in full was the bug this rule is shaped around: the card's
    /// callout sizes itself to its text and would run past the 380pt panel it lives in, and the
    /// Settings row would truncate from the END, cutting off the directory name that is the entire
    /// reason the home is on screen. Two accounts would stop being distinguishable again, in exactly
    /// the case the feature exists for (codex review of e2f3325, 2026-08-04).
    ///
    /// The last segment is never itself shortened: whatever the user called that directory IS the
    /// discriminator, and a `…/codex-te…` names neither account.
    static func homeName(_ path: String, userHome: String = NSHomeDirectory()) -> String {
        let short = underHome(path, userHome: userHome)
        guard short.count > homeNameLimit else { return short }
        // A path with no parent to drop (`/opt`, or a bare name) has nothing this can shorten, and
        // an ellipsis longer than what it replaces would be a longer answer, not a shorter one.
        let tail = (short as NSString).lastPathComponent
        guard tail.count + 2 < short.count else { return short }
        return "…/" + tail
    }

    /// How long a home may be before it is worth shortening. Sized from the surface with the least
    /// room: the card's callout shares the 380pt panel, where the structured callout beside it is
    /// laid out at 240pt (TallyTooltip.blocksWidth) - about 43 characters at the caption size both
    /// are drawn in. A plan and its separator take ten of those, and the rest is deliberately not
    /// spent to the last character: the Settings row shows this beside a name it would otherwise
    /// truncate, and that row is the tighter of the two. Not a view constant, because this file
    /// compiles on its own for the tests - which is also why the number is written down here with
    /// its reason rather than derived.
    private static let homeNameLimit = 20

    /// The `~` form, or the path unchanged when it is somewhere else entirely.
    private static func underHome(_ path: String, userHome: String) -> String {
        guard !userHome.isEmpty else { return path }
        if path == userHome { return "~" }
        guard path.hasPrefix(userHome + "/") else { return path }
        return "~" + path.dropFirst(userHome.count)
    }
}

/// The remembered half, kept pure so the rules below can be tested without a defaults store.
struct AccountIdentityMemory: Codable, Equatable {
    private var emails: [String: String] = [:]
    /// Accounts whose last login landed as somebody else (B-4530): the address each was MEANT to
    /// hold, until a login confirms it or the person keeps the other one. While an account is here
    /// the memory is not written for it, because what the home says is the wrong account and a poll
    /// would record that as the account's identity, so the next "Sign in again" would be asked for
    /// the wrong address and held to it.
    private var unresolved: [String: String] = [:]

    init(emails: [String: String] = [:]) {
        self.emails = emails
    }

    /// Decoded by hand so a memory stored before `unresolved` existed still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emails = try container.decode([String: String].self, forKey: .emails)
        unresolved = try container.decodeIfPresent([String: String].self, forKey: .unresolved) ?? [:]
    }

    func email(_ accountID: String) -> String? { emails[accountID] }

    /// The address a login for this account is to be held to: the unresolved one when a wrong login
    /// left one, otherwise what is remembered.
    func expectedEmail(_ accountID: String) -> String? { unresolved[accountID] ?? emails[accountID] }

    /// A login landed as somebody else: keep `email` as who this account is until that is settled.
    @discardableResult
    mutating func hold(accountID: String, email: String?) -> Bool {
        guard let email, !email.isEmpty, unresolved[accountID] != email else { return false }
        unresolved[accountID] = email
        return true
    }

    /// The question is settled (a login matched, or the other account was kept).
    @discardableResult
    mutating func release(accountID: String) -> Bool { unresolved.removeValue(forKey: accountID) != nil }

    /// Write down what a round learned. A round that could not name the account knows LESS than the
    /// previous one did, so nil (and the empty string, which is the same non-answer wearing a
    /// different type) leaves the memory alone rather than clearing it - otherwise one failed poll
    /// would blank the address on every disabled row too.
    ///
    /// Answers whether anything changed, so the caller can skip a write on the overwhelmingly
    /// common round where every account said the same thing it said last time.
    @discardableResult
    mutating func remember(accountID: String, email: String?) -> Bool {
        guard let email, !email.isEmpty else { return false }
        // A reading that names the held address means the home is back to the account it was meant
        // for, which settles the question on its own; any other answer is the wrong login's.
        var released = false
        if let held = unresolved[accountID] {
            guard held.caseInsensitiveCompare(email) == .orderedSame else { return false }
            unresolved[accountID] = nil
            released = true
        }
        guard emails[accountID] != email else { return released }
        emails[accountID] = email
        return true
    }

    /// The account was REMOVED (its config home went to the Trash, see RemoveAccountAction). A
    /// recreated `~/.codex3` takes the same id, so a memory left behind would put the previous
    /// account's address on the new one's row.
    @discardableResult
    mutating func forget(accountID: String) -> Bool {
        let held = unresolved.removeValue(forKey: accountID) != nil
        return emails.removeValue(forKey: accountID) != nil || held
    }
}

extension AccountIdentity {
    /// The nickname a rename stores for what was typed: none (the default name shows) for nothing,
    /// for blanks, or for the default name typed back in (AccountNameField).
    static func nickname(typed: String, defaultLabel: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        return (trimmed.isEmpty || trimmed == defaultLabel) ? nil : trimmed
    }
}
