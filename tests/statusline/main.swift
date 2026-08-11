import Foundation

// Assertion harness for what `tally statusline claude` renders, compiled against the real source.
//
// The status line is one row shared by four zones, so its formats are only ever as good as their
// worst fit: the pool slot used to be the single figure in the row quoted in a unit of its own
// (accounts' worth, "0.6/5") beside three windows all quoted in percent. These are the pure pieces
// behind that row; the row itself reads stdin and exits, so what is pinned here is the vocabulary
// every surface has to agree on.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

// MARK: - The pool label

// A model pool says WHICH pool it is, because the panel's gauge focus can re-point this slot and a
// bare "pool" flipping between budgets reads as a wrong number. Lower-cased, because the rest of the
// row is.
check("a model pool names itself", poolLabel("Fable") == "fable pool")
check("a pool name is lower-cased into the row", poolLabel("OPUS") == "opus pool")
check("the weekly pool is the unnamed one", poolLabel(nil) == "pool")

// MARK: - The pool figure

// The change this suite was written for: the slot shows the share of the pool still unspent, in the
// same percent vocabulary as the 5h and 7d slots beside it. Accounts' worth stays in `tally status`
// and the panel, where there is room to say what the units are.
check("a pool with 60 of 500 account-points left reads as a percent",
      poolRemainingFigure(remaining: 60, capacity: 500) == "12%")
check("the figure carries no denominator any more",
      !poolRemainingFigure(remaining: 60, capacity: 500).contains("/"))
check("a full pool is 100%", poolRemainingFigure(remaining: 200, capacity: 200) == "100%")
check("a dry pool is 0%", poolRemainingFigure(remaining: 0, capacity: 200) == "0%")
// Whole numbers only: this shares a row with three other figures and a custom status line.
check("a half point rounds rather than truncating",
      poolRemainingFigure(remaining: 25, capacity: 200) == "13%")
check("and rounds down below the half",
      poolRemainingFigure(remaining: 24, capacity: 200) == "12%")
check("a fraction of a percent still shows as a percent",
      poolRemainingFigure(remaining: 1, capacity: 500) == "0%")
// The caller filters these out; the guard exists because `Int(Double.infinity)` traps, which would
// take the whole status line down rather than dropping one slot from it.
check("a pool with no capacity is a figure, not a crash",
      poolRemainingFigure(remaining: 5, capacity: 0) == "0%")

// MARK: - The bar beside it

// The meter and the figure now read the same ratio, which is the other half of the change: while the
// figure was accounts' worth, a bar drawn from the percentage was the only thing in the slot the
// number did not describe.
func filledCells(_ remaining: Double, _ capacity: Double) -> Int {
    let cells = 6
    let pct = remaining / capacity * 100
    return min(cells, max(pct > 0 ? 1 : 0, Int((pct / 100 * Double(cells)).rounded())))
}
check("half a pool fills half the bar", filledCells(100, 200) == 3)
check("a full pool fills every cell", filledCells(200, 200) == 6)
check("a nearly dry pool still shows one cell rather than vanishing", filledCells(2, 200) == 1)
check("an empty pool shows none", filledCells(0, 200) == 0)
check("the figure agrees with the bar it sits beside",
      poolRemainingFigure(remaining: 100, capacity: 200) == "50%" && filledCells(100, 200) == 3)

// MARK: - One figure for every human surface

// `tally status`'s fleet line reads the same way as the status line's pool slot, because the app is
// where the accounts'-worth reading belongs (with the room to say what the units are). Neither
// surface can be asked for its output here - one prints and exits, the other prints and returns
// nothing - so the source carries the invariant, the same technique the supervisor suite uses for
// its call-site rules. Run from the repo root (run-statusline-tests.sh cds there), and a missing
// file FAILS rather than quietly passing.
let statusSource = (try? String(contentsOfFile: "TallyCLI/main.swift", encoding: .utf8)) ?? ""
check("the status source is readable from the status line checks", !statusSource.isEmpty)
check("`tally status` prints the same pool figure",
      statusSource.contains("poolRemainingFigure(remaining: pool.remaining, capacity: pool.capacity)"))
check("and the same pool label", statusSource.contains("poolLabel(pool.poolName)"))
check("with no accounts'-worth formatting left in either human surface",
      !statusSource.contains("%.1f/%d")
          && !((try? String(contentsOfFile: "TallyCLI/Statusline.swift", encoding: .utf8)) ?? "")
              .contains("%.1f/%d"))
// The machine-readable side is deliberately untouched: `status --json` carries the pool's raw
// `remaining` and `capacity` in account-week units, which is a versioned additive contract scripts
// read (pinned in tests/statusjson). A display change must never reach through to it.
let reportSource = (try? String(contentsOfFile: "TallyCLI/StatusReport.swift",
                                encoding: .utf8)) ?? ""
check("the report source is readable from the status line checks", !reportSource.isEmpty)
check("the JSON report formats no percentages of its own",
      !reportSource.contains("poolRemainingFigure"))

// MARK: - Where the rest of the binary is

// Bare `tally` IS `tally status`, so this report is what somebody typing the name gets - and it used
// to be all they got: nothing on screen said the binary had any other command, and the list existed
// only behind a word you had to already know (Albert, 2026-08-10). Asserted through the source for
// the reason the section above gives: the human surface prints and returns nothing.
let statusBody = statusSource.range(of: "func runStatus(").flatMap { start in
    statusSource.range(of: "func runResume(").map { end in
        String(statusSource[start.lowerBound ..< end.lowerBound])
    }
} ?? ""
check("the status command is readable on its own", statusBody.contains("func runStatus("))
check("…and the slice stopped at the next command rather than swallowing the file",
      !statusBody.contains("func runWorktree("))
// A LINE THAT IS THE STATEMENT, not a line that mentions it: the first version of this check asked
// whether the text appeared anywhere in the function, and a mutation that commented the print out
// passed it (2026-08-10, caught by running that mutation rather than by reading the check).
let hintStatements = statusBody.components(separatedBy: "\n").filter {
    $0.trimmingCharacters(in: .whitespaces) == "print(tallyStatusHelpHint)"
}
check("the report ends by naming the way into everything else", hintStatements.count == 1)
check("…and that line names a command that exists rather than a flag to guess at",
      tallyStatusHelpHint.contains("tally help"))
// AND THE REPORT THAT COULD NOT BE PRINTED SAYS IT TOO, which is the run that needs it most: there
// is no snapshot until the app has run once, so a fresh machine reached the early exit and got a
// warning naming a file, with the tail of this function - and the only pointer to the rest of the
// binary - never reached at all (2026-08-10). Read as the slice between the guard and its exit, so
// the check is about THAT path rather than about the word appearing somewhere in the function.
if let guarded = statusBody.range(of: "guard let snapshot else {"),
   let failed = statusBody.range(of: "exit(1)") {
    let earlyExit = String(statusBody[guarded.upperBound ..< failed.lowerBound])
    // One statement carrying both halves: it is said, and the machine-readable shape is exempt for
    // the reason the tail statement returns before its own - a script reading the contract must not
    // have to parse prose on either exit.
    check("the report that could not be printed still names the way into everything else",
          earlyExit.contains("if !json { print(tallyStatusHelpHint) }"))
} else {
    check("the report that could not be printed still names the way into everything else", false)
}
// The machine-readable shape must not grow a sentence: it returns before the hint, which is what
// the early `return` in the `if json` branch is for. THE TAIL STATEMENT IN PARTICULAR, named by the
// line it sits on rather than by its text: the early exit above prints the same line and prints it
// FIRST, so a plain search for the word now finds the wrong one and this check passed on a
// coincidence of order (caught by the early exit landing, 2026-08-10). That path guards itself with
// `!json`, which is the same promise made a different way.
if let jsonReturn = statusBody.range(of: "return\n    }"),
   let hint = statusBody.range(of: "\n    print(tallyStatusHelpHint)") {
    check("the JSON shape returns before it, so no script has to parse prose",
          jsonReturn.upperBound < hint.lowerBound)
} else {
    check("the JSON shape returns before it, so no script has to parse prose", false)
}

// MARK: - `tally help`, and that it describes this binary rather than a past one

/// Every command the usage text documents, taken off the lines that show one.
let documented = tallyUsage.components(separatedBy: "\n").compactMap { line -> String? in
    guard line.hasPrefix("  tally ") else { return nil }
    return line.dropFirst("  tally ".count).split(separator: " ").first.map(String.init)
}
// The extractor's own sanity: a prefix that stopped matching would find nothing and pass every
// check below by saying nothing about anything.
check("the extractor really found the command lines",
      documented.count >= 14 && documented.contains("status") && documented.contains("help"))
for command in Set(documented).sorted() {
    check("`tally \(command)` is documented AND dispatched",
          statusSource.contains("case \"\(command)\""))
}
// ASKED FOR vs COMPLAINED ABOUT: same text, two streams and two exit codes, which is what a shell
// pipeline reads. `tally help | less` needs the first; every wrapper that checks whether a
// subcommand exists (the self-update's `__resupervise` probe among them) needs the second.
check("help is a command of its own, answering on stdout with a zero exit",
      statusSource.contains("case \"help\", \"--help\", \"-h\":")
          && statusSource.contains("    print(tallyUsage)\n    exit(0)"))
check("…while a word this binary does not know is still an error on stderr",
      statusSource.contains("default:\n    warn(tallyUsage)\n    exit(2)"))

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
      tallyCompletionZsh.contains("${_tally_menu:l} != (no|false|off|0) ]] && compstate[insert]=menu"))
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

exit(failures == 0 ? 0 : 1)
