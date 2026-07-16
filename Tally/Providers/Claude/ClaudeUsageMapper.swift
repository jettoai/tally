import Foundation

/// Normalizes the `/api/oauth/usage` response into `UsageMetric`s.
///
/// Grounded in the CURRENT live schema (verified 2026-07-15): Anthropic moved per-model weekly
/// windows out of the top-level `seven_day_opus`/`seven_day_sonnet` keys (now null) into the
/// `limits[]` array, each entry carrying `kind`, `percent`, `severity`, `resets_at`, `is_active`,
/// and (for scoped ones) `scope.model.display_name`. `limits[]` is the source of truth; the
/// top-level `five_hour`/`seven_day` objects are a fallback for older accounts.
enum ClaudeUsageMapper {
    private struct Payload: Decodable {
        struct Window: Decodable { var utilization: Double?; var resets_at: String? }
        struct Limit: Decodable {
            var kind: String?
            var percent: Double?
            var severity: String?
            var resets_at: String?
            var is_active: Bool?
            var scope: Scope?
            struct Scope: Decodable { var model: Model? }
            struct Model: Decodable { var display_name: String? }
        }
        var five_hour: Window?
        var seven_day: Window?
        var limits: [Limit]?
    }

    static func map(data: Data) -> [UsageMetric] {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }

        if let limits = payload.limits, !limits.isEmpty {
            let mapped = limits.compactMap(metric(from:))
            if !mapped.isEmpty { return mapped.uniquingIDs() }
        }
        return fallbackMetrics(payload).uniquingIDs()
    }

    private static func metric(from limit: Payload.Limit) -> UsageMetric? {
        guard let percent = limit.percent else { return nil }
        let resets = limit.resets_at.flatMap(ISO8601.date(from:))
        // Use Tally's own remaining-based thresholds (under 50% amber, under 20% red) uniformly across
        // providers, rather than Anthropic's reported severity, so the colour scale is consistent.
        let severity = MetricSeverity.fromUsedPercent(percent)
        let active = limit.is_active ?? false

        switch limit.kind {
        case "session":
            return UsageMetric(id: "session", kind: .session, label: "Session", modelName: nil,
                               usedPercent: percent, severity: severity, resetsAt: resets, isActive: active)
        case "weekly_all":
            return UsageMetric(id: "weekly_all", kind: .weeklyAll, label: "Weekly", modelName: nil,
                               usedPercent: percent, severity: severity, resetsAt: resets, isActive: active)
        case "weekly_scoped":
            let model = limit.scope?.model?.display_name ?? "Model"
            return UsageMetric(id: "weekly_model:\(model)", kind: .weeklyModel, label: model, modelName: model,
                               usedPercent: percent, severity: severity, resetsAt: resets, isActive: active)
        default:
            return nil
        }
    }

    private static func fallbackMetrics(_ payload: Payload) -> [UsageMetric] {
        var metrics: [UsageMetric] = []
        if let session = payload.five_hour, let used = session.utilization {
            metrics.append(UsageMetric(id: "session", kind: .session, label: "Session", modelName: nil,
                                       usedPercent: used, severity: .unknown,
                                       resetsAt: session.resets_at.flatMap(ISO8601.date(from:)), isActive: false))
        }
        if let weekly = payload.seven_day, let used = weekly.utilization {
            metrics.append(UsageMetric(id: "weekly_all", kind: .weeklyAll, label: "Weekly", modelName: nil,
                                       usedPercent: used, severity: .unknown,
                                       resetsAt: weekly.resets_at.flatMap(ISO8601.date(from:)), isActive: false))
        }
        return metrics
    }

    /// Plan label from the stored credential, e.g. subscriptionType "max" + tier
    /// "default_claude_max_20x" → "Max 20x".
    static func plan(_ credentials: ClaudeAccounts.Credentials) -> String? {
        guard let sub = credentials.subscriptionType?.trimmingCharacters(in: .whitespaces), !sub.isEmpty else {
            return nil
        }
        let base = sub.capitalized
        if let tier = credentials.rateLimitTier,
           let range = tier.range(of: #"\d+x"#, options: .regularExpression) {
            return "\(base) \(tier[range])"
        }
        return base
    }
}
