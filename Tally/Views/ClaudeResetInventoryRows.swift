import SwiftUI

/// The limit resets a Claude account holds, one line per kind ("Full reset ×1 · until Dec 11"), in
/// the look of the Codex banked-reset line. Read-only: no button, the `/limit-reset` press keeps its
/// own control.
///
/// Nothing is drawn for an account never read: the inventory is optional, and the account's reset
/// state (`ResetOffer`) already speaks for "unknown". A login outside the program draws nothing
/// either. A held-over reading stays, dimmed, with its read time in the hover.
struct ClaudeResetInventoryRows: View {
    let accountID: String
    var store = ClaudeResetInventoryStore.shared

    var body: some View {
        if let entry = store.entry(accountID), entry.inventory.eligible {
            let rows = entry.inventory.byKind
            if rows.isEmpty {
                line(Text(L("No limit resets")), detail: readNote(entry))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(rows, id: \.kind) { row in
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 9))
                        Text(verbatim: "\(Self.name(row.kind)) ×\(row.left) ·")
                        // A held-over end date is not coloured: its urgency was true when read.
                        if !entry.isStale, let urgent = Self.urgencyColor(row.endsAt) {
                            Text(verbatim: String(format: L("until %@"), Self.day(row.endsAt)))
                                .foregroundStyle(urgent)
                        } else {
                            Text(verbatim: String(format: L("until %@"), Self.day(row.endsAt)))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(entry.isStale ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .tallyTooltip([Self.explanation(row.kind),
                                   String(format: L("until %@"), UsageFormat.absoluteBody(row.endsAt))]
                                    .compactMap { $0 }.joined(separator: " · "),
                                  detail: readNote(entry))
                }
            }
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
