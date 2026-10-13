import Foundation

/// Keeps Codex current while no window is open: every ten minutes the bundled CLI is asked whether
/// an hourly update check is due (`tally codex-update --if-due`, TallyCLI/CodexUpdateCommand.swift),
/// so a window Tally opens later finds nothing to update and codex's own startup menu never comes up.
/// Through the helper for the same reason KeychainRepairLaunch is: the update logic, its lock and
/// its backoff live in the CLI, shared with the pre-launch update.
enum CodexUpdateSchedule {
    static let interval: TimeInterval = 600
    static let timeout: TimeInterval = 960

    @MainActor
    static func start() {
        #if DEBUG
        // Debug-only, for a Dev.app run against a scratch tally and a scratch codex (never shared state).
        let defaults = UserDefaults.standard
        let override = defaults.string(forKey: "TallyCodexUpdateCLI")
        let every = defaults.double(forKey: "TallyCodexUpdateEvery")
        let extra = defaults.string(forKey: "TallyCodexUpdateCodex").map { ["--codex", $0] } ?? []
        var environment: [String: String?] = [:]
        if let pair = defaults.string(forKey: "TallyCodexUpdateEnv"), let eq = pair.firstIndex(of: "=") {
            environment[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        #else
        let override: String? = nil, every = 0.0, extra: [String] = [], environment: [String: String?] = [:]
        #endif
        guard override != nil || !BuildVariant.isUnshipped else { return }
        // The path is read here because the constant is MainActor-isolated; the file check is IO and
        // runs off the main thread.
        let helper = override ?? IntegrationsStore.bundledCLIURL.path
        let pause = every > 0 ? every : interval
        Task.detached(priority: .background) {
            guard FileManager.default.isExecutableFile(atPath: helper) else { return }
            try? await Task.sleep(for: .seconds(120))
            while true {
                _ = await CLIRunner.run(helper, arguments: ["codex-update", "--if-due"] + extra,
                                        environment: environment, timeout: timeout)
                try? await Task.sleep(for: .seconds(pause))
            }
        }
    }
}
