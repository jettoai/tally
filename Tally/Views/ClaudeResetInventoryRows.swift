import SwiftUI

/// The limit resets a Claude account holds, one line per kind ("Full reset ×1 · until Dec 11"), in
/// the look of the Codex banked-reset line. A use button requests explicit confirmation first.
///
/// Nothing is drawn for an account never read: the inventory is optional, and the account's reset
/// state (`ResetOffer`) already speaks for "unknown". A login outside the program draws nothing
/// either. A held-over reading stays, dimmed, with its read time in the hover.
struct ClaudeResetInventoryRows: View {
    let accountID: String
    var store = ClaudeResetInventoryStore.shared
    @State private var busyGrant: ClaudeResetInventory.GrantID?
    @State private var resultMessage: String?

    var body: some View {
        if let entry = store.entry(accountID), entry.inventory.eligible {
            if entry.inventory.grants.allSatisfy({ $0.left == 0 }) {
                line(Text(L("No limit resets")), detail: readNote(entry))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(entry.inventory.grants.filter { $0.left > 0 }, id: \.id) { grant in
                    HStack(spacing: 4) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 9))
                            Text(verbatim: "\(Self.name(grant.kind)) ×\(grant.left) ·")
                            Text(verbatim: String(format: L("until %@"), Self.day(grant.endsAt)))
                                .foregroundStyle(!entry.isStale ? Self.urgencyColor(grant.endsAt) ?? .secondary : .secondary)
                        }
                        .font(.caption2)
                        .foregroundStyle(entry.isStale ? .tertiary : .secondary)
                        .tallyTooltip([Self.explanation(grant.kind),
                                       String(format: L("until %@"), UsageFormat.absoluteBody(grant.endsAt))]
                                        .compactMap { $0 }.joined(separator: " · "),
                                      detail: readNote(entry))
                        Spacer(minLength: 0)
                        Button {
                            confirmAndClaim(grant, entry: entry)
                        } label: {
                            if busyGrant == grant.id { ProgressView().controlSize(.mini) }
                            else { Text(L("Use")) }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        .disabled(store.isClaiming || busyGrant != nil || entry.isStale || !grant.usableNow
                                  || grant.endsAt <= Date() || grant.kind == .other
                                  || (grant.useRequiresLimit && !entry.inventory.atLimit)
                                  || entry.identity == nil || entry.organizationID == nil)
                        .tallyTooltip(L("Use this reset"))
                    }
                }
                if let resultMessage {
                    Text(resultMessage).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func confirmAndClaim(_ grant: ClaudeResetInventory.Grant, entry: ClaudeResetInventoryStore.Entry) {
        guard busyGrant == nil, !store.isClaiming else { return }
        let inventory = entry.inventory
        let label = SettingsStore.shared.displayLabel(accountID: accountID, fallback: "Claude")
        var parts = [label, Self.explanation(grant.kind) ?? L("This reset restores the account's limits"),
                     String(format: L("Resets remaining: %d"), grant.left),
                     String(format: L("until %@"), UsageFormat.absoluteBody(grant.endsAt))]
        var percentUsed = grant.percentUsed
        if percentUsed.isEmpty,
           let usage = UsageStore.shared.accounts.first(where: { $0.id == accountID }) {
            percentUsed = Dictionary(usage.metrics.map { ($0.id, $0.usedPercent) }, uniquingKeysWith: { first, _ in first })
        }
        let percentages = percentUsed.sorted { $0.key < $1.key }
            .map { "\($0.key): \(Int($0.value.rounded()))%" }
        if !percentages.isEmpty { parts.append(percentages.joined(separator: " · ")) }
        if !percentUsed.isEmpty && percentUsed.values.allSatisfy({ $0 < 50 }) {
            parts.append(L("Your limits are not close to full; using this now may waste the reset."))
        }
        if let weekly = inventory.weeklyResetsAt,
           weekly.timeIntervalSinceNow >= 0, weekly.timeIntervalSinceNow < 24 * 60 * 60 {
            parts.append(String(format: L("Your weekly limit resets on its own at %@."), UsageFormat.absoluteBody(weekly)))
        }
        guard CentredAlert.confirmWithCancelDefault(title: "\(Self.name(grant.kind)) \(L("use this reset?"))",
                                                    body: parts.joined(separator: "\n\n"),
                                                    confirmTitle: L("Use")) else { return }
        busyGrant = grant.id
        Task {
            let outcome = await store.claim(accountID: accountID, grantID: grant.id.raw,
                                            approvedEntry: entry, confirmed: true)
            var message = Self.message(outcome)
            if grant.kind == .fable, case .result(.reset, _, _) = outcome {
                message += "\n\n" + L("Weekly limit: only Fable usage was restored.")
            }
            resultMessage = message
            if outcome != .cancelled {
                CentredAlert.notice(title: L("Reset result"), body: message)
            }
            busyGrant = nil
        }
    }

    private static func message(_ outcome: ClaudeResetClaim.Outcome) -> String {
        switch outcome {
        case .cancelled: return L("Cancelled")
        case .result(.reset, let left, _):
            return left.map { String(format: L("Reset used. Remaining: %d."), $0) } ?? L("Reset used.")
        case .result(.notLimited, _, _):
            return L("No reset was applied because you are not at a limit; your reset may still be available. Refreshing the list.")
        case .result(.alreadyUsed, _, _): return L("This reset was already used.")
        case .result(.cooldown, _, let until):
            return until.map { String(format: L("Unavailable during cooldown until %@."), UsageFormat.absoluteBody($0)) }
                ?? L("Unavailable during cooldown.")
        case .result(.ineligible, _, _): return L("This reset is not eligible. Check again in a few minutes if the status is unclear.")
        case .result(.unavailable, _, _), .rateLimited, .authError, .error, .uncertain:
            return L("Reset status is unclear. Check again in a few minutes; it may have been used.")
        }
    }

    private func line(_ text: Text, detail: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 9))
            text
        }
        .font(.caption2)
        .tallyTooltip(detail)
    }

    /// "Read 11.11 14:02", or that the latest attempt failed and this is the reading from then.
    private func readNote(_ entry: ClaudeResetInventoryStore.Entry) -> String {
        String(format: L(entry.isStale ? "Couldn't refresh; last read %@" : "Read %@"),
               UsageFormat.absoluteBody(entry.checkedAt))
    }

    static func name(_ kind: ClaudeResetInventory.Kind) -> String {
        switch kind {
        case .session: return L("5-hour reset")
        case .weekly: return L("Weekly reset")
        case .fable: return L("Fable reset")
        case .full: return L("Full reset")
        case .other: return L("Reset")
        }
    }

    /// What pressing it would clear, for the kinds whose name does not say it.
    static func explanation(_ kind: ClaudeResetInventory.Kind) -> String? {
        switch kind {
        case .fable: return L("Gives back only the Fable spend of the weekly limit and refills the 5-hour limit")
        case .full: return L("Clears the 5-hour and weekly limits")
        case .session, .weekly, .other: return nil
        }
    }

    /// "Dec 11" / "11 Ara", in the app's language.
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(AppLocale.current))
    }

    /// The Codex expiry colours (`AccountFacts.resetExpiryColor`): warning inside 48 hours, critical
    /// inside 6.
    static func urgencyColor(_ endsAt: Date, now: Date = Date()) -> Color? {
        switch ResetExpiryUrgency.of(endsAt, now: now) {
        case .soon: return TallyColor.warning
        case .final: return TallyColor.critical
        case .unknown, .distant, .thisWeek: return nil
        }
    }
}
