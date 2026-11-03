import SwiftUI

/// The small "Add the tally command" window: one screen at a time (TallyCommandScreen), the store
/// says which and this draws it. Width is fixed at 480; the height follows the screen and is
/// reported up so the window can fit it (TallyCommandWindowController).
struct TallyCommandView: View {
    @Bindable var store: TallyCommandStore
    let onHeight: (CGFloat) -> Void

    var body: some View {
        let screen = store.screen
        VStack(spacing: 0) {
            Text(title(screen))
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 38)   // under the 28pt title bar strip
            subtitle(screen)
                .font(.system(size: 13.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            content(screen)
            footer(screen)
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 28)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { Color.clear.preference(key: TallyCommandHeightKey.self, value: $0.size.height) })
        .onPreferenceChange(TallyCommandHeightKey.self) { onHeight($0) }
    }

    // MARK: Words

    private func title(_ screen: TallyCommandScreen) -> String {
        switch screen {
        case .confirm, .installing: return L("Add the tally command")
        case .done: return L("Try it now")
        case .failed: return L("The tally command wasn't installed")
        }
    }

    private func subtitle(_ screen: TallyCommandScreen) -> Text {
        switch screen {
        case .confirm, .installing:
            return HintText.withCode(L("After this, any Terminal window can run `tally claude`."), size: 13.5)
        case .done:
            return Text(L("Open Terminal in the folder you work in and run:"))
        case .failed(.cancelled):
            return Text(L("The password prompt was cancelled, so nothing was added."))
        case .failed(.other):
            return Text(L("Tally could not add the command."))
        }
    }

    // MARK: Middle

    @ViewBuilder
    private func content(_ screen: TallyCommandScreen) -> some View {
        switch screen {
        case .confirm, .installing:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 20)).foregroundStyle(TallyColor.warning)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("macOS asks for your Mac password once")).font(.system(size: 14, weight: .semibold))
                    Text(L("Tally puts one file in /usr/local/bin, a folder only an administrator can write to."))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .modifier(CommandCardStyle())
            .padding(.top, 26)
        case .done:
            HStack(spacing: 12) {
                Text(verbatim: TallyCommandStore.runCommand).font(.system(size: 14, design: .monospaced))
                Spacer(minLength: 0)
                Button(L("Copy")) { store.copyCommand() }.controlSize(.regular)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .modifier(CommandCardStyle())
            .padding(.top, 22)
            HintText.withCode(L("It starts Claude Code on whichever account has the most room left. Plain `claude` still works as before."), size: 12.5)
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
        case .failed:
            EmptyView()
        }
    }

    // MARK: Bottom

    @ViewBuilder
    private func footer(_ screen: TallyCommandScreen) -> some View {
        HStack(spacing: 12) {
            switch screen {
            case .confirm:
                Spacer()
                plain(L("Not Now")) { store.close() }
                prominent(L("Install")) { store.install() }
            case .installing:
                ProgressView().controlSize(.small)
                Spacer()
                plain(L("Not Now")) { store.close() }.disabled(true)
                prominent(L("Install")) {}.disabled(true)
            case .done:
                Spacer()
                plain(L("Done")) { store.close() }
                prominent(L("Copy and Open Terminal")) { store.copyCommandAndOpenTerminal() }
            case .failed:
                link(L("Run it yourself in Terminal")) { store.copyManualInstallAndOpenTerminal() }
                Spacer()
                plain(L("Not Now")) { store.close() }
                prominent(L("Try Again")) { store.tryAgain() }
            }
        }
        .padding(.top, screen == .done ? 24 : 30)
    }

    // MARK: Pieces

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

private struct TallyCommandHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The soft rounded box every block on these screens sits in.
private struct CommandCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.09), lineWidth: 1))
    }
}
