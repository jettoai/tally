import Foundation

// The launch plumbing `tally claude` runs THROUGH once an account has been picked: whether the
// start-mode default is injectable in this directory (TallyCLI/ResumePrompt.swift), and what a
// manual pin resolves to (AccountPick.swift). Split from main.swift for file size; the assertion
// helper and the account fixtures are shared from there, the way the supervisor suite splits.
//
// Neither is burn-rate scoring, which is what main.swift is about - the seam is "which account"
// versus "launched how".

/// The policy the start-mode checks run under. File scope because the helper below names it as a
/// default argument, which a value local to the function could not be.
private let continuePolicy: LaunchPolicy = {
    var policy = LaunchPolicy()
    policy.startMode = "continue"
    return policy
}()

func runLaunchChecks() {
    // MARK: - Start mode: `--continue` is only injected where claude could resolve it
    //
    // `claude --continue` in a directory the launch home has never held a session for prints "No
    // conversation found to continue" and exits, so a first launch in a new project directory used to
    // die on tally's own injected flag.
    let startModeRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-startmode-\(UUID().uuidString)")
    let withSession = startModeRoot.appendingPathComponent("home-used")
    let withoutSession = startModeRoot.appendingPathComponent("home-fresh")
    let workingDir = startModeRoot.appendingPathComponent("project")
    try? FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: withoutSession, withIntermediateDirectories: true)
    let sessionDir = withSession
        .appendingPathComponent("projects/\(projectSlug(forCwd: workingDir.path))")
    try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    try? "{}".write(to: sessionDir.appendingPathComponent("abc.jsonl"), atomically: true, encoding: .utf8)

    func startMode(_ args: [String], home: URL, policy: LaunchPolicy = continuePolicy,
                   wantsNew: Bool = false) -> (args: [String], note: String?) {
        applyStartMode(args, policy: policy, wantsNew: wantsNew, home: home.path, cwd: workingDir.path)
    }

    check("this home has a transcript for the directory", hasConversation(home: withSession.path,
                                                                         cwd: workingDir.path))
    check("a home that has never run here has none", !hasConversation(home: withoutSession.path,
                                                                      cwd: workingDir.path))
    let used = startMode([], home: withSession)
    check("a directory with a session keeps the injected continue", used.args == ["--continue"])
    check("and says nothing about it", used.note == nil)
    let fresh = startMode([], home: withoutSession)
    check("a directory with no session suppresses the injection", fresh.args.isEmpty)
    check("and says so once", fresh.note == "no conversation in this directory yet - starting fresh")
    // A missing home is the same situation as an empty one, not a crash.
    check("a home that does not exist suppresses it too",
          startMode([], home: startModeRoot.appendingPathComponent("absent")).args.isEmpty)
    // The transcript check is per launch home: another account having the conversation does not let
    // claude find it, so the prediction stays exact.
    check("a sibling home's transcript does not count",
          !hasConversation(home: withoutSession.path, cwd: workingDir.path))

    // A hand-typed flag is the user's own choice: never removed, never doubled, and never explained
    // away with our note (they get the CLI's own error if it cannot be resolved).
    let typed = startMode(["--continue"], home: withoutSession)
    check("a hand-typed --continue survives in a fresh directory", typed.args == ["--continue"])
    check("and is not commented on", typed.note == nil)
    check("a hand-typed --resume is left alone",
          startMode(["--resume", "abc"], home: withoutSession).args == ["--resume", "abc"])
    check("a hand-typed -c is not doubled",
          startMode(["-c"], home: withSession).args == ["-c"])
    check("--print is not a session to continue",
          startMode(["-p", "hi"], home: withSession).args == ["-p", "hi"])
    // The other two ways to say no, unchanged by the transcript check.
    check("--new (wantsNew) still suppresses the injection",
          startMode([], home: withSession, wantsNew: true).args.isEmpty)
    check("a policy that does not continue injects nothing",
          startMode([], home: withSession, policy: LaunchPolicy()).args.isEmpty)

    // Injection lands where the flag will be READ: before the first `--`, never appended after the
    // prompt. Appended, claude would never parse it (past the marker it is prompt text) and Tally could
    // not see it either, so the launch would run without the default it believed it had applied.
    check("an injected --continue goes in front of the prompt",
          startMode(["--", "summarise this"], home: withSession).args
          == ["--continue", "--", "summarise this"])
    check("and the prompt itself is untouched",
          startMode(["--", "--continue"], home: withSession).args
          == ["--continue", "--", "--continue"])
    // Which is also why the suppression check reads only the options: a prompt that mentions the flag
    // is not the user choosing it.
    check("a session flag inside the prompt does not suppress the injection",
          startMode(["--", "-p", "hi"], home: withSession).args == ["--continue", "--", "-p", "hi"])
    check("with no marker the injection still simply appends",
          startMode(["--verbose"], home: withSession).args == ["--verbose", "--continue"])

    // The two helpers on their own, including the no-marker case that must stay a plain append.
    check("injecting with no marker appends",
          injectingOptions(["--verbose"], ["--model", "fable"]) == ["--verbose", "--model", "fable"])
    check("injecting with a marker goes before it",
          injectingOptions(["--verbose", "--", "hi"], ["--model", "fable"])
          == ["--verbose", "--model", "fable", "--", "hi"])
    check("injecting into a bare prompt still precedes it",
          injectingOptions(["--", "hi"], ["--model", "fable"]) == ["--model", "fable", "--", "hi"])
    check("removing an own flag leaves the prompt alone",
          removingOption(["--new", "--", "--new"], "--new") == ["--", "--new"])
    check("and removes every copy before the marker",
          removingOption(["--new", "-x", "--new"], "--new") == ["-x"])
    try? FileManager.default.removeItem(at: startModeRoot)

    // MARK: - Resolving a manual pin (AccountPick.swift)

    // A pin carries two things: the account id, and the launch home denormalized beside it so the pin
    // still works while its account is briefly missing from the snapshot. That fallback asks nothing
    // about the account, which is how a pin left behind on an account that later SIGNED OUT kept
    // exec'ing a logged-out config dir (2026-08-03): the app publishes a dormant account without a
    // launch home, and every other surface skipped it - only this one did not look.
    func manualPin(id: String?, home: String?) -> LaunchPolicy {
        LaunchPolicy(mode: "manual", pinnedAccountID: id, pinnedHome: home)
    }
    func snap(_ accounts: [Snapshot.Account]) -> Snapshot {
        Snapshot(version: 2, generatedAt: now, accounts: accounts)
    }
    let livePin = account("A", session: (50, inHours(2)), weekly: (60, inHours(48)))
    var dormantPin = livePin
    dormantPin.launchHome = nil   // exactly what the app publishes for a signed-out account
    let pinSibling = account("B", session: (90, inHours(2)), weekly: (95, inHours(48)))

    check("a live pin launches its account's own home",
          pinnedLaunchHome(snap([livePin, pinSibling]), policy: manualPin(id: "A", home: "/stale"))
              == "/tmp/A")
    // THE FIX. The snapshot listing the account WITHOUT a launch home is Tally saying the login is
    // gone; the saved home must not be exec'd behind that statement.
    check("a pin whose account signed out launches nothing",
          pinnedLaunchHome(snap([dormantPin, pinSibling]), policy: manualPin(id: "A", home: "/tmp/A"))
              == nil)
    check("…and that is recognised as signed out rather than as a missing account",
          pinnedAccountIsSignedOut(snap([dormantPin]), policy: manualPin(id: "A", home: "/tmp/A")))
    // The case the fallback was ADDED for stays: absent from the snapshot says only that Tally has not
    // seen the account this round (a refresh mid-flight, an app that has not run yet).
    check("a pin whose account is simply absent still launches by saved home",
          pinnedLaunchHome(snap([pinSibling]), policy: manualPin(id: "A", home: "/tmp/A")) == "/tmp/A")
    check("…and absence is not read as a sign-out",
          !pinnedAccountIsSignedOut(snap([pinSibling]), policy: manualPin(id: "A", home: "/tmp/A")))
    check("no snapshot at all keeps the saved home too",
          pinnedLaunchHome(nil, policy: manualPin(id: "A", home: "/tmp/A")) == "/tmp/A"
              && !pinnedAccountIsSignedOut(nil, policy: manualPin(id: "A", home: "/tmp/A")))
    // Only manual mode has a pin to resolve, and a policy with neither half resolves to nothing.
    check("smart mode resolves no pin",
          pinnedLaunchHome(snap([livePin]), policy: LaunchPolicy(pinnedAccountID: "A",
                                                                 pinnedHome: "/tmp/A")) == nil)
    check("a manual policy with nothing pinned resolves to nothing",
          pinnedLaunchHome(snap([livePin]), policy: manualPin(id: nil, home: nil)) == nil
              && !pinnedAccountIsSignedOut(snap([livePin]), policy: manualPin(id: nil, home: nil)))
}
