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
            // The view menu: both layout dimensions behind one footer icon. "Gauges only" is the
            // one-click version of collapsing every pooled provider (clicking a single gauge row
            // stays the granular tool); below the divider, the same column value the Settings
            // pane edits. Two dimensions, one door - not a knob per feature.
            Menu {
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
                Picker("", selection: $settings.panelColumns) {
                    Text(L("Auto")).tag(0)
                    Text(verbatim: "1").tag(1)
                    Text(verbatim: "2").tag(2)
                    Text(verbatim: "3").tag(3)
                    Text(verbatim: "4").tag(4)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                // What the gauges render: all pooled windows (primary budget + weekly total,
                // both runways at once - the default), or collapsed to a single pool for people
                // who only ration one budget. The menu-bar number follows the leading pool.
                Section(L("Gauges show")) {
                    Picker("", selection: $settings.gaugeFocus) {
                        Text(L("All pools")).tag(GaugeFocus.all)
                        Text(L("Primary model only")).tag(GaugeFocus.primary)
                        Text(L("Weekly total only")).tag(GaugeFocus.weekly)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            } label: {
                Image(systemName: "rectangle.split.3x1")
                    .font(.callout)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help(L("View options"))
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
            if popoverWidth >= 560 {
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
}
