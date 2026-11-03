import AppKit
import SwiftUI

@MainActor
@Observable
final class MoveToApplicationsModel {
    enum Phase: Equatable { case prompt, moving, failed(MoveFailure) }
    var phase: Phase = .prompt
}

/// The one thing a copy running from a disk image does: offer to move itself to Applications and
/// open from there. Such a copy starts nothing else (AppDelegate returns right after `showIfNeeded`),
/// because every path it registered (login item, hooks, updater) would be gone with the image.
@MainActor
final class MoveToApplicationsWindowController: NSObject, NSWindowDelegate {
    static let shared = MoveToApplicationsWindowController()
    /// True from the moment this launch is held at the window until the process ends. Every other
    /// entrance (terminate, reopen, the Settings command) asks this and does nothing shared.
    private(set) static var isHoldingLaunch = false

    private var window: NSWindow?
    private let model = MoveToApplicationsModel()
    private var launch = MoveToApplicationsLaunch()

    /// Decides and, when this copy runs from a disk image (or the dev preview asks), shows the
    /// window. Returns true when it did; the caller must then return without starting anything.
    func showIfNeeded() -> Bool {
        let devOrDemo = BuildVariant.isDev || DemoUsage.isActive
        launch = MoveToApplicationsLaunch.read(from: .standard, devOrDemo: devOrDemo)
        let path = Bundle.main.bundleURL.path
        let hit = launch.preview || InstallLocation.isRunningFromDiskImage(
            bundlePath: path, volumeIsReadOnly: InstallLocation.volumeIsReadOnly(atPath: path),
            isDev: BuildVariant.isDev, isDemo: DemoUsage.isActive)
        guard hit else { return false }
        Self.isHoldingLaunch = true
        if let forced = launch.forcedFailure { model.phase = .failed(forced) }
        show()
        if launch.autoMove, launch.forcedFailure == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.move() }
        }
        return true
    }

    /// A second double-click on the app inside the image lands here instead of starting the UI.
    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func show() {
        let hosting = NSHostingController(rootView: MoveToApplicationsView(
            model: model, onQuit: { NSApp.terminate(nil) }, onMove: { [weak self] in self?.move() }))
        // The one size authority: fixed width, height from the content. Nothing here sets a frame.
        hosting.sizingOptions = [.preferredContentSize]
        let window = makeWindow(hosting)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = L("Move Tally to Applications first")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.layoutIfNeeded()
        window.center()
        self.window = window
        ActivationPolicy.promote()
        if CaptureLaunch.launchMayTakeForeground {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    private func makeWindow(_ hosting: NSViewController) -> NSWindow {
        #if DEBUG
        // A background preview is never key, so the default button would draw grey in a capture.
        if launch.preview { return MovePreviewKeyWindow(contentViewController: hosting) }
        #endif
        return NSWindow(contentViewController: hosting)
    }

    private func move() {
        guard model.phase == .prompt else { return }
        model.phase = .moving
        window?.standardWindowButton(.closeButton)?.isEnabled = false
        let source = Bundle.main.bundleURL
        let directory = launch.destinationDirectory
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        let executable = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String ?? ""
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let sourceVersion = BuildVariant.version
        // Everything that touches the disk is read here, off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let resolved = destination.resolvingSymlinksInPath().path
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { $0.processIdentifier != getpid() && $0.bundleURL?.resolvingSymlinksInPath().path == resolved }
            let plist = NSDictionary(contentsOf: destination.appendingPathComponent("Contents/Info.plist"))
            let situation = MoveSituation(
                destinationExists: fm.fileExists(atPath: destination.path),
                destinationRunning: running != nil,
                destinationVersion: plist?["CFBundleShortVersionString"] as? String,
                sourceVersion: sourceVersion,
                directoryWritable: fm.isWritableFile(atPath: directory.path),
                freeBytes: AppMover.freeBytes(at: directory),
                neededBytes: AppMover.bundleSize(source))
            let outcome: MoveFailure?
            switch InstallLocation.plan(situation) {
            case .fail(let reason): outcome = reason
            case .openExisting: outcome = nil
            case .copy(let replacing):
                outcome = AppMover(source: source, destination: destination, executableName: executable)
                    .run(replacing: replacing)
            }
            DispatchQueue.main.async {
                if let outcome { self.fail(outcome) } else { self.open(destination, alreadyRunning: running) }
            }
        }
    }

    private func open(_ url: URL, alreadyRunning: NSRunningApplication?) {
        // The installed copy is already up: bring it forward and leave. Asking LaunchServices to
        // open it instead would resolve to a running instance by bundle id, which can be THIS one.
        if let alreadyRunning {
            alreadyRunning.activate()
            NSApp.terminate(nil)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        // Always a new instance: this copy shares the bundle id, so without it LaunchServices hands
        // back the running disk image copy and the move ends with nothing open.
        config.createsNewApplicationInstance = true
        config.activates = CaptureLaunch.launchMayTakeForeground
        // Only the demo flag travels: without it a dev relaunch reads real credentials, and the
        // preview flags must never travel or the new copy would show this window (and move) again.
        config.arguments = DemoUsage.isActive ? ["-TallyDemoData", "YES"] : []
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            DispatchQueue.main.async {
                if app != nil, error == nil { NSApp.terminate(nil) } else { self.fail(.launchFailed) }
            }
        }
    }

    private func fail(_ reason: MoveFailure) {
        model.phase = .failed(reason)
        window?.standardWindowButton(.closeButton)?.isEnabled = true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { model.phase != .moving }

    /// The close button is Quit.
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

#if DEBUG
private final class MovePreviewKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasActiveControls() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func hasKeyAppearance() -> Bool { true }
}
#endif
