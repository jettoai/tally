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
    // The account name only carries information when there is a choice: with one account it
    // reads as noise next to a Claude session, so the status signal stands alone.
    let siblings = snapshot?.accounts.filter { $0.provider == "claude" }.count ?? 0
    let identity = [statusPiece, siblings > 1 ? "\(dim)\(label)\(reset)" : nil]
        .compactMap { $0 }.joined(separator: " · ")
    let input = FileHandle.standardInput.readDataToEndOfFile()

    // The quota pieces: per-window remaining as a mini meter bar + percent (tinted by room
    // left) + reset countdown. Built once, used by the standalone line and the full-quota
    // wrapped line alike; empty when the snapshot is stale or the account is unknown.
    // Session model, straight from the status-line JSON (tracks live switches/degradations);
    // the configured launch model is the fallback when the JSON carries none.
    let sessionJSON = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
    let sessionModel = (sessionJSON?["model"] as? [String: Any])?["display_name"] as? String

    var quota: [String] = []
    var fleetPiece: String?
    /// Identity slot 3: the session model, WEARING ITS OWN METER when it has a dedicated
    /// window ("Fable 5 ██ 12% (27h)"); name-only for models without one ("Opus 4.8"). The
    /// name and its budget travel together, so the quota zone needs no label for it and no
    /// word repeats. Starts as the bare name and upgrades below once the account is known.
    var modelToken = sessionModel
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
        // The fleet piece: the whole provider pool as ONE slot with its own label, in the
        // panel gauge's units (accounts' worth left - a remaining number by nature) plus the
        // pace forecast. Present only while the app's fleet gauge is on (same switch, same
        // meaning; launch mode is deliberately irrelevant).
        if let fleet = snapshot?.fleet?["claude"], fleet.capacity > 0 {
            let remainingPct = fleet.remaining / fleet.capacity * 100
            let tint = tintFor(remainingPct)
            let worth = String(format: "%.1f/%d", fleet.remaining / 100,
                               Int((fleet.capacity / 100).rounded()))
            // "pool", not "fleet": the DATA label matches the panel's own ("Weekly pool") -
            // "fleet" stays the FEATURE's name (the gauge, the Settings toggle, the README).
            // A model pool says WHICH ("fable pool"): the gauge focus can re-point this slot,
            // and a bare "pool" flipping between budgets read as a wrong number (panel rule:
            // pool names are always spelled out).
            let label = fleet.poolName.map { "\($0.lowercased()) pool" } ?? "pool"
            var text = "\(dim)\(label)\(reset) \(meter(remainingPct, tint)) \(tint)\(worth)\(reset)"
            if let dryAt = fleet.dryAt, dryAt > now {
                text += " \(dim)(~\(shortETA(dryAt.timeIntervalSince(now))))\(reset)"
            } else if fleet.sustainable {
                text += " \u{1B}[38;5;71m✓\(reset)"
            }
            fleetPiece = text
        }
        // The model wears its meter only when THIS session is actually consuming its window: a
        // sonnet session doesn't burn the Fable window, so quota there is noise (the fleet-wide
        // Fable story lives in the panel). Matched against the live session model, falling
        // back to the configured launch model; unknowable → shown (info beats absence).
        if let windowName = account.modelWindowName {
            let reference = sessionModel ?? launchPolicy("claude").model ?? windowName
            if reference.lowercased().contains(windowName.lowercased()) {
                modelToken = piece(sessionModel ?? windowName,
                                   account.modelRemaining, account.modelResetsAt) ?? modelToken
            }
        }
        // The account's own 7d yields to the fleet slot when the pool is shown: under smart
        // handoff the pool IS the weekly budget, and two weekly numbers side by side confuse.
        quota = [piece("5h", account.sessionRemaining, account.sessionResetsAt),
                 fleetPiece == nil
                     ? piece("7d", account.weeklyRemaining, account.weeklyResetsAt) : nil]
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
        // rely on Tally's. The line is ours, so the account always shows here. Three zones
        // (identity | this account's windows | the fleet pool), separated by | so the
        // single-account numbers and the whole-fleet number never read as one list.
        if snapshot?.statuslineFullQuota == true, !quota.isEmpty {
            // The session model always rides the identity, same fixed position for every
            // model - one grammar, no conditional homes. The custom line above may show a
            // model of its own, but THIS line's model is the one tally launched or adopted.
            let identityZone = [statusPiece, "\(dim)\(label)\(reset)", modelToken]
                .compactMap { $0 }
                .joined(separator: " · ")
            let richLine = [identityZone, quota.joined(separator: " · "), fleetPiece ?? ""]
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
    print([identityZone, quota.joined(separator: " · "), fleetPiece ?? ""]
        .filter { !$0.isEmpty }
        .joined(separator: " \(dim)|\(reset) "))
    exit(0)
}
