import Foundation

// External services are inert. Tests compile the production store and its state logic unchanged.
enum DemoUsage { static let isActive = false }
enum BuildVariant { static let isUnshipped = true }
func L(_ key: String) -> String { key }

@MainActor
final class LoginHealthStore {
    static let shared = LoginHealthStore()
    var invalidated: [String] = []
    func invalidate(_ accountID: String) { invalidated.append(accountID) }
    func evaluate(accounts: [ProviderAccount], known: Set<String>, userInitiated: Bool) async {}
}

@MainActor
final class SettingsStore {
    static let shared = SettingsStore()
    func displayLabel(accountID: String, fallback: String) -> String { fallback }
}

@MainActor
final class UsageStore {
    static let shared = UsageStore()
    func discoveredAccountsNow() -> [ProviderAccount] { [] }
}

enum IntegrationsStore {
    enum Shim: String {
        case claude, codex
        var envKey: String { self == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME" }
    }
}

enum ProviderCLI {
    static func executable(_ provider: String, devOverrideKey: String) -> String { "/usr/bin/false" }
}

@MainActor
final class NotificationRouter {
    static let shared = NotificationRouter()
    func refreshCategories() {}
}

enum SystemAlert {
    @MainActor
    static func post(title: String, body: String, categoryID: String?, userInfo: [String: String]) async -> Bool {
        fatalError("An unshipped login-store test must not submit system notifications")
    }
}
