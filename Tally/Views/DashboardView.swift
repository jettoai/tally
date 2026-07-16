import SwiftUI

/// The main app window: a resizable dashboard of every account, complementing the compact menu-bar
/// popover. Cards flow in an adaptive grid so a wider window shows more per row.
struct DashboardView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore

    var body: some View {
        // Key `.id` on the language so a change tears down + rebuilds the whole tree — a bare read
        // wouldn't re-localize the AccountCardView children (see PopoverRootView for the full note).
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 380, minHeight: 420)
        .id(settings.languageOverride ?? "system")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.medium").foregroundStyle(.tint)
            Text("Tally").font(.title3.weight(.semibold))
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let updated = UsageFormat.updatedAgo(store.lastSuccessfulRefreshAt,
                                                        now: context.date) {
                    Text(updated).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await store.refresh(userInitiated: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing
                        ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                        value: store.isRefreshing)
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .accessibilityLabel(L("Refresh"))
            .help(L("Refresh"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if store.contentState != .hasAccounts {
            EmptyStateView(state: store.contentState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 288, maximum: 360), spacing: TallyMetrics.sectionSpacing)],
                    spacing: TallyMetrics.sectionSpacing
                ) {
                    ForEach(store.orderedAccounts) { usage in
                        AccountCardView(usage: usage, settings: settings)
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .padding(TallyMetrics.pagePaddingH)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                settings.displayMode = settings.displayMode.toggled
            } label: {
                Label(settings.displayMode == .used ? L("Showing: Used") : L("Showing: Left"),
                      systemImage: "arrow.left.arrow.right").font(.caption)
            }
            .buttonStyle(.borderless)
            Spacer()
            Button {
                StatusItemController.openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(L("Settings…"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
