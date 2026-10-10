import SwiftUI

/// The account row (B-1355, the pane's one layout): one 28pt line per account
/// in fixed columns, so a long list reads straight down like a table and twenty accounts fit one
/// screen. Left to right: number, name (renamed in place), address,
/// plan, 5-hour and weekly figures with thin bars, sharing mark, menu-bar switch, enabled switch,
/// actions, and the reorder grip the panel's rows carry. Each card opens with a header naming
/// those columns, and the pane ends on a legend.
extension SettingsAccountsView {
    /// Fixed column widths; only the address flexes (it is the longest value and the one that must
    /// not truncate), so every other column lines up row to row and with the header.
    private enum Column {
        static let lead: CGFloat = 28
        static let name: CGFloat = 96
        static let plan: CGFloat = 54
        static let cell: CGFloat = 32
        static let usage: CGFloat = cell * 2 + 6
        static let status: CGFloat = plan + 6 + usage
        // Wide enough for the widest name over them in all five languages at the header's 10pt
        // (Sharing 37.9 en, Enabled 39.6 en, Menu bar 46.3 en; the ja Menu bar, 57.0, spills into
        // the short names either side), so no two header names touch and each centres on its column.
        static let share: CGFloat = 40
        static let mark: CGFloat = 22
        static let toggle: CGFloat = 48
        static let actions: CGFloat = 16
        static let handle: CGFloat = 12
    }

    /// The provider switch in its section header, placed in the rows' "Enabled" column: the same
    /// width, and the row's trailing inset, actions column and the spacing before it to its right.
    func headerToggleSlot(_ toggle: some View) -> some View {
        toggle.frame(width: Column.toggle)
            .padding(.trailing, 12 + 6 + Column.actions + 6 + Column.handle)
    }

    /// The column names over a card's rows, in the row's own grid.
    func compactHeader() -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: Column.lead, height: 1)
            headerLabel("Name").frame(width: Column.name, alignment: .leading)
            headerLabel("Account").frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                headerLabel("Plan").frame(width: Column.plan, alignment: .leading)
                headerLabel("5 hours").frame(width: Column.cell, alignment: .trailing)
                headerLabel("Week").frame(width: Column.cell, alignment: .trailing)
            }
            .frame(width: Column.status, alignment: .leading)
            headerLabel("Sharing").frame(width: Column.share)
            headerLabel("Menu bar").frame(width: Column.toggle)
            headerLabel("Enabled").frame(width: Column.toggle)
            Color.clear.frame(width: Column.actions, height: 1)
            Color.clear.frame(width: Column.handle, height: 1)
        }
        .frame(height: 22)
        .padding(.horizontal, 12)
    }

    private func headerLabel(_ key: String) -> some View {
        Text(L(key))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// What the marks and colours in the rows mean: the sharing link in its two states and its
    /// absence, whether a figure is what is left or what is used, and where the bar turns colour
    /// (the thresholds MetricSeverity.fromUsedPercent applies).
    var compactLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 14) {
                legendItem(sharedMark(full: true), L("Shares the first account's whole setup"))
                legendItem(sharedMark(full: false), L("Shares part of it"))
                Text(L("No mark: its own setup"))
            }
            HStack(spacing: 14) {
                Text(L(settings.displayMode == .remaining ? "Percentages show what is left"
                                                          : "Percentages show what is used"))
                HStack(spacing: 3) {
                    ForEach([MetricSeverity.normal, .warning, .critical], id: \.self) { severity in
                        Capsule().fill(severity.color).frame(width: 10, height: 3)
                    }
                    Text(L("Bar: green 50% or more left, orange 20 to 49%, red under 20%"))
                        .padding(.leading, 2)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func legendItem(_ mark: some View, _ text: String) -> some View {
        HStack(spacing: 4) { mark; Text(text) }
    }

    /// Two shapes as well as two colours, so the states hold apart on any screen: a filled accent
    /// disc for the whole setup, a plain grey link for part of it.
    private func sharedMark(full: Bool) -> some View {
        Image(systemName: full ? "link.circle.fill" : "link")
            .font(.system(size: full ? 12 : 10, weight: .semibold))
            .foregroundStyle(full ? Color.accentColor : Color.secondary)
            .frame(width: Column.mark, height: 14)
    }

    func compactRow(_ item: ProviderAccount, usage: AccountUsage?, badge: Int?,
                    moveUp: (() -> Void)?, moveDown: (() -> Void)?) -> some View {
        let enabled = settings.isAccountEnabled(item.id)
        let signIn = signInState(of: item)
        let email = identityEmail(item, usage: usage)
        let homeName = home(of: item).map { AccountIdentity.homeName($0) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(badge.map { "\($0)" } ?? "")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: Column.lead, alignment: .trailing)

                HStack(spacing: 5) {
                    nameField(item, font: .system(size: 13, weight: .medium), fieldWidth: Column.name)
                    if isPersonal(item) { personalBadge }
                }
                .frame(width: Column.name, alignment: .leading)

                // No address: the config home in its place, faint and small, so two rows given the
                // same nickname can still be told apart without hovering.
                Group {
                    if let email {
                        Text(email).font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Text(homeName ?? "")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tallyTooltip([email, homeName].compactMap { $0 }.joined(separator: "\n"))

                compactStatus(item, usage: usage, enabled: enabled, signIn: signIn)
                    .frame(width: Column.status, alignment: .leading)

                // A fixed slot even when empty: a bare frame on an empty branch collapses, and
                // took the HStack spacing with it, shifting every column to its left.
                Color.clear.frame(width: Column.share, height: 14).overlay { shareMark(item) }
                menuBarToggle(item.id)
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.35)
                    .frame(width: Column.toggle)
                enabledSwitch(item).frame(width: Column.toggle)
                actionsMenu(item, moveUp: moveUp, moveDown: moveDown)
                // The panel row's grip, on the same outer edge (ReorderHandle).
                ReorderHandle(bright: hoveredAccountID == item.id || rowLift?.id == item.id)
                    .font(.caption)
                    .frame(width: Column.handle)
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
                    let columns = UsageMetric.columns(usage.metrics)
                    let cells = [columns.session, columns.weekly]
                    HStack(spacing: 6) {
                        // Each window under its own header; a missing one keeps its width empty.
                        ForEach(cells.indices, id: \.self) { index in
                            if let metric = cells[index] {
                                usageCell(metric, usage)
                            } else {
                                Color.clear.frame(width: Column.cell, height: 1)
                            }
                        }
                    }
                    .frame(width: Column.usage, alignment: .leading)
                    // Figure plus bar, centred as one block, sat 1.5pt below the name's midline
                    // (measured on the 2x capture, 2026-10-10): lifted to meet it.
                    .offset(y: -1.5)
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
        .frame(width: Column.cell)
        .tallyTooltip(passed
            ? "\(L(metric.label)) ? · \(L("Reset passed, awaiting refresh"))"
            : "\(L(metric.label)) \(UsageFormat.percent(metric, mode: mode)) \(UsageFormat.modeWord(mode))")
    }

    /// The link mark alone (the panel's path and words move into its hover): a filled accent disc
    /// when the account shares the primary's whole setup, a plain grey link when only some of it,
    /// nothing when it keeps its own (the legend under the cards says which is which).
    @ViewBuilder
    private func shareMark(_ item: ProviderAccount) -> some View {
        let primary = discovered(for: item.providerID).first
        if primary?.id != item.id, let report = sharing[item.id], let tag = report.tag,
           let home = home(of: item) {
            sharedMark(full: tag == .shared)
                .tallyTooltip(AccountIdentity.homeName(home) + " · "
                    + String(format: L(tag == .shared ? "Shared with %@" : "Partly shared with %@"),
                             primaryName(primary))
                    + "\n" + AccountHomeTag.detail(report))
        }
    }
}
