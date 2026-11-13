import Foundation

/// Session incidents and credential deadlines remain independent of a CLI's local sign-in verdict.
struct LoginHealthSession: Equatable, Identifiable {
    let id: String
    let accountID: String
    let childPid: Int?
    let directory: String?
    let failedAt: Date

    var episode: String { id + ":" + String(failedAt.timeIntervalSince1970) }
}

struct LoginHealthAlert: Equatable {
    enum Kind: String, Codable { case session, expiring, expired }
    let accountID: String
    let key: String
    let kind: Kind
    var sessionID: String? = nil
}

/// Reserved means accepted for posting, not read by the user. Failed submissions release the key.
struct LoginHealthAlerts: Codable, Equatable {
    var sessions: Set<String> = []
    var deadlines: [String: Date] = [:]
    var expiryKeys: Set<String> = []
    /// Per account, when a renewal landed: every session failure at or before it is retired (B-4530).
    /// Persisted with the rest, so a relaunch does not bring the same red mark back.
    var retiredAt: [String: Date] = [:]

    func isRetired(_ session: LoginHealthSession) -> Bool {
        retiredAt[session.accountID].map { session.failedAt <= $0 } ?? false
    }

    mutating func retire(_ accountID: String, at: Date) { retiredAt[accountID] = at }

    mutating func advance(sessions active: [LoginHealthSession], deadlines observed: [String: Date],
                          known: Set<String>, now: Date) -> [LoginHealthAlert] {
        var result: [LoginHealthAlert] = []
        sessions.formIntersection(Set(active.map(\.episode)))
        for session in active where !sessions.contains(session.episode) {
            sessions.insert(session.episode)
            result.append(LoginHealthAlert(accountID: session.accountID, key: session.episode,
                                           kind: .session, sessionID: session.id))
        }
        for id in Array(deadlines.keys) where !known.contains(id) {
            clearDeadline(id)
        }
        for (id, deadline) in observed where known.contains(id) {
            if deadlines[id] != deadline {
                clearDeadline(id)
                deadlines[id] = deadline
            }
            let kind: LoginHealthAlert.Kind
            switch ClaudeLoginExpiry.state(deadline: deadline, now: now) {
            case .expired: kind = .expired
            case .expiring: kind = .expiring
            case .unknown, .valid: continue
            }
            let key = expiryKey(id, deadline, kind)
            if expiryKeys.insert(key).inserted {
                result.append(LoginHealthAlert(accountID: id, key: key, kind: kind))
            }
        }
        return result
    }

    mutating func rearm(_ alert: LoginHealthAlert) {
        if alert.kind == .session { sessions.remove(alert.key) }
        else { expiryKeys.remove(alert.key) }
    }

    private mutating func clearDeadline(_ id: String) {
        if let previous = deadlines.removeValue(forKey: id) {
            expiryKeys.remove(expiryKey(id, previous, .expiring))
            expiryKeys.remove(expiryKey(id, previous, .expired))
        }
    }

    private func expiryKey(_ id: String, _ date: Date, _ kind: LoginHealthAlert.Kind) -> String {
        id + ":" + String(date.timeIntervalSince1970) + ":" + kind.rawValue
    }
}

extension LoginHealthAlerts {
    /// State saved before `retiredAt` existed has no such key; it must still load.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try values.decodeIfPresent(Set<String>.self, forKey: .sessions) ?? []
        deadlines = try values.decodeIfPresent([String: Date].self, forKey: .deadlines) ?? [:]
        expiryKeys = try values.decodeIfPresent(Set<String>.self, forKey: .expiryKeys) ?? []
        retiredAt = try values.decodeIfPresent([String: Date].self, forKey: .retiredAt) ?? [:]
    }
}
