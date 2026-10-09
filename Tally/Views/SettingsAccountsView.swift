import SwiftUI

/// The Accounts group of Settings: one sub-group per provider - its enable switch and one row
/// per discovered account (rename, reorder, menu-bar/enable switches). Launch policy and launch
/// defaults live in the Launch pane (SettingsLaunchView): "which accounts exist" and "what
/// happens when I launch" are different questions.
struct SettingsAccountsView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore

    // Not private: the two row layouts live in their own files (SettingsAccountRowLoose/Compact).
    @State var renamingAccountID: String? = Self.demoRenamingID()
    /// The row under the pointer: the compact row shows its drag handle and sharing detail on it.
    @State var hoveredAccountID: String?
    /// Drag-to-reorder (B-1033): each row's frame in window space, and the row in hand.
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var draggingAccountID: String?
    /// Each account's sharing against its provider's primary, worked out off the main thread.
    @State var sharing: [String: HarnessSharing.Report] = [:]
    @State private var addingAccount = false
    private let flow = AddAccountStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: density == .compact ? 16 : 24) {
            ForEach(ProviderCatalog.descriptors, id: \.id) { descriptor in
                providerGroup(id: descriptor.id, name: descriptor.name)
            }
            if density == .compact { compactLegend }
        }
        // One sheet for both provider groups: which one opened it is a preselection, not a
        // different flow, and the sheet lets the user change their mind about it anyway.
        .sheet(isPresented: $addingAccount) {
            SettingsAddAccountView(
                flow: flow,
                fallbackCommand: { Self.addAccountCommand($0, homes: launchHomes($0)) },
                dismiss: { addingAccount = false })
        }
        // This pane is the one surface that draws from discovery alone, and discovery only lands
        // when a whole refresh round has finished polling every provider CLI. Asking for the pass
        // here is what fills the list on a cold start (the relaunch an update performs) instead of
        // leaving it empty for those seconds. Idempotent in the store, which is what lets it hang
        // off a ForEach that runs it once per provider group.
        .onAppear { store.ensureDiscovered() }
        // Merged, not assigned: each provider's card reports only its own rows.
        .onPreferenceChange(CardFramePreferenceKey.self) { rowFrames.merge($0) { $1 } }
    }

    var density: SettingsDensity { SettingsDensity.current }

    /// Starts under the row's text column, so the number column reads as one unbroken strip.
    private var rowDivider: some View {
        SettingsCardDivider(leading: density == .compact ? 14 : 56)
    }

    /// The line standing in for a provider's account rows while there are none, saying which of the
    /// two reasons applies (AccountListState.swift). Before discovery has answered it borrows the
    /// account row's own waiting vocabulary - mini spinner, "Loading…" - rather than the sentence
    /// below it, which is a claim about this machine that nothing has checked yet.
    private func placeholderRow(_ state: AccountListState) -> some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 22, height: 22)
            if state == .discovering { ProgressView().controlSize(.mini) }
            Text(state == .discovering ? L("Loading…") : L("No signed-in accounts found"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .padding(.leading, 18)
    }

    /// `-TallyDemoData YES -TallyDemoRenaming <n>`: row n of the fixtures opens with its rename
    /// field up, for a capture (the field otherwise needs a click). Debug builds only.
    private static func demoRenamingID() -> String? {
        #if DEBUG
        let row = UserDefaults.standard.integer(forKey: "TallyDemoRenaming")
        let ids = SettingsStore.shared.orderedAccountIDs(DemoUsage.discoveredAccounts().map(\.id))
        if DemoUsage.isActive, ids.indices.contains(row - 1) { return ids[row - 1] }
        #endif
        return nil
    }

    /// This provider's accounts by EXISTENCE (discovery), not by fetched usage - a switched-off
    /// account must stay listed or it could never be switched back on.
    func discovered(for providerID: String) -> [ProviderAccount] {
        let mine = store.discoveredAccounts.filter { $0.providerID == providerID }
        let order = AddAccountStore.demoLanding(settings.orderedAccountIDs(mine.map(\.id)), providerID)
        return order.compactMap { id in mine.first { $0.id == id } }
    }

    @ViewBuilder
    private func providerGroup(id: String, name: String) -> some View {
        let items = discovered(for: id)
        VStack(alignment: .leading, spacing: density == .compact ? 8 : 10) {
            // Count only when there is something to count - a "1" badge said nothing.
            SettingsSectionHeader(title: name, count: items.count > 1 ? items.count : nil) {
                ProviderIconView(providerID: id, size: 14)
            } trailing: {
                if settings.isEnabled(id) { addAccountButton(id) }
                providerToggle(id)
            }
            // Re-asked whenever the list or its order changes: the first account is the primary.
            .task(id: items.map(\.id) + items.compactMap(\.launchHome)) {
                if let demo = AccountHomeTag.demoReports(items) {
                    sharing = demo
                } else {
                    sharing.merge(await AccountHomeTag.reports(items, providerID: id)) { $1 }
                }
            }

            if settings.isEnabled(id) {
                VStack(spacing: 0) { accountList(id, items) }
                    .modifier(SettingsCardSurface())
            }
        }
    }

    /// The provider's own switch, at the end of its section header.
    private func providerToggle(_ id: String) -> some View {
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
        .controlSize(.mini)
    }

    @ViewBuilder
    private func accountList(_ id: String, _ items: [ProviderAccount]) -> some View {
        let state = AccountListState.resolve(hasDiscovered: store.hasDiscovered,
                                             accountCount: items.count)
        if state != .populated {
            placeholderRow(state)
        } else if density == .compact {
            compactHeader()
        }
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 || state != .populated || density == .compact { rowDivider }
            // Same numbering the menu-bar strip uses for same-provider accounts, so the
            // settings row visibly maps to a strip segment.
            accountRow(
                item,
                usage: store.accounts.first { $0.id == item.id },
                badge: items.count > 1 ? index + 1 : nil,
                moveUp: index > 0 ? { swapAccounts(items, index, index - 1) } : nil,
                moveDown: index < items.count - 1 ? { swapAccounts(items, index, index + 1) } : nil)
            .background(Rectangle()
                .fill(draggingAccountID == item.id ? Color.primary.opacity(0.06)
                      : hoveredAccountID == item.id ? Color.primary.opacity(0.03) : .clear))
            .onHover { inside in
                if inside { hoveredAccountID = item.id }
                else if hoveredAccountID == item.id { hoveredAccountID = nil }
            }
            .background(GeometryReader { proxy in
                Color.clear.preference(key: CardFramePreferenceKey.self,
                                       value: [item.id: proxy.frame(in: .global)])
            })
            .gesture(reorderDrag(item.id, siblings: items.map(\.id)))
            // The reserve belongs to the marked account and appears NOWHERE ELSE - not greyed on
            // the other rows, not a line the pane always carries. A machine with one account, or
            // one where nobody has marked theirs, has nothing to reserve quota from, and a
            // control standing there anyway is a question the user cannot answer.
            if let home = PersonalAccount.home(accountID: item.id, launchHome: item.launchHome),
               PersonalAccount.isPersonal(accountID: item.id, home: home) {
                rowDivider
                reserveRow(home, nameInset: density == .compact ? 46 : 56,
                           owner: settings.displayLabel(accountID: item.id, fallback: item.label))
            }
        }
        // The add in flight, at the end of the list where its account will land, until that
        // account is listed as itself (the watcher can adopt it a beat before the flow lands).
        if flow.runProviderID == id, SettingsPendingAccountRow.content(flow.phase) != nil,
           !flow.phase.isListed(among: items.compactMap(\.launchHome)) {
            rowDivider
            SettingsPendingAccountRow(flow: flow)
        }
    }

    /// The entry to the add-account flow (SettingsAddAccountView): Tally creates the next free
    /// `~/.claudeN` / `~/.codexN`, optionally shares the main account's setup into it, and starts
    /// the provider's own sign-in in the browser. The copyable terminal command it replaced is
    /// still one click away - the sheet offers it whenever a run does not finish. A header button
    /// rather than a row of its own: with twenty accounts a full row per provider is room lost.
    private func addAccountButton(_ providerID: String) -> some View {
        Button {
            // Provider and reset in one call: a login still out there owns both, and this
            // button must not repoint the flow at another provider while it does (the sheet
            // would then offer that provider's command for this one's home).
            flow.beginEntry(providerID: providerID)
            addingAccount = true
        } label: {
            Label(L("Add account…"), systemImage: "plus").font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        // Demo fixtures have no config home behind them, so the flow could only ever leave a
        // stray directory: a button that cannot work must not look like one that can.
        .disabled(!flow.canAdd(providerID: providerID) || flow.isRunning)
        .tallyTooltip(L("Tally creates the next config home and opens the provider's sign-in in your browser."))
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

    /// Drag a row onto a sibling to reorder, the way the panel's cards reorder (CardReorder.swift):
    /// the order changes live under the pointer and is saved as it goes. Only within the provider
    /// (`moveAccountWithinProvider` refuses a foreign target, and only siblings are hit-tested); the
    /// switches, the menu and the name keep their own clicks, and a row being renamed does not move.
    private func reorderDrag(_ id: String, siblings: [String]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                guard renamingAccountID != id else { return }
                draggingAccountID = id
                guard let target = reorderTarget(at: value.location, frames: rowFrames,
                                                 excluding: id, orderedIDs: siblings) else { return }
                var moved = false
                withAnimation(CardMotion.spring) {
                    moved = settings.moveAccountWithinProvider(
                        id, onto: target, siblingIDs: siblings,
                        allIDs: store.discoveredAccounts.map(\.id))
                }
                if moved { Haptics.snap() }
            }
            .onEnded { _ in draggingAccountID = nil }
    }

    private func swapAccounts(_ items: [ProviderAccount], _ a: Int, _ b: Int) {
        var ids = items.map(\.id)
        ids.swapAt(a, b)
        settings.applyProviderOrder(orderedProviderIDs: ids,
                                    allIDs: store.discoveredAccounts.map(\.id))
    }

    /// One line per account, in the layout this build draws (SettingsDensity).
    @ViewBuilder
    private func accountRow(_ item: ProviderAccount, usage: AccountUsage?, badge: Int?,
                            moveUp: (() -> Void)?, moveDown: (() -> Void)?) -> some View {
        switch density {
        case .loose: looseRow(item, usage: usage, badge: badge, moveUp: moveUp, moveDown: moveDown)
        case .compact: compactRow(item, usage: usage, badge: badge, moveUp: moveUp, moveDown: moveDown)
        }
    }

    /// The row's name, and beside it the config home this account launches from.
    ///
    /// The name renames in place: a click on it opens the field (AccountNameField), and the row's
    /// menu opens the same one.
    ///
    /// The home shares the NAME's line rather than the address's below it, which is where it started.
    /// The address is what tells two logins apart when both are readable, and it is long enough that
    /// anything sharing its line truncates it - measured in the window on 2026-08-04, adding the home
    /// there cut "dreamerhyde@gmail.com" to "dreame…ail.com", and two addresses that differ in the
    /// middle would then read as the same string. That is a worse failure than the one this feature
    /// fixes. The name line has the room: a name is short, and the home is shorter.
    ///
    /// It appears only where the provider has more than one account, on the same rule the count badge
    /// one level up follows: with a single account it can only ever say `~/.codex`, which the
    /// provider's own name already said. With siblings it is the discriminator that never fails - two
    /// accounts cannot share a directory - and it is what a nickname takes away, since the default
    /// name is derived from that very directory ("Codex 2" ← `~/.codex2`, ClaudeAccounts.swift).
    func nameLine(_ item: ProviderAccount, showsHome: Bool, isPersonal: Bool) -> some View {
        HStack(spacing: 6) {
            nameField(item, font: .system(size: 15, weight: .medium), fieldWidth: 180)
            // The marking rides the NAME line rather than the status line below it, for the reason
            // the home does: the status line carries an address, a plan and two percentages and
            // truncates as soon as anything joins it. At most one row in the pane ever wears this.
            if isPersonal { personalBadge }
            if showsHome, let home = home(of: item) {
                // Never the part that gives way: it is short, it is fixed, and a half-written path
                // ("~/.clau…") could name either of the two accounts it is here to separate. A long
                // nickname truncates instead - the user chose that one and knows what it says.
                let primary = discovered(for: item.providerID).first
                AccountHomeTag(home: home, report: primary?.id == item.id ? nil : sharing[item.id],
                               primaryName: primaryName(item.providerID))
            }
        }
    }

    /// The name, renamed in place (AccountNameField): a click on it opens the field, and the row's
    /// menu opens the same one.
    func nameField(_ item: ProviderAccount, font: Font, fieldWidth: CGFloat) -> some View {
        AccountNameField(
            defaultLabel: item.label,
            displayed: settings.displayLabel(accountID: item.id, fallback: item.label),
            override: Binding(get: { settings.accountLabels[item.id] },
                              set: { settings.accountLabels[item.id] = $0 }),
            isEditing: Binding(get: { renamingAccountID == item.id },
                               set: { on in
                                   // Closing never closes another row's field.
                                   if on { renamingAccountID = item.id }
                                   else if renamingAccountID == item.id { renamingAccountID = nil }
                               }),
            font: font, fieldWidth: fieldWidth)
    }

    /// Every occasional action a row has, behind one "⋯" on its outer edge: rename, reorder, and
    /// the three the card's right-click offers (AccountActionsMenu). Never disabled on a
    /// switched-off account: renaming, reordering and marking one personal all outlive that.
    func actionsMenu(_ item: ProviderAccount, moveUp: (() -> Void)?,
                     moveDown: (() -> Void)?) -> some View {
        Menu {
            let personalHome = PersonalAccount.home(accountID: item.id, launchHome: item.launchHome)
            AccountActionsMenu(accountID: item.id, providerID: item.providerID,
                               label: settings.displayLabel(accountID: item.id, fallback: item.label),
                               home: item.launchHome,
                               rename: { renamingAccountID = item.id },
                               moveUp: moveUp, moveDown: moveDown,
                               // Offered on Claude rows alone, and only where there is a home to
                               // store the marking under (PersonalAccount.canMark).
                               togglePersonal: PersonalAccount.canMark(
                                   providerID: item.providerID, home: personalHome)
                                   ? { PersonalAccount.toggle(accountID: item.id, home: personalHome) }
                                   : nil,
                               isPersonal: PersonalAccount.isPersonal(accountID: item.id,
                                                                      home: personalHome))
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
        .tallyTooltip(L("Account actions"))
    }

    /// The config home a row names: discovery's, or on a many-accounts demo capture the fixture's.
    func home(of item: ProviderAccount) -> String? {
        item.launchHome ?? DemoUsage.manyAccountsHome(accountID: item.id)
    }

    /// The provider's primary account's display name (nickname applied), for the sharing mark.
    func primaryName(_ providerID: String) -> String {
        discovered(for: providerID).first.map {
            settings.displayLabel(accountID: $0.id, fallback: $0.label)
        } ?? ""
    }

    /// Which account this row actually IS. The panel keeps it in a hover callout (a card has no room
    /// for an address), but this list is where somebody comes to ask "which of my logins is Codex
    /// 2?", so here it is on the face of the row.
    ///
    /// Data, not a label: never localized, and absent rather than blank when neither the probe nor
    /// the config home can name the account (an empty caption where a name should be reads as a
    /// rendering bug).
    ///
    /// Asked by ACCOUNT ID, not off the usage row: a disabled account has no usage row at all (it is
    /// never polled), and this list is exactly where its address is worth reading. The store answers
    /// from what it last knew (AccountIdentity.swift).
    func identityEmail(_ item: ProviderAccount, usage: AccountUsage?) -> String? {
        LoginStatusStore.shared.identityEmail(accountID: item.id,
                                              polled: usage?.accountEmail)
    }
}
