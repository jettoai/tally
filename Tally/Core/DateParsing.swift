import Foundation

/// Lenient ISO-8601 parsing for provider timestamps like `2026-07-15T12:30:00.496259+00:00`
/// (fractional seconds + timezone offset) and their fraction-less variants.
enum ISO8601 {
    // Read-only after init; ISO8601DateFormatter parsing is thread-safe on modern OSes.
    nonisolated(unsafe) private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(from string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return withFractional.date(from: trimmed) ?? plain.date(from: trimmed)
    }
}
