import Foundation

/// The limit resets a Claude login holds (a full reset, a Fable reset...), read from the
/// `cedar_ember` block of Anthropic's OAuth usage response. Foundation only, so the inventory suite
/// compiles it standalone.
///
/// READ-ONLY. Nothing here spends a reset: the one claim is ClaudeResetClaim, behind the card's
/// confirmation. A grant's id is kept for that claim only, inside `GrantID`, which prints as
/// redacted, so no log, snapshot or description carries it.
struct ClaudeResetInventory: Equatable, Sendable {
    /// What a grant gives back, named the way Claude Code names it. `other` is a `type` this build
    /// does not know: the card calls it a plain reset, the snapshot keeps the type as sent.
    enum Kind: String, Codable, CaseIterable, Sendable {
        case session, weekly, fable, full, other
    }

    /// The server's id for one grant, which the claim names. Prints as redacted.
    struct GrantID: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
                    CustomReflectable {
        let raw: String
        var description: String { "GrantID(<redacted>)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }

    struct Grant: Equatable, Sendable {
        var id: GrantID
        var kind: Kind
        /// The snapshot's name for it: the kind, or for `other` the `type` the response sent.
        var name: String
        var left: Int
        var total: Int
        var endsAt: Date
        /// `usable_now`: absent or malformed metadata never enables spending.
        var usableNow: Bool = false
        /// `use_requires_limit`: only usable while the login is at a limit (`at_limit`).
        var useRequiresLimit: Bool = false
        /// `percent_used` per window ("five_hour", "seven_day", ...), when the server sent it.
        var percentUsed: [String: Double] = [:]
        /// The windows it clears, as sent.
        var clears: [String] = []
    }

    /// False when the response says the login is not in the program (`eligible` not true, or no
    /// `cedar_ember` block at all). An ineligible login has no grants by definition.
    var eligible: Bool
    /// The grants in force at `now` of the parse: started, not ended, not paused. Soonest end first.
    var grants: [Grant]
    /// `at_limit`: the login is at one of its limits now.
    var atLimit: Bool = false
    /// `weekly_resets_at`: when the weekly limit refills on its own.
    var weeklyResetsAt: Date?
    /// `next_grant_id`, kept only when it names a grant in force: the one the server expects next.
    var nextGrantID: GrantID?

    var left: Int { grants.reduce(0) { $0 + $1.left } }

    /// One line per kind: resets left summed, the soonest end among grants that still have one,
    /// soonest-ending kind first. Kinds with nothing left are dropped, so an all-spent inventory
    /// is an empty list.
    var byKind: [(kind: Kind, left: Int, endsAt: Date)] {
        Kind.allCases.compactMap { kind -> (kind: Kind, left: Int, endsAt: Date)? in
            let mine = grants.filter { $0.kind == kind && $0.left > 0 }
            guard let end = mine.map(\.endsAt).min() else { return nil }
            return (kind, mine.reduce(0) { $0 + $1.left }, end)
        }
        .sorted { $0.endsAt < $1.endsAt }
    }

    /// The grant a press on this kind's row claims: the server's next grant when it is of this
    /// kind, otherwise the soonest-ending one that still has a reset. Nil when none has.
    func claimable(_ kind: Kind) -> Grant? {
        let mine = grants.filter { $0.kind == kind && $0.left > 0 }
        if let next = nextGrantID, let grant = mine.first(where: { $0.id == next }) { return grant }
        return mine.min { $0.endsAt < $1.endsAt }
    }

    /// Claude Code 2.1.311's own rule: a grant that gives back weekly spend is a Fable reset even
    /// when its `type` says "full"; otherwise the type names it, a type this build does not know
    /// included (`other`); only with no type do the windows it clears decide.
    static func kind(givesBackWeekly: Bool, type: String?, clears: [String]) -> Kind {
        if givesBackWeekly { return .fable }
        if let type { return Kind(rawValue: type) ?? .other }
        let session = clears.contains("five_hour")
        let other = clears.contains { $0 != "five_hour" }
        if session && !other { return .session }
        if other && !session { return .weekly }
        return .full
    }

    /// The inventory in a usage response body, or nil when it cannot be told: a body that is not a
    /// JSON object, a `cedar_ember` or `eligible` of the wrong shape, an eligible login whose
    /// `grants` is not a list, or any grant this cannot read. One unreadable grant fails the whole
    /// read on purpose: a held-over inventory is better than a list that silently lost a reset,
    /// and far better than "no resets". A missing or null `cedar_ember` reads as ineligible: the
    /// response was read and carries no program for this login.
    static func parse(_ body: Data, now: Date) -> ClaudeResetInventory? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        let block: [String: Any]
        switch root["cedar_ember"] {
        case nil, is NSNull: return ClaudeResetInventory(eligible: false, grants: [])
        case let value as [String: Any]: block = value
        default: return nil
        }
        guard let eligible = flag(block["eligible"]) else { return nil }
        guard eligible else { return ClaudeResetInventory(eligible: false, grants: []) }
        guard let raw = block["grants"] as? [Any] else { return nil }
        var grants: [Grant] = []
        for item in raw {
            guard let object = item as? [String: Any] else { return nil }
            switch grant(object, now: now) {
            case .inForce(let grant): grants.append(grant)
            case .outOfScope: continue
            case .unreadable: return nil
            }
        }
        // Advisory fields: an odd one is dropped rather than failing the read.
        let next = (block["next_grant_id"] as? String).map(GrantID.init(raw:))
        return ClaudeResetInventory(eligible: true, grants: grants.sorted { $0.endsAt < $1.endsAt },
                                    atLimit: flag(block["at_limit"]) ?? false,
                                    weeklyResetsAt: (block["weekly_resets_at"] as? String).flatMap(date),
                                    nextGrantID: grants.contains { $0.id == next } ? next : nil)
    }

    /// For the fetch's log, so an ineligible answer says why: whether `cedar_ember` came back
    /// ("present", "null", "absent", "other"), its `eligible` ("true", "false", "absent", "other")
    /// and `ineligible_reason` (a short code, cut to 64 characters; "-" when there is none). Nothing
    /// from a grant: no id, label or count.
    static func programFields(_ body: Data) -> (block: String, eligible: String, reason: String) {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return ("unreadable", "-", "-")
        }
        let block: [String: Any]
        switch root["cedar_ember"] {
        case nil: return ("absent", "-", "-")
        case is NSNull: return ("null", "-", "-")
        case let value as [String: Any]: block = value
        default: return ("other", "-", "-")
        }
        let eligible: String
        switch block["eligible"] {
        case nil, is NSNull: eligible = "absent"
        case let value?: eligible = flag(value).map { $0 ? "true" : "false" } ?? "other"
        }
        let reason = (block["ineligible_reason"] as? String).map { String($0.prefix(64)) } ?? "-"
        return ("present", eligible, reason)
    }

    /// What one grant is at `now`. Paused, not started and ended are out of scope; that is decided
    /// from those three fields alone, so a lapsed grant in an older shape does not fail the read.
    private enum Reading { case inForce(Grant), outOfScope, unreadable }

    private static func grant(_ object: [String: Any], now: Date) -> Reading {
        guard let starts = (object["starts_at"] as? String).flatMap(date),
              let ends = (object["ends_at"] as? String).flatMap(date),
              let paused = flag(object["paused"]) else { return .unreadable }
        if paused || starts > now || ends <= now { return .outOfScope }
        guard let id = object["id"] as? String, !id.isEmpty,
              let left = integer(object["resets_left"]), left >= 0,
              let total = integer(object["resets_total"]), total >= 0,
              let givesBack = flag(object["gives_back_weekly"]) else { return .unreadable }
        let type: String?
        switch object["type"] {
        case nil, is NSNull: type = nil
        case let value as String where !value.isEmpty: type = value
        default: return .unreadable
        }
        let clears: [String]
        switch object["clears"] {
        case nil, is NSNull: clears = []
        case let value as [String]: clears = value
        default: return .unreadable
        }
        // With neither a type nor a weekly give-back, the windows are the only thing naming it.
        if !givesBack && type == nil && clears.isEmpty { return .unreadable }
        let kind = kind(givesBackWeekly: givesBack, type: type, clears: clears)
        // The claim's gates and the confirmation's numbers: an odd value closes the gate or drops
        // the number, never the read.
        let usableNow: Bool
        switch object["usable_now"] {
        case nil, is NSNull: usableNow = false
        default: usableNow = flag(object["usable_now"]) ?? false
        }
        var percentUsed: [String: Double] = [:]
        for (window, value) in object["percent_used"] as? [String: Any] ?? [:] {
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue.isFinite { percentUsed[window] = number.doubleValue }
        }
        return .inForce(Grant(id: GrantID(raw: id), kind: kind,
                              name: kind == .other ? (type ?? kind.rawValue) : kind.rawValue,
                              left: left, total: total, endsAt: ends, usableNow: usableNow,
                              useRequiresLimit: flag(object["use_requires_limit"]) ?? true,
                              percentUsed: percentUsed, clears: clears))
    }

    /// A JSON integer; a boolean (which `JSONSerialization` also hands over as NSNumber) is not one.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }

    /// A JSON boolean, with a missing or null key read as false.
    private static func flag(_ value: Any?) -> Bool? {
        switch value {
        case nil, is NSNull: return false
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): return number.boolValue
        default: return nil
        }
    }

    /// "2026-11-10T21:30:00+00:00", with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
