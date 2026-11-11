import SwiftUI

/// The first-run welcome window: one screen at a time, each with one job (WelcomeScreen). The
/// store derives which; this only draws it. Width is fixed at 560; the height follows the screen
/// and is reported up so the window can fit it (WelcomeWindowController).
struct WelcomeView: View {
    @Bindable var store: WelcomeStore
    let onHeight: (CGFloat) -> Void

    var body: some View {
        let screen = store.screen
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 68, height: 68)
                .padding(.top, 16)   // under the 28pt title bar strip: 44pt from the window's top
            HStack(spacing: 10) {
                Text(title(screen))
                    .font(.system(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)
                if screen == .detecting { OverlayApp.welcomeTitleBadge }
            }
            .padding(.top, 22)
            if let sub = subtitle(screen) {
                Text(sub)
                    .font(.system(size: 13.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            content(screen)
            footer(screen)
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 28)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { Color.clear.preference(key: WelcomeHeightKey.self, value: $0.size.height) })
        .onPreferenceChange(WelcomeHeightKey.self) { onHeight($0) }
    }

    // MARK: Words

    private func title(_ screen: WelcomeScreen) -> String {
        switch screen {
        case .detecting: return OverlayApp.welcomeTitle ?? L("Tally is in your menu bar")
        case .found:
            let n = store.rows.count
            return n == 1 ? L("Found 1 account") : String(format: L("Found %lld accounts"), n)
        case .needsCLI(let p): return WelcomeCopy.installTitle(p)
        case .waiting(let p): return WelcomeCopy.waitingTitle(p)
        case .waitingStalled(let p): return WelcomeCopy.stalledTitle(p)
        case .signIn(let p): return WelcomeCopy.signInTitle(p)
        case .signingIn: return L("Finish in your browser")
        case .success: return L("You're all set")
        case .failed: return L("Sign-in didn't finish")
        }
    }

    private func subtitle(_ screen: WelcomeScreen) -> String? {
        switch screen {
        case .detecting:
            return OverlayApp.welcomeSubtitle ?? L("It shows every Claude and Codex account you pay for, side by side. Click it any time.")
        case .found:
            let from = WelcomeCopy.readFrom(store.foundProviders)
            return store.rows.count == 1
                ? String(format: L("Tally reads its usage from %@. Nothing to set up."), from)
                : String(format: L("Tally reads their usage from %@. Nothing to set up."), from)
        case .needsCLI(let p): return WelcomeCopy.installBlurb(p)
        case .waiting: return L("Keep this window open. It moves on by itself when the install finishes.")
        case .waitingStalled: return WelcomeCopy.stalledBody
        case .signIn(let p): return WelcomeCopy.signInBlurb(p)
        case .signingIn(let p): return WelcomeCopy.signingInBody(p)
        case .success: return WelcomeCopy.successBody
        case .failed(_, let reason): return WelcomeCopy.failureBody(reason)
        }
    }

    // MARK: Middle

    @ViewBuilder
    private func content(_ screen: WelcomeScreen) -> some View {
        switch screen {
        case .detecting:
            menuBarHint.padding(.top, 26)
            statusCard {
                ProgressView().controlSize(.small)
            } title: {
                L("Looking for Claude Code and Codex on this Mac")
            } detail: {
                L("This takes a second.")
            }
            .padding(.top, 16)
        case .found:
            rowsCard.padding(.top, 26)
            note(L("Tally only reads usage. It never sees your password or sign-in token."))
        case .needsCLI(let p):
            let rechecked = store.recheckedMissing == p
            if rechecked { notFoundCard(p).padding(.top, 26) }
            commandBox(p).padding(.top, rechecked ? 18 : 26)
            note(L("Never used Terminal? Tally opens it for you. Paste with ⌘V, press Return, then come back here."))
        case .waiting(let p):
            steps([(.done, L("Install command copied")),
                   (.active, L("Paste it in Terminal and press Return")),
                   (.todo, String(format: L("Tally finds %@"), WelcomeCopy.cliName(p)))])
        case .waitingStalled(let p):
            note(WelcomeCopy.stalledNote(p)).padding(.top, 14)
        case .signIn(let p):
            // Asked once per render: each answer resolves the CLI and walks the login PATH.
            let advice = store.pathAdvice(p)
            statusCard {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(TallyColor.normal)
            } title: {
                String(format: advice == nil ? L("%@ is installed") : L("%@ is ready"), WelcomeCopy.cliName(p))
            } detail: {
                if case .foundIn(let location) = CLIPathAdvice.installedDetail(
                    location: store.installedLocation(p), terminalFinds: advice == nil) {
                    String(format: L("Found in %@"), location)
                } else { "" }
            }
            .padding(.top, 26)
            if let advice { pathCard(advice).padding(.top, 12) }
        case .signingIn:
            // The tick is the CLI's own word that the browser opened, not the click that asked for it.
            steps([(store.browserOpened ? .done : .active,
                    L(store.browserOpened ? "Browser opened" : "Opening your browser…")),
                   (store.browserOpened ? .active : .todo, L("Waiting for you to approve")),
                   (.todo, L("Your usage appears here"))])
        case .success:
            rowsCard.padding(.top, 26)
            if let email = store.rows.first?.email { note(email) }
        case .failed:
            EmptyView()
        }
    }

    // MARK: Bottom

    @ViewBuilder
    private func footer(_ screen: WelcomeScreen) -> some View {
        HStack(spacing: 12) {
            switch screen {
            case .detecting:
                EmptyView()
            case .found:
                link(L("Add another account")) { store.secondary() }
                Spacer()
                prominent(L("Show My Usage")) { store.primary() }
            case .needsCLI(let p):
                link(L("Check again")) { store.checkAgain(p) }
                    .padding(.trailing, 6)
                link(WelcomeCopy.useOtherProvider(p)) { store.secondary() }
                Spacer()
                prominent(L("Copy and Open Terminal")) { store.primary() }
            case .waiting, .waitingStalled:
                Spacer()
                plain(L("Show the Command Again")) { store.secondary() }
            case .signIn(let p):
                link(WelcomeCopy.useOtherProvider(p)) { store.secondary() }
                Spacer()
                prominent(L("Sign In with Browser")) { store.primary() }
            case .signingIn:
                link(L("Browser didn't open? Open it again")) { store.openBrowserAgain() }
                Spacer()
                plain(L("Cancel")) { store.secondary() }
            case .success:
                Spacer()
                plain(L("Add Another Account")) { store.secondary() }
                prominent(L("Show My Usage")) { store.primary() }
            case .failed:
                Spacer()
                plain(L("Cancel")) { store.secondary() }
                prominent(L("Try Again")) { store.primary() }
            }
        }
        .padding(.top, screen == .detecting ? 0 : 30)
    }

    // MARK: Pieces

    private var menuBarHint: some View {
        HStack(spacing: 14) {
            Text(L("Top right of your screen")).font(.system(size: 13.5))
            Spacer()
            Image(systemName: "switch.2").font(.system(size: 13)).foregroundStyle(.secondary)
            // The symbol the real status item wears until it has accounts to draw.
            Image(systemName: StatusItemController.fallbackSymbolName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1.5))
            Image(systemName: "wifi").font(.system(size: 13)).foregroundStyle(.secondary)
            Text(Date.now.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 13.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .modifier(CardStyle())
    }

    private func statusCard<Icon: View>(@ViewBuilder icon: () -> Icon, title: () -> String,
                                        detail: () -> String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title()).font(.system(size: 14, weight: .semibold))
                let text = detail()
                if !text.isEmpty { Text(text).font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .modifier(CardStyle())
    }

    private var rowsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.horizontal, 14) }
                WelcomeAccountRow(row: row)
            }
        }
        .modifier(CardStyle())
    }

    /// The yellow card for what the user should know but has not done wrong.
    private func warningCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill").font(.system(size: 18)).foregroundStyle(TallyColor.warning)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 8) { content() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(TallyColor.warning.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(TallyColor.warning.opacity(0.35), lineWidth: 1))
    }

    /// signIn, when Tally found the CLI but the user's Terminal would not: nothing is wrong with
    /// Tally, and the one line offered is the user's to paste (Tally never edits a shell file).
    private func pathCard(_ advice: PathAdvice) -> some View {
        warningCard {
            Text(String(format: L("Terminal can't find %@ yet."), advice.cliName))
                .font(.system(size: 14, weight: .semibold))
            Text(String(format: L("It's in %@, which your Terminal doesn't look in. Tally works fine without it."),
                        advice.directory))
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text(String(format: advice.fixCommand == nil ? L("To run %@ yourself, type its full path:")
                                                         : L("To run %@ yourself, add that folder once:"),
                        advice.cliName))
                .font(.system(size: 13)).foregroundStyle(.secondary)
            let line = advice.fixCommand ?? advice.fullPath
            HStack(spacing: 10) {
                Text(verbatim: line).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                Spacer(minLength: 0)
                Button(L("Copy")) { store.copyText(line) }.controlSize(.small).fixedSize().layoutPriority(2)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            if advice.fixCommand != nil {
                Text(L("Then open a new Terminal window. Tally never edits your shell files."))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// needsCLI after "Check again" found nothing: where Tally looked.
    private func notFoundCard(_ providerID: String) -> some View {
        let home = CLISearchPath.shared.home
        let places = CLISearchPath.shared.fixedDirectories.map { CLIPathAdvice.display($0, home: home) }
        return warningCard {
            Text(String(format: L("Tally still can't find %1$@. It looked in %2$@ and your shell's PATH. If you installed it somewhere else, installing once more with the official command puts it where Tally looks."),
                        WelcomeCopy.cliName(providerID), places.joined(separator: ", ")))
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func commandBox(_ providerID: String) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: WelcomeFlow.installCommand(providerID: providerID))
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button(L("Copy")) { store.copyCommand(providerID) }
                .controlSize(.regular)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .modifier(CardStyle())
    }

    private enum StepState { case done, active, todo }

    private func steps(_ items: [(StepState, String)]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 12) {
                    Group {
                        switch item.0 {
                        case .done:
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 21)).foregroundStyle(TallyColor.normal)
                        case .active: ProgressView().controlSize(.small)
                        case .todo:
                            Circle().stroke(Color.secondary.opacity(0.6), lineWidth: 1.5).frame(width: 19, height: 19)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(item.1)
                        .font(.system(size: 14, weight: item.0 == .active ? .semibold : .regular))
                        .foregroundStyle(item.0 == .todo ? Color.secondary : Color.primary)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 28)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
    }

    private func prominent(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).font(.system(size: 14)).padding(.horizontal, 6) }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }

    private func plain(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).font(.system(size: 14)).padding(.horizontal, 6) }
            .buttonStyle(.bordered).controlSize(.large)
    }

    private func link(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).font(.system(size: 14)).foregroundStyle(Color.accentColor) }
            .buttonStyle(.plain)
    }
}

private struct WelcomeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The soft rounded box every block on these screens sits in.
private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.09), lineWidth: 1))
    }
}

/// One account line: mark, name, plan chip, then the 5-hour and weekly meters.
private struct WelcomeAccountRow: View {
    let row: WelcomeRow

    var body: some View {
        HStack(spacing: 10) {
            ProviderIconView(providerID: row.providerID, size: 17, usesProviderColor: true)
            Text(row.name).font(.system(size: 15, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
            if let plan = row.plan {
                Text(plan)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            }
            Spacer(minLength: 8)
            if row.isLoading {
                ProgressView().controlSize(.mini)
                Text(L("Loading…")).font(.system(size: 12.5)).foregroundStyle(.secondary)
            } else {
                meter(row.session)
                meter(row.weekly)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    @ViewBuilder
    private func meter(_ meter: WelcomeRow.Meter?) -> some View {
        if let meter {
            HStack(spacing: 7) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(color(meter.severity))
                        .frame(width: 52 * CGFloat(max(0, min(100, meter.leftPercent))) / 100)
                }
                .frame(width: 52, height: 5)
                Text(verbatim: "\(meter.leftPercent)%")
                    .font(.system(size: 14.5, weight: .semibold)).monospacedDigit().fixedSize()
                Text(verbatim: meter.resetText).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize()
            }
        }
    }

    private func color(_ severity: MetricSeverity) -> Color {
        switch severity {
        case .warning: return TallyColor.warning
        case .critical: return TallyColor.critical
        case .normal, .unknown: return TallyColor.normal
        }
    }
}
