import Foundation

/// What "is this account still signed in?" runs, and how the answer is read.
///
/// The question is asked of the provider's own CLI, read-only: `claude auth status` and
/// `codex login status` both report a local credential's state and neither writes anything, spends
/// quota, or hands Tally a token. The environment, the executable rule and the ANSI stripping are
/// the renewal's (`RenewLoginCommand`), because this is the same login seen from the other side -
/// one spelling of the config-home variable, one rule for which binary is the real one.
///
/// Split from the store for the same reason the renewal was: the verdict rules are the part that
/// can be wrong in a way no type check sees. tests/logincheck drives them against stub CLIs.
///
/// What this can and cannot see: both CLIs answer from the credential ON THIS MACHINE, so a
/// credential that was removed, never created, or expired past the CLI's own refresh reads as
/// signed out - while a token the vendor revoked server-side keeps reading as signed in until the
/// CLI next fails to refresh it. That is the honest scope of the alert: "this machine has no
/// working login for that account any more", which is exactly the state a re-login fixes.
enum LoginStatusCommand {
    enum Verdict: String, Sendable, Equatable {
        /// The CLI named a live login.
        case signedIn
        /// The CLI said there is none. The only verdict that raises anything on screen.
        case signedOut
        /// The CLI could not be run, or said something Tally does not recognise. Deliberately
        /// distinct from `signedOut`: an updated CLI, a broken config file or a missing binary must
        /// never be reported to the user as an expired login, and must not re-arm the alert either.
        case unknown
    }

    /// The read-only status subcommand, or nil for a provider Tally cannot ask.
    ///
    /// Claude: `claude auth status` prints a JSON object (`loggedIn`, `email`, `subscriptionType`,
    /// …) on stdout and exits 0 signed in, 1 signed out - measured on 2.1.220, 2026-08-03.
    /// `--strict-mcp-config` for the same reason every other spawn carries it (the fork-bomb guard),
    /// and BEFORE the subcommand because that is where the main command parses a global option; the
    /// other order is the bug 13ade3a fixed, and the reason it shipped is that it was checked with
    /// `--help`, which prints and exits before any option is validated. This placement was measured
    /// by a run that actually parses it - the very `auth status` below, which costs nothing.
    ///
    /// Codex: `codex login status` prints one line to STDERR ("Logged in using ChatGPT" / "Not
    /// logged in") and exits 0 / 1 - measured on codex-cli 0.146.0, 2026-08-03. No JSON is on offer
    /// (`codex login status --help` lists no format option), so the line and the exit code are the
    /// whole answer, which is why `verdict` reads text before it reads either.
    static func arguments(providerID: String) -> [String]? {
        switch providerID {
        case "claude": return ["--strict-mcp-config", "auth", "status"]
        case "codex": return ["login", "status"]
        default: return nil
        }
    }

    /// How long a status probe is allowed to take. Both CLIs answer from local state and measured
    /// well under a second (claude 0.22s, codex 0.03s); the ceiling only exists so a wedged CLI
    /// cannot hold a refresh's task group open.
    static let timeout: TimeInterval = 20

    /// The account facts a probe can establish along the way. `email` is the point: the CLI names
    /// who is signed in RIGHT NOW, where the config file it would otherwise be read from can be
    /// left over from whoever was signed in before.
    struct Reading: Sendable, Equatable {
        var verdict: Verdict
        var email: String?
    }

    /// Read one probe's result. `output` is stdout and stderr together on purpose: the two CLIs put
    /// their answer on different streams, and a CLI that moves its own between releases must not
    /// turn into a false "expired".
    ///
    /// Order matters. The structured answer wins; then the words, signed-OUT first (every
    /// signed-out phrase contains a signed-in one - "not logged in" contains "logged in"); then, and
    /// only to say YES, the exit code. There is deliberately no path from an exit code alone to
    /// `signedOut`: a CLI that failed to parse its config file, or that a rename broke, exits
    /// non-zero too, and the cost of that being read as an expired login is a red chip and a
    /// notification about an account that is fine.
    static func read(exitCode: Int32?, output: String) -> Reading {
        guard let exitCode else { return Reading(verdict: .unknown) }
        let text = RenewLoginCommand.plainText(output)
        let json = jsonObject(in: text)
        let email = (json?["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let loggedIn = json?["loggedIn"] as? Bool {
            return Reading(verdict: loggedIn ? .signedIn : .signedOut, email: email)
        }
        if contains(Self.signedOutMarkers, in: text) { return Reading(verdict: .signedOut) }
        if contains(Self.signedInMarkers, in: text) { return Reading(verdict: .signedIn, email: email) }
        // Nothing recognisable was said. A status subcommand that exits 0 is reporting a healthy
        // account; anything else is a CLI Tally no longer understands, which is not news about a
        // login.
        return Reading(verdict: exitCode == 0 ? .signedIn : .unknown, email: email)
    }

    /// Matched loosely (lowercased, on ANSI-stripped text) and kept plural on purpose: a CLI is free
    /// to reword its own status line, and the cost of a stale phrase has to be a missed alert, never
    /// a false one. Both lists are as of claude 2.1.220 / codex-cli 0.146.0 (2026-08-03).
    static let signedOutMarkers = ["not logged in", "not signed in", "logged out", "signed out",
                                   "no credentials", "no active account"]
    static let signedInMarkers = ["logged in", "signed in"]

    private static func contains(_ markers: [String], in output: String) -> Bool {
        let text = output.lowercased()
        return markers.contains { text.contains($0) }
    }

    /// The first `{ … }` run of the output, decoded. Sliced rather than decoded whole so a notice
    /// printed above the JSON (an update nudge, a deprecation warning) does not cost the answer.
    private static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start ... end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }
}

// MARK: The one-notification-per-outage rule

/// Which accounts have already been told about. Persisted, because "once" has to mean once across
/// relaunches too - an app that restarts every update would otherwise re-announce every expired
/// account it still sees.
struct LoginAlertState: Codable, Equatable {
    var announced: Set<String> = []
}

/// The pure half of the expiry alert: who gets announced this round, and what the state becomes.
/// Pure so the dedup can be tested without a notification centre - the same split as
/// `DryPoolLogic` and `ResetHintLogic`.
enum LoginAlertLogic {
    /// `verdicts` is what this round could establish, `known` every account that still exists.
    ///
    /// An account is announced on its first signed-out round and not again until a `signedIn`
    /// round clears it. `unknown` changes nothing in either direction, which is the whole reason
    /// it is a separate verdict: a CLI that could not be run must not silently re-arm an alert
    /// that would then fire again the moment it works.
    static func advance(state: LoginAlertState, verdicts: [String: LoginStatusCommand.Verdict],
                        known: Set<String>) -> (LoginAlertState, [String]) {
        var announced = state.announced.intersection(known)
        for (id, verdict) in verdicts where verdict == .signedIn { announced.remove(id) }
        let fresh = verdicts
            .filter { $0.value == .signedOut && !announced.contains($0.key) }
            .keys.sorted()
        announced.formUnion(fresh)
        return (LoginAlertState(announced: announced), fresh)
    }

    /// Undo one announcement, for a notification that could not be delivered: an alert the system
    /// refused was never seen, so the account has to stay armed for the next round.
    static func rearm(state: LoginAlertState, accountID: String) -> LoginAlertState {
        var next = state
        next.announced.remove(accountID)
        return next
    }
}
