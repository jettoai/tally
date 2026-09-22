import Foundation

// `tally send <claude|codex> …`: the grammar of the top-level spelling, that it produces the very
// request the namespace spelling does, the bare project name `--project` now takes, and the
// provider check this spelling is worth having for.
//
// A file of its own rather than more of sessionprojectchecks.swift, on the size rule that split
// that one off sessionsendchecks.swift, and along the same seam the source is split on: this
// states the second spelling (SessionSendVerb.swift) and the name half of the lookup.
//
// Pure throughout. Every roster here is written by hand, so nothing depends on which sessions this
// machine happens to be running, and no session is typed into.

func runSessionSendVerbChecks() {
    /// Two lines of one repository, and a same-named checkout somewhere else entirely: the third
    /// is what makes a bare name ambiguous, which is the case the name route exists to refuse.
    let trunk = "/Users/a/workspace/repo"
    let line = "/Users/a/workspace/repo-feature"
    let elsewhere = "/Users/a/archive/repo"

    func session(pid: Int?, dir: String?, provider: String?, state: String? = "idle")
        -> SessionProjectCandidate {
        SessionProjectCandidate(pid: pid, directory: dir, provider: provider, state: state)
    }
    let mixed = [session(pid: 70_324, dir: trunk, provider: "claude"),
                 session(pid: 98_743, dir: trunk, provider: "codex", state: "working"),
                 session(pid: 53_487, dir: line, provider: "claude", state: "blocked")]
    /// The same machine with a second checkout that happens to be called `repo` too.
    let twinned = mixed + [session(pid: 44_100, dir: elsewhere, provider: "claude")]

    /// The request one command line asks for, or a value no grammar produces. A sentinel rather
    /// than a `!`: a parse that stopped working should fail the check that names it, not kill the
    /// suite before the rest of the file has run.
    func asked(_ args: [String]) -> SessionSendIntent {
        sendVerbRequest(args)?.intent ?? SessionSendIntent(text: "<not parsed>", session: nil)
    }

    // MARK: - The provider is a required position

    check("the verb alone asks for nothing this command can act on",
          sendVerbRequest([]) == nil)
    check("a bare word in the provider's position is not a provider",
          sendVerbRequest(["hi"]) == nil && sendVerbRequest(["--project", trunk]) == nil)
    check("only the names the roster publishes are providers",
          sendVerbRequest(["gemini", "hi"]) == nil && sendVerbRequest(["Claude", "hi"]) == nil
              && sendVerbRequest(["claude codex", "hi"]) == nil)
    // `--` ends the flags for the TEXT. A position that could hide behind it would be a position
    // indistinguishable from content.
    check("a provider written after -- is text rather than the position",
          sendVerbRequest(["--", "claude", "hi"]) == nil
              && sendVerbRequest(["--", "claude"]) == nil)
    check("the provider is read off the FIRST word, not found anywhere on the line",
          sendVerbRequest(["--project", trunk, "claude"]) == nil)
    // The position has already answered this question, so a second answer is either a repetition
    // or a contradiction and there is no safe reading of the second.
    check("--provider is not a flag of this spelling",
          sendVerbRequest(["claude", "--project", trunk, "--provider", "claude"]) == nil
              && sendVerbRequest(["claude", "--project", trunk, "--provider", "codex"]) == nil
              && sendVerbRequest(["claude", "--provider", "codex"]) == nil)
    check("--project beside --session is a usage error here too",
          sendVerbRequest(["claude", "--project", trunk, "--session", "412"]) == nil
              && sendVerbRequest(["codex", "--session", "412", "--project", trunk]) == nil)
    check("no text is a request rather than an error, as it is in the other spelling",
          sendVerbRequest(["claude"])?.intent == SessionSendIntent(text: "", session: nil))
    check("-- ends the flags here too, so text that looks like one is sendable",
          asked(["claude", "--", "--help"]) == SessionSendIntent(text: "--help", session: nil))
    check("…and a directory named before it still addresses the send",
          asked(["codex", "--project", trunk, "--", "--help"])
              == SessionSendIntent(text: "--help", session: nil, project: trunk,
                                   provider: "codex"))
    check("two bare words after the provider are still a usage error",
          sendVerbRequest(["claude", "hello", "there"]) == nil)
    // NO SINGLE-LETTER FLAGS: `-p` is `--print` to Claude Code and `--profile` to Codex, and this
    // command's whole job is typing into one of those two.
    check("-p is not a spelling of --project",
          sendVerbRequest(["claude", "-p", trunk]) == nil && !sendVerbUsage.contains(" -p "))

    // MARK: - One implementation, two spellings

    // FIELD FOR FIELD, which is the assertion that stops a second send path growing here: what
    // travels on carries no trace of which spelling was typed.
    check("`tally send claude --project x` is `tally session send --project x --provider claude`",
          asked(["claude", "hi", "--project", trunk])
              == sessionSendIntent(["hi", "--project", trunk, "--provider", "claude"]))
    check("…and a pid addresses the same send either way",
          asked(["codex", "--session", "412", "hi"]) == sessionSendIntent(["hi", "--session",
                                                                           "412"]))
    check("…and so does a send that named no address at all",
          asked(["claude", "/clear"]) == sessionSendIntent(["/clear"]))
    // The named provider narrows the directory lookup where there is one, and travels beside the
    // request where there is not: a provider on an intent with no project is a filter with nothing
    // to filter, which `SessionSendAddress` refuses in the other spelling for the same reason.
    check("the provider narrows a directory and is left off a request with none",
          sendVerbRequest(["codex", "--project", trunk])?.intent.provider == "codex"
              && sendVerbRequest(["codex", "--session", "412"])?.intent.provider == nil
              && sendVerbRequest(["codex", "hi"])?.intent.provider == nil)
    check("…and it travels with the request whichever way it was addressed",
          sendVerbRequest(["codex", "hi"])?.provider == "codex"
              && sendVerbRequest(["claude", "--session", "412"])?.provider == "claude")
    // ONE PARSER AND ONE QUEUE, asserted on the source as well as on the values: two spellings
    // that agree today drift apart the moment one grows a parse of its own, and the values above
    // would go on agreeing about every case somebody thought to write down.
    let verb = (try? String(contentsOfFile: "TallyCLI/SessionSendVerb.swift",
                            encoding: .utf8)) ?? ""
    check("the new spelling parses through the old grammar and queues through the old path",
          verb.contains("sessionSendIntent(Array(args.dropFirst()))")
              && verb.contains("return runSessionSend(request.intent, "
                  + "requiredProvider: request.provider)")
              && !verb.contains("func queueSessionLine")
              && !verb.contains("writeSessionInputRequest"))

    // MARK: - The session that was reached has to be the kind that was named

    // WHAT THIS CHECK IS FOR, and what it is not. It is the insurance on the routes that have no
    // filter to narrow with - a pid typed on the command line, and this session - where the only
    // way to find out what was reached is to ask once it has been. On the directory route the
    // provider is a SELECTION filter instead (asserted below), so this is a second, agreeing
    // answer there rather than the judgement.

    check("a session of the kind that was asked for is not refused",
          sessionProviderMismatch(wanted: "codex", found: "codex", sessionKey: "98743") == nil
              && sessionProviderMismatch(wanted: "claude", found: "claude",
                                         sessionKey: "70324") == nil)
    let crossed = sessionProviderMismatch(wanted: "claude", found: "codex",
                                          sessionKey: "98743") ?? ""
    check("a session of the other kind is refused, named, and told what it actually is",
          crossed.contains("98743") && crossed.contains("codex"))
    check("…and told that nothing was queued, which is what a caller has to know",
          crossed.contains("nothing was queued"))
    check("…and given the spelling that would have worked",
          crossed.contains("tally send codex"))
    // THE POSITION IS A SELECTION FILTER ON THE DIRECTORY ROUTE, NOT A CHECK AFTER ONE. This is
    // the shape of the machine this is written on (`tally status --json`, 2026-09-22: nine
    // sessions over eight directories, and the tally checkout itself holding one Claude beside one
    // Codex), so it is the ordinary case rather than a corner: a provider read only after a
    // session had been picked would find that directory ambiguous and refuse the send every
    // caller actually wants to make. It is the same `--provider` the other spelling passes, and it
    // narrows BEFORE ambiguity is judged (`sessionProjectMatch` filters, then counts).
    check("a directory holding one of each is not ambiguous once the position named which",
          resolveSessionProject(asked(["claude", "hi", "--project", trunk]), sessions: mixed)
              == .addressed(SessionSendIntent(text: "hi", session: "70324"))
              && resolveSessionProject(asked(["codex", "hi", "--project", trunk]), sessions: mixed)
              == .addressed(SessionSendIntent(text: "hi", session: "98743")))
    // …and what IS ambiguous stays ambiguous: two of the same provider in one directory is the
    // case the position cannot narrow, so it is refused with the candidates listed and nothing
    // queued, exactly as the other spelling refuses it.
    let twoClaudes = [session(pid: 70_324, dir: trunk, provider: "claude"),
                      session(pid: 55_432, dir: trunk, provider: "claude", state: "working")]
    check("two sessions of the named provider in one directory are still refused",
          resolveSessionProject(asked(["claude", "hi", "--project", trunk]), sessions: twoClaudes)
              == .refused(sessionProjectRefusal(.ambiguous(twoClaudes), directory: trunk,
                                                provider: "claude") ?? ""))
    check("…and that refusal lists both pids and says nothing was queued",
          {
              let why = sessionProjectRefusal(.ambiguous(twoClaudes), directory: trunk,
                                              provider: "claude") ?? ""
              return why.contains("70324") && why.contains("55432")
                  && why.contains("nothing was queued") && why.contains("--session <pid>")
          }())
    // The directory route's own half of the provider rule, which is the roster filter the other
    // spelling already had: this proves the new verb feeds it rather than bypassing it.
    let codexOnly = [session(pid: 98_743, dir: trunk, provider: "codex", state: "working")]
    check("a directory holding only the other provider refuses the send before anything is written",
          resolveSessionProject(asked(["claude", "hi", "--project", trunk]), sessions: codexOnly)
              == .refused(sessionProjectRefusal(.noneOfProvider(codexOnly), directory: trunk,
                                                provider: "claude") ?? ""))
    check("…while the provider that IS there resolves to its pid",
          resolveSessionProject(asked(["codex", "hi", "--project", trunk]), sessions: codexOnly)
              == .addressed(SessionSendIntent(text: "hi", session: "98743")))

    // MARK: - A bare name rather than a path

    check("a slash, a tilde or a leading dot is a path",
          sessionProjectIsPath("/Users/a/repo") && sessionProjectIsPath("a/b")
              && sessionProjectIsPath("repo/") && sessionProjectIsPath("~/repo")
              && sessionProjectIsPath("~") && sessionProjectIsPath("./repo")
              && sessionProjectIsPath("../repo") && sessionProjectIsPath("."))
    check("…and a bare word is a name",
          !sessionProjectIsPath("repo") && !sessionProjectIsPath("repo-feature")
              && !sessionProjectIsPath("a.b"))
    check("one directory of that name is the directory it means",
          sessionProjectNamed("repo-feature", sessions: mixed) == .directory(line))
    // Several sessions in the ONE directory is not this question: that ambiguity is judged next
    // door, with the pids and the --provider way out (`sessionProjectMatch`).
    check("two sessions in the one directory of that name still name that directory",
          sessionProjectNamed("repo", sessions: mixed) == .directory(trunk))
    check("a name nothing was launched under names nothing",
          sessionProjectNamed("nowhere", sessions: mixed) == .noDirectory)
    check("the match is exact rather than a prefix, and it keeps its case",
          sessionProjectNamed("rep", sessions: mixed) == .noDirectory
              && sessionProjectNamed("repo-", sessions: mixed) == .noDirectory
              && sessionProjectNamed("Repo", sessions: mixed) == .noDirectory)
    check("two different directories of one name are refused rather than picked between",
          sessionProjectNamed("repo", sessions: twinned) == .several([elsewhere, trunk]))

    // MARK: - What a name that answered nothing is told

    check("a name that found its one directory is not refused at all",
          sessionProjectNameRefusal(.directory(trunk), name: "repo", sessions: mixed) == nil)
    let unknown = sessionProjectNameRefusal(.noDirectory, name: "nowhere", sessions: mixed) ?? ""
    check("an unknown name is told what a name is matched against, and the way to be exact",
          unknown.contains("nowhere") && unknown.contains("LAST component")
              && unknown.contains("full path") && unknown.contains("nothing was queued"))
    let twins = sessionProjectNameRefusal(.several([elsewhere, trunk]), name: "repo",
                                          sessions: twinned) ?? ""
    check("an ambiguous name lists every full path, with the sessions in each",
          twins.contains(elsewhere) && twins.contains(trunk) && twins.contains("44100")
              && twins.contains("70324") && twins.contains("98743"))
    check("…and says nothing was queued, and that the full path is the way out",
          twins.contains("nothing was queued") && twins.contains("full path"))

    // MARK: - From a name to a session

    check("a bare name addresses the send its directory does",
          resolveSessionProject(SessionSendIntent(text: "hi", session: nil, project: "repo-feature",
                                                  provider: nil), sessions: mixed)
              == .addressed(SessionSendIntent(text: "hi", session: "53487")))
    check("…and the name is spent doing it, so nothing downstream sees one",
          {
              guard case .addressed(let intent) = resolveSessionProject(
                  SessionSendIntent(text: "hi", session: nil, project: "repo-feature",
                                    provider: nil), sessions: mixed)
              else { return false }
              return intent.project == nil && intent.provider == nil
          }())
    check("a name two directories answer to refuses the send rather than addressing it",
          resolveSessionProject(SessionSendIntent(text: "hi", session: nil, project: "repo",
                                                  provider: "claude"), sessions: twinned)
              == .refused(sessionProjectNameRefusal(.several([elsewhere, trunk]), name: "repo",
                                                    sessions: twinned) ?? ""))
    check("a name nothing answers to refuses it too",
          resolveSessionProject(SessionSendIntent(text: "hi", session: nil, project: "nowhere",
                                                  provider: nil), sessions: mixed)
              == .refused(sessionProjectNameRefusal(.noDirectory, name: "nowhere",
                                                    sessions: mixed) ?? ""))
    // WHICH READING APPLIES IS THE SPELLING'S, not the disk's: a path whose last component is a
    // name on the roster is looked up as that path, and the two can name different sessions.
    check("a spelled-out path is looked up as that path rather than as its last component",
          resolveSessionProject(SessionSendIntent(text: "hi", session: nil, project: elsewhere,
                                                  provider: nil), sessions: twinned)
              == .addressed(SessionSendIntent(text: "hi", session: "44100")))
    // `~` has no slash of its own and is still a path, which the expansion proves: a session in
    // the home directory is reached by it, rather than one in a directory CALLED `~`.
    let home = realpathString(NSHomeDirectory())
    check("a bare ~ is the home directory rather than a project called ~",
          resolveSessionProject(SessionSendIntent(text: "hi", session: nil, project: "~",
                                                  provider: nil),
                                sessions: [session(pid: 31_000, dir: home, provider: "claude")])
              == .addressed(SessionSendIntent(text: "hi", session: "31000")))
    // A relative path still resolves against the directory the command runs in, which is the one
    // reading that DOES move with the environment and is the reason a bare word may not. A real
    // directory rather than a fictional one, and built through `realpathString` rather than
    // Foundation's resolver, for the reasons sessionprojectchecks.swift states at length: the two
    // disagree under the roots macOS mounts into `/private`, and `realpath` needs something on
    // disk to resolve a dot segment against.
    let temp = URL(fileURLWithPath: realpathString(NSTemporaryDirectory()))
        .appendingPathComponent("tally-sendverb-\(UUID().uuidString)")
    let real = temp.appendingPathComponent("checkout")
    try? FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    check("a dotted relative path is still resolved against the working directory",
          resolveSessionProject(SessionSendIntent(text: "hi", session: nil, project: "./checkout",
                                                  provider: nil),
                                sessions: [session(pid: 31_001, dir: real.path,
                                                   provider: "claude")],
                                cwd: temp.path)
              == .addressed(SessionSendIntent(text: "hi", session: "31001")))
    // …and the same word WITHOUT the dot does not consult the working directory at all, which is
    // the promise: run from `/`, where no `checkout` exists to resolve against, the name still
    // finds the roster entry that ends in it. One command line, one meaning, wherever it is typed.
    check("…while the same word written bare is a name and answers the same from anywhere",
          resolveSessionProject(SessionSendIntent(text: "hi", session: nil, project: "checkout",
                                                  provider: nil),
                                sessions: [session(pid: 31_001, dir: real.path,
                                                   provider: "claude")],
                                cwd: "/")
              == .addressed(SessionSendIntent(text: "hi", session: "31001")))

    // MARK: - What the help says, which is the half bd0f98c forgot

    check("the short list documents --project on the session verb",
          tallyUsage.contains("tally session send [<text>] [--session <pid> | --project"))
    check("…and the new spelling has a command line of its own",
          tallyUsage.contains("\n  tally send <claude|codex> "))
    // Asserted on the sentence rather than on the whitespace around it: the help text is wrapped
    // by hand, so a check that spans a line break fails the next time somebody rewraps a word.
    check("…which says how it differs from `tally message`",
          tallyUsage.contains("is the other thing and not a synonym"))
    check("the verb's own usage states the bare name and that there is no --provider flag",
          sendVerbUsage.contains("PROJECT NAME") && sendVerbUsage.contains("no --provider flag"))
    check("…and that a session of the other kind is refused",
          sendVerbUsage.contains("refused rather than typed"))
    check("the session verb's usage carries the same three facts",
          sessionSendUsage.contains("--project <dir-or-name>")
              && sessionSendUsage.contains("bare PROJECT NAME")
              && sessionSendUsage.contains("tally send claude|codex"))
}
