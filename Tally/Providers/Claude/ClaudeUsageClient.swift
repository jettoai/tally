import Foundation

/// Calls the semi-official Claude Code usage endpoint. This is the exact request the CLI itself makes.
struct ClaudeUsageClient: Sendable {
    struct Response: Sendable {
        var statusCode: Int
        var body: Data
    }

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    var session: URLSession = .tally

    func fetchUsage(accessToken: String) async throws -> Response {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Honest first-party identity — the endpoint returns 200 without spoofing the CLI's User-Agent.
        request.setValue("Tally", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return Response(statusCode: code, body: data)
    }
}
