import Foundation

/// Authentication evidence from the bound Claude transcript. It never produces a quota signal.
struct TranscriptLoginSignals {
    private(set) var requiredAt: Date?
    /// The newest failure of the unresolved episode. `requiredAt` keeps the episode's first failure, so
    /// this is what tells a failure after a renewal from the one the renewal already retired (B-4530).
    private(set) var lastFailedAt: Date?

    mutating func observe(_ line: Substring, since: Date, sessionID: String?) {
        guard requiredAt != nil || line.contains("authentication_failed") else { return }
        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              event["isSidechain"] as? Bool != true,
              let stamp = event["timestamp"] as? String, let at = parseISO(stamp), at >= since,
              let type = event["type"] as? String else { return }
        // Some records omit the id. An explicit different id is never evidence for this file.
        if let id = event["sessionId"] as? String, let sessionID, id != sessionID { return }
        let message = event["message"] as? [String: Any]
        if type == "assistant", event["isApiErrorMessage"] as? Bool == true,
           event["error"] as? String == "authentication_failed" {
            requiredAt = requiredAt ?? at
            lastFailedAt = at
            return
        }
        guard let failedAt = requiredAt, at > failedAt else { return }
        if type == "assistant", event["isApiErrorMessage"] as? Bool != true,
           event["error"] == nil,
           let model = message?["model"] as? String, model.hasPrefix("claude") {
            requiredAt = nil
            lastFailedAt = nil
            return
        }
    }
}
