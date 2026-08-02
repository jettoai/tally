import SwiftUI
import AppKit

/// The popover's footer strip, split out of PopoverRootView for file size: the used/left toggle,
/// the view menu (layout + gauge metric), help, pin, window and settings buttons, with the jetto
/// credit centered when the width leaves the middle empty.
extension PopoverRootView {
    var footer: some View {
        HStack {
            // A segmented control, not a switch: both states are valid views (nothing is "off"), and
            // showing both labels at once means the current mode and the alternative are always legible.
            // Used before Left, mirroring the meters' geometry: the used portion fills from the
            // track's left edge and the remainder hugs the right, so the toggle order matches
            // where each quantity lives in the bar.
            Picker("", selection: $settings.displayMode) {
                Text(L("Used")).tag(DisplayMode.used)
                Text(L("Left")).tag(DisplayMode.remaining)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .fixedSize()
            .help(L("Meters show"))
            Spacer()
            // Footer icons are one muted set (secondary); only the pin lights up (accent) when active,
            // so an unpinned pin doesn't read as already-on.
            // First in the group because it is the only ACTION here: everything after it changes
            // what this window shows, and an action reads wrong buried among view toggles. The
            // glyph is deliberately not a plain circular arrow - that is the header's quota
            // refresh, and two circular arrows on one surface would read as the same control.
            // Two arrows closing a loop: at the footer's 13pt a single circular arrow is the
            // header's quota refresh and a gear-in-loop turns to mush, while this reads as
            // "cycle it" at size (rendered and compared at 13pt before choosing).
            // Never disabled on a live count: nothing tells SwiftUI that a session started or ended,
            // so a rendered zero would leave the icon dead for the life of the window. The press
            // reads the count fresh and says so (see ReloadAction.presentConfirm).
            Button {
                ReloadAction.presentConfirm()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(ReloadAction.tooltip())
            // View options: every layout dimension behind one footer icon. A popover card rather
            // than a native menu, because the column count is now a row of layout tiles - a picture
            // of each layout beats five numbers, and a menu can only list text. The keyboard and
            // VoiceOver affordances a menu would have brought for free are carried by the tiles'
            // own help / accessibility labels instead.
            Button {
                showViewOptions.toggle()
            } label: {
                Image(systemName: "rectangle.split.3x1")
                    .font(.callout)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(showViewOptions ? Color.accentColor : Color.secondary)
            .help(L("View options"))
            .popover(isPresented: $showViewOptions, arrowEdge: .bottom) { viewOptions }
            Button {
                showLaunchHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.callout)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L("Help"))
            .popover(isPresented: $showLaunchHelp, arrowEdge: .bottom) { launchHelp }
            Button {
                StatusItemController.togglePin()
            } label: {
                Image(systemName: settings.isUsagePanelPinned ? "pin.fill" : "pin")
                    .font(.callout)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(settings.isUsagePanelPinned ? Color.accentColor : Color.secondary)
            .help(settings.isUsagePanelPinned ? L("Unpin window") : L("Pin on top"))
            Button {
                MainWindowController.shared.show()
            } label: {
                Image(systemName: "macwindow")
                    .font(.callout)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L("Open Tally"))
            Button {
                StatusItemController.openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.callout)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L("Settings…"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        // The jetto credit, dead centre in the footer's empty middle - quiet, on every surface,
        // and off the header so the product wordmark stands alone. Only when the middle is
        // actually empty: at the single-column width the icon cluster reaches the centre and
        // the credit drew underneath it.
        .overlay {
            if popoverWidth >= PopoverRootView.twoColumnPanelWidth {
                HStack(spacing: 4) {
                    Text("by").font(.caption2).foregroundStyle(.tertiary)
                    ProviderIconShape(pathData: ProviderMarks.jettoWordmark, inset: 0)
                        .fill(Color.secondary, style: FillStyle(eoFill: true))
                        .frame(width: 40, height: 9)
                }
                .opacity(0.75)
                .allowsHitTesting(false)
            }
        }
    }

    /// The view-options card, in the cards' own spacing vocabulary: the layout tiles first (the
    /// dimension people come here to change), then the two switches that decide what is on the
    /// panel at all, then what the gauges render. Same order and same words as the Settings pane's
    /// display rows, so neither surface teaches a vocabulary the other contradicts.
    var viewOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: TallyMetrics.headerToCard) {
                Text(L("Layout")).font(.caption).foregroundStyle(.secondary)
                LayoutColumnPicker(selection: $settings.panelColumns)
            }
            Divider()
            Toggle(L("Group by provider"), isOn: $settings.groupByProvider)
            // "Gauges only" is the one-click version of collapsing every pooled provider; clicking
            // a single gauge row stays the granular tool.
            Toggle(L("Gauges only"), isOn: Binding(
                get: {
                    let pooled = pooledProviderIDs
                    return !pooled.isEmpty && pooled.isSubset(of: settings.collapsedProviders)
                },
                set: { on in
                    let pooled = pooledProviderIDs
                    if on { settings.collapsedProviders.formUnion(pooled) }
                    else { settings.collapsedProviders.subtract(pooled) }
                }
            ))
            .disabled(pooledProviderIDs.isEmpty)
            Divider()
            // What the gauges render: all pooled windows (primary budget + weekly total, both
            // runways at once - the default), or collapsed to a single pool for people who only
            // ration one budget. The menu-bar number follows the leading pool.
            VStack(alignment: .leading, spacing: TallyMetrics.headerToCard) {
                Text(L("Gauges show")).font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $settings.gaugeFocus) {
                    Text(L("All pools")).tag(GaugeFocus.all)
                    Text(L("Primary model only")).tag(GaugeFocus.primary)
                    Text(L("Weekly total only")).tag(GaugeFocus.weekly)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .padding(TallyMetrics.cardPaddingH)
        .frame(width: 268)
    }
}
