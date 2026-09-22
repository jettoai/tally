import Foundation

// `tally session send --project <dir>`: the grammar of the address flags, the one spelling a
// directory is compared in, which session a directory names, and what a caller that named none or
// several is told.
//
// A file of its own rather than more of sessionsendchecks.swift, on the size rule that split that
// file from sessioninputchecks.swift and along the same seam the source is split on: this states
// the lookup (SessionProjectAddress.swift), that one states the command around it.
//
// Pure throughout. The roster every check here asks about is written by hand, so nothing depends on
// which sessions this machine happens to be running, and no session is typed into.

func runSessionProjectChecks() {
    /// Two lines of one repository: the trunk and a worktree of it. They are different directories
    /// on purpose, which is the whole of what this lookup promises.
    let trunk = "/Users/a/workspace/repo"
    let line = "/Users/a/workspace/repo-feature"

    func session(pid: Int?, dir: String?, provider: String?, state: String? = "idle")
        -> SessionProjectCandidate {
        SessionProjectCandidate(pid: pid, directory: dir, provider: provider, state: state)
    }
    /// The ordinary roster on this machine: a trunk holding one Claude and one Codex side by side,
    /// and a parallel line of the same repository holding one more.
    let mixed = [session(pid: 70_324, dir: trunk, provider: "claude"),
                 session(pid: 98_743, dir: trunk, provider: "codex", state: "working"),
                 session(pid: 53_487, dir: line, provider: "claude", state: "blocked")]

    // MARK: - The grammar

    check("--project names a session by its directory",
          sessionSendIntent(["--project", trunk, "hi"])
              == SessionSendIntent(text: "hi", session: nil, project: trunk, provider: nil))
    check("…and takes --provider to narrow it",
          sessionSendIntent(["--project", trunk, "--provider", "codex"])
              == SessionSendIntent(text: "", session: nil, project: trunk, provider: "codex"))
    check("…and leaves --session alone when it is the one given",
          sessionSendIntent(["--session", "412", "hi"])
              == SessionSendIntent(text: "hi", session: "412"))
    // TWO ADDRESSES ARE NOT AN ADDRESS: the two can disagree, and the caller that wrote both has
    // said it is unsure which it meant.
    check("--project beside --session is a usage error rather than a preference",
          sessionSendIntent(["--session", "412", "--project", trunk]) == nil
              && sessionSendIntent(["--project", trunk, "--session", "412", "hi"]) == nil)
    // A filter with nothing to filter is accepted nowhere: honouring it would let a caller believe
    // it had restricted a target it never restricted.
    check("--provider without --project is a usage error",
          sessionSendIntent(["--provider", "claude"]) == nil
              && sessionSendIntent(["--session", "412", "--provider", "claude"]) == nil)
    check("--provider takes only the names the roster publishes",
          sessionSendIntent(["--project", trunk, "--provider", "gemini"]) == nil
              && sessionSendIntent(["--project", trunk, "--provider", "Claude"]) == nil
              && sessionSendIntent(["--project", trunk, "--provider", "--session"]) == nil)
    check("--project without a value, or twice, is a usage error",
          sessionSendIntent(["--project"]) == nil
              && sessionSendIntent(["--project", trunk, "--project", line]) == nil)
    check("…and so is an empty directory, which has no reading that is not a guess",
          sessionSendIntent(["--project", ""]) == nil)
    check("--provider without a value, or twice, is a usage error",
          sessionSendIntent(["--project", trunk, "--provider"]) == nil
              && sessionSendIntent(["--project", trunk, "--provider", "claude",
                                    "--provider", "codex"]) == nil)
    // `--` still ends the flags, which is what makes text that looks like one sendable.
    check("-- ends the flags, so --project after it is text",
          sessionSendIntent(["--", "--project"])
              == SessionSendIntent(text: "--project", session: nil))
    check("…and a directory named before it still addresses the send",
          sessionSendIntent(["--project", trunk, "--", "--help"])
              == SessionSendIntent(text: "--help", session: nil, project: trunk, provider: nil))
    check("two bare words are still a usage error beside --project",
          sessionSendIntent(["--project", trunk, "hello", "there"]) == nil)

    // MARK: - The one spelling a directory is compared in

    // realpathString, not resolvingSymlinksInPath: the fixture has to be built through the same
    // resolve the function under test now uses, because they disagree about /tmp's own /private
    // prefix (Foundation's resolvingSymlinksInPath strips it back off when the result names the
    // same file without it; realpath does not), and NSTemporaryDirectory() lives under /var, one
    // of the roots that disagreement bites on.
    let temp = URL(fileURLWithPath: realpathString(NSTemporaryDirectory()))
        .appendingPathComponent("tally-sessionproject-\(UUID().uuidString)")
    let real = temp.appendingPathComponent("checkout")
    try? FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let alias = temp.appendingPathComponent("alias")
    try? FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    defer { try? FileManager.default.removeItem(at: temp) }

    check("a trailing slash is not a different directory",
          sessionProjectDirectory(real.path + "/") == real.path)
    check("a relative path is resolved against the directory the command runs in",
          sessionProjectDirectory("checkout", cwd: temp.path) == real.path)
    check("…and so are the dot segments in one",
          sessionProjectDirectory("./checkout/../checkout", cwd: temp.path) == real.path)
    // The roster publishes a realpath, so a path reached through a link compares unequal to it as a
    // string until it is resolved here.
    check("a checkout reached through a symlink is that checkout",
          sessionProjectDirectory(alias.path) == real.path)
    check("~ is the home directory rather than a directory called ~",
          sessionProjectDirectory("~") == URL(fileURLWithPath: NSHomeDirectory())
              .resolvingSymlinksInPath().path)
    check("an empty path names nothing", sessionProjectDirectory("") == nil)
    check("the root is left as it is", sessionProjectDirectory("/") == "/")

    // `/tmp` is a symlink to `/private/tmp`, which is exactly the case `resolvingSymlinksInPath()`
    // used to get wrong (it documents stripping a leading `/private` back off): the contract under
    // test is "the same spelling as the roster's `realpathString`", not a literal `/private/tmp`,
    // so this asserts against `realpathString` directly rather than hard-coding which one is right.
    let privateCheck = URL(fileURLWithPath: "/tmp")
        .appendingPathComponent("tally-sessionproject-private-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: privateCheck, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: privateCheck) }
    check("a /tmp checkout compares the way the roster's realpath does, /private prefix and all",
          sessionProjectDirectory(privateCheck.path) == realpathString(privateCheck.path))

    // MARK: - Which session a directory names

    check("one session in a directory is the session that directory names",
          sessionProjectMatch(mixed, directory: line, provider: nil) == .one("53487"))
    check("…and a provider that agrees changes nothing",
          sessionProjectMatch(mixed, directory: line, provider: "claude") == .one("53487"))
    check("--provider is what makes a shared directory unambiguous",
          sessionProjectMatch(mixed, directory: trunk, provider: "codex") == .one("98743")
              && sessionProjectMatch(mixed, directory: trunk, provider: "claude")
              == .one("70324"))
    check("two sessions in one directory are refused rather than picked between",
          sessionProjectMatch(mixed, directory: trunk, provider: nil)
              == .ambiguous([mixed[0], mixed[1]]))
    check("a directory nothing was launched in names nothing",
          sessionProjectMatch(mixed, directory: "/Users/a/workspace/elsewhere", provider: nil)
              == .noSession)
    // THE CHECKOUT IS THE ADDRESS, not the repository: the trunk's path does not reach the line's
    // session, which is what stops a message for one line of work landing in another.
    check("a worktree is not addressed by the trunk's path",
          sessionProjectMatch([mixed[2]], directory: trunk, provider: nil) == .noSession)
    check("a provider nothing there is running is its own refusal, carrying what is",
          sessionProjectMatch([mixed[2]], directory: line, provider: "codex")
              == .noneOfProvider([mixed[2]]))
    // A session running perfectly well that this command has no way to name. Counting it towards
    // "exactly one" would send the line to the other one and report success.
    let pidless = session(pid: nil, dir: trunk, provider: "claude")
    check("a session that publishes no pid cannot be typed into",
          sessionProjectMatch([pidless], directory: trunk, provider: nil)
              == .unaddressable([pidless]))
    check("…and makes the one beside it ambiguous rather than picked by elimination",
          sessionProjectMatch([pidless, mixed[0]], directory: trunk, provider: nil)
              == .ambiguous([pidless, mixed[0]]))
    // Neither of these can be typed into either way, so how many there are does not matter: telling
    // the caller "ambiguous, name one with --session <pid>" would be sending them to look for a pid
    // that does not exist on either candidate.
    let pidless2 = session(pid: nil, dir: trunk, provider: "claude")
    check("two sessions that both publish no pid are unaddressable, not ambiguous",
          sessionProjectMatch([pidless, pidless2], directory: trunk, provider: nil)
              == .unaddressable([pidless, pidless2]))
    // Proof the provider filter runs before ambiguity is judged: with --provider codex, the pidless
    // claude session is dropped before `wanted` is even counted, leaving one addressable session.
    let codexWithPid = session(pid: 60_111, dir: trunk, provider: "codex")
    check("a provider filter that narrows to one addressable session still resolves",
          sessionProjectMatch([pidless, codexWithPid], directory: trunk, provider: "codex")
              == .one("60111"))

    // MARK: - What the caller is told

    check("the session a directory names is not refused at all",
          sessionProjectRefusal(.one("70324"), directory: trunk, provider: nil) == nil)
    let several = sessionProjectRefusal(.ambiguous([mixed[0], mixed[1]]), directory: trunk,
                                        provider: nil) ?? ""
    check("an ambiguous directory is told both pids, with what each one is",
          several.contains("70324 (claude, idle)") && several.contains("98743 (codex, working)")
              && several.contains("2 supervised sessions"))
    check("…and what to type next, both ways out",
          several.contains("--session <pid>") && several.contains("--provider claude|codex"))
    check("…and that nothing was queued, which is what a caller has to know",
          several.contains("nothing was queued"))
    // The narrowing is offered only where it narrows. Suggesting it to a caller that already passed
    // it, or one looking at two sessions of one provider, sends them back to a flag that will
    // refuse them again for the same reason.
    let twoClaudes = [mixed[0], session(pid: 55_432, dir: trunk, provider: "claude")]
    check("--provider is not suggested where it would not narrow",
          sessionProjectRefusal(.ambiguous(twoClaudes), directory: trunk, provider: nil)?
              .contains("--provider") == false
              && sessionProjectRefusal(.ambiguous([mixed[0], mixed[1]]), directory: trunk,
                                       provider: "claude")?.contains("--provider") == false)
    let none = sessionProjectRefusal(.noSession, directory: trunk, provider: nil) ?? ""
    check("an empty directory is told where the roster is, and that a line keeps its own path",
          none.contains(trunk) && none.contains("tally status --json")
              && none.contains("nothing was queued"))
    let wrong = sessionProjectRefusal(.noneOfProvider([mixed[2]]), directory: line,
                                      provider: "codex") ?? ""
    check("a provider nothing runs is told which provider, and what is there instead",
          wrong.contains("no supervised codex session") && wrong.contains("53487 (claude, blocked)")
              && wrong.contains("Drop --provider"))
    let stuck = sessionProjectRefusal(.unaddressable([pidless]), directory: trunk,
                                      provider: nil) ?? ""
    check("a session with no pid to name is told the restart that gives it one",
          stuck.contains("1 supervised session") && stuck.contains("tally claude"))

    // MARK: - From a command line to an address

    let asked = SessionSendIntent(text: "/clear", session: nil, project: line, provider: nil)
    check("a resolved directory is the send somebody would have typed by hand",
          resolveSessionProject(asked, sessions: mixed)
              == .addressed(SessionSendIntent(text: "/clear", session: "53487")))
    check("…and the directory is spent doing it, so nothing downstream sees one",
          {
              guard case .addressed(let intent) = resolveSessionProject(asked, sessions: mixed)
              else { return false }
              return intent.project == nil && intent.provider == nil
          }())
    check("a send that named no directory is passed through untouched",
          resolveSessionProject(SessionSendIntent(text: "hi", session: "412"), sessions: mixed)
              == .addressed(SessionSendIntent(text: "hi", session: "412")))
    check("an ambiguous directory refuses the send rather than addressing it",
          resolveSessionProject(SessionSendIntent(text: "hi", session: nil, project: trunk,
                                                  provider: nil), sessions: mixed)
              == .refused(sessionProjectRefusal(.ambiguous([mixed[0], mixed[1]]), directory: trunk,
                                                provider: nil) ?? ""))
    // The directory is put through the same spelling the match is made in, rather than compared as
    // it was typed: a caller passing `$PWD` with a trailing slash addresses the same session. A
    // real directory (`real`, from the fixture above) rather than a fictional path: `realpath`
    // needs something on disk to resolve the dot segment against, where `resolvingSymlinksInPath`
    // did not.
    check("the address is resolved before it is looked up",
          resolveSessionProject(SessionSendIntent(text: "hi", session: nil, project: "./checkout/",
                                                  provider: nil),
                                sessions: [session(pid: 70_324, dir: real.path, provider: "claude")],
                                cwd: temp.path)
              == .addressed(SessionSendIntent(text: "hi", session: "70324")))
}
