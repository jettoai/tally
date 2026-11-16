import Foundation

/// How Codex's raw `planType` code (the app-server's own vocabulary) reads on screen. The code
/// itself stays on `AccountUsage.planKey`, because the capacity weight is keyed by it
/// (`PlanWeight`); only the display name is derived here.
enum CodexPlan {
    /// OpenAI names the three Pro tiers by price in its own client
    /// (codex-rs/tui/src/subscription.rs: ProLite "Pro 100", Pro "Pro 200", ProMax "Pro 500").
    /// Every other code keeps the plain capitalised word ("plus" -> "Plus", "team" -> "Team"), and a
    /// code with underscores reads as words ("self_serve_business_prolite" -> "Self Serve Business
    /// Prolite") rather than as a raw identifier.
    static func displayName(planType raw: String?) -> String? {
        guard let code = key(planType: raw) else { return nil }
        switch code {
        case "prolite": return "Pro 100"
        case "pro": return "Pro 200"
        case "promax": return "Pro 500"
        default: return code.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The raw code as the weight table keys it: trimmed, lower case; nil when absent or empty.
    static func key(planType raw: String?) -> String? {
        guard let code = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !code.isEmpty
        else { return nil }
        return code
    }
}
