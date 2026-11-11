import Foundation

/// Consent is bound to a particular login and measured inventory, never just to a config folder.
/// All panels share the store's one gate, so reopening a panel cannot submit a duplicate claim.
struct ClaudeResetClaimGate {
    struct Consent: Equatable {
        var accountID: String
        var identity: String
        var organizationID: String
        var grantID: ClaudeResetInventory.GrantID
        var checkedAt: Date
    }

    private var active: UUID?
    var isBusy: Bool { active != nil }

    mutating func begin(_ consent: Consent, current: Consent?, grant: ClaudeResetInventory.Grant,
                        stale: Bool, confirmed: Bool, now: Date) -> UUID? {
        guard confirmed, active == nil, consent == current, !stale,
              grant.id == consent.grantID, grant.left > 0, grant.usableNow,
              grant.endsAt > now else { return nil }
        let ticket = UUID()
        active = ticket
        return ticket
    }

    func isCurrent(_ ticket: UUID, consent: Consent, current: Consent?) -> Bool {
        active == ticket && current == consent
    }

    mutating func finish(_ ticket: UUID) {
        if active == ticket { active = nil }
    }
}
