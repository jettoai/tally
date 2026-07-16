import Foundation

/// The fixed, ordered set of providers Tally ships. Add a provider here to register it everywhere
/// (refresh loop + settings toggles).
enum ProviderCatalog {
    static let all: [any UsageProvider] = [
        ClaudeProvider(),
        CodexProvider(),
    ]

    /// (id, display name) pairs for the settings UI, in catalog order.
    static var descriptors: [(id: String, name: String)] {
        all.map { ($0.id, $0.displayName) }
    }

    static func displayName(for providerID: String) -> String {
        all.first { $0.id == providerID }?.displayName ?? providerID.capitalized
    }

    /// SF Symbol used to mark each provider's card.
    static func iconName(for providerID: String) -> String {
        switch providerID {
        case "claude": return "sparkle"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        default: return "circle.grid.2x2"
        }
    }
}
