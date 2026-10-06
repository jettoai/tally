import Foundation

/// The cost view's render input for one range (rust/crates/core/src/tokenstats/cost.rs): what the
/// tokens cost at list prices, by token class, provider and project. Priced tokens only reach the
/// project rows; a provider with no price list (Codex) keeps a row with a nil cost.
struct CostSummary: Sendable {
    var parts = Parts()
    var subagentCost = 0.0
    /// Turns on a model the price table does not know: shown, never treated as free in silence.
    var unpricedTurns: Int64 = 0
    var providers: [ProviderRow] = []
    var projects: [ProjectRow] = []

    var total: Double { parts.total }
    var isEmpty: Bool { total <= 0 && !providers.contains { !$0.tokens.isEmpty } }

    struct Parts: Sendable {
        var input = 0.0, cacheWrite = 0.0, cacheRead = 0.0, output = 0.0
        var total: Double { input + cacheWrite + cacheRead + output }
    }

    struct ProviderRow: Identifiable, Sendable {
        var providerID: String
        var cost: Double?
        var tokens: TokenTotals
        var id: String { providerID }
    }

    struct ProjectRow: Identifiable, Sendable {
        var key: String
        var name: String
        var cost: Double
        var share: Double
        var tokens: TokenTotals
        /// The window of equal length just before this one; nil for All and for Other.
        var previousCost: Double?
        var id: String { key }
        var isOther: Bool { key == TokenProject.otherKey }
    }

    static func make(samples: [TokenSample], range: TokenStatsRange,
                     today: Int = LocalDayStamper.today()) -> CostSummary {
        let made = tokenStatsSummarizeCost(samples: samples.map(\.ffi), dayCount: range.dayCount.map(UInt32.init),
                                           today: Int64(today), providerOrder: ProviderCatalog.all.map(\.id))
        return CostSummary(
            parts: Parts(input: made.parts.input, cacheWrite: made.parts.cacheWrite,
                         cacheRead: made.parts.cacheRead, output: made.parts.output),
            subagentCost: made.subagentCost,
            unpricedTurns: made.unpricedTurns,
            providers: made.providers.map {
                ProviderRow(providerID: $0.providerId, cost: $0.cost, tokens: TokenTotals($0.tokens))
            },
            projects: made.projects.map {
                ProjectRow(key: $0.key,
                           name: $0.isOther ? TokenProject.displayName(forKey: TokenProject.otherKey) : $0.name,
                           cost: $0.cost, share: $0.share, tokens: TokenTotals($0.tokens),
                           previousCost: $0.previousCost)
            })
    }
}

enum CostFormat {
    /// `$1,234` from $100 up, `$12.34` below: cents matter on a small figure and are noise on a
    /// large one. US dollars and digit grouping whatever the locale, since the prices are.
    static func dollars(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        let digits = abs(value) < 100 ? 2 : 0
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return "$" + (f.string(from: NSNumber(value: value)) ?? "0")
    }

    /// The change against the previous window, e.g. "+12%", or nil when there is nothing to compare.
    static func change(_ cost: Double, previous: Double?) -> String? {
        guard let previous else { return nil }
        guard previous > 0.005 else { return cost > 0 ? L("New") : nil }
        let percent = Int(((cost - previous) / previous * 100).rounded())
        return percent >= 0 ? "+\(percent)%" : "\(percent)%"
    }
}
