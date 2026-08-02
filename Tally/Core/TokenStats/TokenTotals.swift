import Foundation

/// The four token classes a coding session produces, kept apart rather than summed into one
/// number. They are not interchangeable: cache reads are usually the largest count by an order of
/// magnitude and the cheapest per token, so a single "tokens" figure would be dominated by the
/// one class that says the least about how much work was done. Output is the honest headline.
struct TokenTotals: Codable, Sendable, Equatable {
    /// Fresh input the model had to read (Claude's `input_tokens`; for Codex, the part of its
    /// `input_tokens` that was not served from cache).
    var input: Int64 = 0
    /// Tokens written into the prompt cache (Claude's `cache_creation_input_tokens`).
    var cacheWrite: Int64 = 0
    /// Tokens served from the prompt cache (Claude's `cache_read_input_tokens`).
    var cacheRead: Int64 = 0
    /// Tokens the model generated, reasoning included (Codex counts reasoning inside its own
    /// `output_tokens`, so both providers report the same thing here).
    var output: Int64 = 0

    var total: Int64 { input + cacheWrite + cacheRead + output }
    var isEmpty: Bool { total == 0 }

    static func += (lhs: inout TokenTotals, rhs: TokenTotals) {
        lhs.input += rhs.input
        lhs.cacheWrite += rhs.cacheWrite
        lhs.cacheRead += rhs.cacheRead
        lhs.output += rhs.output
    }
}

/// One aggregation cell: a local calendar day, one project, one provider. This is the finest grain
/// Tally keeps, and the grain the cache is written at, so a re-scan of one changed transcript
/// replaces exactly that file's contribution and nothing else.
struct TokenBucket: Codable, Sendable {
    /// Local days since 1970-01-01. An integer rather than a date string because nothing ever
    /// displays a day (the UI only ever shows range totals), and range filtering is then a
    /// comparison instead of a parse.
    var day: Int
    /// Absolute working directory, or `TokenProject.otherKey` for the pooled bucket.
    var project: String
    var totals: TokenTotals
}

/// A merged cell, with the provider that produced it (which the cache stores once per file).
struct TokenSample: Sendable {
    var day: Int
    var project: String
    var providerID: String
    var totals: TokenTotals
}

/// The project row's identity. Which directory maps to which project is `TokenProjectMap`.
enum TokenProject {
    /// The pooled row: directories that are not projects in any useful sense, plus the sessions
    /// that recorded no directory at all. Kept as one visible row rather than dropped, so the
    /// project table's numbers still add up to the headline.
    static let otherKey = ""

    /// What the project table shows: the trailing path component, because the full path is too
    /// wide for the row and the leading directories are the same for every project anyway. More
    /// components are asked for when that trailing name is not unique in the table (`.../web/src`
    /// and `.../api/src` are two different projects and must not render as two identical rows).
    static func displayName(forKey key: String, components: Int = 1) -> String {
        guard key != otherKey else { return L("Other") }
        let parts = key.split(separator: "/")
        return parts.suffix(max(1, components)).joined(separator: "/")
    }
}

/// The time window the Tokens tab is showing. Day-grained, always including today, because the
/// transcripts are timestamped per message but the cache aggregates per local day.
enum TokenStatsRange: String, CaseIterable, Identifiable, Sendable {
    case today, sevenDays, thirtyDays, all

    var id: String { rawValue }

    /// How many days back the window reaches, `nil` for "everything on this machine".
    var dayCount: Int? {
        switch self {
        case .today: return 1
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .all: return nil
        }
    }

    /// Segmented-control label. The numeric ones are verbatim (a "7D" needs no translation and a
    /// translated one would break the control's even column widths).
    var label: String {
        switch self {
        case .today: return L("Today")
        case .sevenDays: return "7D"
        case .thirtyDays: return "30D"
        case .all: return L("All")
        }
    }
}
