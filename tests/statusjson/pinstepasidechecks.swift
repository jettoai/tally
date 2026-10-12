import Foundation

// The markers `tally status` prints for a pin whose account has just capped (B-1540): the arrow
// follows the launch onto the smart pick while another account can take it, and the pin marker
// stays where the pin points.
func pinStepAsideMarkerChecks() {
    // Exactly as runLaunch now launches it: the pin marker stays on the account it names.
    let pinnedHeld = parse(encodeStatusReport(statusReport(
        snapshot,
        policies: ["claude": LaunchPolicy(mode: "manual", pinnedAccountID: "claude:.claude2")],
        quarantined: ["claude": ["claude:.claude2"]], now: now)))
    check("quarantine: a pin over a held account steps aside, so its sibling takes the marker",
          account(pinnedHeld, "claude:.claude")["best"] as? Bool == true
              && account(pinnedHeld, "claude:.claude2")["best"] as? Bool == false)
    check("quarantine: …and the pin is still named where it points",
          account(pinnedHeld, "claude:.claude2")["pinned"] as? Bool == true)
    // With nowhere else to land, the pin launches as before ("launching it anyway").
    let pinnedAllHeld = parse(encodeStatusReport(statusReport(
        snapshot,
        policies: ["claude": LaunchPolicy(mode: "manual", pinnedAccountID: "claude:.claude2")],
        quarantined: ["claude": ["claude:.claude", "claude:.claude2"]], now: now)))
    check("quarantine: a pin with nowhere to step aside to keeps the marker",
          account(pinnedAllHeld, "claude:.claude2")["best"] as? Bool == true)
}
