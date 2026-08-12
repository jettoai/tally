import Foundation

// What `tally completion zsh` offers at the cursor (TallyCLI/Completion.swift and the data behind
// it), asserted against the same two sources the usage text is: the script itself and the dispatch
// in main.swift. Split from main.swift for file size; `check`, `statusSource` and `documented` are
// shared from there, the way the supervisor suite splits.
//
// It lives in the status line's suite because both are surfaces this binary presents to somebody
// who is typing rather than reading - and because the two share the invariant that no surface may
// name a command the binary would refuse.

func runCompletionChecks() {
    // MARK: - `tally completion zsh`, and that it offers this binary rather than a past one

    // The third way in (Completion.swift): the list arrives at the cursor instead of being asked for.
    // Its failure mode is the usage text's, one degree worse - a command renamed here and nowhere else
    // is a word suggested at the cursor that the binary then answers with usage and exit 2 - so the
    // same invariant is pinned, against the same two sources.
    //
    /// The commands the completion offers at the top level, read off the array it builds them from.
    let offered: [String] = {
        guard let start = tallyCompletionZsh.range(of: "\n  commands=(\n"),
              let end = tallyCompletionZsh.range(of: "\n  )\n",
                                                 range: start.upperBound ..< tallyCompletionZsh.endIndex)
        else { return [] }
        return tallyCompletionZsh[start.upperBound ..< end.lowerBound]
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                let entry = line.trimmingCharacters(in: .whitespaces)
                guard entry.hasPrefix("\"") || entry.hasPrefix("'") else { return nil }
                return entry.dropFirst().split(separator: ":").first.map(String.init)
            }
    }()
    // The extractor's own sanity, for the reason the usage extractor states its: a marker that stopped
    // matching would find nothing and pass every check below by saying nothing about anything.
    check("the completion's command list was really found",
          offered.count >= 14 && offered.contains("status") && offered.contains("completion"))
    // BOTH DIRECTIONS, because each one is a different way for this to rot: a command offered but not
    // dispatched is a suggestion the binary refuses, and a command documented but not offered is the
    // discoverability this file exists for, silently not extended to it.
    check("everything the completion offers is documented in the usage text",
          Set(offered) == Set(documented))
    for command in Set(offered).sorted() {
        check("`tally \(command)` is offered AND dispatched", statusSource.contains("case \"\(command)\""))
    }
    // The internal subcommands stay out of it. They are dispatched (a hook registration written by an
    // older app still calls them) and deliberately absent from `tally help`; a completion offering
    // them would put them back in front of the one audience they were kept from.
    for internalCommand in ["hook-tally", "hook-switch", "hook-model", "mcp-serve", "__resupervise"] {
        check("`\(internalCommand)` is not offered at the cursor",
              !offered.contains(internalCommand) && !tallyCompletionZsh.contains(internalCommand))
    }
    // The two things that make a file on disk THIS script: the tag zsh autoloads on, and the marker the
    // app looks for before it rewrites or deletes a `_tally` in a site-functions directory
    // (IntegrationsCompletion.swift). Somebody else's completion for this command has the tag too, so
    // the marker is what keeps their file theirs.
    check("the script announces itself to zsh and to the installer",
          tallyCompletionZsh.hasPrefix("#compdef tally\n")
              && tallyCompletionZsh.contains("tally-completion"))
    // The dynamic helpers ask this machine questions, at the cursor of a line somebody is typing. Every
    // such helper has to survive the binary being absent and the command answering nothing, because a
    // completion that prints a diagnostic there has broken the line it was helping with.
    check("the helpers ask the binary being completed, and give up when there is none",
          tallyCompletionZsh.contains("command -v -- \"$bin\" > /dev/null 2>&1 || return 1"))
    for probe in ["\"$bin\" completion data accounts $provider 2>/dev/null",
                  "\"$bin\" worktree list 2>/dev/null"] {
        check("`\(probe)` cannot spill an error onto the line", tallyCompletionZsh.contains(probe))
    }
    // The accounts are ASKED FOR rather than parsed out of `status --json`: a label is free text from
    // the rename popover, so it can carry a quote that JSONEncoder escapes, and a shell reader that
    // stops at the next `"` hands back a name no account answers to (review, 2026-08-11).
    // Named by the CALL rather than by the words: the comment above the helper still says what it
    // stopped doing and why, which a search for the report's name would read as the thing itself.
    check("no JSON is parsed in the shell any more",
          !tallyCompletionZsh.contains("\"$bin\" status") && !tallyCompletionZsh.contains("_tally_json"))
    // The plumbing is one program talking to itself: it must not appear where a person is reading.
    check("the plumbing is not offered at the cursor",
          !offered.contains("data") && tallyCompletionZsh.contains("(completion) _arguments \":shell:(zsh)\""))
    check("…nor documented as something to type", !tallyUsage.contains("completion data"))

    // EVERY CALL SITE NAMES ITS PROVIDER. The helper defaults to claude when asked without one, which
    // is the pre-fix behaviour for whichever site forgets, so "it still completes something" is exactly
    // what a regression here looks like. Written as a sweep over the call sites rather than as one
    // example, because the failure is per-site.
    let accountCallSites = tallyCompletionZsh.components(separatedBy: "\n")
        .filter { $0.contains("_tally_accounts") && !$0.contains("_tally_accounts()") }
    check("the account call sites were found", accountCallSites.count == 4)
    for site in accountCallSites {
        let named = site.contains(" _tally_accounts claude") || site.contains(" _tally_accounts codex")
            || site.contains(" _tally_accounts $provider")
        check("a call site names the provider it is completing for (\(site.trimmingCharacters(in: .whitespaces).prefix(28)))",
              named)
    }
    // The two launches, by name: a codex launch offering claude accounts is the defect this closed, and
    // it is invisible unless the codex site is asserted on its own.
    check("the codex launch completes codex accounts",
          accountCallSites.contains { $0.contains("_tally_accounts codex") })
    check("the claude launch completes claude accounts",
          accountCallSites.contains { $0.contains("_tally_accounts claude") })
    // `tally project set --account` writes a profile for whichever provider the line named, so its
    // candidates follow that word rather than a constant.
    check("the project profile completes the provider the line named",
          accountCallSites.contains { $0.contains("_tally_accounts $provider") })
    // AND IT READS THE WHOLE LINE FOR IT, because the command does: `optionValue` scans the entire
    // argument list and takes the first match (ProjectPolicy.swift), so `--provider codex` written after
    // the account is a legal Codex profile - and a scan stopping at the cursor offered claude accounts
    // to it, which is the command refusing its own suggestion (review, 2026-08-11).
    check("the provider is read off the whole line, not the half left of the cursor",
          tallyCompletionZsh.contains("for (( i = 1; i <= $#words; i++ ))")
              && !tallyCompletionZsh.contains("for (( i = 1; i < CURRENT; i++ ))"))
    check("…first occurrence and a claude default, the way `optionValue` answers",
          tallyCompletionZsh.contains("{ provider=${words[i+1]:-claude}; break }"))

    // MARK: - The names the completion is allowed to offer

    // ASKED OF THE MATCHER ITSELF, so a suggestion is true by construction. Each case below is a name
    // the CLI would answer differently, and the completion has to agree with that answer.
    func testAccount(_ id: String, provider: String, label: String, home: String?) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: provider, label: label, launchHome: home, isStale: false)
    }
    func fleet(_ accounts: [Snapshot.Account]) -> Snapshot {
        Snapshot(version: 2, generatedAt: Date(), accounts: accounts)
    }
    let mixed = fleet([
        testAccount("c1", provider: "claude", label: "Claude", home: "/u/.claude"),
        testAccount("c2", provider: "claude", label: "Claude 2", home: "/u/.claude2"),
        testAccount("x1", provider: "codex", label: "Codex", home: "/u/.codex"),
    ])
    check("a launch is offered its own provider's accounts",
          completionAccountNames(mixed, provider: "claude") == ["Claude", "Claude 2"])
    // The one that made this a defect rather than a tidy-up: `accountMatching` filters on the provider
    // before anything else, so a Codex name offered to `tally claude --account` is a word the command
    // refuses by construction.
    check("…and never the other provider's", !completionAccountNames(mixed, provider: "claude")
        .contains("Codex"))
    check("the other provider gets its own", completionAccountNames(mixed, provider: "codex") == ["Codex"])
    // Two accounts under one label: the label resolves to neither ("name one of them exactly"), so what
    // is offered is the name that does resolve - the config-dir name, which is what the ambiguity
    // message itself prints beside each candidate (accountMatchCandidates).
    let twins = fleet([
        testAccount("t1", provider: "claude", label: "Work", home: "/u/.claude"),
        testAccount("t2", provider: "claude", label: "Work", home: "/u/.claude2"),
    ])
    check("a shared label is replaced by the names that do resolve",
          completionAccountNames(twins, provider: "claude") == [".claude", ".claude2"])
    for name in completionAccountNames(twins, provider: "claude") {
        guard case .one = accountMatching(name, provider: "claude", in: twins) else {
            check("every offered name resolves to exactly one account (\(name))", false)
            continue
        }
        check("every offered name resolves to exactly one account (\(name))", true)
    }
    // A signed-out account has no launch home, which is the matcher's other precondition: there is no
    // word that would land on it, so there is nothing to suggest.
    check("an account with no launch home is offered under no name",
          completionAccountNames(fleet([testAccount("d", provider: "claude", label: "Dormant",
                                                    home: nil)]), provider: "claude").isEmpty)
    // The label that started this: free text, quotes and all, handed back exactly as the matcher will
    // read it. Nothing here escapes or truncates it, which was the whole point of moving the question
    // out of the shell.
    let quoted = fleet([testAccount("q", provider: "claude", label: "Work \"Main\"",
                                    home: "/u/.claude")])
    check("a label carrying a quote survives verbatim",
          completionAccountNames(quoted, provider: "claude") == ["Work \"Main\""])
    check("…and the CLI resolves the very name that was offered",
          { if case .one = accountMatching("Work \"Main\"", provider: "claude", in: quoted)
            { return true } else { return false } }())
    // A name with a newline in it cannot travel a line-per-candidate channel, so it is dropped rather
    // than sent half-way.
    check("a label with a newline is dropped rather than split",
          completionAccountNames(fleet([testAccount("n", provider: "claude", label: "two\nlines",
                                                    home: "/u/.claude")]),
                                 provider: "claude") == [".claude"])

    // MARK: - Positions that must NOT fall back to file names

    // The word after -w/--worktree is a worktree NAME, not a path: `extractWorktreeFlag` takes any
    // non-flag word, so accepting `README.md` there has the launch create a branch and a directory
    // called that (review, 2026-08-11). WRITING THE ARGUMENT AS REQUIRED IS THE FIX AND THE ONLY ONE
    // AVAILABLE: an optional argument makes zsh complete the position twice, once as the name and once
    // as though it were already given, and the second parse is indistinguishable from the ordinary next
    // position - so no guard on the fallback can tell them apart (measured at the cursor, 2026-08-11).
    // One character, which is exactly why it is pinned here.
    // THE SPEC LINE, not the file: the comment above it names the wrong spelling in order to warn
    // about it, and a search of the whole script finds that sentence (it did, twice in one session -
    // the same shape as the `print(tallyStatusHelpHint)` check above).
    let worktreeSpec = tallyCompletionZsh.components(separatedBy: "\n")
        .first { $0.contains("{-w,--worktree}") } ?? ""
    check("the worktree flag spec was found on a line of its own", !worktreeSpec.isEmpty)
    check("the worktree argument is required, so the position has one reading",
          worktreeSpec.contains("]:worktree:_tally_worktrees") && !worktreeSpec.contains("::worktree:"))
    // NOT ONE ARGUMENT OF THIS BINARY TAKES A PATH, so the working directory is never an answer and the
    // default completer has no place here at all (Albert, 2026-08-11). Asserted as a ban rather than
    // per-branch: the previous shape had three branches falling back to it and a fourth was one edit
    // away. What each position offers instead is checked where it can only be checked, in a real shell
    // (tests/completion).
    check("no position falls back to file completion", !tallyCompletionZsh.contains("_default"))
    // `resume` keeps a branch of its own even with nothing to say, because the last reader who found it
    // missing filled it with file completion.
    check("resume is named, with nothing to offer", tallyCompletionZsh.contains("(resume) ;;"))
    // The lesson at an empty word is built from the same spec strings `_arguments` is handed, so a flag
    // renamed in one is renamed in the other. A teaching list assembled separately is a second list.
    check("the teaching list is built from the specs themselves",
          tallyCompletionZsh.contains("_tally_teach \"launch option\" $_tally_specs")
              && tallyCompletionZsh.contains("_arguments $_tally_specs \"*: :_tally_rest\""))
    // The lesson stays away from a foreign flag's values, ALL of them: eleven of the child's flags take
    // a list rather than one word (`--add-dir a b`, LaunchFlags.swift), so a guard reading only the word
    // before the cursor let the second value be taught at, inserting `--account` into the middle of the
    // list and truncating it (review, 2026-08-11). The nearest dash word to the left is the flag whose
    // run this is; what that looks like at the cursor is checked in a real shell (tests/completion).
    check("the quiet position is judged from the nearest flag, not the previous word",
          tallyCompletionZsh.contains("for (( i = CURRENT - 1; i > 1; i-- ))")
              && tallyCompletionZsh.contains("[[ ${words[i]} == -* ]] && { previous=${words[i]}; break }")
              && !tallyCompletionZsh.contains("local previous=${words[CURRENT-1]}"))
    // And the question asked of that flag is whether it is OURS, of any arity: `_arguments` binds the
    // value position of every flag in the specs, so reaching this function means ours is satisfied,
    // while a foreign one may still be eating words. A test for "takes nothing" instead would have gone
    // quiet after `-w wt-alpha`, which is a completed pair of our own.
    check("the nearest flag is judged by whether it is one of ours",
          tallyCompletionZsh.contains("[[ ${spec%%\\[*} == \"$previous\" ]] && { ours=1; break }")
              && !tallyCompletionZsh.contains("# this one takes a value"))
    // Two spellings of one flag are one lesson, recognised through the exclusion group the alias set
    // already carries for `_arguments` - so nothing is declared twice to say they belong together. What
    // the merged line LOOKS like is checked where it can be seen, in a real shell (tests/completion).
    check("alias sets are found through the group they already declare",
          tallyCompletionZsh.contains("(( ${${(z)group}[(Ie)$name]} ))"))
    // Presentation styles are scoped to this command and asked about before being set, so a preference
    // the user already expressed here is not overwritten (`-s` tests whether a style is SET; `-t` tests
    // whether it is TRUE, which reads "unset" for somebody who chose `menu no`).
    // Counted rather than sampled: what matters is that NO style is set without being asked about
    // first, and a per-style example says nothing about the one somebody adds next.
    let styleLines = tallyCompletionZsh.components(separatedBy: "\n")
    let probes = styleLines.filter { $0.contains("zstyle -s ':completion:*:*:tally:*") }.count
    let sets = styleLines.filter {
        $0.contains("|| ") && $0.contains("zstyle ':completion:*:*:tally:*")
    }.count
    check("every style this script sets is asked about first", probes == 3 && sets == 3)
    // The menu answer is not just kept out of the style, it decides the behaviour: respecting `menu no`
    // in the zstyle and then forcing the insertion anyway was respecting nothing (review, 2026-08-11).
    check("the forced menu reads the same answer the probe already has",
          tallyCompletionZsh.contains("_tally_menu_wanted \"$_tally_menu\" && compstate[insert]=menu"))
    // And it reads the WHOLE of zsh's vocabulary for that style, not the four words it started with:
    // `menu no=1` and `menu no no-select` are a user saying no in forms the exact comparison missed, so
    // they got the menu they had turned off (review, 2026-08-11). The conditional TRUE forms are
    // refusals here too, because this line runs before any match exists and the count they are about
    // cannot be known. What each value does at the cursor is checked in a real shell (tests/completion).
    for refusal in ["(no|false|off|0) return 1", "(no=*|false=*|off=*|0=*) return 1",
                    "(yes=*|true=*|on=*|1=*) return 1"] {
        check("`\(refusal)` keeps this script from forcing a menu", tallyCompletionZsh.contains(refusal))
    }
    check("…and only an unconditional yes lets it force one",
          tallyCompletionZsh.contains("(yes|true|on|1|select) wanted=1")
              && tallyCompletionZsh.contains("return $(( ! wanted ))"))
    check("the styles say tally rather than everything",
          !tallyCompletionZsh.contains("zstyle ':completion:*' "))
    // `tally model auto high` is usage and exit 2 (`modelIntent` refuses two words when either is the
    // release), so the depth is not offered once the release has been named.
    check("no depth is offered after the release word",
          tallyCompletionZsh.contains("[[ ${(L)words[2]} == (auto|--auto) ]] && return 0"))
    check("…and the model position still routes through that gate",
          tallyCompletionZsh.contains("\":effort:_tally_model_effort\""))
    // The axis names come from the one list both targets compile (LaunchAxisNames.swift), so the
    // suggestions cannot name an effort the CLI would refuse.
    check("the effort suggestions are the list the CLI validates against",
          tallyCompletionZsh.contains("efforts=(\(claudeEffortNames().joined(separator: " ")))"))
    check("the model suggestions are the aliases the pickers offer",
          tallyCompletionZsh.contains("models=(\(claudeModelAliases.joined(separator: " ")))"))
    check("the provider suggestions are the providers this binary launches",
          tallyCompletionZsh.contains("ids=(\(providers.map(\.id).joined(separator: " ")))"))
    // Asked for, so it answers on stdout with a zero exit: `eval "$(tally completion zsh)"` reads
    // exactly that, and a script written into somebody's ~/.zshrc is the last place an error belongs.
    check("the completion is printed to stdout with a zero exit",
          (try? String(contentsOfFile: "TallyCLI/CompletionData.swift", encoding: .utf8))?
              .contains("print(tallyCompletionZsh)\n        return 0") == true)
}
