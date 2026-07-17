import SwiftUI

/// Preferences as hand-built grouped cards over a NON-LAZY VStack - deliberately not SwiftUI's
/// `Form`: the grouped form is List-backed, lazily materializes rows and exposes no intrinsic
/// height, which made "open the window exactly content-fit" unsolvable (a short window keeps rows
/// unbuilt, so the measured height stays short - a self-locking loop). A plain VStack lays out
/// everything at once, so the measured height below IS the true content height, reported to the
/// window controller the same way the pinned panel sizes itself (`onContentSize` pattern).
struct SettingsView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    /// Reports the content's full natural height so the host window can fit itself exactly.
    var onContentHeight: (CGFloat) -> Void = { _ in }

    @State private var renamingAccountID: String?

    var body: some View {
        // The ScrollView is inert at the natural size; it only actually scrolls when the content
        // outgrows the screen cap applied by the controller.
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                sectionCard { accountsRows }
                sectionHeader(L("Display"))
                sectionCard { displayRows }
                sectionHeader(L("General"))
                sectionCard { generalRows }
                sectionCard { aboutRows }
                    .padding(.top, 8)
            }
            .padding(16)
            .background(
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                        onContentHeight(height)
                    }
                }
            )
        }
        .frame(width: 500)
        .controlSize(.small)
        // Key `.id` on the language so switching it rebuilds the whole tree and re-localizes every
        // label (see PopoverRootView for why a bare read isn't enough).
        .id(settings.languageOverride ?? "system")
    }

    // MARK: Section chrome

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 10)
            .padding(.leading, 4)
    }

    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.5)))
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 14)
    }

    // MARK: Accounts - one group per provider, its accounts nested beneath the provider's switch.

    @ViewBuilder
    private var accountsRows: some View {
        let descriptors = ProviderCatalog.descriptors
        ForEach(Array(descriptors.enumerated()), id: \.element.id) { index, descriptor in
            if index > 0 { rowDivider }
            providerGroup(id: descriptor.id, name: descriptor.name)
        }
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
                HStack(spacing: 5) {
                    Text(settings.displayLabel(accountID: item.id, fallback: item.label))
                        .font(.subheadline.weight(.semibold))
                    Button {
                        renamingAccountID = item.id
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Rename"))
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
                }

                HStack(spacing: 8) {
                    if !enabled {
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

            // Reorder arrows (multi-account providers only, column always reserved so the switch
            // columns line up across every card).
            VStack(spacing: 2) {
                reorderArrow("chevron.up", action: moveUp)
                reorderArrow("chevron.down", action: moveDown)
            }
            .frame(width: 16)
            .opacity(moveUp == nil && moveDown == nil ? 0 : 1)

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
                Text(L("Enabled")).font(.caption).foregroundStyle(.secondary)
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

    private func reorderArrow(_ symbol: String, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(action == nil ? Color(nsColor: .quaternaryLabelColor) : .secondary)
                .frame(width: 16, height: 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
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
            Text(L("Menu bar")).font(.caption).foregroundStyle(.secondary)
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

    // MARK: Display

    @ViewBuilder
    private var displayRows: some View {
        HStack {
            Text(L("Meters show")).font(.subheadline)
            Spacer()
            Picker("", selection: $settings.displayMode) {
                Text(L("Left")).tag(DisplayMode.remaining)
                Text(L("Used")).tag(DisplayMode.used)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        rowDivider

        toggleRow(L("Show every model tier"),
                  subtitle: L("Off shows only the highest-tier model at a glance."),
                  isOn: $settings.showAllModels)

        rowDivider

        toggleRow(L("Glass pinned panel"),
                  subtitle: L("The pinned panel shows the desktop through frosted glass."),
                  isOn: $settings.isPanelTranslucent)
    }

    private func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: isOn) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: General

    @ViewBuilder
    private var generalRows: some View {
        HStack {
            Text(L("Language")).font(.subheadline)
            Spacer()
            Picker("", selection: Binding(
                get: { settings.languageOverride ?? "" },
                set: { settings.languageOverride = $0.isEmpty ? nil : $0 }
            )) {
                Text(L("System")).tag("")
                ForEach(AppLocale.supported, id: \.self) { code in
                    Text(languageName(code)).tag(code)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        rowDivider

        HStack {
            Text(L("Refresh every")).font(.subheadline)
            Spacer()
            Picker("", selection: $settings.refreshIntervalMinutes) {
                // Short intervals are safe now that reads go through the providers' own CLIs
                // (first-party identity → the generous rate-limit bucket; Tally's old direct reads
                // 429'd at 1 min). Each poll spawns the CLIs, so 1 min costs a few seconds of
                // background CPU per tick - the user's call.
                ForEach([1, 2, 5, 15], id: \.self) { minutes in
                    Text(String(localized: "\(minutes) min", bundle: AppLocale.bundle)).tag(minutes)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: About - brand + version (brand names stay unlocalized).

    @ViewBuilder
    private var aboutRows: some View {
        HStack(spacing: 6) {
            TallyWordmarkView(glyphHeight: 11)
            Text("by").font(.subheadline)
            ProviderIconShape(pathData: ProviderMarks.jettoWordmark, inset: 0)
                .fill(Color.primary, style: FillStyle(eoFill: true))
                .frame(width: 53, height: 12)
            Spacer()
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .font(.caption).foregroundStyle(.secondary)
            Link("jetto.ai", destination: URL(string: "https://jetto.ai")!)
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        // Hidden in dev builds (the updater is dormant without a feed URL + ED key).
        if UpdaterController.shared.isActive {
            rowDivider
            HStack {
                Text(L("Check for Updates…")).font(.subheadline)
                Spacer()
                Button(L("Check Now")) { UpdaterController.shared.checkForUpdates() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
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

    private func languageName(_ code: String) -> String {
        switch code {
        case "en": return "English"
        case "zh-Hant": return "繁體中文"
        case "zh-Hans": return "简体中文"
        case "ja": return "日本語"
        case "ko": return "한국어"
        default: return code
        }
    }
}
