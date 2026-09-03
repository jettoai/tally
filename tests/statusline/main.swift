import Foundation

// Assertion harness for what `tally statusline claude` renders, compiled against the real source.
//
// The row is a SESSION reading: this account, the model and depth it runs, and this account's own
// two windows. The pool slot it used to carry is gone (owner ruling, 2026-08-12) and the pool
// helpers below now serve `tally status` alone. The row itself reads stdin and exits, so what is
// pinned here is the vocabulary every surface has to agree on, plus the shape of the row asserted
// through its source - the same technique the supervisor suite uses for its call-site rules.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

/// The status line's own source, which several sections below assert the row's shape through.
/// Read from the repo root (run-statusline-tests.sh cds there); an unreadable file FAILS rather
/// than quietly passing every check that reads it.
let lineSource = (try? String(contentsOfFile: "TallyCLI/Statusline.swift", encoding: .utf8)) ?? ""
check("the status line source is readable from these checks", !lineSource.isEmpty)

// MARK: - The row is this session's, not the fleet's

// THE POOL LEFT THE ROW. It used to take the 7d slot's place whenever the app's fleet gauge was on,
// on the reasoning that under smart handoff the pool is the binding budget. A person reading the
// row under their prompt is asking about the session they are in, and the fleet view is the app's
// (and `tally status`'s) job, so the row now always carries this account's own two windows.
// Asserted as the ABSENCE of the pool vocabulary in this file, which is what a re-introduction
// would have to bring back, plus the presence of both windows unconditionally.
for gone in ["fleetPiece", "poolPieces", "fleetPools", "fleet ✓"] {
    check("the row no longer builds `\(gone)`", !lineSource.contains(gone))
}
check("the 5h and 7d slots are built together, with nothing between them",
      lineSource.contains("""
        quota = [piece("5h", account.sessionRemaining, account.sessionResetsAt),
                 piece("7d", account.weeklyRemaining, account.weeklyResetsAt)]
"""))
// AND NEITHER SLOT IS CONDITIONAL ON ANYTHING. The yield was written as a ternary inside the array,
// so the shape a regression takes here is a `?` between those two lines rather than a new zone.
check("neither window slot is handed to anything else",
      !lineSource.contains("piece(\"7d\", account.weeklyRemaining, account.weeklyResetsAt) : nil"))
// The pool helpers are still compiled, because `tally status` prints a pool: what changed is who
// calls them. A call from this file is the regression this pins.
let lineBody = lineSource.range(of: "// MARK: - The fleet pool slot in `tally status`")
    .map { String(lineSource[lineSource.startIndex ..< $0.lowerBound]) } ?? ""
check("the row's own body was sliced off from the helpers below it", !lineBody.isEmpty)
for helper in ["poolLabel(", "poolRemainingFigure("] {
    check("the row itself never calls `\(helper))`", !lineBody.contains(helper))
}

// MARK: - The depth beside the model

// The identity says which model AND at what depth, because that is the pair a person sets in one
// breath (`tally model fable high`). The depth is read off the supervisor's per-pid session context
// (SessionContext.swift), which carries two fields for it - and the order between them is the rule.
//
// THE PIN OUTRANKS THE COMMAND LINE. This suite first asserted the opposite ("the running reading,
// not the pinned one") and called it the contract, on the reasoning that argv is what the live child
// actually runs. It is not always the later fact: Claude Code's own `/model` moving ONLY the depth
// is adopted into the pin with no relaunch at all (`adoptNativeModelChoice`, SessionModel.swift),
// so argv still names the depth this child started on while `sessionEffort` has moved. The line
// showed the stale one, and this check certified it (codex review of 201dd2c).
check("the pin outranks the command line",
      lineSource.contains("depth = context?.sessionEffort ?? context?.runningEffort"))
// AND THE COMMAND LINE IS NOT OPTIONAL EITHER, which is the half a "just read the pin" fix would
// have dropped: most sessions carry no pin at all (nobody ran `tally model`), and their depth is
// only in the arguments. Asserted apart from the line above so a change that keeps the order but
// loses the fallback cannot pass on the first check's wording.
check("…and the command line is still the fallback, for the sessions that have no pin",
      lineSource.contains("?? context?.runningEffort"))
// ONE READ OF THE FILE, so the pin and the arguments cannot come from either side of a republish.
check("both fields come from one reading of the context",
      lineSource.components(separatedBy: "readSessionContext(pid: pidStr)").count == 2)
// FAIL-OPEN, LIKE EVERYTHING ELSE HERE: no depth means the model is printed exactly as it was
// before this existed. A placeholder or a stray separator in that case is the defect this pins,
// so the token is built by mapping over the depth rather than by interpolating an optional.
check("an unknown depth leaves the model token untouched",
      lineSource.contains("""
    let modelToken = sessionModel.map { model -> String in
        let base = depth.map { "\\(model) \\(dim)\\($0)\\(reset)" } ?? model
        return flagshipPiece.map { "\\(base) \\($0)" } ?? base
    }
"""))

// MARK: - The flagship window rides beside the model, not as a third quota slot

// SESSION MODEL, NOT ACCOUNT WINDOW: the flagship piece only fills in when the window an account
// publishes actually names the model this session is running. Asserted as the exact match rule
// (a prefix test on both sides lower-cased) so a looser or reversed comparison fails this rather
// than passing on a coincidence.
check("the flagship window is matched by name against the session's own model",
      lineSource.contains("model.hasPrefix(windowName)"))
check("…both sides lower-cased, so \"Fable\" matches \"Fable 5.1\" case-insensitively",
      lineSource.contains("account.modelWindowName?.lowercased()")
          && lineSource.contains("sessionModel?.lowercased()"))
// AND NOT EMPTY: `hasPrefix("")` is true of every string, so an empty window name must be turned
// away before it ever reaches the prefix test - otherwise it would match every session's model.
check("an empty flagship window name is turned away before the prefix test",
      lineSource.contains("!windowName.isEmpty"))
// ONE ASSIGNMENT, ONLY INSIDE THE MATCH: `flagshipPiece` starts nil (declared as `var ... : String?`
// with no initial value) and the only place anything is ever assigned to it is behind the match
// guard above - a fallback model, a Codex account, or either field missing all fall through that
// guard and leave the var exactly as declared, which is what the model token's own `?? base`
// fallback (pinned above) renders unchanged.
check("the flagship piece starts unset",
      lineSource.contains("var flagshipPiece: String?"))
check("…and is assigned in exactly one place: inside the match guard",
      lineSource.components(separatedBy: "flagshipPiece = ").count == 2)
// NO NAME ON THE FLAGSHIP PIECE: the window's own name already rides on the model token it
// follows, so the piece itself must not repeat it - that is the whole reason `piece()`'s name
// became optional rather than gaining a second formula.
check("the flagship piece asks `piece()` for no name of its own",
      lineSource.contains("flagshipPiece = piece(nil, account.modelRemaining, account.modelResetsAt)"))
// SAME METER FORMULA, NOT A COPY: `piece()`'s name parameter turned optional rather than a second
// nameless function appearing beside it - the tint/meter/ETA rules the 5h and 7d slots use are the
// exact same call for the flagship piece.
check("`piece()` grew an optional name rather than being duplicated",
      lineSource.contains("func piece(_ name: String?, _ remaining: Double?, _ resetsAt: Date?) -> String?")
          && lineSource.components(separatedBy: "func piece(").count == 2)
// NOT A THIRD QUOTA SLOT: the flagship piece must never join the `quota` array the 5h/7d slots
// build (asserted above as "built together, with nothing between them") - it rides the model
// token instead, appended in the `modelToken` fallback pinned above.
check("the flagship piece never joins the account's own quota array",
      !lineSource.contains("quota = [piece(\"5h\", account.sessionRemaining, account.sessionResetsAt),\n"
          + "                 piece(\"7d\", account.weeklyRemaining, account.weeklyResetsAt),\n")
          && !lineSource.contains(", flagshipPiece]"))
// And the read is inside the liveness guard the other per-pid readings sit behind: a dead
// supervisor's leftover file must not paint a depth this session is not running at.
if let guardRange = lineSource.range(of: "supervisorAlive(pid) {"),
   let readRange = lineSource.range(of: "readSessionContext(pid: pidStr)") {
    check("the depth is only read while that supervisor is alive",
          guardRange.upperBound < readRange.lowerBound)
} else {
    check("the depth is only read while that supervisor is alive", false)
}

// MARK: - The pool label, in the surface that still prints one

// A model pool says WHICH pool it is, because the panel's gauge focus can re-point what a report
// names and a bare "pool" flipping between budgets reads as a wrong number. Lower-cased, because
// the rest of the report is.
check("a model pool names itself", poolLabel("Fable") == "fable pool")
check("a pool name is lower-cased into the report", poolLabel("OPUS") == "opus pool")
check("the weekly pool is the unnamed one", poolLabel(nil) == "pool")

// MARK: - The pool figure

// The share of the pool still unspent, as a percent. It reads that way because it was born in the
// status line's row beside two windows already quoted in percent; the row is gone and the reading
// stays, since `tally status` prints it next to the same per-account percentages. Accounts' worth
// stays in the panel, where there is room to say what the units are.
check("a pool with 60 of 500 account-points left reads as a percent",
      poolRemainingFigure(remaining: 60, capacity: 500) == "12%")
check("the figure carries no denominator any more",
      !poolRemainingFigure(remaining: 60, capacity: 500).contains("/"))
check("a full pool is 100%", poolRemainingFigure(remaining: 200, capacity: 200) == "100%")
check("a dry pool is 0%", poolRemainingFigure(remaining: 0, capacity: 200) == "0%")
// Whole numbers only: the report line carries one of these per pool.
check("a half point rounds rather than truncating",
      poolRemainingFigure(remaining: 25, capacity: 200) == "13%")
check("and rounds down below the half",
      poolRemainingFigure(remaining: 24, capacity: 200) == "12%")
check("a fraction of a percent still shows as a percent",
      poolRemainingFigure(remaining: 1, capacity: 500) == "0%")
// The caller filters these out; the guard exists because `Int(Double.infinity)` traps, which would
// take the whole report down rather than dropping one pool from it.
check("a pool with no capacity is a figure, not a crash",
      poolRemainingFigure(remaining: 5, capacity: 0) == "0%")

// MARK: - The bar the figure was drawn beside

// The meter and the figure read the same ratio, which was the other half of that change: while the
// figure was accounts' worth, a bar drawn from the percentage was the only thing in the slot the
// number did not describe. Kept as the rule for whoever draws a pool bar next - the app's gauge
// draws one today - because it is the invariant, not the caller.
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

// MARK: - The one human surface that prints a pool

// `tally status`'s fleet line is now the only one, and it reads in percent for the reason above.
// It cannot be asked for its output here (it prints and returns nothing), so the source carries the
// invariant, the same technique the supervisor suite uses for its call-site rules. Run from the repo
// root (run-statusline-tests.sh cds there), and a missing file FAILS rather than quietly passing.
let statusSource = (try? String(contentsOfFile: "TallyCLI/main.swift", encoding: .utf8)) ?? ""
check("the status source is readable from the status line checks", !statusSource.isEmpty)
check("`tally status` prints the same pool figure",
      statusSource.contains("poolRemainingFigure(remaining: pool.remaining, capacity: pool.capacity)"))
check("and the same pool label", statusSource.contains("poolLabel(pool.poolName)"))
check("with no accounts'-worth formatting left in either CLI source",
      !statusSource.contains("%.1f/%d") && !lineSource.contains("%.1f/%d"))
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
// Ends at the dispatch rather than at `func runResume(`, which is where it used to end: resume
// moved to ResumeCommand.swift when main.swift reached the 500-line cap (2026-08-13), and an anchor
// that is no longer in this file makes the slice empty, which passes nothing and fails everything.
let statusBody = statusSource.range(of: "func runStatus(").flatMap { start in
    statusSource.range(of: "// MARK: - Entry").map { end in
        String(statusSource[start.lowerBound ..< end.lowerBound])
    }
} ?? ""
check("the status command is readable on its own", statusBody.contains("func runStatus("))
check("…and the slice stopped at the next thing rather than swallowing the file",
      !statusBody.contains("case \"status\", nil:"))
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

runCompletionChecks()

exit(failures == 0 ? 0 : 1)
