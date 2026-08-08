import Foundation

/// The launch flags that exist so something can be LOOKED AT, and the one policy they share: a
/// launch carrying any of them never pulls the app to the front by itself.
///
/// The policy started life inside the login-item state preview, which was the flag that needed it
/// first, and that was the mistake: every other capture flag has exactly the same requirement and
/// none of them were covered, so a launch asking for a panel snapshot still got yanked forward by
/// a window restore. What is scoped to one flag here is nothing; the family is the unit.
///
/// Membership is decided by PURPOSE, one question per flag: does this exist so something can be
/// observed without taking the observer's desktop away? The one flag that answers no is
/// `TallyRenewLoginCLI`, which points a renewal at a stand-in binary so the chain (menu, click,
/// renewal, verdict) can be DRIVEN by hand. Driving it means being in front of it, so it is not in
/// the family. It costs nothing either way, since a plain `open` activates the app regardless, but
/// the family means something only while it is defined by purpose rather than by convenience.
///
/// `TallyUpdateChipReady` and `TallyTokenGraphHover` are absent for a different reason: they are
/// modifiers, inert without the flag they qualify, and that flag is in the list. A launch carrying
/// one of them alone is showing nothing and has nothing to protect.
///
/// The asymmetry worth knowing when adding a flag: including one that did not need it changes
/// nothing observable, because a foreground launch is activated by macOS anyway and this only
/// suppresses the app's own second activation. LEAVING ONE OUT is the direction that breaks, and
/// it breaks silently, in the background, where nobody is watching. When unsure, include it.
enum CaptureLaunch {
    /// The login-item row's own state preview. Named because two other rules ask about it
    /// specifically (LoginItemPreview), and a second spelling of the key would put them on a
    /// different flag from this list.
    static let loginItemPreview = "TallyLoginItemPreview"

    /// Every flag whose launch is here to be observed. Grouped by what they put on screen.
    static let backgroundKeys: [String] = [
        // Fixtures and chrome the whole app is captured through.
        "TallyDemoData",        // fixture accounts, the README and marketing shots
        "TallyAppearance",      // pins this instance light or dark for a capture
        "TallyCardStyle",       // which glass variant, judged on screen rather than in a diff
        // Surfaces held open so they can be photographed without synthesized input.
        "TallyPanelCapture",    // the pinned usage panel
        "TallyTooltipPreview",  // one callout, which otherwise needs a real hover
        "TallyEmptyStatePreview",
        "TallyTokenGraphPreview",
        "TallyUpdateChip",      // the header's update nudge, with no live feed
        "TallyPickPreview",     // the pick panel, with no MCP client or request on disk
        loginItemPreview,
        // Artefacts written to disk rather than shown.
        "TallyStripSnapshot",   // the menu bar strip as a standalone PNG
        // Alerts posted to be looked at. A banner needs no focus, so taking it is pure cost.
        "TallyDryNotifyTest",
        "TallyResetHintTest",
        "TallyLoginExpiryTest",
    ]

    /// Whether a launch carrying exactly these flags may pull the app forward on its own.
    ///
    /// One answer for the whole launch, asked by every startup path that shows a window without
    /// anybody having clicked anything. Phrased over the set rather than over any single flag so
    /// that a launch combining several (a demo panel capture in dark mode is three) is answered
    /// once, the same way.
    static func mayTakeForeground(activeKeys: Set<String>) -> Bool {
        activeKeys.isDisjoint(with: backgroundKeys)
    }

    /// This launch's answer.
    static var launchMayTakeForeground: Bool { mayTakeForeground(activeKeys: activeKeys()) }

    /// Which of the family this launch carries.
    static func activeKeys(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(backgroundKeys.filter { isActive(rawValue: defaults.object(forKey: $0)) })
    }

    /// Whether a flag was carried, from whatever the defaults hold for it.
    ///
    /// Presence is the switch, because the family has no single value shape: `-TallyPanelCapture
    /// YES` is a boolean, `-TallyTooltipPreview fleet` names a target, `-TallyUpdateChip 0.15.0`
    /// carries a version, `-TallyStripSnapshot <path>` carries a path. What they share is being
    /// there. An explicit falsy value is still honoured, so a flag can be switched off in a saved
    /// command without deleting it, which is how these commands are actually edited.
    static func isActive(rawValue: Any?) -> Bool {
        switch rawValue {
        case let text as String: return !falsy.contains(text.lowercased())
        case let number as NSNumber: return number.boolValue
        case nil: return false
        default: return true
        }
    }

    private static let falsy: Set<String> = ["", "no", "false", "0", "off"]
}
