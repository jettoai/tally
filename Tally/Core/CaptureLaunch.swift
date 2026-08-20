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
/// observed without taking the observer's desktop away? The ones that answer no are in
/// `interactiveKeys`, and they exist to be DRIVEN by hand instead. Driving something means being in
/// front of it, so they are not in the family. It costs nothing either way, since a plain `open`
/// activates the app regardless, but the family means something only while it is defined by purpose
/// rather than by convenience.
///
/// The `modifierKeys` are absent for a different reason: they are modifiers, inert without the flag
/// they qualify, and that flag is in the list. A launch carrying one of them alone is showing
/// nothing and has nothing to protect.
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

    /// The Settings window held open for a capture. Named for the same reason, and spelled HERE
    /// rather than beside the code that reads it (`SettingsCaptureLaunch`): that code reaches
    /// SwiftUI, and the classification below must stay compilable on its own, which is what lets the
    /// completeness check compile this file without the app.
    static let settingsCapture = "TallySettingsCapture"

    /// Every flag whose launch is here to be observed. Grouped by what they put on screen.
    static let backgroundKeys: [String] = [
        // Fixtures and chrome the whole app is captured through.
        "TallyDemoData",        // fixture accounts, the README and marketing shots
        "TallyAppearance",      // pins this instance light or dark for a capture
        "TallyCardStyle",       // which glass variant, judged on screen rather than in a diff
        "TallySessionCardCap",  // how wide a session card may get, the same judgement on the board
        // Surfaces held open so they can be photographed without synthesized input.
        "TallyPanelCapture",    // the pinned usage panel
        "TallyTab",             // which of that surface's pages it opens on (SurfaceTabLaunch)
        // The Settings window, and which pane it opens on: one flag rather than two, because the
        // pane is the value it carries (SettingsCaptureLaunch).
        settingsCapture,
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

    /// Flags that qualify another flag and show nothing on their own. Inert alone, and the flag
    /// each of them qualifies is in `backgroundKeys`, so a launch carrying one is answered by its
    /// parent.
    static let modifierKeys = ["TallyUpdateChipReady", "TallyUpdateChipBusy", "TallyTokenGraphHover",
                               // The pick panel with a row already circled, which is the state its
                               // apply bar exists for and the one state of it no fixture can reach:
                               // the circle rests on the row the session is already on, so a panel
                               // that has never been touched has nothing pending by construction
                               // (`pickColumnSelection`). Reaching it otherwise means synthesized
                               // clicks on somebody's desktop.
                               "TallyPickPending"]

    /// The override that hands the pick claim back to a build that has stood down
    /// (`pickMayBeClaimed`). Named for the same reason `loginItemPreview` is: the panel's gate asks
    /// about this flag specifically, and a second spelling of the key would gate on a different flag
    /// from the one classified here.
    static let pickClaimOverride = "TallyPickClaim"

    /// HOW LONG THAT OVERRIDE LASTS, counted from the launch that carried it.
    ///
    /// THE INCIDENT (2026-08-10, twice in one day): a dev instance started to test one thing and
    /// then left running answered a real `/tally-account`, both times because nobody closes a
    /// window they have stopped thinking about. An override with no end is a stand-down that lasts
    /// exactly as long as somebody's attention does. Thirty minutes outlasts a session of driving
    /// the picker by hand and expires well inside an afternoon: too short costs a developer one
    /// relaunch of a build they are sitting in front of, too long costs somebody else's
    /// conversation, silently. Asked as arithmetic when a request knocks (`pickMayBeClaimed`)
    /// rather than by a timer that switches the flag off, so nothing has to fire and nothing has
    /// to be cancelled, and a build that slept for an hour is answered like one that was busy.
    static let pickClaimOverrideLifetime: TimeInterval = 30 * 60

    /// Flags that exist so something can be DRIVEN by hand rather than looked at, which is the other
    /// answer to the family's one question. Driving something means being in front of it, so these
    /// are not the family, and that is a statement about purpose rather than about cost (a plain
    /// `open` activates either way).
    ///
    /// Two of them point a chain at a stand-in binary: probe, verdict, chip, click, renewal. The
    /// third hands a stood-down build back a capability instead of substituting anything, and it is
    /// here on the same test: a developer answering the pick panel to see what a real request does
    /// is working the app, not observing it.
    ///
    /// The first two were missed by a scan for `forKey:`, because both reach the defaults through a
    /// named constant instead. That is why the completeness check now scans for the LITERALS rather
    /// than for any particular way of looking one up.
    static let interactiveKeys = ["TallyRenewLoginCLI", "TallyLoginStatusCLI", pickClaimOverride]

    /// Every launch flag this app has, in exactly one bucket each. The completeness check compares
    /// this against the flags actually spelled in the source, so a new one cannot be added without
    /// somebody deciding which bucket it is in.
    static var allFlagKeys: [String] { backgroundKeys + modifierKeys + interactiveKeys }

    /// Whether a launch carrying exactly these flags may pull the app forward on its own.
    ///
    /// One answer for the whole launch, asked by every startup path that shows a window without
    /// anybody having clicked anything. Phrased over the set rather than over any single flag so
    /// that a launch combining several (a demo panel capture in dark mode is three) is answered
    /// once, the same way.
    static func mayTakeForeground(activeKeys: Set<String>) -> Bool {
        activeKeys.isDisjoint(with: backgroundKeys)
    }

    /// Whether a surface being raised right now may take the foreground.
    ///
    /// `prompted` = somebody asked for it just now and is waiting on it: a click, or a command they
    /// typed that will not finish until they answer. Those always come forward, whatever the launch
    /// was for, because being in front of the person who asked IS the surface working. Everything
    /// unprompted asks the family instead.
    ///
    /// The two go through one function so that "which of these is this?" is a decision with a name
    /// rather than a default argument somebody remembers to override. The pick panel has one of
    /// each: the picker a CLI is blocked on, and the same panel raised by a launch flag for a look.
    static func mayTakeForeground(prompted: Bool, activeKeys: Set<String>) -> Bool {
        prompted || mayTakeForeground(activeKeys: activeKeys)
    }

    /// This launch's answer for anything unprompted.
    static var launchMayTakeForeground: Bool { mayTakeForeground(activeKeys: activeKeys()) }

    /// Which of the family this launch carries.
    static func activeKeys(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(backgroundKeys.filter { carries($0, in: defaults) })
    }

    /// Whether this launch carries one named flag, in whatever shape its value arrived (`isActive`).
    /// For the flags asked about one at a time rather than as a set: the family is answered over the
    /// whole launch, an override is answered about itself.
    static func carries(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        isActive(rawValue: defaults.object(forKey: key))
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
