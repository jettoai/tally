/// Which column a list-row meter stands in, by what the window IS and never by its position, so a
/// kind keeps one x down a block whatever else the row reports. Deliberately knows nothing of
/// `MetricKind`: the view maps its kinds onto `MeterWindowRole`, which keeps this file pure.
enum MeterColumnKey: Hashable, Comparable {
    case model(Int)   // n-th model-scoped weekly window of the row (0 = the flagship)
    case other(Int)   // n-th window of a kind (or a repeat of a single-slot kind) nothing else claims
    case session      // the rolling 5-hour window
    case weekly       // the all-models weekly window, always the rightmost column
}

enum MeterWindowRole { case model, session, weekly, other }

enum MeterColumns {
    /// One row's keys, in the row's own order. `session` and `weekly` own one column each; a second
    /// window of either kind falls to `other(n)` so two windows can never share a column.
    static func keys(_ roles: [MeterWindowRole]) -> [MeterColumnKey] {
        var models = 0, others = 0
        var hasSession = false, hasWeekly = false
        return roles.map { role in
            switch role {
            case .model:
                defer { models += 1 }
                return .model(models)
            case .session where !hasSession:
                hasSession = true
                return .session
            case .weekly where !hasWeekly:
                hasWeekly = true
                return .weekly
            case .session, .weekly, .other:
                defer { others += 1 }
                return .other(others)
            }
        }
    }

    /// A block's columns: the union of its rows' keys, flagship windows leftmost, then the rest, the
    /// 5-hour window, and the weekly window last. A block with no 5-hour window at all has no
    /// 5-hour column.
    static func block(_ rows: [[MeterColumnKey]]) -> [MeterColumnKey] {
        Array(Set(rows.flatMap { $0 })).sorted()
    }

    /// The same columns in the order the Detailed panel reads them: the 5-hour window, the weekly
    /// one, then anything else, then the model-scoped windows with the flagship first. Which window a
    /// column holds never changes (`block` and `keys` are untouched); only where it stands.
    static func displayBlock(_ rows: [[MeterColumnKey]]) -> [MeterColumnKey] {
        func rank(_ key: MeterColumnKey) -> Int {
            switch key {
            case .session: 0
            case .weekly: 1
            case .other: 2
            case .model: 3
            }
        }
        return block(rows).sorted { (rank($0), $0) < (rank($1), $1) }
    }
}
