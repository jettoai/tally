import Foundation
import Observation

@MainActor
@Observable
final class CodexHarnessStore {
    var state = "not-inspected"
    var nativeHomes: [[String: String]] = []
    var busy = false
    var error: String?
    let previewRoot: String?

    init() { previewRoot = Self.previewDirectory(ProcessInfo.processInfo.environment["TALLY_HARNESS_PREVIEW_ROOT"]) }

    var mayWrite: Bool { !BuildVariant.isUnshipped || previewRoot != nil }
    var hasInstallation: Bool { ["installed", "incomplete"].contains(state) }

    func inspect() { perform("inspect") }
    func install() { perform("install") }
    func remove() { perform("remove") }

    private func configuration() throws -> HarnessToolsConfiguration {
        if let root = previewRoot {
            return try HarnessToolsConfiguration(claudeHomes: [root + "/claude", root + "/claude2"],
                codexHomes: [root + "/codex", root + "/codex2"], skillsRoot: root + "/skills", stateRoot: root + "/state/harness")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let environment = ProcessInfo.processInfo.environment
        return try HarnessToolsConfiguration(
            claudeHomes: [environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude"] + IntegrationsStore.claudeHomes().map(\.path),
            codexHomes: [environment["CODEX_HOME"] ?? home + "/.codex"] + CodexAccounts.discover().compactMap(\.launchHome),
            skillsRoot: home + "/.agents/skills", stateRoot: home + "/.tally/harness")
    }

    private func perform(_ action: String) {
        guard !busy else { return }
        do {
            let configuration = try configuration()
            if action != "inspect" {
                guard mayWrite else { throw HarnessError(L("Integrations are managed by the installed release app.")) }
                if let root = previewRoot { try Self.validatePreview(configuration, root: root) }
            }
            let executable = previewRoot == nil ? IntegrationsStore.bundledCLIURL.path
                : Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("tally").path
            busy = true; error = nil
            Task {
                defer { busy = false }
                do {
                    let data = try await Task.detached {
                        if action == "install" { try HarnessTools.install(configuration, executable: executable) }
                        else if action == "remove" { try HarnessTools.remove(configuration.stateRoot) }
                        var value = try HarnessTools.status(configuration)
                        if let receipt = try HarnessTools.receipt(in: configuration.stateRoot) {
                            value["nativeHomes"] = configuration.codexHomes.map { home in
                                let registrations = receipt.registrations.filter { $0.path == HarnessIO.canonical(home + "/hooks.json") }
                                let status = CodexHarnessTrust.read(home: home, cwd: home, registrations: registrations)
                                return ["home": home, "state": status["state"] as? String ?? "unavailable"]
                            }
                        }
                        return try HarnessIO.json(value)
                    }.value
                    let value = try HarnessIO.object(data)
                    state = value["state"] as? String ?? "unknown"
                    nativeHomes = value["nativeHomes"] as? [[String: String]] ?? []
                    if let changes = value["changes"] as? [String], !changes.isEmpty { error = changes.joined(separator: "\n") }
                } catch {
                    self.error = error.localizedDescription
                    if HarnessIO.exists(configuration.manifestPath) { state = "incomplete" }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    nonisolated private static func previewDirectory(_ path: String?) -> String? {
        guard BuildVariant.isDev, let path, path.hasPrefix("/") else { return nil }
        let root = HarnessIO.canonical(path), temp = HarnessIO.canonical(NSTemporaryDirectory())
        guard root.hasPrefix(temp + "/"), FileManager.default.fileExists(atPath: root) else { return nil }
        return root
    }

    nonisolated private static func validatePreview(_ configuration: HarnessToolsConfiguration, root: String) throws {
        var paths = configuration.claudeHomes + configuration.codexHomes + [configuration.skillsRoot, configuration.stateRoot]
            + configuration.skillPaths + configuration.configurations.map(\.path)
        if let receipt = try HarnessTools.receipt(in: configuration.stateRoot) {
            paths += receipt.files.map(\.path) + receipt.files.compactMap(\.backup)
        }
        guard paths.allSatisfy({ HarnessIO.canonical($0).hasPrefix(root + "/") }) else {
            throw HarnessError("Preview writes must stay inside the isolated fixture directory.")
        }
    }
}
