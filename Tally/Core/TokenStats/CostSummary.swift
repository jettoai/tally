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
    /// False when the scan does not reach back to the start of the previous window (see
    /// `CostChange.previousWindowCovered`): the table then shows no change figures at all.
    var previousWindowCovered = true

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
        let compared = made.projects.filter { $0.previousCost != nil }
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
            },
            // Only Claude has a price list, so only its transcripts decide how far back the cost
            // history goes (Codex sessions are kept longer and would hide the gap).
            previousWindowCovered: CostChange.previousWindowCovered(
                oldestDay: samples.lazy.filter { $0.providerID == "claude" }.map(\.day).min(),
                today: today, dayCount: range.dayCount,
                previous: compared.reduce(0) { $0 + ($1.previousCost ?? 0) },
                current: compared.reduce(0) { $0 + $1.cost }))
    }
}

enum CostFormat {
    static func dollars(_ value: Double) -> String { costDollars(value) }

    /// The change against the previous window, e.g. "+12%", or nil when there is nothing to compare.
    static func change(_ cost: Double, previous: Double?) -> String? {
        guard let previous else { return nil }
        guard previous > 0.005 else { return cost > 0 ? L("New") : nil }
        return CostChange.percentLabel(Int(((cost - previous) / previous * 100).rounded()))
    }
}
