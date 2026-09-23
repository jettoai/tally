import Foundation

/// `result.rateLimitResetCredits` from the Codex app-server's `account/rateLimits/read`, decoded on
/// its own so the list's shape can be asserted without spawning the CLI (tests/resethint).
///
/// AN ABSENT LIST IS NOT AN EMPTY ONE. `credits` missing or null says the server did not list the
/// credits this round; `[]` says it listed none. Reading the first as the second told the expiry
/// hints that every banked credit had gone, which pruned their per-credit memory, and the same
/// stage was announced again once the list came back (`ResetHintLogic.advance`, codex review of
/// dcbc04f).
struct CodexResetBank: Decodable {
    let availableCount: Int?
    let credits: [Credit]?

    struct Credit: Decodable {
        let id: String?
        let status: String?
        let resetType: String?
        let expiresAt: Double?
    }

    /// The credits as the app carries them, an expiry kept even when null. Nil when the response
    /// did not list them, which `AccountUsage.resetCredits` reads as "not listed this round".
    var listed: [BankedResetCredit]? {
        credits.map { credits in
            credits.map {
                BankedResetCredit(id: $0.id, resetType: $0.resetType, status: $0.status,
                                  expiresAt: $0.expiresAt.map { Date(timeIntervalSince1970: $0) })
            }
        }
    }
}
