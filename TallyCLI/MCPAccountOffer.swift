import Foundation

// THE ACCOUNTS A BARE `/tally-account` OFFERS, and the one sentence above them. Split out of
// MCPPicker.swift, which owns the models and the tools themselves: this is the half a person reads
// numbers off, and it is the half that grew when the windows gained their reset countdowns.

// MARK: - The accounts a bare `/tally-account` offers

/// The rows of the account dialog, drawn to MIRROR TALLY'S OWN PANEL.
///
/// A dialog raised over the menu bar sits inches from the panel listing the same fleet, and a person
/// reads them together: the third row here has to be the third row there, and the numbers have to
/// come in the order their eye already learned. So two things are taken from the panel rather than
/// from the listing this used to share:
///
///   - THE ORDER IS THE SNAPSHOT'S, which is what the panel renders (Claude, Claude 2, …). The
///     ranked order the text listing and the arrow-key menu use is deliberately not applied here.
///     Nothing is lost by it: the recommendation was never carried by the position, it is a TAG,
///     and it still is.
///   - THE FIELDS ARE THE PANEL'S: flagship window, then 5-hour, then weekly (measured against the
///     app 2026-08-07 - a row reading 54/86/47 is fable/session/weekly). The old
///     `session · weekly · flagship` order was the listing's, and reading a dialog whose columns
///     are shuffled against the window beside it is worse than reading either alone.
///
/// The ranked rows still come in, for the two things only they know: which accounts may be switched
/// to at all (a listed account with no launch home is not one), and which has the most headroom.
/// Accounts the ranking left out are left out here too.
///
/// THE VALUE IS THE ID. An account label can be a prefix of another one, and matching by label is
/// how a pick lands on the wrong account (SwitchMenu.swift); the row already knows exactly which
/// account it is, so it hands that over and `attemptSwitch(.pinAccount:)` skips the matcher
/// entirely (SwitchCommand.swift states why that is not merely a convenience).
func mcpAccountOptions(accounts: [Snapshot.Account], ranked rows: [SwitchFleetRow])
    -> [MCPPickOption] {
    // A PROJECTION OF THE PICKER'S ROWS rather than a second reading of the fleet: the two channels
    // must offer the same accounts in the same order with the same recommendation, and the only way
    // to be sure of that is for one of them to be the other one flattened. What the form adds is
    // only that its single string has to carry what the panel draws in three places.
    mcpAccountPickRows(accounts, ranked: rows).map { row in
        MCPPickOption(value: row.value,
                      label: [row.label, row.detail].compactMap { $0 }.joined(separator: "  ")
                          + (row.tags.isEmpty ? ""
                             : "  (\(row.tags.joined(separator: ", ")))"))
    }
}

/// The dialog those rows are the options of: ONE field, because moving a conversation is one
/// decision (the second axis the model dialog carries is that axis's own meaning, `mcpModelSchema`).
/// The counterpart to that one, and here for the same reason `mcpAccountPrompt` is: two tools raise
/// this dialog now, and a sentence spelled out at both is two sentences the day one is reworded.
func mcpAccountSchema(accounts: [Snapshot.Account],
                      ranked rows: [SwitchFleetRow]) -> [String: Any] {
    mcpEnumSchema(field: mcpAccountField, title: "Account",
                  description: "Where this conversation continues, from the end of this turn",
                  options: mcpAccountOptions(accounts: accounts, ranked: rows))
}

/// The three windows one account reads as, in the order the PANEL draws them (flagship, 5-hour,
/// weekly - measured against the app 2026-08-07). One formatter, because the form's option list and
/// the native picker's rows both show them and a person reading the two would notice a difference
/// before they noticed anything else.
///
/// WITH WHEN EACH ONE COMES BACK, which is half of what the number means: "session 12%" is a reason
/// to move the conversation if it refreshes in four hours and no reason at all if it refreshes in
/// six minutes, and the whole point of this list is choosing between accounts on it. The countdown
/// is `shortETA`, the same two-unit form the status line and the launcher's pick reason already
/// spend it in, so a person reading two surfaces reads one vocabulary.
///
/// A COUNTDOWN IS SAID ONCE. Every real fleet has the flagship window coming back on the weekly
/// boundary (measured across five accounts, 2026-08-10), so spelling both would put the same duration
/// twice in one line; the one that keeps it is the LAST window that reads that way, where the eye is
/// already looking for it. A window that really does come back at another time keeps its own.
///
/// ON WHAT IS DRAWN, NOT ON THE INSTANT, which is the correction of the first version of this rule
/// and it was caught on a live panel rather than reasoned about: the two boundaries in a real
/// snapshot are minted by separate readings and land seconds apart, so an equality test on the dates
/// passed them as different and the row read "fable 35% (3d13h) · session 98% (2h43m) · weekly 11%
/// (3d13h)". The repetition a person sees is the repetition of the WORDS, and that is what this
/// compares.
///
/// A reset in the past is not drawn at all: the snapshot is a file with an age (`snapshotMaxAge`),
/// and "(0m)" on a window that refreshed while nobody was looking says less than nothing.
func mcpAccountWindows(_ account: Snapshot.Account, now: Date = Date()) -> String {
    let flagship = account.modelWindowName?.lowercased() ?? "model"
    let windows = [(flagship, account.modelRemaining, account.modelResetsAt),
                   ("session", account.sessionRemaining, account.sessionResetsAt),
                   ("weekly", account.weeklyRemaining, account.weeklyResetsAt)]
    let countdowns = windows.map { _, _, resetsAt -> String? in
        guard let resetsAt, resetsAt > now else { return nil }
        return shortETA(resetsAt.timeIntervalSince(now))
    }
    return windows.indices.map { index -> String in
        let text = "\(windows[index].0) \(fmt(windows[index].1))"
        guard let countdown = countdowns[index],
              !countdowns[(index + 1)...].contains(countdown) else { return text }
        return "\(text) (\(countdown))"
    }.joined(separator: " · ")
}

/// What the release row is called on both channels, from the file both targets compile so the panel
/// and the form cannot come to call it different things.
let mcpAccountAutoLabel = pickAutoLabel

/// The line above those rows: which pool is being chosen from, and what choosing does.
///
/// Every account in this dialog belongs to one provider (the pickers speak for `providers[0]`), so
/// naming it and counting it is the whole of the grouping: "Claude ×5" is what the panel's own
/// heading says, and it tells a person at a glance that the five rows below are the machine's whole
/// Claude fleet rather than a filtered view of it. A snapshot carries no pool NAME to use instead,
/// so the provider is the name.
///
/// SEVERAL POOLS ARE NOT GROUPED HERE, deliberately: nothing on this path can produce a dialog
/// holding two of them today, and a grouping with no second case to test against is a shape that
/// would go wrong the first time it met one.
func mcpAccountPrompt(offering count: Int, provider: String, problem: String?) -> String {
    let pool = "\(provider.prefix(1).uppercased())\(provider.dropFirst()) ×\(count)"
    // The snapshot's own complaint leads, exactly as it does in the listing: every percentage in
    // the rows below is a reading of a file that old, and so is the recommendation drawn from them.
    return [problem, "\(pool) · Move this conversation to another account"]
        .compactMap { $0 }.joined(separator: "\n")
}
