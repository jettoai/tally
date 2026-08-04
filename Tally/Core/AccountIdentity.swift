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

    init(emails: [String: String] = [:]) {
        self.emails = emails
    }

    func email(_ accountID: String) -> String? { emails[accountID] }

    /// Write down what a round learned. A round that could not name the account knows LESS than the
    /// previous one did, so nil (and the empty string, which is the same non-answer wearing a
    /// different type) leaves the memory alone rather than clearing it - otherwise one failed poll
    /// would blank the address on every disabled row too.
    ///
    /// Answers whether anything changed, so the caller can skip a write on the overwhelmingly
    /// common round where every account said the same thing it said last time.
    @discardableResult
    mutating func remember(accountID: String, email: String?) -> Bool {
        guard let email, !email.isEmpty, emails[accountID] != email else { return false }
        emails[accountID] = email
        return true
    }

    /// The account was REMOVED (its config home went to the Trash, see RemoveAccountAction). A
    /// recreated `~/.codex3` takes the same id, so a memory left behind would put the previous
    /// account's address on the new one's row.
    @discardableResult
    mutating func forget(accountID: String) -> Bool {
        emails.removeValue(forKey: accountID) != nil
    }
}
