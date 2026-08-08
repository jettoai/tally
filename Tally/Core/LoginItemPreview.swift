import Foundation

/// Which login-item state the "Start at login" row is standing in for
/// (`-TallyLoginItemPreview requiresApproval`, demo or dev builds only, argument domain so nothing
/// persists): the row draws that state and can be operated against a fixture, with SMAppService
/// never asked and never told anything.
///
/// It exists because this row's design lives almost entirely in states nobody can reach on
/// purpose. A reviewer looking at a normal build sees "on" or "off"; the four sentences that are
/// the actual feature (macOS holding a registration back, a login item macOS cannot find, a status
/// this build does not know, and a failure that has to disappear once its cause is settled) need a
/// denied consent or a broken install to appear. Same family as `-TallyTooltipPreview`,
/// `-TallyUpdateChip` and `-TallyEmptyStatePreview`, and the same rule behind all of them: a
/// dev-only flag that puts the state on screen is the sanctioned answer, because the alternatives
/// are synthesizing input into somebody's desktop or asking them to break their own login items
/// (~/.claude/docs/patterns/macos-app-verification.md).
///
/// A fixture is an OBSTRUCTION plus a registration, not just a state, and that is the whole reason
/// the row can be operated rather than merely looked at. macOS does not stop refusing because the
/// user flipped a switch, so neither does this: a held-back fixture switched off and back on is
/// held back again, which is precisely the loop the row's notice tells the user they cannot win.
/// Collapsing it to a bare state would make the second press succeed and the preview would be
/// teaching the opposite of what ships.
enum LoginItemPreview {
    /// The volatile launch flag. Argument domain, like every other capture flag, so it applies to
    /// one launch and a normal one is untouched.
    static let flagKey = "TallyLoginItemPreview"

    /// What stands between the fixture and a login item that runs.
    enum Obstruction: Equatable {
        /// Nothing: the switch behaves the way it does on a healthy machine.
        case unobstructed
        /// Consent withheld in System Settings. Registering keeps working and keeps not running.
        case awaitingApproval
        /// macOS finds no such service, whatever it is asked.
        case missing
        /// macOS answers with a status this build has no name for.
        case unrecognized
    }

    struct Fixture: Equatable {
        var obstruction: Obstruction
        var registered: Bool

        /// The state the row draws, derived rather than stored so a fixture cannot hold a pair the
        /// real API could never report (registered and missing at the same time, say).
        var state: LaunchAtLoginState {
            switch obstruction {
            case .missing: return .notFound
            case .unrecognized: return .unknown
            case .awaitingApproval: return registered ? .requiresApproval : .notRegistered
            case .unobstructed: return registered ? .enabled : .notRegistered
            }
        }
    }

    /// Whether this build may preview at all, as a decision rather than a read, so the rule can be
    /// asserted from a test process that is neither.
    ///
    /// The same gate the rest of the capture family uses, and deliberately NOT `isUnshipped`, which
    /// gates the row's write path. The two answer different questions and the sets differ in both
    /// directions: `isUnshipped` would refuse a shipped build running `-TallyDemoData` (breaking the
    /// one path this family exists to serve, a screenshot of a surface) while admitting a copy run
    /// straight out of a downloaded DMG, which is a REAL user, and the last person who should be
    /// shown an invented answer about their own login items. Being a build nobody installed is a
    /// reason not to touch the system; it is not a reason to be trusted with fiction.
    static func previewable(isDemo: Bool, isDev: Bool) -> Bool { isDemo || isDev }

    /// What this launch previews, or nil on every normal launch.
    static var fixture: Fixture? {
        fixture(named: UserDefaults.standard.string(forKey: flagKey),
                isDemo: DemoUsage.isActive, isDev: BuildVariant.isDev)
    }

    /// The whole rule as a function of its three inputs, so "a normal build previews nothing, no
    /// matter what the flag says" is a thing a test can state exhaustively rather than a thing a
    /// reader has to trace. The property above is this with the inputs read.
    static func fixture(named raw: String?, isDemo: Bool, isDev: Bool) -> Fixture? {
        guard previewable(isDemo: isDemo, isDev: isDev) else { return nil }
        return fixture(named: raw)
    }

    /// The flag's value as a fixture, with the build gate left out so the gate and the spelling can
    /// be asserted apart.
    ///
    /// Punctuation and case are thrown away before matching, because the four names are read off a
    /// state enum and get typed back as `notFound`, `not-found` and `not found` by the same person
    /// in the same afternoon. An unrecognized word previews NOTHING rather than guessing: the
    /// failure mode of a guess here is a row quietly showing fiction to somebody who thought they
    /// had asked for something else.
    static func fixture(named raw: String?) -> Fixture? {
        let key = (raw ?? "").lowercased().filter(\.isLetter)
        switch key {
        case "enabled": return Fixture(obstruction: .unobstructed, registered: true)
        case "notregistered": return Fixture(obstruction: .unobstructed, registered: false)
        case "requiresapproval": return Fixture(obstruction: .awaitingApproval, registered: true)
        case "notfound": return Fixture(obstruction: .missing, registered: false)
        case "unknown": return Fixture(obstruction: .unrecognized, registered: false)
        default: return nil
        }
    }

    /// The names the flag accepts, for the one place that has to list them.
    static let names = ["enabled", "notRegistered", "requiresApproval", "notFound", "unknown"]

    /// What pressing the switch does to a fixture: the new fixture, and the failure the attempt
    /// would have thrown, raw and unfiltered.
    ///
    /// Raw on purpose. The row puts this through `LaunchAtLoginState.surviving` exactly as it puts
    /// a real thrown error, so what the preview shows is produced by the shipping rule and not by a
    /// second one written to look like it. That is what makes it worth showing to a reviewer: a
    /// preview with its own idea of when a failure disappears would prove nothing about the app.
    static func pressing(_ wanted: Bool, on fixture: Fixture)
        -> (fixture: Fixture, failure: LaunchAtLoginFailure?) {
        var next = fixture
        switch fixture.obstruction {
        case .unobstructed:
            next.registered = wanted
            return (next, nil)
        case .awaitingApproval:
            next.registered = wanted
            // Registering succeeds and still will not run, so macOS reports the denial. The row
            // drops this line because `.requiresApproval` says it better; seeing that happen is
            // half the point of previewing this state.
            return (next, wanted ? LaunchAtLoginFailure(
                wanted: wanted, message: "Operation not permitted") : nil)
        case .missing, .unrecognized:
            // Nothing the switch does reaches a service macOS cannot find, so the state does not
            // move and the failure is the only thing that answers.
            return (next, LaunchAtLoginFailure(
                wanted: wanted, message: "The specified service did not ship with this app."))
        }
    }

    /// How a launch opens the Settings window. A preview launch differs in exactly two respects,
    /// and the type exists so those two are named rather than left as bare booleans at a call site.
    struct SettingsOpening: Equatable {
        /// Start on the Launch pane, where the previewed row lives, instead of the usual Accounts.
        ///
        /// A flag whose whole job is putting one row in front of a reviewer has not done it if the
        /// window opens on a different pane and leaves them to find it. That is not hypothetical:
        /// the first version opened Settings and landed on Accounts, and the reviewer saw the
        /// account list and no login item row at all.
        let onLaunchPane: Bool

    }

    /// How this launch opens it.
    static var settingsOpening: SettingsOpening { settingsOpening(previewing: fixture) }

    /// The rule as a function of the fixture, so both answers can be asserted from a process that
    /// is previewing nothing.
    static func settingsOpening(previewing fixture: Fixture?) -> SettingsOpening {
        SettingsOpening(onLaunchPane: fixture != nil)
    }

    /// Whether a launch previewing `fixture` and carrying nothing else may pull the app forward.
    ///
    /// A view of `CaptureLaunch`'s rule from this one flag, not a second copy of it: the foreground
    /// policy belongs to the whole capture family and is stated there. Kept because two callers
    /// reason about the login-item preview specifically, and because it pins the membership that
    /// makes a preview launch a background one at all.
    ///
    /// The paths this governs, which is the point rather than any individual fix: both window
    /// restores (`MainWindowController` and `SettingsWindowController`) call `NSApp.activate` and
    /// are wired through the launch-wide answer; the pinned panel's restore orders its panel front
    /// but never activates, so it cannot take the foreground from another app; and the updater's
    /// alerts do activate but stay dormant without a feed URL, which is exactly the build a
    /// preview runs in.
    static func mayTakeForeground(previewing fixture: Fixture?) -> Bool {
        CaptureLaunch.mayTakeForeground(
            activeKeys: fixture == nil ? [] : [CaptureLaunch.loginItemPreview])
    }

    /// The fixture after the trip the row's button offers: consent given, login item present.
    ///
    /// In a preview launch that button does NOT open System Settings, it lands here instead. Going
    /// to Login Items and coming back is the one sequence a reviewer has to watch (it is what makes
    /// a stale failure line disappear), and it is also the one sequence that cannot be staged: the
    /// real panel would be showing the reviewer's own login items, where the fixture does not exist
    /// and nothing they clicked would change what the row says.
    static let settledInSystemSettings = Fixture(obstruction: .unobstructed, registered: true)
}
