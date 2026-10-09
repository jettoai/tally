import SwiftUI

/// The dense account row (B-1355 direction pack, the default layout): one 28pt line per account
/// in fixed columns, so a long list reads straight down like a table and twenty accounts fit one
/// screen. Left to right: drag handle (on hover) and number, name (renamed in place), address,
/// plan, 5-hour and weekly figures with thin bars, sharing mark, menu-bar switch, enabled switch,
/// actions.
extension SettingsAccountsView {
    /// Fixed column widths; only the name flexes, so every other column lines up row to row.
    private enum Column {
        static let email: CGFloat = 128
        static let plan: CGFloat = 54
        static let usage: CGFloat = 86
        static let status: CGFloat = plan + 6 + usage
    }

    func compactRow(_ item: ProviderAccount, usage: AccountUsage?, badge: Int?,
                    moveUp: (() -> Void)?, moveDown: (() -> Void)?) -> some View {
        let enabled = settings.isAccountEnabled(item.id)
        let signIn = signInState(of: item)
        let email = identityEmail(item, usage: usage)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                        .opacity(hoveredAccountID == item.id ? 1 : 0)
                    Text(badge.map { "\($0)" } ?? "")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, alignment: .trailing)
                }

                HStack(spacing: 5) {
                    nameField(item, font: .system(size: 13, weight: .medium), fieldWidth: 130)
                    if isPersonal(item) { personalBadge }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(email ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: Column.email, alignment: .leading)
                    .tallyTooltip([email, home(of: item).map { AccountIdentity.homeName($0) }]
                        .compactMap { $0 }.joined(separator: "\n"))

                compactStatus(item, usage: usage, enabled: enabled, signIn: signIn)
                    .frame(width: Column.status, alignment: .leading)

                // A fixed slot even when empty: a bare frame on an empty branch collapses, and
                // took the HStack spacing with it, shifting every column to its left.
                Color.clear.frame(width: 14, height: 14).overlay { shareMark(item) }
                compactMenuBarToggle(item.id)
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.35)
                enabledSwitch(item)
                actionsMenu(item, moveUp: moveUp, moveDown: moveDown)
            }
            .frame(height: 28)
            .opacity(enabled ? 1 : 0.6)

            AccountLoginHealthView(accountID: item.id, owner: rowOwner(item, usage: usage),
                canRenew: RenewLoginStore.shared.canRenew(accountID: item.id,
                    providerID: item.providerID, home: item.launchHome),
                showsExpiry: signIn == .signedIn)
                .padding(.leading, 34)
        }
        .padding(.horizontal, 12)
    }

    /// The plan and the two figures, or in their place the one thing that matters more: a login
    /// to renew, a switched-off account, or a first read still on its way.
    @ViewBuilder
    private func compactStatus(_ item: ProviderAccount, usage: AccountUsage?, enabled: Bool,
                               signIn: AccountSignIn.State) -> some View {
        if signIn != .signedIn {
            signInState(signIn, item, usage: usage)
        } else if !enabled {
            Text(L("Disabled")).font(.caption2).foregroundStyle(.tertiary)
        } else if let usage {
            HStack(spacing: 6) {
                Text(usage.planName ?? "")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary).opacity(usage.planName == nil ? 0 : 1))
                    .frame(width: Column.plan, alignment: .leading)
                if usage.metrics.isEmpty, let error = usage.error {
                    Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .tallyTooltip(error)
                } else {
                    HStack(spacing: 6) {
                        ForEach(usage.metrics.filter { !$0.isModelScoped }.prefix(2)) { metric in
                            usageCell(metric, usage)
                        }
                    }
                    .frame(width: Column.usage, alignment: .leading)
                }
            }
        } else {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(L("Loading…")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// One window's figure over a thin bar of the same value, coloured by severity.
    private func usageCell(_ metric: UsageMetric, _ account: AccountUsage) -> some View {
        let passed = account.resetPassed(metric)
        let mode = settings.displayMode
        return VStack(alignment: .trailing, spacing: 2) {
            Text(UsageFormat.percent(metric, mode: mode, resetPassed: passed))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Capsule().fill(Color.primary.opacity(0.1))
                .frame(height: 2.5)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(passed ? Color.secondary : metric.severity.color)
                            .frame(width: passed ? 0 : proxy.size.width
                                   * UsageFormat.fillFraction(metric, mode: mode))
                    }
                }
        }
        .frame(width: 40)
        .tallyTooltip(passed
            ? "\(L(metric.label)) ? · \(L("Reset passed, awaiting refresh"))"
            : "\(L(metric.label)) \(UsageFormat.percent(metric, mode: mode)) \(UsageFormat.modeWord(mode))")
    }

    /// The link mark alone (the panel's path and words move into its hover): filled accent when
    /// the account shares the primary's whole setup, plain when only some of it, nothing when it
    /// keeps its own.
    @ViewBuilder
    private func shareMark(_ item: ProviderAccount) -> some View {
        let primary = discovered(for: item.providerID).first
        if primary?.id != item.id, let report = sharing[item.id], let tag = report.tag,
           let home = home(of: item) {
            Image(systemName: "link")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tag == .shared ? Color.accentColor : Color.secondary)
                .tallyTooltip(AccountIdentity.homeName(home) + " · "
                    + String(format: L(tag == .shared ? "Shared with %@" : "Partly shared with %@"),
                             primaryName(item.providerID))
                    + "\n" + AccountHomeTag.detail(report))
        }
    }

    /// The menu-bar switch as a glyph, since a labelled one does not fit the line: lit when the
    /// account has a segment in the menu bar. Dead in the pooled layout, as the labelled one is.
    private func compactMenuBarToggle(_ accountID: String) -> some View {
        let pooled = settings.menuBarLayout == .pooled
        let shown = settings.isShownInMenuBar(accountID)
        return Button {
            settings.setShownInMenuBar(accountID, !shown)
            UsageStore.shared.onChange?()
        } label: {
            Image(systemName: "menubar.rectangle")
                .font(.system(size: 12))
                .foregroundStyle(shown && !pooled ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pooled)
        .tallyTooltipAroundControl(pooled
              ? L("The menu bar is pooling each provider into one segment, so it shows every account. Set Menu bar shows to Accounts in Display to pick which ones appear.")
              : L("Show in menu bar"))
    }
}
