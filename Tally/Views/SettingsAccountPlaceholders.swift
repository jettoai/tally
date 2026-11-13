import SwiftUI

/// What a provider's account card holds in place of account rows (B-4474), written to the same
/// grid as the rows so nothing jumps when they arrive: still waiting for discovery (the header, a
/// waiting line, then grey skeleton rows: Claude three, Codex two), or discovery finished and found
/// none (one 52 high row, top-aligned). Static on purpose: no spinner, nothing that pulses.
///
/// Which of the two applies is `AccountListState`'s answer (AccountListState.swift), never this
/// file's: the sentence below is a claim about this machine that nothing has checked until the
/// discovery pass has answered.
extension SettingsAccountsView {
    @ViewBuilder
    func accountPlaceholder(_ state: AccountListState, providerID: String) -> some View {
        let t = AccountTableStyle.current
        if state == .discovering {
            compactHeader()
            Text(L("Loading…"))
                .font(.system(size: t.secondary)).foregroundStyle(.secondary)
                .padding(.leading, t.nameLeading)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)  // the reserve line's height
            ForEach(0 ..< (providerID == "claude" ? 3 : 2), id: \.self) { index in
                AccountSkeletonRow(index: index).overlay(alignment: .top) { rowDivider }
            }
        } else {
            HStack(spacing: PageSkeleton.rowIconGap) {
                Image(systemName: "person.2").font(.system(size: SettingsType.rowIcon)).foregroundStyle(.tertiary)
                Text(L("No signed-in accounts found"))
                    .font(.system(size: SettingsType.body)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, PageSkeleton.rowInsetH)
            .frame(maxWidth: .infinity, minHeight: PageSkeleton.rowMinHeight, alignment: .leading)
        }
    }
}

/// One grey stand-in row: bars where the name, address, plan, two figures and two switches will be.
private struct AccountSkeletonRow: View {
    let index: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = AccountTableStyle.current
        let fill = Color.primary.opacity(scheme == .dark ? 0.07 : 0.06)
        func bar(_ width: CGFloat) -> some View {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(fill).frame(width: width, height: 11)
        }
        return TableRowFrame {
            HStack(spacing: t.gap) {
                Color.clear.frame(width: t.lead, height: 1)
                bar([70, 56, 64][index % 3]).frame(width: t.nameColumn, alignment: .leading)
                bar([120, 104, 132][index % 3]).frame(maxWidth: .infinity, alignment: .leading)
                bar(40).frame(width: t.plan, alignment: .leading)
                bar(44).frame(width: t.cell, alignment: .trailing)
                bar(44).frame(width: t.cell, alignment: .trailing)
                Color.clear.frame(width: t.share, height: 1)
                bar(30).frame(width: t.toggle)
                bar(30).frame(width: t.toggle)
                Color.clear.frame(width: t.actions, height: 1)
                Color.clear.frame(width: t.handle, height: 1)
            }
            .frame(height: t.rowHeight)
        }
        .accessibilityHidden(true)
    }
}
