import Darwin
import Foundation

// The `tally statusline claude` subcommand: everything Claude Code's status line renders for a
// session under Tally. Split from main.swift for file size; selection/launch plumbing stays in
// Snapshot.swift.

/// `tally statusline claude` - Claude Code's statusLine hook (registered by the app's
/// Integrations pane): reads the session JSON claude pipes on stdin, prints "account · model".
/// The account is whichever home this claude was launched with (the hook inherits its env),
/// labeled with the user's nickname from the snapshot. Fail-open at every step: a status line
/// must render SOMETHING, never error.
func runStatusline(args: [String]) -> Never {
    let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
    let (snapshot, problem) = loadSnapshot()
    let label = snapshot?.accounts.first { $0.launchHome == home }?.label
        ?? URL(fileURLWithPath: home).lastPathComponent
    // The working-state signal answers the user's actual unknown - "is this Claude session
    // under Tally's control?" - so it names Tally outright (the user already knows they are
    // in Claude; the env marker rides in from exec/supervisor/shim). A stale/missing snapshot
    // adds the off note: launched by Tally or not, steering data is dead.
    let steered = ProcessInfo.processInfo.environment["TALLY_LAUNCHED"] == "1"
    // Colors: the sparkle wears the same electric purple as the app's Smart badge (one brand
    // vocabulary for "Tally is steering"); the account stays dim (payload, not signal) and
    // the off note goes warning-yellow. Claude Code renders ANSI in status lines.
    let purple = "\u{1B}[38;5;135m", dim = "\u{1B}[2m", yellow = "\u{1B}[33m", reset = "\u{1B}[0m"
    let statusPiece: String? = steered
        ? (problem == nil
            ? "\(purple)✦ Tally\(reset)"
            : "\(purple)✦ Tally\(reset) \(yellow)(off)\(reset)")
        : (problem != nil ? "\(yellow)(tally off)\(reset)" : nil)
    // Supervision health: a session launched before an app update runs an OLD supervisor with stale
    // handoff logic, so say so while it replaces itself. The supervisor stamps its build into the
    // child env; a mismatch with THIS binary's version is "outdated", a missing stamp is "unknown"
    // (an old pre-stamp supervisor, or a deliberate --no-handoff launch - never asserted as
    // outdated).
    let supervisionPiece = supervisionStatus(
        steered: steered,
        supervised: ProcessInfo.processInfo.environment["TALLY_SUPERVISED"] != "0",
        supervisorVersion: ProcessInfo.processInfo.environment["TALLY_SUPERVISOR_VERSION"],
        installedVersion: supervisorBuildVersion()).note.map { "\(yellow)\($0)\(reset)" }
    // Model-drift badge: a Fable safeguard fell this session onto a fallback model and left it
    // there. The supervisor writes the from/to/category to a per-pid state file; render it only
    // while that supervisor still runs (a crashed supervisor's leftover file paints nothing). The
    // detection lives entirely in the supervisor - the status line only reads the state it left.
    //
    // The badge is also the whole announcement now: the supervisor used to print the fallback and a
    // five-minute reminder to stderr, over the child's own drawing, for something it was not about
    // to act on (PendingNotice.swift). A badge that stays up for the whole episode says it better
    // than two lines that say it twice and land on top of the input box.
    var driftPiece: String?
    var noticePiece: String?
    // The depth this session is running at, read off the same per-pid track as the two badges
    // below (SessionContext.swift).
    //
    // THE PIN LEADS AND THE COMMAND LINE FILLS IN, because the two ways a session's depth moves
    // leave their trace in different fields:
    //
    //   - `tally model fable high` rewrites the child's arguments and relaunches, so `runningEffort`
    //     (the `--effort` it was spawned with) is the fresh reading and no pin need exist at all.
    //     Most sessions are this one, which is why the fallback has to stay.
    //   - Claude Code's OWN `/model`, moving only the depth, is adopted into the pin with NO
    //     relaunch (`adoptNativeModelChoice`, SessionModel.swift): the arguments still name the
    //     depth this child started on, and `sessionEffort` is the only field that moved.
    //
    // So a pin, where there is one, is always the later fact. Neither present (an unsupervised
    // launch, a supervisor too old to publish it, the moment before the first tick) means "cannot
    // say", and the line does not mention the depth: fail-open, like everything else here.
    //
    // WHAT NEITHER FIELD SEES, said rather than left to be found: a depth moved underneath the
    // session (a safeguard or quota fallback) touches neither, so this names the depth that was
    // ASKED for. The model beside it does track that, because Claude Code reports the model it is
    // rendering for and reports no depth. Closing it needs a reading that does not exist yet.
    var depth: String?
    if let pidStr = ProcessInfo.processInfo.environment["TALLY_SUPERVISOR_PID"],
       let pid = pid_t(pidStr), supervisorAlive(pid) {
        // One read, both fields: this is a file, and the two answers have to come from one moment
        // of it or the pin and the arguments could be read either side of a republish.
        let context = readSessionContext(pid: pidStr)
        depth = context?.sessionEffort ?? context?.runningEffort
        if let drift = readDriftState(pid: pidStr) {
            // While a restore is queued the badge says what is about to happen, in the same
            // already-under-way voice as the supervisor's own update note: the session keeps working
            // at the wrong depth until it is left alone, which can be a while, and a restart nobody
            // announced reads as the session dying on its own. With nothing queued the session is
            // staying where it is until the user moves it, so the badge carries the way back.
            let tail = drift.restorePending
                ? ", restoring at idle"
                : ", /model \(shortModelName(drift.from)) to return"
            driftPiece = "\(yellow)⚠ \(shortModelName(drift.from))→\(shortModelName(drift.to)) " +
                "(\(drift.category))\(tail)\(reset)"
        }
        // What the supervisor is waiting to do (a queued reload, a model change held behind a busy
        // session, a cap with nowhere to go yet). Dim rather than yellow: nothing is wrong, it is
        // simply not happening yet.
        noticePiece = pendingNoticePiece(pid: pidStr).map { "\(dim)\($0)\(reset)" }
    }
    // The account name only carries information when there is a choice: with one account it
    // reads as noise next to a Claude session, so the status signal stands alone.
    let siblings = snapshot?.accounts.filter { $0.provider == "claude" }.count ?? 0
    let identity = [statusPiece, supervisionPiece, driftPiece, noticePiece,
                    siblings > 1 ? "\(dim)\(label)\(reset)" : nil]
        .compactMap { $0 }.joined(separator: " · ")
    let input = FileHandle.standardInput.readDataToEndOfFile()

    // The quota pieces: per-window remaining as a mini meter bar + percent (tinted by room
    // left) + reset countdown. Built once, used by the standalone line and the full-quota
    // wrapped line alike; empty when the snapshot is stale or the account is unknown.
    // Session model, straight from the status-line JSON (tracks live switches/degradations);
    // the configured launch model is the fallback when the JSON carries none.
    let sessionJSON = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
    let sessionModel = (sessionJSON?["model"] as? [String: Any])?["display_name"] as? String
    // WHILE WE HAVE IT: this same object names the conversation Claude Code is rendering for, which
    // is the one thing the supervisor otherwise has to GUESS (TranscriptIdentity.swift states the
    // three defects that guess produced). Reporting it here costs one small file read in the case
    // that is true on almost every render (nothing changed), and it cannot fail loudly: everything
    // behind this call is best-effort over small files, it prints nothing, and it never blocks. The
    // line below is drawn either way.
    //
    // AND WHERE THERE IS NO SUPERVISOR TO REPORT TO, the session records ITSELF instead
    // (UnmanagedLaunch.swift): a session nothing is watching is exactly the one the next launch in
    // this directory would otherwise resume into, on top of it. This render is the only place that
    // question can be asked of EVERY session whatever started it - a Tally launch, the PATH shim, or
    // the binary typed by hand - which is why it is asked here and not at the launcher, where it was
    // asked first and could only ever see the launches this program makes. The two channels and the
    // one walk up the process tree they share are composed in `publishConversationIdentity`, so the
    // rule can be asserted with injected inputs rather than read off this entry point.
    publishConversationIdentity(sessionID: sessionJSON?["session_id"] as? String,
                                cwd: sessionJSON?["cwd"] as? String)

    var quota: [String] = []
    /// Identity slot 3: the model this session is running, with the depth it runs at beside it -
    /// name only, every model the same shape. The pair is what a person sets in one breath
    /// (`tally model fable high`), so the line reports it in one; the depth is dim because the
    /// model is the word being read and the depth qualifies it. No depth, no token of its own: an
    /// unknown one is left unsaid rather than drawn as a gap or a placeholder.
    ///
    /// TWO SOURCES IN ONE TOKEN, worth saying out loud: the model is what Claude Code reports it
    /// is rendering for (the session JSON below, which tracks a live switch or a degradation),
    /// while the depth comes from the supervisor's own per-pid reading - the only channel that
    /// carries one, with the precedence and the blind spot stated where it is read above.
    let modelToken = sessionModel.map { model in
        depth.map { "\(model) \(dim)\($0)\(reset)" } ?? model
    }
    if problem == nil, let account = snapshot?.accounts.first(where: { $0.launchHome == home }) {
        let now = Date()
        // The number and bar follow the panel's used/remaining toggle; the tint always keys
        // off remaining, so severity never flips with the toggle (same rule as the meters).
        let usedMode = snapshot?.displayMode == "used"
        // Same thresholds AND the same palette as the app's meters (TallyColor sage green /
        // amber / softened red, 256-colour approximations) - one brand vocabulary from the
        // panel to the terminal.
        func tintFor(_ remaining: Double) -> String {
            remaining < 20 ? "\u{1B}[38;5;167m"
                : remaining < 50 ? "\u{1B}[38;5;214m" : "\u{1B}[38;5;71m"
        }
        func meter(_ shownPct: Double, _ tint: String) -> String {
            let cells = 6
            let filled = min(cells, max(shownPct > 0 ? 1 : 0,
                                        Int((shownPct / 100 * Double(cells)).rounded())))
            return tint + String(repeating: "█", count: filled) + reset
                + dim + String(repeating: "░", count: cells - filled) + reset
        }
        func piece(_ name: String, _ remaining: Double?, _ resetsAt: Date?) -> String? {
            guard let remaining else { return nil }
            let tint = tintFor(remaining)
            let shown = usedMode ? 100 - remaining : remaining
            var text = "\(dim)\(name)\(reset) \(meter(shown, tint)) \(tint)\(Int(shown.rounded()))%\(reset)"
            if let resetsAt, resetsAt > now {
                text += " \(dim)(\(shortETA(resetsAt.timeIntervalSince(now))))\(reset)"
            }
            return text
        }
        // THIS ACCOUNT'S OWN WINDOWS, BOTH OF THEM, ALWAYS. The line used to hand the 7d slot over
        // to the fleet pool whenever the app's gauge was on, on the reasoning that under smart
        // handoff the pool is the budget that binds. The pool is a FLEET reading and this line is
        // a SESSION reading: what a person wants from the row under their prompt is the account
        // they are on and how much of it is left, and the fleet view is the app's job - the menu
        // bar and the panel draw it, with the room to say what its units are (owner ruling,
        // 2026-08-12). Two slots, unconditional, so the row has one shape whatever the app's
        // gauge is set to.
        quota = [piece("5h", account.sessionRemaining, account.sessionResetsAt),
                 piece("7d", account.weeklyRemaining, account.weeklyResetsAt)]
            .compactMap { $0 }
    }

    // Wrapped mode: the user's own status line (carried as base64 - see IntegrationsStore)
    // keeps the lead position, fed the same JSON; the account is appended. Augmentation,
    // never replacement.
    if let wrapIndex = args.firstIndex(of: "--wrap"), wrapIndex + 1 < args.count,
       let original = Data(base64Encoded: args[wrapIndex + 1])
           .flatMap({ String(data: $0, encoding: .utf8) }) {
        var body = ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", original]
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            stdinPipe.fileHandleForWriting.write(input)
            try? stdinPipe.fileHandleForWriting.close()
            let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // The WHOLE output passes through - multi-line status lines keep every line and
            // their layout (only line 1 survived at first, which would wreck them).
            body = String(data: out, encoding: .utf8)?
                .trimmingCharacters(in: .newlines) ?? ""
        }
        // No double identity: a status line that already names the account anywhere (by
        // nickname or by config-dir name) keeps its account rendering, gaining only the
        // working-state signals; otherwise the whole identity joins the LAST line, where a
        // width-padded first line can't be pushed out of shape.
        // Full-quota mode (opt-in via the app): the whole quota line joins on its OWN line
        // beneath the custom status line - for people who drop their own quota rendering and
        // rely on Tally's. The line is ours, so the account always shows here. Two zones
        // (identity | this account's windows), separated by | so the session's names and its
        // numbers never read as one list.
        if snapshot?.statuslineFullQuota == true, !quota.isEmpty {
            // The session model always rides the identity, same fixed position for every
            // model - one grammar, no conditional homes. The custom line above may show a
            // model of its own, but THIS line's model is the one tally launched or adopted.
            let identityZone = [statusPiece, supervisionPiece, driftPiece, noticePiece,
                                "\(dim)\(label)\(reset)", modelToken]
                .compactMap { $0 }
                .joined(separator: " · ")
            let richLine = [identityZone, quota.joined(separator: " · ")]
                .filter { !$0.isEmpty }
                .joined(separator: " \(dim)|\(reset) ")
            print(body.isEmpty ? richLine : "\(body)\n\(richLine)")
            exit(0)
        }
        let homeName = URL(fileURLWithPath: home).lastPathComponent
        let alreadyShown = body.localizedCaseInsensitiveContains(label)
            || body.localizedCaseInsensitiveContains(homeName)
        let addition = alreadyShown ? (statusPiece ?? "") : identity
        // A run of spaces in the last line means the script width-manages it (right-aligned
        // time/diff); appending inline would push that content off the edge (live incident
        // 2026-07-19: the git diff truncated to "+413 -1…"). The addition takes its own line
        // there; plain last lines keep the compact inline join.
        let widthManaged = body.split(separator: "\n").last?.contains("   ") ?? false
        print(addition.isEmpty ? body
              : body.isEmpty ? addition
              : widthManaged ? "\(body)\n\(addition)" : "\(body) · \(addition)")
        exit(0)
    }

    // Standalone mode: Tally IS the whole status line, so it always carries the quota story
    // itself. The model token always joins the identity, fixed position for every model - the
    // same one-grammar rule as the wrapped rich line above.
    let identityZone = [identity.isEmpty ? nil : identity, modelToken].compactMap { $0 }
        .joined(separator: " · ")
    print([identityZone, quota.joined(separator: " · ")]
        .filter { !$0.isEmpty }
        .joined(separator: " \(dim)|\(reset) "))
    exit(0)
}

// MARK: - The fleet pool slot in `tally status`
//
// These two live here for where they came from - the status line used to carry a pool slot of its
// own - and `tally status` is the one human surface left that prints a pool (main.swift). The
// status line above is a SESSION reading now: this account, this model, this account's windows.

/// What a pool slot is called. "pool", not "fleet": the DATA label matches the panel's own
/// ("Weekly pool") - "fleet" stays the FEATURE's name (the gauge, the Settings toggle, the README).
/// A model pool says WHICH ("fable pool"): the gauge focus can re-point what a report names, and a
/// bare "pool" flipping between budgets read as a wrong number (panel rule: pool names are always
/// spelled out).
func poolLabel(_ poolName: String?) -> String {
    poolName.map { "\($0.lowercased()) pool" } ?? "pool"
}

/// The figure `tally status` shows for a pool: how much of the WHOLE pool is still unspent, as a
/// percent, rounded to a whole number.
///
/// The pool's own units are accounts' worth (one account's full weekly window = 100), which is how
/// `capacity` is expressed and what the app's own gauge draws. Reading that out as "0.6/5" needed
/// its denominator carried along to mean anything, and sat beside windows already quoted in percent
/// - so the one figure in the row that was not a percentage was also the one nobody could read at a
/// glance. The share of capacity says the thing the row is for (how much is left) in the row's own
/// vocabulary, and the app is where the accounts' worth is shown with the space to explain it.
///
/// `status --json` keeps the raw `remaining`/`capacity` untouched: that is a versioned, additive
/// contract read by scripts, and the units are part of it. This is the human reading.
///
/// A pool with no capacity cannot have a share and is filtered out before this is called; it is
/// guarded rather than trusted because the division would otherwise produce an infinity, and
/// converting one to `Int` traps.
func poolRemainingFigure(remaining: Double, capacity: Double) -> String {
    guard capacity > 0 else { return "0%" }
    return "\(Int((remaining / capacity * 100).rounded()))%"
}
