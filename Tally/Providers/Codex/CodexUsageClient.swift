import Foundation

/// Calls the ChatGPT backend usage endpoint the Codex CLI uses.
struct CodexUsageClient: Sendable {
    struct Response: Sendable {
        var statusCode: Int
        var body: Data
    }

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    var session: URLSession = .tally

    func fetchUsage(accessToken: String, accountId: String) async throws -> Response {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("Tally", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return Response(statusCode: code, body: data)
    }
}
