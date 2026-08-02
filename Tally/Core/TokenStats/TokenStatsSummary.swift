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

    /// Aggregate `samples` over the window ending today.
    ///
    /// Ranking, bars and shares are all by TOTAL, the same figure the headline states, so a row's
    /// bar and the card above it are the same quantity measured the same way. Output ties are
    /// broken second, which only matters between two projects whose totals match exactly.
    static func make(samples: [TokenSample], range: TokenStatsRange,
                     today: Int = LocalDayStamper.today()) -> TokenStatsSummary {
        let earliest = range.dayCount.map { today - ($0 - 1) }
        var summary = TokenStatsSummary()

        var byProvider: [String: TokenTotals] = [:]
        var byProject: [String: TokenTotals] = [:]
        var everSeenProviders = Set<String>()
        for sample in samples {
            everSeenProviders.insert(sample.providerID)
            if let earliest, sample.day < earliest { continue }
            summary.totals += sample.totals
            byProvider[sample.providerID, default: TokenTotals()] += sample.totals
            byProject[sample.project, default: TokenTotals()] += sample.totals
        }

        let denominator = Double(max(summary.totals.total, 1))

        // Catalog order, and every provider that has ever recorded anything keeps its row even
        // when this window is empty - so switching ranges changes numbers, not the layout.
        summary.providers = ProviderCatalog.all.map(\.id).filter(everSeenProviders.contains).map {
            let totals = byProvider[$0] ?? TokenTotals()
            return ProviderRow(providerID: $0, totals: totals,
                               share: Double(totals.total) / denominator)
        }

        var pooled = byProject.removeValue(forKey: TokenProject.otherKey) ?? TokenTotals()
        let ranked = byProject.sorted { ($0.value.total, $0.value.output) > ($1.value.total, $1.value.output) }
        for (_, totals) in ranked.dropFirst(projectRowLimit) { pooled += totals }

        summary.projects = ranked.prefix(projectRowLimit).map { key, totals in
            ProjectRow(key: key, name: TokenProject.displayName(forKey: key), totals: totals,
                       share: Double(totals.total) / denominator)
        }
        summary.projects = disambiguated(summary.projects)
        if !pooled.isEmpty {
            summary.projects.append(
                ProjectRow(key: TokenProject.otherKey,
                           name: TokenProject.displayName(forKey: TokenProject.otherKey),
                           totals: pooled, share: Double(pooled.total) / denominator))
        }
        return summary
    }

    /// Widen the names that repeat. Trailing path components collide constantly in a real
    /// checkout (`src`, `web`, `app`), and two rows reading the same with different numbers looks
    /// like a bug in the counting rather than two different directories. Deeper collisions keep
    /// the two-component form and lean on the row's full-path tooltip.
    private static func disambiguated(_ rows: [ProjectRow]) -> [ProjectRow] {
        let counts = rows.reduce(into: [String: Int]()) { $0[$1.name, default: 0] += 1 }
        return rows.map { row in
            guard counts[row.name, default: 0] > 1 else { return row }
            var widened = row
            widened.name = TokenProject.displayName(forKey: row.key, components: 2)
            return widened
        }
    }
}
