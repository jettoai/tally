import Foundation

extension IntegrationsStore {
    static var codexSessionRoot: URL { UsageSnapshot.directory }

    static func codexSessionHomes() -> [String] {
        CodexAccounts.discover().compactMap(\.launchHome)
    }

    static func detectCodexSessionHooks() -> Status {
        do {
            if try CodexSessionHooks.installed(homes: codexSessionHomes(), root: codexSessionRoot) {
                return .installed
            }
            return try CodexSessionHooks.receipt(root: codexSessionRoot) == nil
                ? .notInstalled : .broken(L("Codex session status installation needs attention."))
        } catch { return .broken(error.localizedDescription) }
    }

    func installCodexSessionHooks() {
        guard guardNotDev() else { return }
        guard cliToolStatus == .installed else {
            lastError = L("Install the command line tool first.")
            return
        }
        lastError = nil
        do {
            try CodexSessionHooks.install(homes: Self.codexSessionHomes(), root: Self.codexSessionRoot)
        } catch { lastError = error.localizedDescription }
        // Keep a partial installation visible and removable after a failed write.
        if let receipt = try? CodexSessionHooks.receipt(root: Self.codexSessionRoot) {
            recordManifest(CodexSessionHooks.component,
                           paths: receipt.paths + [CodexSessionHooks.receiptURL(root: Self.codexSessionRoot).path])
        }
        refresh()
    }

    func removeCodexSessionHooks() {
        guard guardNotDev() else { return }
        lastError = nil
        do {
            try CodexSessionHooks.remove(root: Self.codexSessionRoot)
            recordManifest(CodexSessionHooks.component, paths: nil)
        } catch { lastError = error.localizedDescription }
        refresh()
    }
}
