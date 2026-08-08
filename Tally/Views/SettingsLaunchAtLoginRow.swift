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
/// Disabled for a build nobody installed (`BuildVariant.isUnshipped`), the same gate the
/// Integrations pane uses, for its reason plus one of its own. `SMAppService.mainApp` registers
/// the bundle that is RUNNING: "Tally Dev" only ever runs out of DerivedData, and a locally built
/// Release carries the installed app's bundle id (`ai.jetto.tally`, the dev flavour is
/// `ai.jetto.tally.dev`), so registering from one would take the installed app's login item over
/// and aim the next boot at a build directory. Both leave a login item pointed at a path that is
/// about to be deleted; the second does it wearing the installed app's name, which is the failure
/// BuildVariant.isBuildTree was written for.
struct SettingsLaunchAtLoginRow: View {
    @State private var state: LaunchAtLoginState = .notRegistered
    /// The last register/unregister error that the state beside it does not already explain.
    @State private var failure: String?

    /// A build nobody installed reads the login item but never writes it.
    private var manageable: Bool { !BuildVariant.isUnshipped }

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
                    if let failure { notice(failure) }
                    if state.offersSystemSettings {
                        Button(L("Open Login Items")) { LaunchAtLoginService.openLoginItems() }
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

    /// Read even where the row cannot be operated: a locally built Release shares the installed
    /// app's identity, so the honest thing to show is that app's real login item, greyed out.
    private func refresh() {
        state = LaunchAtLoginService.current
    }

    private func setRegistered(_ registered: Bool) {
        var thrown: Error?
        do {
            try LaunchAtLoginService.setRegistered(registered)
        } catch {
            thrown = error
        }
        // The state macOS reports AFTER the attempt is the answer, including when the attempt
        // threw: a denied registration is still a registration, and it is what the notice above
        // is written from.
        let settled = LaunchAtLoginService.current
        state = settled
        failure = thrown.flatMap { error in
            LaunchAtLoginState.surfacesFailure(after: settled, wanted: registered)
                ? error.localizedDescription : nil
        }
    }
}
