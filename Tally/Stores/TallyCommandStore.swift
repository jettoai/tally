import AppKit
import Foundation

/// The state behind the small "Add the tally command" window: which screen it is on, and the one
/// install it can start (`IntegrationsStore.installCLITool`, the same path as Settings > Integrations,
/// so the administrator prompt and the Dev-build guard are not re-implemented here).
@MainActor
@Observable
final class TallyCommandStore {
    static let shared = TallyCommandStore()

    private(set) var screen: TallyCommandScreen = .confirm
    /// A held `-TallyCommandPreview` screen: the buttons only walk between screens.
    private var preview: TallyCommandScreen?
    private var watch: Task<Void, Never>?
    var closeWindow: () -> Void = {}

    /// What the window opens on. `previewName` is the dev flag's value, already gated.
    func begin(previewName: String?) {
        watch?.cancel()
        preview = TallyCommandScreen.preview(named: previewName)
        screen = preview ?? .confirm
    }

    func windowClosed() {
        watch?.cancel()
        watch = nil
    }

    // MARK: Buttons

    /// "Install" and "Try Again".
    func install() {
        if preview != nil {
            screen = .done
            return
        }
        guard screen != .installing else { return }
        screen = .installing
        let integrations = IntegrationsStore.shared
        integrations.installCLITool()
        watch?.cancel()
        // The password window is up while the elevated install runs; it clears its handle in the same
        // main-actor turn that records the result, so a nil handle means the answer is in.
        watch = Task { [weak self] in
            while integrations.cliElevationTask != nil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        let integrations = IntegrationsStore.shared
        if case .link = integrations.cliToolPresence {
            screen = .done
            return
        }
        let cancelled = IntegrationsStore.cliInstallMessage(.cancelled, target: IntegrationsStore.bundledCLIURL)
        screen = .failed(TallyCommandFailure.classify(lastError: integrations.lastError,
                                                      cancelledMessage: cancelled))
    }

    /// "Not Now", "Done": the window goes, nothing else changes.
    func close() { closeWindow() }

    /// "Try Again" on a held failure goes back to the question; a real one runs the install again.
    func tryAgain() {
        if preview != nil {
            screen = .confirm
            return
        }
        install()
    }

    /// "Copy" next to the command on the last screen.
    func copyCommand() {
        guard preview == nil else { return }
        Self.copy(Self.runCommand)
    }

    /// "Copy and Open Terminal": the command on the clipboard and Terminal in front.
    func copyCommandAndOpenTerminal() {
        guard preview == nil else { return }
        Self.copy(Self.runCommand)
        Self.openTerminal()
    }

    /// "Run it yourself in Terminal": the same link the install makes, as one line to paste.
    func copyManualInstallAndOpenTerminal() {
        guard preview == nil else { return }
        Self.copy(IntegrationsStore.manualInstallCommand(target: IntegrationsStore.bundledCLIURL))
        Self.openTerminal()
    }

    static let runCommand = "tally claude"

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A plain open: no Automation permission, unlike typing into a Terminal window.
    private static func openTerminal() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }
}
