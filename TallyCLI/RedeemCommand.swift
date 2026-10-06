import Foundation

// `tally redeem --account <name>`: spend one Codex banked reset through the running app, so the
// redeem shares the panel's dedupe with the automatic redeem (RedeemRequest.swift says how the
// request travels). The CLI never talks to codex app-server itself.

struct RedeemArgs: Equatable { var account: String; var timeout: TimeInterval }

/// Nil = usage error (the caller prints the usage line, exit 2).
func parseRedeemArgs(_ args: [String]) -> RedeemArgs? {
    var account: String?; var timeout: TimeInterval = 60
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--account" where i + 1 < args.count: account = args[i + 1]; i += 2
        case "--timeout" where i + 1 < args.count:
            guard let t = TimeInterval(args[i + 1]), t > 0 else { return nil }
            timeout = t; i += 2
        default: return nil
        }
    }
    guard let account, !account.isEmpty else { return nil }
    return RedeemArgs(account: account, timeout: timeout)
}

enum RedeemTarget: Equatable {
    case codex(Snapshot.Account)
    case claude(Snapshot.Account)
    case none
    case several(provider: String, [Snapshot.Account])
    case noSnapshot
}

/// Which account a name means. Codex first; a Claude hit is named so the refusal can say why.
func redeemTarget(_ name: String, in snapshot: Snapshot?) -> RedeemTarget {
    guard let snapshot else { return .noSnapshot }
    switch accountMatching(name, provider: "codex", in: snapshot) {
    case .one(let a): return .codex(a)
    case .several(let list): return .several(provider: "codex", list)
    case .none: break
    }
    switch accountMatching(name, provider: "claude", in: snapshot) {
    case .one(let a): return .claude(a)
    case .several(let list): return .several(provider: "claude", list)
    case .none: return .none
    }
}

let redeemUsage = "usage: tally redeem --account <name> [--timeout <seconds>]"

func runRedeem(args: [String]) -> Int32 {
    guard let parsed = parseRedeemArgs(args) else { warn(redeemUsage); return 2 }
    let account: Snapshot.Account
    switch redeemTarget(parsed.account, in: loadSnapshot().0) {
    case .codex(let a): account = a
    case .claude(let a):
        warn("\(a.label) is a Claude account. Tally can only redeem Codex banked resets; "
             + "Claude's reset is used from claude.ai Settings > Usage.")
        return 1
    case .none:
        warn("No account named \"\(parsed.account)\". Run 'tally status' to see the labels.")
        return 1
    case .several(let provider, let list):
        warn(accountMatchAmbiguity(parsed.account, provider: provider, candidates: list))
        return 2
    case .noSnapshot:
        warn("Tally has not written a usage snapshot yet. Open Tally and try again.")
        return 1
    }
    guard tallyAppRunning() else { warn("Tally is not running. Open Tally and try again."); return 1 }

    let request = RedeemRequest(id: UUID().uuidString, accountID: account.id,
                                label: account.label, createdAt: Date())
    do { try writeRedeemRequest(request) } catch {
        warn("Could not write the redeem request: \(error.localizedDescription)")
        return 1
    }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(redeemRequestedNotification), object: nil, userInfo: nil,
        deliverImmediately: true)

    let pickupDeadline = Date().addingTimeInterval(redeemPickupWindow)
    let answerDeadline = Date().addingTimeInterval(parsed.timeout)
    let resultURL = redeemResultURL(request.id)
    var claimed = false
    while true {
        if let data = try? Data(contentsOf: resultURL), let result = parseRedeemResult(data) {
            try? FileManager.default.removeItem(at: resultURL)
            let answer = redeemAnswer(result, label: account.label)
            if answer.code == 0 { print("\(warnPrefix)\(answer.message)") } else { warn(answer.message) }
            return answer.code
        }
        if !claimed {
            // Gone without a result yet means the app renamed it; the result is read next round.
            claimed = !FileManager.default.fileExists(atPath: redeemRequestURL(request.id).path)
            if !claimed, Date() >= pickupDeadline {
                if withdrawRedeemRequest(request.id) {
                    warn("Tally did not pick up the request. Update Tally to the latest version "
                         + "(Tally Dev builds do not redeem).")
                    return 1
                }
                claimed = true   // lost the race to the app's claim: it owns the request now
            }
        }
        // Only a claimed request can time out here: an unclaimed one is settled by the withdrawal
        // above, so a short --timeout never reports "took the request" for one nobody took.
        if claimed, Date() >= answerDeadline {
            warn("Tally took the request but did not report back in time. Check 'tally status' "
                 + "before trying again: the reset may have been spent.")
            return 3
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
}
