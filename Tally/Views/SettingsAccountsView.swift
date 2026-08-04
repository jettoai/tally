import SwiftUI

/// The Accounts group of Settings: one sub-group per provider - its enable switch and one row
/// per discovered account (rename, reorder, menu-bar/enable switches). Launch policy and launch
/// defaults live in the Launch pane (SettingsLaunchView): "which accounts exist" and "what
/// happens when I launch" are different questions.
struct SettingsAccountsView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore

    @State private var renamingAccountID: String?
    @State private var addingAccount = false
    private let flow = AddAccountStore.shared

    var body: some View {
        let descriptors = ProviderCatalog.descriptors
        ForEach(Array(descriptors.enumerated()), id: \.element.id) { index, descriptor in
            if index > 0 { rowDivider }
            providerGroup(id: descriptor.id, name: descriptor.name)
        }
        // One sheet for both provider groups: which one opened it is a preselection, not a
        // different flow, and the sheet lets the user change their mind about it anyway.
        .sheet(isPresented: $addingAccount) {
            SettingsAddAccountView(
                flow: flow,
                fallbackCommand: { Self.addAccountCommand($0, homes: launchHomes($0)) },
                dismiss: { addingAccount = false })
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 14)
    }

    /// This provider's accounts by EXISTENCE (discovery), not by fetched usage - a switched-off
    /// account must stay listed or it could never be switched back on.
    private func discovered(for providerID: String) -> [ProviderAccount] {
        let mine = store.discoveredAccounts.filter { $0.providerID == providerID }
        let order = settings.orderedAccountIDs(mine.map(\.id))
        return order.compactMap { id in mine.first { $0.id == id } }
    }

    @ViewBuilder
    private func providerGroup(id: String, name: String) -> some View {
        let items = discovered(for: id)
        Toggle(isOn: Binding(
            // userInitiated:false so toggling one provider can't force-reread another provider's
            // declined Keychain item and re-raise its access prompt.
            get: { settings.isEnabled(id) },
            set: { on in
                settings.setEnabled(id, on)
                // Optimistic: every surface reacts the moment the switch flips - cached rows come
                // straight back on enable, rows drop instantly on disable; the refresh behind
                // converges live data and the CLI snapshot.
                if on { store.showCachedAccounts(providerID: id) }
                else { store.hideAccounts { $0.providerID == id } }
                Task { await store.refresh(userInitiated: false) }
            }
        )) { EmptyView() }
        .labelsHidden()
        .toggleStyle(.switch)
        // Custom layout (no Form): spread the identity and the switch ourselves - a bare Toggle
        // renders its control right beside the label, which parked the switch mid-row.
        .frame(maxWidth: .infinity, alignment: .trailing)
        .overlay(alignment: .leading) {
            HStack(spacing: 10) {
                ProviderIconView(providerID: id, size: 16)
                    .frame(width: 20)
                Text(name).font(.subheadline.weight(.semibold))
                // Count only when there is something to count - a "1" badge said nothing.
                if items.count > 1 {
                    Text("\(items.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        if settings.isEnabled(id) {
            if items.isEmpty {
                rowDivider
                HStack(spacing: 10) {
                    Color.clear.frame(width: 22, height: 22)
                    Text(L("No signed-in accounts found")).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .padding(.leading, 18)
            }
            rowDivider
            addAccountRow(id)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                rowDivider
                // Same numbering the menu-bar strip uses for same-provider accounts, so the
                // settings row visibly maps to a strip segment. Repeating the provider's brand
                // mark per account (it's already on the group row) said nothing.
                accountRow(
                    item,
                    usage: store.accounts.first { $0.id == item.id },
                    badge: items.count > 1 ? index + 1 : nil,
                    moveUp: index > 0 ? { swapAccounts(items, index, index - 1) } : nil,
                    moveDown: index < items.count - 1 ? { swapAccounts(items, index, index + 1) } : nil)
            }
        }
    }

    /// Which account new `tally` sessions launch on: Off (observe only), Manual (pin a card in
    /// the panel), Smart (burn-rate pick - time and remaining both count - re-run every launch).
    /// The entry to the add-account flow (SettingsAddAccountView): Tally creates the next free
    /// `~/.claudeN` / `~/.codexN`, optionally shares the main account's setup into it, and starts
    /// the provider's own sign-in in the browser. The copyable terminal command it replaced is
    /// still one click away - the sheet offers it whenever a run does not finish.
    private func addAccountRow(_ providerID: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Add another account")).font(.subheadline)
                Text(L("Tally creates the next config home and opens the provider's sign-in in your browser."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(L("Add account…")) {
                // Provider and reset in one call: a login still out there owns both, and this
                // button must not repoint the flow at another provider while it does (the sheet
                // would then offer that provider's command for this one's home).
                flow.beginEntry(providerID: providerID)
                addingAccount = true
            }
            // Demo fixtures have no config home behind them, so the flow could only ever leave a
            // stray directory: a button that cannot work must not look like one that can.
            .disabled(!flow.canAdd(providerID: providerID) || flow.isRunning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsRowPadding()
    }

    private func launchHomes(_ providerID: String) -> [String] {
        discovered(for: providerID).compactMap(\.launchHome)
    }

    /// With the tally CLI on PATH the whole dance (pick the next free number, create the
    /// directory, launch the right login) is one short command. The raw fallback stays for
    /// installs without the CLI tool: no account yet means the plain CLI is the whole story,
    /// otherwise point the provider's config-home variable at the first unused numbered sibling.
    static func addAccountCommand(_ providerID: String, homes: [String]) -> String {
        if IntegrationsStore.shared.cliToolStatus == .installed {
            return "tally add \(providerID)"
        }
        let claude = providerID == "claude"
        guard !homes.isEmpty else { return claude ? "claude" : "codex login" }
        let base = claude ? ".claude" : ".codex"
        let taken = Set(homes.map { URL(fileURLWithPath: $0).lastPathComponent })
        let suffix = (2 ... 99).first { !taken.contains("\(base)\($0)") } ?? 2
        return claude
            ? "CLAUDE_CONFIG_DIR=~/\(base)\(suffix) claude"
            // codex refuses a CODEX_HOME that doesn't exist yet (claude creates its own), so the
            // copyable command must create it or it fails on paste.
            : "mkdir -p ~/\(base)\(suffix) && CODEX_HOME=~/\(base)\(suffix) codex login"
    }

    private func swapAccounts(_ items: [ProviderAccount], _ a: Int, _ b: Int) {
        var ids = items.map(\.id)
        ids.swapAt(a, b)
        settings.applyProviderOrder(orderedProviderIDs: ids,
                                    allIDs: store.discoveredAccounts.map(\.id))
    }

    /// One line per account: number badge, name + rename popover over a live status line, then a
    /// fixed column set (reorder arrows, menu-bar switch, enable switch) that never shifts.
    private func accountRow(_ item: ProviderAccount, usage: AccountUsage?, badge: Int?,
                            moveUp: (() -> Void)?, moveDown: (() -> Void)?) -> some View {
        let enabled = settings.isAccountEnabled(item.id)
        // Read once for the row: the status line renders it, and both sources of "signed out" plus
        // a renewal already in flight are folded into one answer there (AccountSignIn.swift).
        let signIn = AccountSignIn.state(
            isRenewing: RenewLoginStore.shared.isRenewing(item.id),
            isExpired: LoginStatusStore.shared.isExpired(item.id),
            isDormant: item.isDormant,
            renewalSucceededAt: RenewLoginStore.shared.renewalSucceededAt(item.id))
        return HStack(spacing: 10) {
            // No reserved column for single-account providers: their name starts where the
            // number badges start, so every row's HEAD lines up on one vertical line.
            if let badge {
                ZStack {
                    Circle().fill(.quaternary)
                    Text("\(badge)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 3) {
                // Plain Text + a pencil-popover for renaming: an inline TextField can't live in
                // this layout sanely (see RenamePopover) and the popover field behaves normally.
                Text(settings.displayLabel(accountID: item.id, fallback: item.label))
                    .font(.subheadline.weight(.semibold))

                // Which account this actually IS. The panel keeps it in a hover tooltip (a card has
                // no room for an address), but this list is where somebody comes to ask "which of
                // my logins is Codex 2?", so here it is on the face of the row.
                //
                // Data, not a label: never localized, and absent rather than blank when neither the
                // probe nor the config home can name the account (an empty caption where a name
                // should be reads as a rendering bug).
                //
                // Its OWN line rather than trailing the account name, which is where it started:
                // sharing the line left roughly 200pt for both, and in English - where the two
                // switch labels are widest - every address on this machine truncated to something
                // unreadable ("albert.…er.com", measured in the window, 2026-08-04). A line of its
                // own fits the addresses people actually have; middle truncation keeps the domain
                // for the ones it does not.
                //
                // Asked by ACCOUNT ID, not off the usage row: a disabled account has no usage row
                // at all (it is never polled), and this list is exactly where its address is worth
                // reading. The store answers from what it last knew (AccountIdentity.swift).
                if let email = LoginStatusStore.shared.identityEmail(accountID: item.id,
                                                                     polled: usage?.accountEmail) {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(email)
                }

                HStack(spacing: 8) {
                    // A login problem REPLACES the plan and the numbers rather than crowding in
                    // beside them: those numbers are whatever was true before the credential went,
                    // the chip is the one actionable thing on the row, and all three together
                    // truncated each other in a 500pt window (measured 2026-08-04).
                    if signIn != .signedIn {
                        signInState(signIn, item)
                    } else if !enabled {
                        Text(L("Disabled")).font(.caption2).foregroundStyle(.tertiary)
                    } else if let usage {
                        if let plan = usage.planName {
                            Text(plan)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                        }
                        if usage.metrics.isEmpty, let error = usage.error {
                            Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            liveStatus(usage)
                        }
                    } else {
                        ProgressView().controlSize(.mini)
                        Text(L("Loading…")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                // Constant height across all variants (plan capsule, plain caption, spinner) so
                // toggling an account never changes the row height and shifts its neighbours.
                .frame(height: 17, alignment: .leading)
            }
            Spacer()

            // Every occasional action this row has, behind one button: rename (which the pencil
            // used to own), reorder (the arrows), and the three the card's right-click offers
            // (AccountActionsMenu). One control replacing two is not a tidiness preference - the row
            // carries a number, a name, an address, a plan, two percentages and two labelled
            // switches inside a 500pt window, and measured here on 2026-08-04 the pencil, the arrows
            // and this button together truncated both the address AND the percentages.
            Menu {
                AccountActionsMenu(accountID: item.id, providerID: item.providerID,
                                   label: settings.displayLabel(accountID: item.id,
                                                                fallback: item.label),
                                   home: item.launchHome,
                                   rename: { renamingAccountID = item.id },
                                   moveUp: moveUp, moveDown: moveDown)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 16)
            .help(L("Account actions"))
            // The rename field lives outside the row layout entirely (see RenamePopover), anchored
            // on the button that opens it.
            .popover(isPresented: Binding(
                get: { renamingAccountID == item.id },
                set: { if !$0 { renamingAccountID = nil } }
            )) {
                RenamePopover(
                    defaultLabel: item.label,
                    override: Binding(
                        get: { settings.accountLabels[item.id] },
                        set: { settings.accountLabels[item.id] = $0 }
                    ),
                    dismiss: { renamingAccountID = nil })
            }

            // Always laid out (dimmed + inert when the account is off) so toggling never shifts
            // the controls around - disappearing chrome made the row jump.
            menuBarToggle(item.id)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.35)
                .padding(.trailing, 10)

            // The account's own switch, mirroring the provider switch one level down: off means
            // not polled, no card, no menu-bar segment, and the CLI skips it. Labeled like the
            // menu-bar switch next to it - two adjacent switches with one label were a coin flip.
            HStack(spacing: 6) {
                Text(L("Enabled")).font(.caption).foregroundStyle(.secondary).fixedSize()
                Toggle(isOn: Binding(
                    get: { settings.isAccountEnabled(item.id) },
                    set: { on in
                        settings.setAccountEnabled(item.id, on)
                        // Optimistic, same as the provider switch above.
                        if on { store.showCachedAccounts(providerID: item.providerID) }
                        else { store.hideAccounts { $0.id == item.id } }
                        Task { await store.refresh(userInitiated: false) }
                    }
                )) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
        .opacity(enabled ? 1 : 0.6)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .padding(.leading, 18)   // nested under the provider row
    }

    /// The row's login state: an inline "Sign in again" in the severity colour when the account is
    /// signed out, the running renewal while one is in flight, nothing at all otherwise.
    ///
    /// The same button the card's expiry chip is, in the same colour, starting the same renewal
    /// through the same store - this list is simply the other place people look for it. Which state
    /// wins is decided in AccountSignIn.swift, so the two surfaces cannot disagree about whether an
    /// account needs signing in.
    @ViewBuilder
    private func signInState(_ state: AccountSignIn.State, _ item: ProviderAccount) -> some View {
        let renew = RenewLoginStore.shared
        switch state {
        case .signedIn:
            EmptyView()
        case .renewing:
            HStack(spacing: 3) {
                ProgressView().controlSize(.mini)
                Text(L("renewing login…"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        case .needsSignIn:
            Button { renew.renew(accountID: item.id) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
                    Text(L("Sign in again")).lineLimit(1)
                }
                .fixedSize()
                .font(.caption2.weight(.semibold))
                .foregroundStyle(TallyColor.critical)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(TallyColor.critical.opacity(0.15)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            // Greyed where the menu entry is: a demo fixture has no config home behind it, so a
            // chip must never look more able than the action it starts.
            .disabled(!renew.canRenew(providerID: item.providerID, home: item.launchHome))
            .help(L("Sign in again to bring this account's usage back."))
        }
    }

    /// "● 98% · ● 71%" - session then weekly, dot coloured by the window's severity. Compact
    /// (no window names): the row also carries reorder arrows and two switches, and the full
    /// labels truncated; hover explains each value.
    private func liveStatus(_ account: AccountUsage) -> some View {
        HStack(spacing: 8) {
            ForEach(account.metrics.filter { !$0.isModelScoped }.prefix(2)) { metric in
                HStack(spacing: 3) {
                    Circle().fill(metric.severity.color).frame(width: 5, height: 5)
                    Text(UsageFormat.percent(metric, mode: settings.displayMode))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .help("\(L(metric.label)) \(UsageFormat.percent(metric, mode: settings.displayMode)) \(UsageFormat.modeWord(settings.displayMode))")
            }
        }
    }

    // A labeled mini switch: an icon-only toggle here read as "no idea what this does".
    private func menuBarToggle(_ accountID: String) -> some View {
        HStack(spacing: 6) {
            Text(L("Menu bar")).font(.caption).foregroundStyle(.secondary).fixedSize()
            Toggle(isOn: Binding(
                get: { settings.isShownInMenuBar(accountID) },
                set: { settings.setShownInMenuBar(accountID, $0); UsageStore.shared.onChange?() }
            )) { EmptyView() }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .help(L("Show in menu bar"))
    }

    /// Rename UI in a popover so the field lives outside the row layout entirely. Clearing (or
    /// typing the default name back) removes the override.
    private struct RenamePopover: View {
        let defaultLabel: String
        @Binding var override: String?
        let dismiss: () -> Void
        @State private var text = ""

        var body: some View {
            TextField("", text: $text, prompt: Text(defaultLabel))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .padding(12)
                .onAppear { text = override ?? "" }
                .onSubmit { commit() }
                .onDisappear { commit() }
        }

        private func commit() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            override = (trimmed.isEmpty || trimmed == defaultLabel) ? nil : trimmed
            dismiss()
        }
    }
}
