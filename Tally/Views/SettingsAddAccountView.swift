import SwiftUI

/// The "Add account" sheet: pick a provider, decide whether the new account shares the main one's
/// setup, then watch the provider's own sign-in happen in the browser.
///
/// It says what will happen BEFORE it happens - which directory gets created, and exactly what
/// sharing means - because everything on this sheet touches the user's own filesystem and their own
/// paid subscriptions. Tally reads; the sign-in is the vendor's, in the user's browser.
struct SettingsAddAccountView: View {
    @Bindable var flow: AddAccountStore
    /// The command that does the same thing in a terminal, offered when the in-app run could not
    /// finish. It resumes the very home this run created: an unfinished home is what `tally add`
    /// hands back rather than skipping.
    let fallbackCommand: (String) -> String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Add an account")).font(.headline)
            switch flow.phase {
            case .idle, .failed:
                setup
            case .preparing, .signingIn:
                running
            case .added(let name):
                finished(name)
            case .pending(let name, let reason):
                unfinished(name, reason)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: Before it starts

    private var setup: some View {
        // Asked ONCE per pass: the probe walks up to 99 directories, and a SwiftUI body is
        // evaluated far more often than the answer changes.
        let nextHome = nextFreeAccountHome(providerID: flow.providerID)?.name
        return VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $flow.providerID) {
                ForEach(ProviderCatalog.descriptors, id: \.id) { descriptor in
                    Text(descriptor.name).tag(descriptor.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            // Looked up with the same probes the creation uses, so the sheet names the directory it
            // is about to make rather than a guess the user has to verify afterwards. The path
            // stands on its own line rather than inside the sentence: a directory glued into
            // running text is the one part of it that does not translate.
            if let nextHome {
                caption(L("Tally will create the next config home and open the provider's sign-in page in your browser."))
                Text(verbatim: "~/\(nextHome)").font(.caption.monospaced())
            } else {
                caption(L("Every numbered config home for this provider already has a login."))
            }

            Toggle(isOn: $flow.shareHarness) {
                Text(L("Share the main account's setup")).font(.subheadline)
            }
            .toggleStyle(.checkbox)
            caption(flow.shareHarness
                ? L("The new account links to your main account's instructions, skills, hooks, agents, settings and conversation history, so one setup serves every account. Every account can then read every account's conversations. Sign-in details are never shared.")
                : L("The new account starts empty: its own instructions, skills, hooks, agents, settings and its own conversation history."))

            if case .failed(let reason) = flow.phase {
                problem(reason)
            }

            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Add account")) { flow.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canAdd(providerID: flow.providerID) || nextHome == nil)
            }
        }
    }

    // MARK: While it runs

    @ViewBuilder
    private var running: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(phaseLine).font(.subheadline)
        }
        // Closing is safe and worth saying so: the login is a background process with its own
        // deadlines and its own notifications, not something this window is holding up.
        caption(L("Finish the sign-in in your browser. You can close this window; Tally will notify you either way."))
        HStack {
            Spacer()
            Button(L("Close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var phaseLine: String {
        if case .signingIn(let name) = flow.phase {
            return L("Signing in") + " · ~/\(name)"
        }
        return L("Preparing the config home…")
    }

    // MARK: How it ended

    @ViewBuilder
    private func finished(_ name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(L("Account added") + " · ~/\(name)").font(.subheadline)
        }
        caption(L("It is signed in and listed above. Rename it, reorder it or switch it off any time."))
        HStack {
            Spacer()
            Button(L("Done")) { flow.reset(); dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// The home exists, the login does not. The directory is deliberately KEPT: the next attempt
    /// resumes it (share links and carried-over folder trust included) instead of taking the next
    /// number, and deleting it would be the only irreversible step in this flow.
    @ViewBuilder
    private func unfinished(_ name: String, _ reason: String) -> some View {
        problem(L("Sign-in not finished") + " · ~/\(name)")
        caption(reason + " " + L("The config home is ready and waiting - finishing the sign-in later adds the account, and nothing is created twice."))
        CopyCommandChip(command: fallbackCommand(flow.providerID))
        HStack {
            Spacer()
            Button(L("Close")) { flow.reset(); dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("Try again")) { flow.start() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func problem(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            Text(text).font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
