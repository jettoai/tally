import Foundation

// The redeem request channel, shared by BOTH targets: `tally redeem` writes a request and waits for
// the answer; the installed app claims the request, spends through the same call the panel's button
// makes (RedeemAction.redeem), and writes the answer back. Compiled into Tally.app as well as the
// tally tool (project.yml, beside ReloadRequest.swift), so it must stay dependency-free.
//
// One file per request (~/.tally/redeem/<id>.json) so two requests never overwrite each other.
// Ownership is decided by ONE path operation that only one side can win: the app claims by
// renaming <id>.json to <id>.claimed, the CLI withdraws by removing <id>.json. Whichever lands
// first, the other fails, so a request the CLI already reported as "not picked up" can never be
// spent afterwards.

let redeemDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/redeem")

/// Posted by the CLI after writing a request; the app's observer drains the directory.
let redeemRequestedNotification = "ai.jetto.tally.redeemRequested"

/// How long a request may wait to be claimed. The CLI withdraws after this; the app drops anything
/// older without acting, so an orphan from a killed CLI is never spent.
let redeemPickupWindow: TimeInterval = 10

struct RedeemRequest: Codable, Equatable {
    var id: String
    var accountID: String
    var label: String
    var createdAt: Date
}

/// The app's answer. `code` is one of `RedeemResultCode`'s raw values; `detail` is the server's own
/// words for a failure, never shown alone.
struct RedeemResult: Codable, Equatable {
    var id: String
    var code: String
    var detail: String?
}

enum RedeemResultCode: String, CaseIterable {
    case redeemed, noCredit, alreadyUsed, failed, busy, signedOut, notFound, notReady, notSupported
}

func redeemRequestURL(_ id: String, dir: URL = redeemDir) -> URL {
    dir.appendingPathComponent("\(id).json")
}
func redeemClaimedURL(_ id: String, dir: URL = redeemDir) -> URL {
    dir.appendingPathComponent("\(id).claimed")
}
func redeemResultURL(_ id: String, dir: URL = redeemDir) -> URL {
    dir.appendingPathComponent("\(id).result")
}

private func redeemEncoder() -> JSONEncoder {
    let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e
}
private func redeemDecoder() -> JSONDecoder {
    let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
}

/// Parse a request body; a truncated or foreign body is nil (never acted on).
func parseRedeemRequest(_ data: Data) -> RedeemRequest? {
    try? redeemDecoder().decode(RedeemRequest.self, from: data)
}
func parseRedeemResult(_ data: Data) -> RedeemResult? {
    try? redeemDecoder().decode(RedeemResult.self, from: data)
}

func writeRedeemRequest(_ request: RedeemRequest, dir: URL = redeemDir) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try redeemEncoder().encode(request).write(to: redeemRequestURL(request.id, dir: dir),
                                              options: .atomic)
}
func writeRedeemResult(_ result: RedeemResult, dir: URL = redeemDir) throws {
    try redeemEncoder().encode(result).write(to: redeemResultURL(result.id, dir: dir),
                                             options: .atomic)
}

/// The app's claim: true exactly when this call moved the request out of the CLI's reach.
func claimRedeemRequest(_ id: String, dir: URL = redeemDir) -> Bool {
    (try? FileManager.default.moveItem(at: redeemRequestURL(id, dir: dir),
                                       to: redeemClaimedURL(id, dir: dir))) != nil
}

/// The CLI's withdrawal: true exactly when the app had not claimed it yet.
func withdrawRedeemRequest(_ id: String, dir: URL = redeemDir) -> Bool {
    (try? FileManager.default.removeItem(at: redeemRequestURL(id, dir: dir))) != nil
}

/// The app's sweep of the request directory: drop unreadable and expired requests unclaimed, and
/// claim the rest. What comes back is exactly what this call now owns. Plain file work, so the app
/// runs it off the main thread.
func claimPendingRedeemRequests(dir: URL = redeemDir, now: Date = Date()) -> [RedeemRequest] {
    let files = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap { file in
        guard let data = try? Data(contentsOf: file), let request = parseRedeemRequest(data),
              !redeemRequestExpired(request, now: now) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return claimRedeemRequest(request.id, dir: dir) ? request : nil   // nil: the CLI withdrew
    }
}

/// The app's answer: the result for the waiting CLI, then the claim released.
func answerRedeemRequest(_ result: RedeemResult, dir: URL = redeemDir) {
    try? writeRedeemResult(result, dir: dir)
    try? FileManager.default.removeItem(at: redeemClaimedURL(result.id, dir: dir))
}

/// At app launch: a `.claimed` left by a crash mid-redeem is never retried (it may have spent), and
/// no CLI is still waiting on a `.result` from a previous run of the app.
func sweepRedeemLeftovers(dir: URL = redeemDir) {
    let files = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.pathExtension == "claimed" || file.pathExtension == "result" {
        try? FileManager.default.removeItem(at: file)
    }
}

/// Whether an unclaimed request is too old to act on.
func redeemRequestExpired(_ request: RedeemRequest, now: Date = Date(),
                          window: TimeInterval = redeemPickupWindow) -> Bool {
    let age = now.timeIntervalSince(request.createdAt)
    return age > window || age < -window   // a clock jump either way is not a fresh request
}

/// Exit code and sentence for one answer. Pure, so the whole table is testable.
func redeemAnswer(_ result: RedeemResult, label: String) -> (code: Int32, message: String) {
    switch RedeemResultCode(rawValue: result.code) {
    case .redeemed:
        return (0, "Redeemed 1 banked reset on \(label). Its usage clears within about a minute; "
                 + "'tally status' shows it after Tally's next reading.")
    case .noCredit:     return (1, "\(label) has no banked reset to redeem.")
    case .alreadyUsed:  return (1, "That reset credit was already used. Nothing was spent.")
    case .busy:         return (1, "A redeem for \(label) is already running, or one was spent on this run-out in the last 15 minutes.")
    case .signedOut:    return (1, "\(label) is signed out, so there is no session to redeem on.")
    case .notFound:     return (1, "Tally no longer lists \(label).")
    case .notReady:     return (1, "Tally has not finished its first reading yet. Try again in a minute.")
    case .notSupported: return (1, "\(label) cannot redeem a banked reset from Tally.")
    case .failed, nil:
        return (1, "Redeem failed: \(result.detail ?? "no answer from codex app-server").")
    }
}
