import Foundation

/// Normalizes the ChatGPT `wham/usage` response into `UsageMetric`s.
///
/// Grounded in the live schema (verified 2026-07-15): `rate_limit.primary_window` /
/// `secondary_window` each carry `used_percent`, `limit_window_seconds` (used to classify session vs
/// weekly), and `reset_at` (epoch seconds). `additional_rate_limits[]` carries per-model windows
/// (e.g. Spark) on plans that have them. Codex reports no per-window severity, so it's computed.
enum CodexUsageMapper {
    private struct Payload: Decodable {
        struct Window: Decodable {
            var used_percent: Double?
            var limit_window_seconds: Double?
            var reset_at: Double?
        }
        struct RateLimit: Decodable {
            var primary_window: Window?
            var secondary_window: Window?
        }
        struct AdditionalLimit: Decodable {
            var used_percent: Double?
            var reset_at: Double?
            var limit_name: String?
            var metered_feature: String?
        }
        var plan_type: String?
        var rate_limit: RateLimit?
        var additional_rate_limits: [AdditionalLimit]?
    }

    static func map(data: Data) -> [UsageMetric] {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }

        var metrics: [UsageMetric] = []
        if let window = payload.rate_limit?.primary_window { appendWindow(window, to: &metrics) }
        if let window = payload.rate_limit?.secondary_window { appendWindow(window, to: &metrics) }

        for limit in payload.additional_rate_limits ?? [] {
            guard let used = limit.used_percent else { continue }
            let name = modelName(from: limit) ?? "Model"
            metrics.append(UsageMetric(
                id: "codex_model:\(name)", kind: .weeklyModel, label: name, modelName: name,
                usedPercent: used, severity: .fromUsedPercent(used),
                resetsAt: epochDate(limit.reset_at), isActive: false))
        }
        return metrics.uniquingIDs()
    }

    private static func appendWindow(_ window: Payload.Window, to metrics: inout [UsageMetric]) {
        guard let used = window.used_percent else { return }
        let isWeekly = (window.limit_window_seconds ?? 0) >= 86_400
        metrics.append(UsageMetric(
            id: isWeekly ? "weekly_all" : "session",
            kind: isWeekly ? .weeklyAll : .session,
            label: isWeekly ? "Weekly" : "Session",
            modelName: nil,
            usedPercent: used, severity: .fromUsedPercent(used),
            resetsAt: epochDate(window.reset_at), isActive: false))
    }

    private static func modelName(from limit: Payload.AdditionalLimit) -> String? {
        let raw = limit.limit_name ?? limit.metered_feature
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func epochDate(_ seconds: Double?) -> Date? {
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Plan label from `plan_type`, e.g. "plus" → "Plus".
    static func plan(data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let raw = payload.plan_type?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        return raw.capitalized
    }
}
