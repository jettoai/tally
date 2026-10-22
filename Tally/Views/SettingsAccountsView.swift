import SwiftUI

/// The Accounts group of Settings: one sub-group per provider - its enable switch and one row
/// per discovered account (rename, reorder, menu-bar/enable switches). Launch policy and launch
/// defaults live in the Launch pane (SettingsLaunchView): "which accounts exist" and "what
/// happens when I launch" are different questions.
struct SettingsAccountsView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore

    // Not private: the row itself lives in its own file (SettingsAccountRowCompact).
    @State var renamingAccountID: String? = Self.demoRowID(forKey: "TallyDemoRenaming")
    /// The row under the pointer: the compact row shows its drag handle and sharing detail on it.
    @State var hoveredAccountID: String?
    /// Drag-to-reorder, the panel's own mechanics (CardReorder.swift): each row's frame in the
    /// pane's reorder space, and the row in hand (not private: the row file reads it for its grip).
    static let reorderSpace = "tallySettingsAccountReorder"
    @State private var rowFrames: [String: CGRect] = [:]
    @State var rowLift: ReorderLift?
    /// Resets on cancel as well as on end, the only hook a cancelled gesture guarantees.
    @GestureState private var isRowDragActive = false
    /// Each account's sharing against its provider's primary, worked out off the main thread.
    @State var sharing: [String: HarnessSharing.Report] = [:]
    @State private var addingAccount = false
    private let flow = AddAccountStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.sectionGap) {
            SettingsPageHeader(title: L("Accounts"),
                               subtitle: L("Every Claude and Codex account Tally reads, side by side.")) {
                addAccountAction
            }
            ForEach(ProviderCatalog.descriptors, id: \.id) { descriptor in
                providerGroup(id: descriptor.id, name: descriptor.name)
            }
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
        // The floating copy of the row in hand, above both cards, tracking the pointer.
        .overlay { if let rowLift { liftedRow(rowLift) } }
        .coordinateSpace(name: Self.reorderSpace)
        // Cancellation safety net, mirroring the panel: a cancelled preview vanishes.
        .onChange(of: isRowDragActive) { _, active in if !active { rowLift = nil } }
        .onDisappear { rowLift = nil }
    }

    /// Starts under the name column, so the number column reads as one unbroken strip.
    private var rowDivider: some View {
        let style = AccountTableStyle.current
        return SettingsDivider(inset: style.inset + style.lead)
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

    /// `-TallyDemoData YES` plus `-TallyDemoRenaming <n>` (the row opens with its rename field up),
    /// `-TallyDemoMenuOpen <n>` (its actions menu open) or `-TallyDemoStopSharing <n>` (the row
    /// after "Stop sharing settings"): row n of the fixtures, for a capture. Debug builds only.
    static func demoRowID(forKey key: String) -> String? {
        #if DEBUG
        guard DemoUsage.isActive else { return nil }
        let row = UserDefaults.standard.integer(forKey: key)
        let ids = SettingsStore.shared.orderedAccountIDs(DemoUsage.discoveredAccounts().map(\.id))
        if ids.indices.contains(row - 1) { return ids[row - 1] }
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
        VStack(alignment: .leading, spacing: SettingsChrome.headerToCard) {
            // Count only when there is something to count - a "1" badge said nothing. Nothing sits
            // to the title's right: the provider switch is the card's first row, the add-account
            // entry is the page header's.
            SettingsSectionTitle(title: name, count: items.count > 1 ? items.count : nil,
                                 icon: ProviderIconView(providerID: id, size: 14))
            // Re-asked whenever the list or its order changes: the first account is the primary.
            .task(id: items.map(\.id) + items.compactMap(\.launchHome)) {
                // Merged like the real reports: each provider group reports only its own rows, and
                // an assignment would wipe the other group's marks.
                if let demo = AccountHomeTag.demoReports(items) {
                    sharing.merge(demo) { $1 }
                    // `-TallyDemoStopSharing <n>`: the row after the press, for a capture.
                    if let id = Self.demoRowID(forKey: "TallyDemoStopSharing"),
                       let item = items.first(where: { $0.id == id }) { stopSharing(item) }
                } else {
                    sharing.merge(await AccountHomeTag.reports(items, providerID: id)) { $1 }
                }
            }

            // The card is always there now: switched off it holds just the provider's own switch.
            VStack(spacing: 0) {
                SettingsRow(title: String(format: L("Track %@"), name)) { providerToggle(id) }
                if settings.isEnabled(id) {
                    SettingsDivider(inset: SettingsChrome.dividerInsetPlain)
                    // The table's switches, menus and spinners are small: seventeen regular
                    // switches in a column would outweigh the figures they sit beside.
                    accountList(id, items).controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .modifier(SettingsCardSurface())
            // On the stable card, never on a row: a live reorder moves the rows, and SwiftUI
            // cancels a gesture whose view that diff tears down (the panel's lesson,
            // PopoverRootView). High priority after 4pt of travel, so a press that stays put
            // is still the switch's, the menu's or the name's own click. Switched off there are no
            // rows to grab, so a drag on the lone switch row lifts nothing.
            .highPriorityGesture(reorderDrag(siblings: items.map(\.id)))
        }
    }

    /// The provider's own switch, at the end of its card's first row.
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
    }

    @ViewBuilder
    private func accountList(_ id: String, _ items: [ProviderAccount]) -> some View {
        let state = AccountListState.resolve(hasDiscovered: store.hasDiscovered,
                                             accountCount: items.count)
        if state != .populated {
            placeholderRow(state)
        } else {
            compactHeader()
        }
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            rowDivider
            // The account's row and, under the marked account, its reserve line are one block: one
            // hover wash and no divider between them (B-2526 G17).
            VStack(alignment: .leading, spacing: 0) {
                // Same numbering the menu-bar strip uses for same-provider accounts, so the
                // settings row visibly maps to a strip segment.
                compactRow(
                    item,
                    usage: store.accounts.first { $0.id == item.id },
                    badge: items.count > 1 ? index + 1 : nil,
                    moveUp: index > 0 ? { swapAccounts(items, index, index - 1) } : nil,
                    moveDown: index < items.count - 1 ? { swapAccounts(items, index, index + 1) } : nil)
                // The row in hand leaves its seat empty; the floating copy is what moves.
                .opacity(rowLift?.id == item.id ? 0 : 1)
                .contentShape(Rectangle())
                .cardFrame(id: item.id, in: Self.reorderSpace)
                // The reserve belongs to the marked account and appears NOWHERE ELSE - not greyed
                // on the other rows, not a line the pane always carries. A machine with one
                // account, or one where nobody has marked theirs, has nothing to reserve quota
                // from, and a control standing there anyway is a question the user cannot answer.
                if let home = PersonalAccount.home(accountID: item.id, launchHome: item.launchHome),
                   PersonalAccount.isPersonal(accountID: item.id, home: home) {
                    reserveRow(home,
                               owner: settings.displayLabel(accountID: item.id, fallback: item.label))
                }
            }
            .background(Rectangle()
                .fill(hoveredAccountID == item.id && rowLift == nil ? Color.primary.opacity(0.03)
                      : .clear))
            .onHover { inside in
                if inside { hoveredAccountID = item.id }
                else if hoveredAccountID == item.id { hoveredAccountID = nil }
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
    /// still one click away - the sheet offers it whenever a run does not finish. One button in the
    /// page header: it opens the flow for the only tracked provider, or asks which of two.
    @ViewBuilder
    private var addAccountAction: some View {
        let tracked = ProviderCatalog.descriptors.filter { settings.isEnabled($0.id) }
        let hint = L("Tally creates the next config home and opens the provider's sign-in in your browser.")
        if tracked.count == 1, let only = tracked.first {
            PageActionButton(title: L("Add account…"), symbol: "plus") { beginAddAccount(only.id) }
                .disabled(!canAddAccount(only.id))
                .tallyTooltip(hint)
        } else if tracked.count > 1 {
            Menu {
                ForEach(tracked, id: \.id) { descriptor in
                    Button(descriptor.name) { beginAddAccount(descriptor.id) }
                        .disabled(!canAddAccount(descriptor.id))
                }
            } label: {
                PageActionLabel(title: L("Add account…"), symbol: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .tallyTooltip(hint)
        }
    }

    /// Demo fixtures have no config home behind them, so the flow could only ever leave a stray
    /// directory: a button that cannot work must not look like one that can.
    private func canAddAccount(_ providerID: String) -> Bool {
        flow.canAdd(providerID: providerID) && !flow.isRunning
    }

    private func beginAddAccount(_ providerID: String) {
        // Provider and reset in one call: a login still out there owns both, and this
        // entry must not repoint the flow at another provider while it does (the sheet
        // would then offer that provider's command for this one's home).
        flow.beginEntry(providerID: providerID)
        addingAccount = true
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

    /// Drag a row onto a sibling to reorder, exactly the way the panel's rows reorder
    /// (PopoverCardGrid `reorderGesture`): the row under the drag's start is lifted once, a floating
    /// copy follows the pointer, and the copy's centre (not the pointer) is what has to reach a
    /// sibling's core, so a row grabbed by its handle at the far edge still reorders (B-1388). Only
    /// within the provider (only siblings are hit-tested, and `moveAccountWithinProvider` refuses a
    /// foreign target); a row being renamed does not lift.
    private func reorderDrag(siblings: [String]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.reorderSpace))
            .updating($isRowDragActive) { _, state, _ in state = true }
            .onChanged { value in
                if rowLift == nil {
                    guard let grip = ReorderLift(grabbing: value.startLocation, at: value.location,
                                                 frames: rowFrames.filter { siblings.contains($0.key) }),
                          renamingAccountID != grip.id
                    else { return }
                    rowLift = grip
                }
                guard var lift = rowLift else { return }   // grab began off a row
                lift.location = value.location
                rowLift = lift
                guard let target = reorderTarget(at: lift.previewCentre, frames: rowFrames,
                                                 excluding: lift.id, orderedIDs: siblings)
                else { return }
                var moved = false
                withAnimation(CardMotion.spring) {
                    moved = settings.moveAccountWithinProvider(
                        lift.id, onto: target, siblingIDs: siblings,
                        allIDs: store.discoveredAccounts.map(\.id))
                }
                if moved { Haptics.snap() }
            }
            .onEnded { _ in rowLift = nil }
    }

    /// The row in hand, lifted the way the panel lifts its rows (`liftedCard`), on a card surface of
    /// its own: a row draws none, and a floating row with nothing behind it would show the pane through.
    @ViewBuilder
    private func liftedRow(_ lift: ReorderLift) -> some View {
        if let item = store.discoveredAccounts.first(where: { $0.id == lift.id }) {
            let siblings = discovered(for: item.providerID)
            compactRow(item, usage: store.accounts.first { $0.id == item.id },
                       badge: siblings.count > 1 ? siblings.firstIndex { $0.id == item.id }.map { $0 + 1 } : nil,
                       moveUp: nil, moveDown: nil)
                .modifier(SettingsCardSurface())
                .liftedCard(width: lift.sourceFrame.width, centre: lift.previewCentre,
                            following: lift.location)
        }
    }

    private func swapAccounts(_ items: [ProviderAccount], _ a: Int, _ b: Int) {
        var ids = items.map(\.id)
        ids.swapAt(a, b)
        settings.applyProviderOrder(orderedProviderIDs: ids,
                                    allIDs: store.discoveredAccounts.map(\.id))
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
                                                                      home: personalHome),
                               stopSharing: canStopSharing(item) ? { stopSharing(item) } : nil)
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
        .background { if Self.demoRowID(forKey: "TallyDemoMenuOpen") == item.id { DemoMenuOpener() } }
        .tallyTooltip(L("Account actions"))
    }

    /// The config home a row names: discovery's, or on a many-accounts demo capture the fixture's.
    func home(of item: ProviderAccount) -> String? {
        item.launchHome ?? DemoUsage.manyAccountsHome(accountID: item.id)
    }

    /// Whether this row offers "Stop sharing settings": exactly when it draws the link mark (the
    /// same report and the same first-row rule `shareMark` uses), and never on the provider's main
    /// home, which every other account's links point into (the rule the Remove entry asks).
    /// `home(of:)` rather than `launchHome`, so a many-accounts demo capture offers it too.
    func canStopSharing(_ item: ProviderAccount) -> Bool {
        discovered(for: item.providerID).first?.id != item.id
            && sharing[item.id]?.tag != nil
            && accountHomeIsRemovable(providerID: item.providerID, home: home(of: item))
    }

    /// Unlink one account, then ask the filesystem again so the mark follows what is on disk. A
    /// demo capture stands for homes that are not on this machine: its mark goes, nothing is touched.
    func stopSharing(_ item: ProviderAccount) {
        guard !DemoUsage.isActive else {
            sharing[item.id] = nil
            return
        }
        guard let home = item.launchHome else { return }
        IntegrationsStore.shared.stopSharingHarness(providerID: item.providerID,
                                                    home: URL(fileURLWithPath: home))
        let items = discovered(for: item.providerID)
        Task { sharing.merge(await AccountHomeTag.reports(items, providerID: item.providerID)) { $1 } }
    }

    /// The provider's primary account's display name (nickname applied), for the sharing mark.
    func primaryName(_ primary: ProviderAccount?) -> String {
        primary.map { settings.displayLabel(accountID: $0.id, fallback: $0.label) } ?? ""
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

    /// A login that landed this launch and has not named itself yet (`UsageStore.arrivedThisLaunch`).
    func isSigningIn(_ item: ProviderAccount) -> Bool {
        !item.isDormant && UsageStore.shared.arrivedThisLaunch.contains(item.id)
    }
}

/// `-TallyDemoMenuOpen` (Debug captures only, see `demoRowID`): opens the menu button it sits
/// behind, once, from inside the app, so the open menu can be photographed without a synthesized
/// click on somebody's desktop.
struct DemoMenuOpener: NSViewRepresentable {
    final class Probe: NSView {
        private var fired = false
        // Transparent to the hit test below, so the point lands on the button this sits behind.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !fired else { return }
            fired = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.open() }
        }
        private func open() {
            guard let content = window?.contentView else { return }
            let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            var hit = content.hitTest(content.superview?.convert(center, from: nil) ?? center)
            while let view = hit, !(view is NSControl) { hit = view.superview }
            (hit as? NSControl)?.performClick(nil)
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}
