import Foundation

// B-4530: a login that lands in the WRONG account's name must not be accepted. The command side
// (the `--email` hint, in the right place and quoted for a real shell), the verdict's truth table,
// and then the whole landing replayed against stub CLIs that write a `.claude.json` of their own:
// the background path (the real runner on a pty) and the Terminal path (the very command line the
// fallback hands a shell), each once with the wrong account, once with the right one, and the
// late-write case where `oauthAccount` arrives after the login reported success.

typealias Who = RenewalIdentity.Who

private let expectedEmail = "o'neil+2@example.com"   // a quote and a plus: both must survive a shell
private let expectedWho = Who(email: expectedEmail, uuid: "uuid-2")

private func readState(_ home: URL) -> RenewalIdentity.Reading {
    let url = home.appendingPathComponent(".claude.json")
    let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let account = object["oauthAccount"] as? [String: Any] else { return (nil, modified) }
    return (Who(email: account["emailAddress"] as? String, uuid: account["accountUuid"] as? String), modified)
}

private func stateJSON(_ email: String, _ uuid: String) -> String {
    "{\"oauthAccount\":{\"emailAddress\":\"\(email)\",\"accountUuid\":\"\(uuid)\"}}"
}

private enum Write { case now, late, never }

/// The reader closure is `@Sendable`, so a plain captured counter would not compile.
private final class ReadCount: @unchecked Sendable {
    private(set) var value = 0
    func bump() { value += 1 }
}

func identityChecks(expect: (Bool, String) -> Void, root: URL, storeSource: String) async {
    // MARK: command

    let hint = "o'neil+2@example.com"
    expect(RenewLoginCommand.plan(providerID: "claude", loginHint: hint)?.arguments
               == ["--strict-mcp-config", "auth", "login", "--email", hint],
           "the hint is `--email <address>` AFTER `login`, where the subcommand parses it")
    expect(RenewLoginCommand.plan(providerID: "claude")?.arguments == ["--strict-mcp-config", "auth", "login"]
               && RenewLoginCommand.plan(providerID: "claude", loginHint: "")?.arguments
               == ["--strict-mcp-config", "auth", "login"]
               && RenewLoginCommand.plan(providerID: "codex", loginHint: hint)?.arguments == ["login"],
           "no hint (or an empty one, or Codex) leaves the command exactly as it was")

    // MARK: verdict truth table

    typealias V = RenewalIdentity.Verdict
    let a = Who(email: "A@x.com", uuid: "u1")
    expect(RenewalIdentity.verdict(expected: a, landed: Who(email: "other@x.com", uuid: "u1")) == .match,
           "same account uuid is a match even when the address changed")
    expect(RenewalIdentity.verdict(expected: a, landed: Who(email: "a@x.com", uuid: "u2"))
               == V.mismatch(signedIn: "a@x.com"),
           "a different uuid is a mismatch even under the same address: uuid decides first")
    expect(RenewalIdentity.verdict(expected: Who(email: "A@x.com", uuid: nil),
                                   landed: Who(email: "a@X.com", uuid: "u9")) == .match,
           "without a uuid on both sides the address decides, case-insensitively")
    expect(RenewalIdentity.verdict(expected: Who(email: "a@x.com", uuid: nil),
                                   landed: Who(email: "b@x.com", uuid: nil)) == V.mismatch(signedIn: "b@x.com"),
           "a different address with no uuid is a mismatch, naming who landed")
    expect(RenewalIdentity.verdict(expected: nil, landed: Who(email: "b@x.com", uuid: "u")) == .match
               && RenewalIdentity.verdict(expected: Who(), landed: nil) == .match,
           "a home nobody had named accepts any login")
    expect(RenewalIdentity.verdict(expected: a, landed: nil) == .unconfirmed
               && RenewalIdentity.verdict(expected: a, landed: Who()) == .unconfirmed,
           "a home that will not say who is in it is unconfirmed, not a match and not a mismatch")
    expect(RenewalIdentity.verdict(expected: Who(email: nil, uuid: "u1"), landed: Who(email: "a@x.com", uuid: nil))
               == .unconfirmed,
           "two sides sharing no field cannot be compared")
    let after = Who(email: "wrong@x.com", uuid: "u-wrong")
    expect(RenewalIdentity.expectedIdentity(remembered: "right@x.com", profile: after)
               == Who(email: "right@x.com", uuid: nil)
               && RenewalIdentity.expectedIdentity(remembered: "RIGHT@x.com",
                                                   profile: Who(email: "right@x.com", uuid: "u1"))
               == Who(email: "RIGHT@x.com", uuid: "u1")
               && RenewalIdentity.expectedIdentity(remembered: nil, profile: after) == after
               && RenewalIdentity.expectedIdentity(remembered: nil, profile: Who()) == nil,
           "the remembered address outranks a home that has since taken another login; its uuid only rides along when it is the same address")

    // MARK: the landing, replayed against stub CLIs

    /// One home with the expected account already in it, and a stub that plays the CLI's side.
    func scenario(_ name: String, writes: Write, email: String, uuid: String)
        -> (home: URL, stub: String, before: Date?) {
        let dir = root.appendingPathComponent(name)
        let home = dir.appendingPathComponent(".claude4")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? stateJSON(expectedEmail, "uuid-2").write(to: home.appendingPathComponent(".claude.json"),
                                                      atomically: true, encoding: .utf8)
        let before = readState(home).modifiedAt
        usleep(60_000)   // the stub's write must be strictly newer than the seed
        let write = "printf '%s' \(RenewLoginCommand.shellQuoted(stateJSON(email, uuid))) > \"$CLAUDE_CONFIG_DIR/.claude.json\""
        let landing: String
        switch writes {
        case .now: landing = write
        // The credential is in, the profile follows a moment later from a process that outlives the
        // CLI (B-1702). Replayed on the shell path: the background one hangs up the pty the moment
        // the CLI ends, which takes a detached writer down with it (a harness artifact, not the CLI's).
        case .late:
            landing = "nohup sh -c \(RenewLoginCommand.shellQuoted("sleep 1.5; " + write)) </dev/null >/dev/null 2>&1 &"
        case .never: landing = ":"
        }
        let url = dir.appendingPathComponent("claude")
        try? ("""
        #!/bin/sh
        printf '%s\\n' "$@" > "$CLAUDE_CONFIG_DIR/argv"
        printf 'Opening browser to sign in\\n'
        printf 'Login successful. Press Enter to continue\\n'
        [ -t 0 ] && head -c 1 > /dev/null
        \(landing)
        exit 0
        """ + "\n").write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (home, url.path, before)
    }

    let plan = RenewLoginCommand.plan(providerID: "claude", loginHint: expectedEmail)!

    /// The background path: the real runner, on a pty, exactly as the store starts it.
    func background(_ s: (home: URL, stub: String, before: Date?)) async -> Bool {
        await RenewLoginRunner.run(executable: s.stub, plan: plan,
                                   environment: ["CLAUDE_CONFIG_DIR": s.home.path],
                                   handshakeIdleLimit: 3, overallLimit: 15) == .renewed
    }

    /// The Terminal path: the command line the fallback gives a shell, run by a shell.
    func terminal(_ s: (home: URL, stub: String, before: Date?)) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RenewLoginCommand.shellCommand(
            executable: s.stub, envKey: "CLAUDE_CONFIG_DIR", home: s.home.path, arguments: plan.arguments)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    func verdict(_ s: (home: URL, stub: String, before: Date?), attempts: Int = 30) async
        -> (V, TimeInterval) {
        let start = Date()
        let v = await RenewalIdentity.confirm(expected: expectedWho, before: s.before,
                                              attempts: attempts, interval: .milliseconds(100)) {
            readState(s.home)
        }
        return (v, Date().timeIntervalSince(start))
    }

    func argv(_ s: (home: URL, stub: String, before: Date?)) -> [String] {
        ((try? String(contentsOf: s.home.appendingPathComponent("argv"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    // The wrong account, both paths: the stub writes somebody else's identity.
    for path in ["background", "terminal"] {
        let s = scenario("wrong-\(path)", writes: .now, email: "albert4@example.com", uuid: "uuid-4")
        let ran = path == "background" ? await background(s) : terminal(s)
        let (v, _) = await verdict(s)
        expect(ran && argv(s) == plan.arguments,
               "\(path): the stub was started with the hint in the right place, through the real quoting")
        expect(v == V.mismatch(signedIn: "albert4@example.com"),
               "\(path): a login that lands as another account is a mismatch naming who landed")
    }

    // The right account, both paths: the stub rewrites the same identity.
    for path in ["background", "terminal"] {
        let s = scenario("right-\(path)", writes: .now, email: expectedEmail, uuid: "uuid-2")
        let ran = path == "background" ? await background(s) : terminal(s)
        let (v, _) = await verdict(s)
        expect(ran && v == .match, "\(path): the right account is a match")
    }

    // `oauthAccount` after the credential: the old identity is still in the file when the login
    // reports success. Reading once would answer for whoever was there before.
    do {
        let s = scenario("late-right", writes: .late, email: expectedEmail, uuid: "uuid-2")
        let ran = terminal(s)
        let (v, seconds) = await verdict(s)
        expect(ran && v == .match && seconds >= 1.0 && seconds < 2.5,
               "a profile written 1.5s after the login is waited for and judged a match on the write itself, not on running out of attempts (\(String(format: "%.1f", seconds))s)")
    }
    do {
        let s = scenario("late-wrong", writes: .late, email: "albert4@example.com", uuid: "uuid-4")
        let ran = terminal(s)
        let (v, seconds) = await verdict(s)
        expect(ran && v == V.mismatch(signedIn: "albert4@example.com") && seconds >= 1.0 && seconds < 2.5,
               "the stale old identity is NOT taken for a match while the new one is still on its way (\(String(format: "%.1f", seconds))s)")
    }
    do {
        let s = scenario("never", writes: .never, email: "", uuid: "")
        try? FileManager.default.removeItem(at: s.home.appendingPathComponent(".claude.json"))
        let ran = await background(s)
        let (v, _) = await verdict(s, attempts: 3)
        expect(ran && v == .unconfirmed, "a home that never says who landed is unconfirmed")
    }

    // A retry after a WRONG login: Tally remembers account A, the home's file still names B (the
    // account that landed last time) and has not been rewritten yet. Expected is A, so a read of B
    // disagrees with it, but it is the file's own stale answer, not a new login.
    do {
        let wrongB = Who(email: "b@example.com", uuid: "uuid-B")
        let rememberedA = Who(email: "a@example.com", uuid: nil)
        let home = root.appendingPathComponent("retry-after-wrong").appendingPathComponent(".claude4")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let state = home.appendingPathComponent(".claude.json")
        try? stateJSON("b@example.com", "uuid-B").write(to: state, atomically: true, encoding: .utf8)
        let before = readState(home).modifiedAt
        let profileBefore = readState(home).who
        expect(profileBefore == wrongB, "the retry's home starts out holding the account that landed last time")
        usleep(60_000)   // the late write must be strictly newer than the seed
        Task.detached {   // the CLI's late profile write, as in the .late scenario
            try? await Task.sleep(for: .milliseconds(800))
            try? stateJSON("a@example.com", "uuid-A").write(to: state, atomically: true, encoding: .utf8)
        }
        let start = Date()
        let v = await RenewalIdentity.confirm(expected: rememberedA, before: before, profileBefore: profileBefore,
                                              attempts: 30, interval: .milliseconds(100)) { readState(home) }
        let seconds = Date().timeIntervalSince(start)
        expect(v == .match && seconds >= 0.7 && seconds < 2.5,
               "a retry waits out the file's stale answer and judges the profile that is written later (\(String(format: "%.1f", seconds))s)")

        // Nothing is ever written: out of attempts the stale answer stands, and it is a mismatch.
        let still = await RenewalIdentity.confirm(expected: rememberedA, before: before, profileBefore: profileBefore,
                                                  attempts: 3, interval: .milliseconds(50)) {
            (wrongB, before)   // the same identity and the same time as before the login
        }
        expect(still == V.mismatch(signedIn: "b@example.com"),
               "a profile that is never rewritten is still judged, after the wait, as the account it holds")

        // A genuinely different account landing is not stale and is refused at the first read.
        let reads = ReadCount()
        let other = await RenewalIdentity.confirm(expected: rememberedA, before: before, profileBefore: profileBefore,
                                                  attempts: 10, interval: .milliseconds(50)) {
            reads.bump()
            return (Who(email: "c@example.com", uuid: "uuid-C"), before)
        }
        expect(other == V.mismatch(signedIn: "c@example.com") && reads.value == 1,
               "a third account landing over the stale one is a mismatch on the first read")
    }

    // MARK: the store's order

    // The store's order is the rule: the landing is judged BEFORE any success effect, on both paths,
    // and a handed-off login that matches is the one that retires the account's session marks.
    if let body = functionBody(storeSource, from: "func renew(accountID: String,") {
        if let judged = body.range(of: "RenewalIdentity.confirm("),
           let cooled = body.range(of: "cooldown.succeeded"),
           let settled = body.range(of: "beginSettling(accountID)"),
           let refused = body.range(of: "guard landing == .match else"),
           let retired = body.range(of: "retireSessions"),
           let onboarded = body.range(of: "markClaudeOnboardingComplete(providerID: providerID, home: home)") {
            expect(judged.lowerBound < cooled.lowerBound && judged.lowerBound < settled.lowerBound
                    && refused.lowerBound < retired.lowerBound && refused.lowerBound < onboarded.lowerBound,
                   "background: the landing is judged before cooldown, settling, retirement and the onboarding note")
        } else {
            expect(false, "background: the landing check and every success effect are in renew")
        }
        expect(body.contains("if case .renewed = outcome, landing == .match {"),
               "background: only a landing that matches earns the cooldown and the settling window")
        expect(body.contains("loginHint: expected?.email"), "the login is asked for the account it is meant for")
    } else {
        expect(false, "the store's renew(accountID:providerID:label:home:) is readable from the suite")
    }
    if let body = functionBody(storeSource, from: "private func handOff(") {
        if let judged = body.range(of: "RenewalIdentity.confirm("),
           let retired = body.range(of: "retireSessions"),
           let refused = body.range(of: "announceUnmatched(") {
            expect(judged.lowerBound < retired.lowerBound && judged.lowerBound < refused.lowerBound
                    && body.contains("if verdict == .match"),
                   "terminal: a landing that matches retires the session marks, one that does not says so first")
        } else {
            expect(false, "terminal: handOff judges the landing and retires the marks")
        }
    } else {
        expect(false, "the store's handOff is readable from the suite")
    }
    // A wrong login keeps the address the home was meant for (B-4530), so the next attempt asks for
    // that one: held on a mismatch, released only by a match, and read back from the held address.
    expect(functionBody(storeSource, from: "private func announceUnmatched(").map {
        guard let held = $0.range(of: "holdIdentity("), let refreshed = $0.range(of: "refresh(userInitiated: true)")
        else { return false }
        return held.lowerBound < refreshed.lowerBound
    } == true, "a mismatch holds the original address before the refresh that would read the wrong one")
    expect((functionBody(storeSource, from: "func renew(accountID: String,")?.contains("releaseIdentity(accountID: accountID)") ?? false)
               && (functionBody(storeSource, from: "private func handOff(")?.contains("releaseIdentity(accountID: accountID)") ?? false),
           "a landing that matches releases the held address on both paths")
    expect(storeSource.contains("LoginStatusStore.shared.expectedEmail(accountID)")
               && !storeSource.contains("remembered: LoginStatusStore.shared.rememberedEmail(accountID)"),
           "the next attempt is held to the held address, not to whatever the memory was refreshed to")
    expect(storeSource.contains("profileBefore: profileBefore"),
           "the landing check is told what the file said before the login, apart from who was expected")
    expect(functionBody(storeSource, from: "func keepSignedInAccount(") .map {
        $0.contains("adoptIdentity") && $0.contains("loginRenewed")
    } == true, "only the explicit keep press changes what Tally remembers about the home")
}
