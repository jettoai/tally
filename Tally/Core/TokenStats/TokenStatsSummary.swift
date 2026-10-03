import Foundation

/// The Tokens tab's whole render input: one range's totals, split by provider and by project.
struct TokenStatsSummary: Sendable {
    var totals = TokenTotals()
    var providers: [ProviderRow] = []
    var projects: [ProjectRow] = []

    var isEmpty: Bool { totals.isEmpty }

    struct ProviderRow: Identifiable, Sendable {
        var providerID: String
        var totals: TokenTotals
        /// Share of the range's total tokens, 0...1 - the same quantity the project rows carry, so
        /// both tables answer "how much of this window was that" without arithmetic.
        var share: Double
        var id: String { providerID }
    }

    struct ProjectRow: Identifiable, Sendable {
        /// The project key (absolute path), or `TokenProject.otherKey` for the pooled row.
        var key: String
        var name: String
        var totals: TokenTotals
        /// Share of the range's total tokens, 0...1 - what the row's bar draws.
        var share: Double
        var id: String { key }
        var isOther: Bool { key == TokenProject.otherKey }
    }

    /// How many projects get their own row before the tail is pooled. Beyond this the list stops
    /// being a ranking and starts being a directory listing.
    static let projectRowLimit = 15

    /// Aggregate `samples` over the window ending today (rust/crates/core/src/tokenstats/summary.rs).
    ///
    /// Ranking, bars and shares are all by TOTAL, the same figure the headline states; output
    /// breaks ties second and the key third. Every provider that has ever recorded anything keeps
    /// its row in catalog order even when this window is empty, so switching ranges changes
    /// numbers, not the layout. Names that repeat are widened to two path components.
    static func make(samples: [TokenSample], range: TokenStatsRange,
                     today: Int = LocalDayStamper.today()) -> TokenStatsSummary {
        let made = tokenStatsSummarize(samples: samples.map(\.ffi), dayCount: range.dayCount.map(UInt32.init),
                                       today: Int64(today), providerOrder: ProviderCatalog.all.map(\.id))
        var summary = TokenStatsSummary(totals: TokenTotals(made.totals))
        summary.providers = made.providers.map {
            ProviderRow(providerID: $0.providerId, totals: TokenTotals($0.totals), share: $0.share)
        }
        summary.projects = made.projects.map {
            ProjectRow(key: $0.key,
                       name: $0.isOther ? TokenProject.displayName(forKey: TokenProject.otherKey) : $0.name,
                       totals: TokenTotals($0.totals), share: $0.share)
        }
        return summary
    }
}
