import SwiftUI

/// The account row (B-1355, the pane's one layout): one line per account in fixed columns, so a
/// long list reads straight down like a table and twenty accounts fit one screen. Left to right:
/// number, name (renamed in place), address, plan, 5-hour and weekly figures with thin bars,
/// sharing mark, menu-bar switch, enabled switch, actions, and the reorder grip the panel's rows
/// carry. Each card opens with a header naming those columns; what the marks and colours mean is
/// in the hover on the header names (B-2526 G16), not in a legend under the cards. Type scale, row
/// height and column widths are one value, `AccountTableStyle`.
extension SettingsAccountsView {
    /// Only the address flexes (it is the longest value and the one that must not truncate), so
    /// every other column lines up row to row and with the header.
    private var t: AccountTableStyle { .current }
    private var markWidth: CGFloat { 22 }

    /// The column names over a card's rows, in the row's own grid. The sharing and figure names
    /// carry the legend the pane used to end on.
    func compactHeader() -> some View {
        HStack(spacing: t.gap) {
            Color.clear.frame(width: t.lead, height: 1)
            headerLabel("Name").frame(width: t.nameColumn, alignment: .leading)
            headerLabel("Account").frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: t.gap) {
                headerLabel("Plan").frame(width: t.plan, alignment: .leading)
                headerLabel("5 hours", hover: figuresLegend).frame(width: t.cell, alignment: .trailing)
                headerLabel("Week", hover: figuresLegend).frame(width: t.cell, alignment: .trailing)
            }
            .frame(width: t.status, alignment: .leading)
            headerLabel("Sharing", hover: sharingLegend).frame(width: t.share)
            headerLabel("Menu bar").frame(width: t.toggle)
            headerLabel("Enabled").frame(width: t.toggle)
            Color.clear.frame(width: t.actions, height: 1)
            Color.clear.frame(width: t.handle, height: 1)
        }
        .frame(height: 26)
        .padding(.horizontal, t.inset)
    }

    private func headerLabel(_ key: String, hover: String? = nil) -> some View {
        Text(L(key))
            .font(.system(size: t.secondary, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .tallyTooltip(hover ?? "")
    }

    /// The sharing link in its two states and its absence.
    private var sharingLegend: String {
        [L("Shares the first account's whole setup"), L("Shares part of it"),
         L("No mark: its own setup")].joined(separator: "\n")
    }

    /// Whether a figure is what is left or what is used, and where the bar turns colour (the
    /// thresholds MetricSeverity.fromUsedPercent applies).
    private var figuresLegend: String {
        [L(settings.displayMode == .remaining ? "Percentages show what is left"
                                              : "Percentages show what is used"),
         L("Bar: green 50% or more left, orange 20 to 49%, red under 20%")].joined(separator: "\n")
    }

    /// Two shapes as well as two colours, so the states hold apart on any screen: a filled accent
    /// disc for the whole setup, a plain grey link for part of it.
    private func sharedMark(full: Bool) -> some View {
        Image(systemName: full ? "link.circle.fill" : "link")
            .font(.system(size: full ? 12 : 10, weight: .semibold))
            .foregroundStyle(full ? Color.accentColor : Color.secondary)
            .frame(width: markWidth, height: 14)
    }

    func compactRow(_ item: ProviderAccount, usage: AccountUsage?, badge: Int?,
                    moveUp: (() -> Void)?, moveDown: (() -> Void)?) -> some View {
        let enabled = settings.isAccountEnabled(item.id)
        let signIn = signInState(of: item)
        let email = identityEmail(item, usage: usage)
        let homeName = home(of: item).map { AccountIdentity.homeName($0) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: t.gap) {
                Text(badge.map { "\($0)" } ?? "")
                    .font(.system(size: t.secondary).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: t.lead, alignment: .trailing)

                // The name alone: the personal mark moved to the reserve line under the row, so a
                // long name is never shortened to make room for it.
                nameField(item, font: .system(size: t.name, weight: .medium), fieldWidth: t.nameColumn)
                    .frame(width: t.nameColumn, alignment: .leading)

                // No address: the config home in its place, faint and small, so two rows given the
                // same nickname can still be told apart without hovering. A login that just landed
                // says so instead, in the same faint style, until its address arrives (B-1702).
                Group {
                    switch AccountIdentity.column(email: email, signingIn: isSigningIn(item), home: homeName) {
                    case .address(let address):
                        Text(address).font(.system(size: t.secondary)).foregroundStyle(.secondary)
                    case .signingIn:
                        Text(L("Signing in") + "…")
                            .font(.system(size: t.secondary)).foregroundStyle(.tertiary)
                    case .home(let name):
                        Text(name ?? "")
                            .font(.system(size: t.secondary)).foregroundStyle(.tertiary)
                    }
                }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tallyTooltip([email, homeName].compactMap { $0 }.joined(separator: "\n"))

                compactStatus(item, usage: usage, enabled: enabled, signIn: signIn)
                    .frame(width: t.status, alignment: .leading)

                // A fixed slot even when empty: a bare frame on an empty branch collapses, and
                // took the HStack spacing with it, shifting every column to its left.
                Color.clear.frame(width: t.share, height: 14).overlay { shareMark(item) }
                menuBarToggle(item.id)
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.35)
                    .frame(width: t.toggle)
                enabledSwitch(item).frame(width: t.toggle)
                actionsMenu(item, moveUp: moveUp, moveDown: moveDown)
                // The panel row's grip, on the same outer edge (ReorderHandle).
                ReorderHandle(bright: hoveredAccountID == item.id || rowLift?.id == item.id)
                    .font(.caption)
                    .frame(width: t.handle)
            }
            .frame(height: t.rowHeight)
            .opacity(enabled ? 1 : 0.6)

            AccountLoginHealthView(accountID: item.id, owner: rowOwner(item, usage: usage),
                canRenew: RenewLoginStore.shared.canRenew(accountID: item.id,
                    providerID: item.providerID, home: item.launchHome),
                showsExpiry: signIn == .signedIn)
                .padding(.leading, t.lead + t.gap)
        }
        .padding(.horizontal, t.inset)
    }

    /// The plan and the two figures, or in their place the one thing that matters more: a login
    /// to renew, a switched-off account, or a first read still on its way.
    @ViewBuilder
    private func compactStatus(_ item: ProviderAccount, usage: AccountUsage?, enabled: Bool,
                               signIn: AccountSignIn.State) -> some View {
        if signIn != .signedIn {
            signInState(signIn, item, usage: usage)
        } else if !enabled {
            Text(L("Disabled")).font(.system(size: t.secondary)).foregroundStyle(.tertiary)
        } else if let usage {
            HStack(spacing: t.gap) {
                Text(usage.planName ?? "")
                    .font(.system(size: t.secondary, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08))
                        .opacity(usage.planName == nil ? 0 : 1))
                    .frame(width: t.plan, alignment: .leading)
                if usage.metrics.isEmpty, let error = usage.error {
                    Text(error).font(.system(size: t.secondary)).foregroundStyle(.secondary).lineLimit(1)
                        .tallyTooltip(error)
                } else {
                    let columns = UsageMetric.columns(usage.metrics)
                    let cells = [columns.session, columns.weekly]
                    HStack(spacing: t.gap) {
                        // Each window under its own header; a missing one keeps its width empty.
                        ForEach(cells.indices, id: \.self) { index in
                            if let metric = cells[index] {
                                usageCell(metric, usage)
                            } else {
                                Color.clear.frame(width: t.cell, height: 1)
                            }
                        }
                    }
                    .frame(width: t.usage, alignment: .leading)
                    // Figure plus bar, centred as one block, sat 1.5pt below the name's midline
                    // (measured on the 2x capture, 2026-10-10): lifted to meet it.
                    .offset(y: -1.5)
                }
            }
        } else {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(L("Loading…")).font(.system(size: t.secondary)).foregroundStyle(.secondary)
            }
        }
    }

    /// One window's figure over a thin bar of the same value, coloured by severity.
    private func usageCell(_ metric: UsageMetric, _ account: AccountUsage) -> some View {
        let passed = account.resetPassed(metric)
        let mode = settings.displayMode
        return VStack(alignment: .trailing, spacing: 2) {
            Text(UsageFormat.percent(metric, mode: mode, resetPassed: passed))
                .font(.system(size: t.figure, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
            Capsule().fill(Color.primary.opacity(0.1))
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(passed ? Color.secondary : metric.severity.color)
                            .frame(width: passed ? 0 : proxy.size.width
                                   * UsageFormat.fillFraction(metric, mode: mode))
                    }
                }
        }
        .frame(width: t.cell)
        .tallyTooltip(passed
            ? "\(L(metric.label)) ? · \(L("Reset passed, awaiting refresh"))"
            : "\(L(metric.label)) \(UsageFormat.percent(metric, mode: mode)) \(UsageFormat.modeWord(mode))")
    }

    /// The link mark alone (the panel's path and words move into its hover): a filled accent disc
    /// when the account shares the primary's whole setup, a plain grey link when only some of it,
    /// nothing when it keeps its own (the hover on the "Sharing" header says which is which).
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
