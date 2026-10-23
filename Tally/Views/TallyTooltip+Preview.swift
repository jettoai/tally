import SwiftUI

// Design-capture holds for the hover callout (dev and demo builds only), moved out of
// TallyTooltip.swift to keep it under the file-length cap.
extension TallyTooltip {
    /// Which callout a design capture is holding open (`-TallyTooltipPreview fleet` /
    /// `-TallyTooltipPreview identity`, demo or dev builds only, argument domain so nothing
    /// persists): the named one shows with no pointer involved.
    ///
    /// It exists because the alternative is worse. A callout only appears under a real hover, so
    /// capturing one otherwise means synthesizing mouse events into the app, which takes the
    /// user's desktop away from them for as long as the verification runs (the rule, and the
    /// incident behind it, are in ~/.claude/docs/patterns/macos-app-verification.md: a dev-only
    /// flag that puts the state on screen IS the sanctioned answer). Same family as
    /// `-TallyUpdateChip`, `-TallyEmptyStatePreview` and `-TallyDryNotifyTest`.
    ///
    /// It names ONE target rather than switching every forcible callout on, because all of them
    /// publish into a single preference slot: two forced at once would race for it, and the capture
    /// would show whichever the layout traversal reached last.
    enum PreviewTarget: String {
        case fleet
        case identity
        /// The kept account's shared-login mark (#6): one fixture under `-TallyDemoSharedLogin`.
        case sharedlogin
        /// The session board's update badge (`SessionCardView.supervisorBadge`), which forces itself
        /// only while the FIXTURES are on: exactly one demo session is watched by a build other than
        /// the installed one, so the demo board draws exactly one of these badges and there is
        /// nothing for a second forced callout to race with (`DemoSessions`). A dev build watching
        /// real sessions can have several behind at once, which is a race rather than a preview, so
        /// the card asks `DemoUsage.isActive` alongside this. Same guarantee the identity target
        /// buys by naming one fixture account, bought by a different means.
        case supervisor
        /// The session board's leftovers mark (`SessionLeftoversMark`), on the same terms as the
        /// badge above and for the same reason: a real machine can have several checkouts with work
        /// nobody is answering for, and every one of those marks would publish into this single
        /// slot. The demo board carries leftovers in exactly ONE project by construction
        /// (`DemoSessions.strayReadings`), so under the fixtures there is nothing to race with.
        case leftovers
        /// The session board's away badge (B-1540): `-TallyDemoPinAway` puts exactly one on the board.
        case pinaway
        /// The machine table's lid switch (a private build's pool strip). Shows on every MacBook row
        /// at once, so a capture wants a pool with exactly one MacBook in it.
        case lid
        /// The machine table's CPU figure on this Mac's row (a private build's pool strip). Only one
        /// row is local, so it does not race for the single preference slot.
        case topcpu
        /// Same for the memory figure.
        case topmemory
        /// Settings > Launch > Quota windows, one callout per row (B-2649).
        case settingsrelay, settingsquiet, settingssessionreset, settingscodexredeem
    }

    /// `-TallyTooltipPreview "row:Start with"`: the settings row of that title, for capturing every
    /// row's callout without a named target each (B-2649). Duplicate titles race for the one slot.
    static func previewRowForced(title: String) -> Bool {
        guard let raw = previewFlag else { return false }
        return raw == "row:" + title.lowercased()
    }

    static func previewForced(_ target: PreviewTarget) -> Bool {
        guard let raw = previewFlag else { return false }
        // `YES` predates the flag naming a target, and meant the fleet gauge - the only forcible
        // callout there was then. Kept working so an older capture command still captures.
        if target == .fleet, ["yes", "true", "1"].contains(raw) { return true }
        return raw == target.rawValue
    }

    /// The flag's value, lowercased; nil outside demo and dev builds, so a shipped build never holds one open.
    private static var previewFlag: String? {
        guard DemoUsage.isActive || BuildVariant.isDev else { return nil }
        return (UserDefaults.standard.string(forKey: "TallyTooltipPreview") ?? "").lowercased()
    }
}
