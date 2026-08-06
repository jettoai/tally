import SwiftUI
import AppKit

/// The footer strip, split out of PopoverRootView for file size: the used/left toggle, the reload,
/// view options, pin, window and settings buttons, then the help button set apart at the trailing
/// end, with the jetto credit between the clusters whenever the row has room to spare. What the
/// surface SHOWS is switched in the header, not here: this row is the view controls, and mixing
/// "which screen" into it made the one action here hard to find.

/// The measured widths of everything in the footer that does NOT depend on the credit being shown:
/// the two rigid clusters, plus an unrendered copy of the credit itself. Because no member changes
/// when the credit appears or disappears, the decision below can never feed back into its own inputs
/// and oscillate - the numbers describe the row as it would be laid out with no credit at all.
struct FooterWidths: Equatable {
    var picker: CGFloat = 0
    var icons: CGFloat = 0
    var credit: CGFloat = 0
}

extension PopoverRootView {
    /// The clear space between the switch and the credit. Fixed rather than elastic: the credit is
    /// grouped WITH the leading control, and the one gap that may stretch is the one before the icons.
    private static let creditLead: CGFloat = 16

    /// The break before the help button, on top of the stack's own spacing. Small enough that help
    /// still reads as part of the footer, wide enough that it is plainly not the sixth view control.
    private static let helpLead: CGFloat = 10

    /// The credit rides in the row's layout flow rather than in an overlay. An overlay draws at the
    /// footer's centre whatever else is there, so it could only be kept off the icons by a hand-picked
    /// width threshold - which went stale the moment the trailing group grew by a button, and that is
    /// how it came to draw underneath them. In flow it is kept only while the row has room for it plus
    /// its lead and 12pt of clear space before the icons, and dropped whole otherwise: overlap stops
    /// being expressible.
    ///
    /// It sits with the switch at the leading end rather than in the row's middle. Centred between two
    /// clusters of unequal width, it never looked centred on anything: it drifted with every change to
    /// the trailing group and read as a mark that had missed its mark. Parked after the switch it is
    /// where a byline belongs, and the empty space stays where the row can afford it - in the middle.
    ///
    /// One row, never two. Deciding this with `ViewThatFits` would hand each side of the threshold its
    /// own subtree, so crossing it tears down and rebuilds the icons - and the View options button owns
    /// a `.popover`, which closes when its presenter is rebuilt. Changing the column count from inside
    /// that card is exactly what crosses the threshold, so the card closed under the user's cursor
    /// mid-adjustment. Here the row (and every control's identity in it) is the same view throughout;
    /// only the credit before the spacer comes and goes.
    var footer: some View {
        HStack(spacing: 0) {
            // A segmented control, not a switch: both states are valid views (nothing is "off"), and
            // showing both labels at once means the current mode and the alternative are always legible.
            // Used before Left, mirroring the meters' geometry: the used portion fills from the
            // track's left edge and the remainder hugs the right, so the toggle order matches
            // where each quantity lives in the bar.
            NeutralSegmentedPicker(selection: $settings.displayMode,
                                   options: [.used, .remaining],
                                   size: .mini) { $0 == .used ? L("Used") : L("Left") }
                .tallyTooltip(L("Meters show"))
                .background { widthProbe { footerWidths.picker = $0 } }
            if showsCredit {
                jettoCredit.padding(.leading, Self.creditLead)
            }
            Spacer(minLength: 12)
            footerIcons
        }
        // The credit is measured off a copy that is never drawn and never laid out (a background is
        // sized by its host, not the other way round), so its width is known even in the frames where
        // the credit is hidden - the alternative, measuring the real one, could only ever confirm the
        // decision it was already the result of.
        .background(alignment: .leading) {
            jettoCredit.hidden().background { widthProbe { footerWidths.credit = $0 } }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// Room for the credit, its lead, and 12pt of clear space before the icons, measured rather than
    /// assumed. Unmeasured parts read 0, which stays false: better a late credit than one drawn over
    /// the icons.
    private var showsCredit: Bool {
        let parts = footerWidths
        guard parts.picker > 0, parts.icons > 0, parts.credit > 0 else { return false }
        return parts.picker + Self.creditLead + parts.credit + 12 + parts.icons <= popoverWidth - 24
    }

    /// Quiet, on every surface, and off the header so the product wordmark stands alone.
    ///
    /// The build's own version rides here: during a day of shipping several builds the question "is
    /// this window the one I just installed" has to be answerable without opening Settings, and the
    /// footer is the band that can afford an extra fact. Rendered as part of the credit rather than
    /// beside it so it is inside what `showsCredit` measures - the width probe below sizes an
    /// unrendered copy of THIS view, so a version that is wider on one machine than another is
    /// already accounted for, and the row drops the whole credit rather than letting it reach the
    /// icons.
    ///
    /// FIRST, NOT LAST, and the order is the whole of what it means. Trailing the wordmark it read
    /// as "Jetto 0.38.3" - a version number belonging to the author rather than to this app, which
    /// is the one thing it must not say. Leading it is the ordinary "X by Y" of a byline, where the
    /// version binds to the product and `by` binds to whoever made it.
    private var jettoCredit: some View {
        HStack(spacing: 4) {
            // Not localized on purpose: a dotted version number is a token, not prose. Absent on a
            // bundle that carries none - and the separator goes with it, since a byline opening on
            // a dangling interpunct is worse than one that simply says less.
            if let version = BuildVariant.version {
                Text("\(version) ·").font(.caption2).foregroundStyle(.tertiary)
            }
            Text("by").font(.caption2).foregroundStyle(.tertiary)
            ProviderIconShape(pathData: ProviderMarks.jettoWordmark, inset: 0)
                .fill(Color.secondary, style: FillStyle(eoFill: true))
                .frame(width: 40, height: 9)
        }
        .opacity(0.75)
        .allowsHitTesting(false)
    }

    /// The trailing cluster, one view so it can be measured as one. Its own spacing is the stack
    /// default, unchanged: only the row around it went to explicit spacing, so that the width the
    /// credit needs is exactly the width it and its two 12pt margins occupy.
    private var footerIcons: some View {
        HStack {
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
            .tallyTooltip(ReloadAction.tooltip())
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
            .tallyTooltip(L("View options"))
            // The card carries its own callout layer. A popover is a separate presentation: the
            // environment travels INTO it, so the layout tiles inside read "hosted" and skip the
            // system-tooltip fallback, but their preference never travels back OUT to the panel's
            // layer, so the hover was answered with nothing at all. One layer per presentation is
            // what closes that (see `TallyTooltip`).
            .popover(isPresented: $showViewOptions, arrowEdge: .bottom) {
                viewOptions.tallyTooltipLayer()
            }
            // Published upward because the window controllers need it: every control in that card
            // resizes the surface, and while it is open THAT surface holds the bottom-right corner
            // still so the control stays under the pointer (see `ResizeAnchor`). Written from the
            // one place that owns the presentation, so it cannot say "open" while nothing is, and
            // it names this host so the other surface on screen keeps its own rule.
            .onChange(of: showViewOptions) { _, open in
                settings.setViewOptionsOpen(open, host: host)
            }
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
            .tallyTooltip(settings.isUsagePanelPinned ? L("Unpin window") : L("Pin on top"))
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
            .tallyTooltip(L("Open Tally"))
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
            .tallyTooltip(L("Settings…"))
            // Help sits past the trailing end of the group, with a gap wide enough to read as a
            // break rather than as loose tracking. It is the one control here that acts on nothing
            // in this window, and macOS parks the help button in the bottom trailing corner away
            // from the other controls for exactly that reason. Between the view toggles it read as
            // one of them.
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
            .tallyTooltip(L("Help"))
            // Its own layer too, for the same reason as the view-options card above: the copy chips
            // inside it are hover targets, and a presentation cannot publish into the layer outside it.
            .popover(isPresented: $showLaunchHelp, arrowEdge: .bottom) {
                launchHelp.tallyTooltipLayer()
            }
            .padding(.leading, Self.helpLead)
        }
        .background { widthProbe { footerWidths.icons = $0 } }
    }

    /// The view-options card, in the cards' own spacing vocabulary: the layout tiles first (the
    /// dimension people come here to change), then the two switches that decide what is on the
    /// panel at all, then what the gauges render. Same order and same words as the Settings pane's
    /// display rows, so neither surface teaches a vocabulary the other contradicts.
    var viewOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: TallyMetrics.headerToCard) {
                Text(L("Layout")).font(.caption).foregroundStyle(.secondary)
                // Density first, then the count: what each element IS comes before how many of them
                // fit. The footer's own used/left switch is this control, so the card offers one
                // vocabulary for "pick one of two views" rather than a second hand-rolled one.
                NeutralSegmentedPicker(selection: $settings.panelDensity,
                                       options: PanelDensity.allCases,
                                       size: .small) { $0 == .cards ? L("Cards") : L("List") }
                // One picker, two remembered numbers: it edits the count of whichever density is on
                // screen (`densityColumns`), so switching density restores that density's own layout
                // instead of carrying a number chosen for the other one.
                LayoutColumnPicker(selection: $settings.densityColumns,
                                   maxColumns: settings.densityMaxColumns)
            }
            Divider()
            // The two strips' own switches, the same ones the Settings pane carries: they decide
            // whether the gauge and the advisor are on the panel at all, which is the question that
            // comes before how the gauges are drawn. Reaching Settings to turn a strip off was the
            // one layout decision this card could not make.
            Toggle(L("Fleet gauge"), isOn: $settings.showFleetGauge)
            Toggle(L("Usage advisor"), isOn: $settings.showAdvisor)
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
            // Folding cards behind a gauge that is switched off would hide them behind nothing at
            // all, which is the one state the panel must never reach (see `visibleAccounts`).
            .disabled(pooledProviderIDs.isEmpty || !settings.showFleetGauge)
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
            // Nothing to configure while there is no gauge to configure. Greyed rather than hidden,
            // so the card does not change height under the pointer when the switch above is flipped.
            .disabled(!settings.showFleetGauge)
            .opacity(settings.showFleetGauge ? 1 : 0.5)
        }
        .padding(TallyMetrics.cardPaddingH)
        .frame(width: 268)
        // The card claiming the resize anchor, and the ONLY thing that ever claims it: every
        // control below is reached by pointing at this card, so being pointed at is the same fact
        // as "a control here is about to be clicked" (see `SettingsStore.resizeAnchor(for:)`).
        // On the card as a whole rather than on each control, so a control added here inherits it.
        .onHover { settings.viewOptionsPointer(inside: $0, host: host) }
    }
}
