import Foundation

/// An official usage failure is stronger evidence than a local credential-presence probe.
struct LoginUsageHealth: Equatable {
    private(set) var rejected: Set<String> = []

    mutating func record(accountID: String, authenticated: Bool) {
        if authenticated { rejected.remove(accountID) }
        else { rejected.insert(accountID) }
    }

    mutating func recordIfCurrent(accountID: String, authenticated: Bool, since mark: Int,
                                  landings: LoginProbeGate.Landings) -> Bool {
        guard !landings.isStale(accountID, since: mark) else { return false }
        record(accountID: accountID, authenticated: authenticated)
        return true
    }

    /// A provider callback speaks for one account and cannot prune another account's outage.
    static func updateAlert(state: LoginAlertState, accountID: String,
                            authenticated: Bool) -> (LoginAlertState, [String]) {
        LoginAlertLogic.advance(state: state,
            verdicts: [accountID: authenticated ? .signedIn : .signedOut],
            known: state.announced.union([accountID]))
    }

    func needsSignIn(_ accountID: String, local: LoginStatusCommand.Verdict?) -> Bool {
        rejected.contains(accountID) || local == .signedOut
    }

    func applying(to local: [String: LoginStatusCommand.Verdict]) -> [String: LoginStatusCommand.Verdict] {
        local.merging(Dictionary(uniqueKeysWithValues: rejected.map { ($0, .signedOut) })) { _, remote in remote }
    }
}
