import Foundation
import Observation

/// The app's half of `tally forensics setup|remove` and the Settings row beside the process CPU
/// alert: shows the system's password window (AdminShell) and installs or removes the root evidence
/// helper (ProcessForensicsPrivilege.swift says what it is and why it needs the window).
///
/// A request that arrives by notification may open the window once in ten minutes (anything on this
/// account can post one); the Settings buttons are a person pressing them and only wait for the
/// window already up. Installed app only, like RedeemRequestStore: two apps must never both answer
/// one request, and a build nobody installed must not write root files on the strength of a request.
@MainActor @Observable
final class ForensicsHelperStore {
    static let shared = ForensicsHelperStore()

    private(set) var state: ProcessForensicsPrivilege.State?
    private(set) var busy = false
    @ObservationIgnored private var lastShownAt: Date?
    @ObservationIgnored private var observer: NSObjectProtocol?

    private var handlesRequests: Bool { !BuildVariant.isUnshipped && !DemoUsage.isActive }

    func install() {
        guard handlesRequests, observer == nil else { return }
        Task.detached(priority: .utility) { sweepForensicsResults() }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(forensicsRequestedNotification), object: nil, queue: .main) { note in
            let action = note.userInfo?["action"] as? String
            let id = note.userInfo?["id"] as? String
            Task { @MainActor in self.requested(action: action, id: id) }
        }
    }

    func refresh() {
        Task {
            state = await Task.detached(priority: .utility) { ProcessForensicsPrivilege.state() }.value
        }
    }

    /// The Settings buttons.
    func setUp() { Task { _ = await perform(install: true) } }
    func remove() { Task { _ = await perform(install: false) } }

    private func requested(action: String?, id: String?) {
        guard let id, isValidForensicsRequestID(id), action == "setup" || action == "remove" else { return }
        guard !busy, forensicsPromptAllowed(lastShownAt: lastShownAt, now: Date()) else {
            return answer(id, .throttled)
        }
        answer(id, .pending)
        Task {
            let code = await perform(install: action == "setup")
            answer(id, code)
        }
    }

    private func perform(install: Bool) async -> ForensicsResultCode {
        guard !busy else { return .throttled }
        busy = true
        lastShownAt = Date()
        let prompt = install
            ? L("Tally needs administrator rights to install the helper that captures evidence of a runaway system process.")
            : L("Tally needs administrator rights to remove the helper that captures evidence of a runaway system process.")
        let outcome = await Task.detached(priority: .userInitiated) { () -> ProcessForensicsSetup.Outcome in
            let elevate: ProcessForensicsSetup.Elevate = { AdminShell.run(script: $0, arguments: $1, prompt: $2) }
            return install ? ProcessForensicsSetup.install(prompt: prompt, elevate: elevate)
                           : ProcessForensicsSetup.remove(prompt: prompt, elevate: elevate)
        }.value
        busy = false
        refresh()
        switch outcome {
        case .succeeded: return .done
        case .cancelled: return .cancelled
        case .failed: return .failed
        }
    }

    private func answer(_ id: String, _ code: ForensicsResultCode) {
        Task.detached(priority: .userInitiated) { writeForensicsResult(id, code) }
    }
}
