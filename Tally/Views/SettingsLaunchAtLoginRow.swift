import AppKit
import Combine
import SwiftUI

/// "Start at login": whether macOS starts Tally when the user logs in. It sits at the top of the
/// Launch pane, above the per-provider groups, and it is the one row there about THIS app
/// starting rather than about what a `tally` launch does.
///
/// The switch is drawn from `SMAppService.mainApp.status` and from nothing else, re-read when the
/// window appears, whenever the app comes forward, and after every write. A preference of our own
/// would keep reading "on" after the user revoked the login item in System Settings, and there is
/// no notification for that revocation, so coming back to the app is the closest thing to one.
/// Held in state rather than read inside `body` for the reason SettingsReloadRow gives: a query
/// in `body` re-runs on every unrelated redraw and still would not refresh at the moment it
/// matters.
///
/// The failure line under it gets the same treatment one step removed. It cannot be re-read (a
/// gesture's outcome is not something the machine remembers), so it is re-JUDGED against the state
/// on every refresh, in `LaunchAtLoginState.surviving(_:beside:)`. Left alone it would outlive its
/// cause: told the switch did not take, the user settles it under Login Items, comes back, and
/// reads "on, enabled" with "that failed" still under it.
///
/// Disabled for a build nobody installed (`BuildVariant.isUnshipped`), the same gate the
/// Integrations pane uses, for its reason plus one of its own. `SMAppService.mainApp` registers
/// the bundle that is RUNNING: "Tally Dev" only ever runs out of DerivedData, and a locally built
/// Release carries the installed app's bundle id (`ai.jetto.tally`, the dev flavour is
/// `ai.jetto.tally.dev`), so registering from one would take the installed app's login item over
/// and aim the next boot at a build directory. Both leave a login item pointed at a path that is
/// about to be deleted; the second does it wearing the installed app's name, which is the failure
/// BuildVariant.isBuildTree was written for.
///
/// Which leaves the dev build a reviewer actually looks at showing one greyed switch and a line of
/// apology, while the states worth reviewing need a denied consent to appear. `LoginItemPreview`
/// is the way in: `-TallyLoginItemPreview requiresApproval` and the row stands on a fixture it can
/// be operated against, with SMAppService neither asked nor told.
struct SettingsLaunchAtLoginRow: View {
    @State private var state: LaunchAtLoginState = .notRegistered
    /// The last register/unregister attempt that threw, for as long as the state beside it does
    /// not already explain itself. Filtered through `LaunchAtLoginState.surviving` on every write
    /// AND every refresh, never assigned past it.
    @State private var failure: LaunchAtLoginFailure?

    /// The fixture this row stands on for a dev preview launch (`-TallyLoginItemPreview`,
    /// LoginItemPreview), and nil on every normal launch. Non-nil is the single thing that diverts
    /// this row away from SMAppService, and it diverts BOTH directions at once: the three places
    /// below that would read or write a real login item each check it, so a preview launch asks
    /// macOS nothing and tells it nothing. Nil, and every line runs the code it ran before the flag
    /// existed.
    ///
    /// Seeded at construction rather than in `onAppear` so the first frame is already the previewed
    /// state: a frame of the greyed-out dev notice, in the one build a reviewer looks at this in,
    /// is a frame that could land in a screenshot.
    @State private var fixture: LoginItemPreview.Fixture? = LoginItemPreview.fixture

    /// A build nobody installed reads the login item but never writes it. A preview launch is
    /// operable regardless, which is the point of it: the gate exists to keep this row's hands off
    /// a real login item, and a fixture is not one.
    private var manageable: Bool { fixture != nil || !BuildVariant.isUnshipped }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Start at login")).font(.subheadline)
                Text(L("Tally is in the menu bar as soon as you log in, so a fresh boot still shows your quota."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if manageable {
                    if let key = state.noticeKey { notice(L(key)) }
                    if let failure { notice(failure.message) }
                    if state.offersSystemSettings {
                        Button(L("Open Login Items")) { openLoginItems() }
                            .controlSize(.small)
                            .padding(.top, 2)
                    }
                } else {
                    notice(L("Start at login is managed by the installed release app."))
                }
            }
            Spacer()
            // Both closures written out rather than passed as method references: a bare
            // `set: setRegistered` crashes swift-frontend in IRGen while building the isolation
            // thunk for it (Swift 6.3.3, "While emitting IR SIL function @$sSbScA_pSg…_TR").
            Toggle(isOn: Binding(get: { state.isRegistered },
                                 set: { setRegistered($0) })) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!manageable)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(TallyColor.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Ask what is true, from the fixture on a preview launch and from macOS otherwise.
    ///
    /// The real read happens even where the row cannot be operated: a locally built Release shares
    /// the installed app's identity, so the honest thing to show is that app's real login item,
    /// greyed out.
    private func refresh() {
        apply(fixture?.state ?? LaunchAtLoginService.current)
    }

    /// The one place what is on screen is decided. Every path ends here, an attempt and a preview
    /// press included, so a write and a re-read cannot reach different verdicts, and the failure
    /// line a reviewer watches disappear is filtered by the shipping rule rather than by anything
    /// the preview brought with it.
    private func apply(_ settled: LaunchAtLoginState) {
        state = settled
        failure = LaunchAtLoginState.surviving(failure, beside: settled)
    }

    private func setRegistered(_ registered: Bool) {
        if let fixture {
            let outcome = LoginItemPreview.pressing(registered, on: fixture)
            self.fixture = outcome.fixture
            failure = outcome.failure
            apply(outcome.fixture.state)
            return
        }
        var thrown: Error?
        do {
            try LaunchAtLoginService.setRegistered(registered)
        } catch {
            thrown = error
        }
        // Recorded raw, with what was asked for; `apply` decides whether it survives the state
        // macOS reports afterwards. That state is the answer even when the attempt threw: a denied
        // registration is still a registration, and it is what the notice above is written from.
        failure = thrown.map {
            LaunchAtLoginFailure(wanted: registered, message: $0.localizedDescription)
        }
        refresh()
    }

    /// On a normal launch this opens System Settings. On a preview launch it stands in for having
    /// been there: the fixture comes back settled, which is the sequence a reviewer needs to watch
    /// (it is what clears a failure line that has outlived its cause) and the one sequence that
    /// cannot be staged for real, because the panel that would open shows the reviewer's own login
    /// items, where this row's fixture does not exist.
    private func openLoginItems() {
        guard fixture == nil else {
            fixture = LoginItemPreview.settledInSystemSettings
            apply(LoginItemPreview.settledInSystemSettings.state)
            return
        }
        LaunchAtLoginService.openLoginItems()
    }
}
