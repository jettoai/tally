import Foundation

extension URLSession {
    /// A session for credentialed provider requests. Ephemeral + no cache so authenticated usage
    /// responses (which include account details) are never written to an on-disk URLCache.
    static let tally: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
}
