import Foundation

/// Everything about ONE early-start spawn that can be got wrong without a type check noticing: the
/// argument list, the one environment variable it steers, and the directory it runs in.
///
/// A value rather than a call, so the whole shape can be asserted (tests/earlystart) without a
/// process ever being started. The store hands it straight to `CLIRunner.run`.
struct EarlyStartInvocation: Equatable {
    var arguments: [String]
    /// Overlay on the app's environment. A nil VALUE means the variable is REMOVED (see
    /// `EarlyStartCommand.environment`).
    var environment: [String: String?]
    var currentDirectory: URL
    var timeout: TimeInterval
}

/// What "open this account's window" actually runs.
///
/// One short prompt through the provider's own CLI, which is the only way Tally ever reaches a
/// vendor: the CLI carries its own first-party identity and refreshes its own token, and no
/// credential passes through this app. The reply is discarded unread - what the run is FOR is the
/// fact that a message was sent, which is the event Anthropic starts the 5-hour window on.
enum EarlyStartCommand {
    /// The message. Deliberately trivial and deliberately not a question: the point is to spend the
    /// smallest turn that counts as the window's first message.
    ///
    /// It names the reply it wants because the reply is thrown away unread, so every word past the
    /// first is quota spent on nothing. A greeting invites a greeting back plus an offer to help;
    /// asking for one word gets one word. This is politeness about somebody's quota rather than a
    /// correctness requirement: the window opens on the message being SENT, so the run counts as a
    /// success however the model chooses to answer.
    static let prompt = "Reply with exactly: pong"

    /// The config-home variable for Claude. The same spelling `IntegrationsStore.Shim.claude.envKey`
    /// and `ClaudeUsageCLI` use; written out here because this file compiles alone (both of those
    /// live in types that do not).
    static let configHomeKey = "CLAUDE_CONFIG_DIR"

    /// Long enough that a cold CLI start on a busy machine still lands, short enough that a wedged
    /// one is terminated the same morning it started. `CLIRunner.run`'s watchdog sends SIGTERM at
    /// this point and the pipes are drained either way.
    static let timeout: TimeInterval = 120

    /// A neutral working directory of Tally's own, and this is a safety property rather than
    /// tidiness. A `claude -p` run adopts the hooks, settings and CLAUDE.md of the directory it is
    /// started in, so a run started inside a repository would be steered by whatever that
    /// repository tells Claude Code to do - measured on this very repo, where a Stop hook took over
    /// an unrelated `-p` run and spent quota on it (memory: tally-no-cli-behavioural-tests-via-p).
    /// `~/.tally/early-start` contains nothing and never will.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tally/early-start", isDirectory: true)
    }

    /// The argument list, and why each flag is on it.
    ///
    /// `--strict-mcp-config` is the house rule for every spawned `claude` and is not negotiable: a
    /// child that inherits the host's MCP config can start an MCP server that itself spawns
    /// `claude`, which is an unbounded fork (see ~/.claude/skills/spawn-claude-isolation). The
    /// usage probe carries it for the same reason.
    ///
    /// `--safe-mode` starts the session with the machine's customizations off (CLAUDE.md, skills,
    /// plugins, hooks, MCP servers, commands, agents) while auth, model selection and permissions
    /// keep working. It is what keeps this run to the one short turn it promises: the neutral
    /// directory above already puts project hooks out of reach, but USER-level hooks in
    /// `~/.claude/settings.json` apply to every run from everywhere, and a Stop hook that hands the
    /// session more work turns "one message" into an agent loop on somebody's quota.
    ///
    /// `--no-session-persistence` (print mode only) means the run leaves no transcript behind, so
    /// nothing accumulates one file per account per morning for the life of the install. The usage
    /// probe, which predates the flag, prunes its own instead.
    ///
    /// `--model haiku` pins the run to the cheapest tier, and leaving it off is the expensive
    /// mistake this list exists to prevent. Without it the CLI takes whatever model that config
    /// home defaults to, which on most of these accounts is the flagship, so a throwaway greeting
    /// would be billed against the one window the account most wants kept whole. Nothing about the
    /// 5-hour window depends on which model answers: it opens on the first message being sent, so
    /// the cheapest tier buys exactly the same thing the flagship would.
    ///
    /// The alias rather than a full model ID (`claude-haiku-4-5` and the like) on purpose: an alias
    /// follows the newest model of that tier, while a pinned ID ages into a name the CLI no longer
    /// resolves, and this argument list runs unattended every morning with nobody reading its exit
    /// code. `--help` documents the aliases as the supported spelling (2.1.241).
    ///
    /// `--bare` was the obvious candidate and is unusable: it reads auth strictly from
    /// ANTHROPIC_API_KEY or an apiKeyHelper and never touches OAuth or the keychain, which is
    /// exactly the credential this feature has to spend (verified against 2.1.241's own help text).
    ///
    /// Every flag here was confirmed to PARSE rather than merely to appear in `--help`: run with a
    /// nonsense flag appended, 2.1.241 names only the nonsense one, and misspelling any of these
    /// makes it name that one instead. `--help` alone proves nothing here, because it prints and
    /// exits before options are validated (the mistake `RenewLoginCommand` records).
    static let arguments: [String] = [
        "-p", prompt, "--strict-mcp-config", "--safe-mode", "--no-session-persistence",
        "--model", "haiku",
    ]

    /// The one environment entry, with the default-home rule the whole app shares: `~/.claude` runs
    /// with the variable UNSET, because the CLI namespaces its keychain item by the exact variable
    /// string and spelling out the default path makes it look up an item that does not exist.
    /// Removing it also beats an export inherited from the user's own shell profile, which would
    /// otherwise send the message from a different account than the one the row names.
    ///
    /// Shared with the renewal path rather than spelled a second time: this is the third surface to
    /// need the rule and the first two got it wrong once each.
    static func environment(home: String,
                            userHome: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [String: String?] {
        RenewLoginCommand.environment(envKey: configHomeKey, home: home,
                                      providerID: EarlyStartLogic.providerID, userHome: userHome)
    }

    /// The whole spawn as one value.
    static func invocation(home: String,
                           userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                           directory: URL? = nil) -> EarlyStartInvocation {
        EarlyStartInvocation(arguments: arguments,
                             environment: environment(home: home, userHome: userHome),
                             currentDirectory: directory ?? Self.directory,
                             timeout: timeout)
    }
}
