import Foundation

// What one message actually IS (Tally/Core/EarlyStartCommand.swift), the gate that decides whether
// any of it may run at all, and the sentences the feature shows.
//
// Nothing here starts a process. The spawn is a value, so the flags, the config-home variable and
// the working directory are asserted exactly, and the fake runner checks a whole fleet's worth of
// them at once. The readiness gate and the string catalogue are read out of their own sources: the
// store is @MainActor AppKit and cannot be compiled into this harness, and a hand-kept list of
// strings only ever checks the ones somebody remembered to add to it.

func runSpawnChecks() {
    /// Whether an option and its value stand next to each other. Asking `contains` about each word on
    /// its own would pass a list that names the option and hands it somebody else's value.
    func pins(_ arguments: [String], _ option: String, _ value: String) -> Bool {
        zip(arguments, arguments.dropFirst()).contains { $0 == option && $1 == value }
    }

    // 19. THE SPAWN'S SHAPE. Asserted exactly rather than by "contains", so a flag that goes missing
    //     goes red instead of being covered by the ones that remain.
    do {
        expect(EarlyStartCommand.arguments
                 == ["-p", "Reply with exactly: pong", "--strict-mcp-config", "--safe-mode",
                     "--no-session-persistence", "--model", "haiku"],
               "the argument list is exactly the seven words it is meant to be")
        expect(EarlyStartCommand.arguments.contains("--strict-mcp-config"),
               "…and carries the MCP isolation flag, which is the one that is not negotiable")
        // Pinning the tier is the difference between a throwaway greeting costing the cheapest model
        // and costing the flagship window: with no --model the CLI falls back to whatever that config
        // home defaults to, which on most accounts is the flagship. The window itself opens on the
        // message being sent, not on which model answers. It matters more under a relay than it did
        // under a morning schedule, because there are more of these messages now.
        expect(pins(EarlyStartCommand.arguments, "--model", "haiku"),
               "the cheapest model tier is pinned, and by alias so it survives a model generation")
        expect(EarlyStartCommand.prompt.count <= 32, "the prompt stays short")
        expect(EarlyStartCommand.timeout == 120, "a wedged CLI is terminated within the hour it started")

        let directory = EarlyStartCommand.directory.standardizedFileURL.path
        expect(directory.hasSuffix("/.tally/early-start"),
               "the run happens in Tally's own scratch directory")
        // The reason that directory exists at all: a `claude -p` started inside a repository adopts
        // that repository's hooks and instructions.
        expect(!directory.contains("/workspace/"),
               "…which is not inside any repository")
    }

    // 20. THE CONFIG HOME, which is the one thing that decides WHICH account a message is sent from.
    do {
        let userHome = URL(fileURLWithPath: "/Users/tester")

        let second = EarlyStartCommand.environment(home: "/Users/tester/.claude2", userHome: userHome)
        expect(second["CLAUDE_CONFIG_DIR"] == .some("/Users/tester/.claude2"),
               "a numbered home is passed in CLAUDE_CONFIG_DIR")
        expect(second.count == 1, "…and nothing else is added to the environment")

        // The default home runs with the variable REMOVED, not set to its own path: the CLI namespaces
        // its keychain item by the exact variable string, so spelling out the default makes it look up
        // an item that does not exist. A key present with a nil value is what CLIRunner reads as
        // "remove this"; a missing key would leave whatever the user's shell profile exported.
        let main = EarlyStartCommand.environment(home: "/Users/tester/.claude", userHome: userHome)
        expect(main.keys.contains("CLAUDE_CONFIG_DIR"),
               "the default home still names the variable")
        expect(main["CLAUDE_CONFIG_DIR"] == .some(nil),
               "…with a nil value, which is how it gets UNSET rather than left inherited")

        let trailing = EarlyStartCommand.environment(home: "/Users/tester/./.claude/",
                                                     userHome: userHome)
        expect(trailing["CLAUDE_CONFIG_DIR"] == .some(nil),
               "the default home is recognised through a non-standardized spelling of it")
    }

    // 21. THE WHOLE FLEET THROUGH A FAKE RUNNER. It stands in for CLIRunner: every invocation an
    //     evaluation would have made, recorded instead of spawned.
    final class FakeProcessRunner {
        struct Call: Equatable {
            var accountID: String
            var invocation: EarlyStartInvocation
        }
        private(set) var calls: [Call] = []
        func run(_ account: EarlyStartCandidate, _ invocation: EarlyStartInvocation) {
            calls.append(Call(accountID: account.accountID, invocation: invocation))
        }
    }

    do {
        let now = at("2026-08-24 09:00")
        let userHome = URL(fileURLWithPath: "/Users/tester")
        let scratch = userHome.appendingPathComponent(".tally/early-start", isDirectory: true)
        let fleet = [
            candidate("claude:.claude", home: "/Users/tester/.claude"),
            candidate("claude:.claude2", home: "/Users/tester/.claude2"),
            candidate("claude:.claude3", home: "/Users/tester/.claude3", windowOpen: true),
            candidate("codex:.codex", provider: "codex", home: "/Users/tester/.codex"),
        ]
        let plan = EarlyStartLogic.plan(candidates: fleet, state: EarlyStartState(), quietHours: loud,
                                        now: now, calendar: taipei)
        let runner = FakeProcessRunner()
        for account in plan.start {
            runner.run(account, EarlyStartCommand.invocation(home: account.home ?? "",
                                                             userHome: userHome, directory: scratch))
        }

        expect(runner.calls.map(\.accountID) == ["claude:.claude", "claude:.claude2"],
               "the busy Claude account and the Codex one are never spawned for")
        expect(runner.calls.allSatisfy { $0.invocation.arguments.contains("--strict-mcp-config") },
               "every spawn carries --strict-mcp-config")
        expect(runner.calls.allSatisfy { pins($0.invocation.arguments, "--model", "haiku") },
               "every spawn is pinned to the cheapest model tier, whichever account it is for")
        expect(runner.calls.allSatisfy { $0.invocation.currentDirectory == scratch },
               "every spawn runs in the scratch directory")
        expect(runner.calls.allSatisfy { $0.invocation.timeout == 120 },
               "every spawn carries the same timeout")
        expect(runner.calls.first?.invocation.environment["CLAUDE_CONFIG_DIR"] == .some(nil),
               "the default account's spawn unsets CLAUDE_CONFIG_DIR")
        expect(runner.calls.last?.invocation.environment["CLAUDE_CONFIG_DIR"]
                 == .some("/Users/tester/.claude2"),
               "the second account's spawn names its own home")
        // Two accounts, two different homes: the whole point is that they are not the same message
        // sent twice from one account.
        expect(Set(runner.calls.compactMap { $0.invocation.environment["CLAUDE_CONFIG_DIR"] ?? nil })
                 .count == 1,
               "…and only one of the two spells a home at all (the other is the unset default)")
        expect(runner.calls.count == 2, "one spawn per account started, and no more")

        // And inside quiet hours, the same fleet produces no spawn at all.
        let asleep = EarlyStartLogic.plan(
            candidates: fleet, state: EarlyStartState(),
            quietHours: EarlyStartQuietHours(isEnabled: true, startHour: 23, startMinute: 0,
                                             endHour: 7, endMinute: 0),
            now: at("2026-08-24 03:00"), calendar: taipei)
        expect(asleep.start.isEmpty, "the same fleet at 3am with quiet hours on spawns nothing")
    }

    // 22. THE READINESS GATE, wired rather than merely present, and the answers coming back from a
    //     batch. The store is @MainActor AppKit and cannot be compiled into this harness, so both
    //     are read from its source: the launch-time Keychain repair
    //     rewrites the credentials the `claude` CLI reads, and AppDelegate ordering only holds back the
    //     ONE entrance that goes through `start()`. The notice's button, the Settings switch and the
    //     quiet-hours pickers all reach the schedule without it, so each live path carries the flag.
    //     Both halves are needed - a flag nobody reads, or a read with nothing that ever opens it, is
    //     the defect back with a nicer shape.
    do {
        let store = (try? String(contentsOfFile: "Tally/Stores/EarlyStartStore.swift",
                                 encoding: .utf8)) ?? ""
        expect(!store.isEmpty, "the store's source is readable from these checks")
        expect(store.contains("private var started = false"),
               "the store starts out not ready")
        expect(store.components(separatedBy: "started = true").count - 1 == 1,
               "…and exactly one place opens the gate")
        expect(store.contains("""
            func start() {
                    started = true
            """),
               "…which is start(), the call AppDelegate makes behind the repair")

        expect(store.contains("guard started, Self.mayRun, isArmed, !isRunning else { return }"),
               "a refresh landing inside the repair window sends nothing (evaluate)")
        expect(store.contains("guard started, Self.mayRun, isArmed else { return }"),
               "a nudge inside it asks for no refresh either")
        expect(store.contains("guard started, Self.mayRun, isArmed,\n"),
               "and no timer is armed before the repair is done (scheduleTimer)")
        expect(store.components(separatedBy: "guard started").count - 1 == 3,
               "…which is every live path there is: the other entrances all end at one of these three")

        // NOTHING BUT AN EVALUATION MAY WRITE THIS STATE, and that is what carries the cost floor
        // across the Settings switch. The marks are the whole record of "this account has had its
        // message inside the last five hours"; the switch used to clear them and hand the
        // suppression to a stamp that no longer exists, so a preference path that writes state again
        // would give back the guarantee the panel notice and the Settings row both state in words.
        // Read from the source because the store cannot be compiled here, and asserted on both the
        // low-level writer and the one function that calls it, since either alone leaves a way in.
        expect(store.components(separatedBy: "Self.saveState(").count - 1 == 1,
               "exactly one place puts this state on disk")
        expect(store.contains("""
            private func apply(_ state: EarlyStartState) {
                    Self.saveState(state)
            """),
               "…which is apply(), the one publisher the two folds go through")
        expect(store.components(separatedBy: "apply(").count - 1 == 3,
               "…and its only callers are those two folds: nothing a preference does reaches it")

        // THE ANSWERS ALWAYS COME BACK, read from the same source and for the same reason: the day's
        // two account lists are cleared by `correcting` and by nothing else, so a spawn task that
        // returns early when nothing failed leaves every account it just served on "could not
        // start" until midnight. The batch that goes through entirely is the one this store used to
        // say nothing about, and it is the ordinary case.
        //
        // READ AS A SPAN, not as two string matches. The first version of this lock asked whether
        // the call EXISTS and whether one early return does not, and a review of it put the bug
        // back twice under that green light: wrapping the call in `if !failures.isEmpty` and
        // writing the exit as `if failures.isEmpty { return }` both pass those two. What matters is
        // whether the batch REACHES the call, so what is read is the stretch of code between the
        // answers arriving and the hand-off.
        //
        // THIS IS A TEXT-LAYER HEURISTIC AND IS NAMED AS ONE. It reads Swift as lines rather than
        // as a program, so what it can hold is the shape of THIS function: shapes it cannot see
        // include the hand-off moved into a method of its own and called conditionally, a condition
        // hidden inside `correct` or inside `correcting`, and an `#if` that compiles the call out.
        // The durable oracle for all of those is behaviour coverage of the store, which nothing in
        // this repo compiles today (it is @MainActor AppKit); that gap is tracked as deferred work
        // rather than papered over here.
        var answerPath: String?
        if let answered = store.range(of: "let failures = await Self.send"),
           let handedOver = store.range(of: "self.correct(attempted:"),
           answered.upperBound <= handedOver.lowerBound {
            answerPath = String(store[answered.upperBound..<handedOver.lowerBound])
        }
        expect(answerPath != nil,
               "the stretch from the spawns answering to the tally hearing about it can be read")
        // Whole-line comments are dropped first: prose is where the words below appear innocently,
        // and a sentence explaining the rule must not be able to break it. A breach parked after
        // code on a line of its own trailing comment is one more thing this cannot see.
        // An unreadable span falls back to a string that fails every check below rather than to "",
        // which would pass them all: a lock that cannot find its subject must read as broken.
        let answerCode = (answerPath ?? "if failures.isEmpty { return }\nreturn")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
        expect(answerCode.components(separatedBy: "return").count - 1 == 1,
               "…and exactly one return stands in it: the weak self guard, and no exit for a batch")
        expect(!answerCode.contains("if failures") && !answerCode.contains("if !failures"),
               "…with the failure list branching nothing on its way: success is carried back too")
        expect(store.contains("self.correct(attempted: ids, failed: failures,"),
               "…and both halves of the answer go with it: who was tried, and who failed")
    }

    // 23. EVERY WORD THIS FEATURE SHOWS IS IN THE CATALOGUE, in all four translations. The keys are
    //     pulled OUT OF THE SOURCE rather than listed here: a hand-kept list checks the sentences
    //     somebody remembered to add to it, and the sentence that reaches a Japanese machine in English
    //     is always the one nobody remembered. Tally ships five languages, and a missing translation is
    //     invisible until somebody sees it.
    func localizedKeys(in source: String) -> [String] {
        var keys: [String] = []
        var rest = Substring(source)
        while let open = rest.range(of: "L(\"") {
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "\")") else { break }
            keys.append(String(rest[..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return keys
    }

    do {
        let catalogue = (try? Data(contentsOf: URL(fileURLWithPath:
            "Tally/Resources/Localizable.xcstrings")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let entries = catalogue?["strings"] as? [String: Any] ?? [:]
        expect(!entries.isEmpty, "the string catalogue is readable from this suite")

        var keys: [String] = []
        for path in ["Tally/Views/SettingsEarlyStartRow.swift",
                     "Tally/Views/EarlyStartNoticeStrip.swift"] {
            let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            expect(!source.isEmpty, "\(path) is readable from this suite")
            // The repo bans the em dash outright, English included, as an AI tell (Tally/CLAUDE.md).
            expect(!source.contains("—"), "\(path) carries no em dash")
            keys.append(contentsOf: localizedKeys(in: source))
        }
        // A guard on the guard: an extractor that finds nothing would pass every check below in
        // silence, which is the shape this whole section exists to prevent.
        expect(keys.count >= 12, "the extractor found this feature's strings (\(keys.count) of them)")

        for key in Set(keys) {
            let entry = entries[key] as? [String: Any]
            let localizations = entry?["localizations"] as? [String: Any] ?? [:]
            expect(["zh-Hant", "zh-Hans", "ja", "ko"].allSatisfy { localizations[$0] != nil },
                   "\"\(key.prefix(34))\" is translated into every language Tally ships")
        }

        // The morning schedule's sentences are GONE, not merely unused. A stale entry promising "each
        // morning at 07:00" is a translated, ready-to-ship description of a schedule that no longer
        // exists, one careless `L()` away from being shown again.
        for retired in ["Has not run yet.",
                        "Last run %1$@: %2$d started, %3$d skipped.",
                        "Opens each Claude account's 5-hour window in the morning, so it resets earlier in your day. Tally sends one short message per account and skips any account whose window is already open."] {
            expect(entries[retired] == nil,
                   "the morning schedule's \"\(retired.prefix(28))\" is out of the catalogue")
        }
    }
}
