import SwiftUI

// The Settings window's shared page vocabulary (B-2526, rebuilt on the skeleton in B-4474): a page
// is a fixed header (title, subtitle, page-level actions on the right) over a scroll view of its
// own, sections have their title OUTSIDE their card, and rows come at two type sizes (title,
// secondary description at most two lines). The numbers live in `PageSkeleton` and `SettingsType`;
// the elements here are this app's spellings of the skeleton's, adding its strings and tooltips.
// Every pane builds from these; nothing here knows about a particular pane.

/// A page: the fixed header, then the sections in a scroll view of the page's own, `sectionGap` apart.
/// The subtitle holds one line; its full text is the hover.
struct SettingsPage<Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        MainPageScroll(title: Text(title), subtitle: subtitleText, trailing: trailing) {
            VStack(alignment: .leading, spacing: SettingsChrome.sectionGap) { content }
        }
    }

    @ViewBuilder
    private var subtitleText: some View {
        if let subtitle, !subtitle.isEmpty { Text(subtitle).tallyTooltip(subtitle) } else { EmptyView() }
    }
}

extension SettingsPage where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

/// The face of a page-level action: the skeleton's button (32 high), icon optional. Public so a
/// `Menu` can wear it.
typealias PageActionLabel = PageButtonLabel

/// A page-level action button (Add account, Install all, Remove all).
struct PageActionButton: View {
    let title: String
    var symbol: String?
    var destructive = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            PageButtonLabel(title: title, symbol: symbol, destructive: destructive, hovered: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovered)
    }
}

// MARK: - Sections and cards

/// A card: the skeleton's card A, with its rows' tooltip obstacles measured.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GroupCard { content }.tallyTooltipObstacles()
    }
}

/// A titled group: title outside, an optional `note` under it, one card below (at most five rows by
/// design; an account table or a machine list is the exception; `card: false` leaves the content
/// bare, for a tile row). `icon` is any small view (an SF Symbol, a provider mark).
struct SettingsSection<Icon: View, Content: View>: View {
    let title: String
    var count: Int?
    var icon: Icon?
    var note: String?
    var card = true
    @ViewBuilder var content: Content

    var body: some View {
        PageSection(title: title, count: count, icon: icon, note: note.map { Text($0) }, card: false) {
            if card { SettingsCard { content } } else { content }
        }
    }
}

extension SettingsSection where Icon == Image {
    init(_ title: String, symbol: String, count: Int? = nil, note: String? = nil, card: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, icon: Image(systemName: symbol), note: note, card: card,
                  content: content)
    }
}

extension SettingsSection where Icon == EmptyView {
    init(_ title: String, count: Int? = nil, note: String? = nil, card: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, icon: nil, note: note, card: card, content: content)
    }
}

extension SettingsSection {
    /// Any icon view, e.g. `ProviderIconView`.
    init(_ title: String, count: Int? = nil, note: String? = nil, card: Bool = true,
         @ViewBuilder icon: () -> Icon, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, icon: icon(), note: note, card: card, content: content)
    }
}

// MARK: - Rows

/// The line between two rows (`GroupDivider`).
typealias SettingsDivider = GroupDivider

/// The small `info.circle` after a row title; the hover text rides on the whole label
/// (`SettingsRowLabel`), this only says that there is one.
struct SettingsInfoGlyph: View {
    var body: some View {
        Image(systemName: "info.circle").font(.system(size: SettingsType.info)).foregroundStyle(.tertiary)
    }
}

/// A row's left side: optional line icon in a `rowIconSlot`-wide slot, medium title, description
/// held to two lines. `info` is the long explanation: it moves into a hover and adds the glyph.
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String?
    var icon: String?
    var info: String?
    /// Holds the hover open for a design capture (`-TallyTooltipPreview <target>`).
    var tooltipPreview: TallyTooltip.PreviewTarget?

    var body: some View {
        HStack(spacing: SettingsChrome.rowIconGap) {
            if let icon {
                Image(systemName: icon).font(.system(size: SettingsType.rowIcon)).foregroundStyle(.secondary)
                    .frame(width: SettingsChrome.rowIconSlot)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: SettingsType.rowTitle, weight: .medium)).lineLimit(1)
                    if let info, !info.isEmpty { SettingsInfoGlyph() }
                }
                .tallyTooltipTitle()
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: SettingsType.rowSubtitle))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .tallyTooltipObstacle()
        .tallyTooltip(info ?? "", forced: tooltipPreview.map(TallyTooltip.previewForced) ?? TallyTooltip.previewRowForced(title: title),
                      beside: true)
    }
}

/// One row of a card: label on the left, its control on the right at natural width. Insets
/// `rowInsetH` x `rowInsetV`, at least `rowMinHeight` high, a 3% wash under the pointer.
struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var icon: String?
    var info: String?
    var tooltipPreview: TallyTooltip.PreviewTarget?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        GroupRowFrame {
            SettingsRowLabel(title: title, subtitle: subtitle, icon: icon, info: info,
                             tooltipPreview: tooltipPreview)
        } accessory: {
            accessory.fixedSize().tallyTooltipObstacle()
        }
    }
}

/// A row whose control is a switch. The spelling (`title:subtitle:isOn:`) is the About pane's old
/// one, so existing callers keep compiling.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    var icon: String?
    var info: String?
    let isOn: Binding<Bool>

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, icon: icon, info: info) {
            Toggle(isOn: isOn) { EmptyView() }.labelsHidden().toggleStyle(.switch)
        }
    }
}

/// A setting that belongs to the row above it (quiet hours under a relay switch): the next row of
/// the same card, text aligned under the parent's title, no icon, secondary, 36 high.
struct SettingsSubRow<Accessory: View>: View {
    let title: String
    var tint: Color?
    /// The explanation, as a hover on the title only (like `SettingsRowLabel`). Never on the whole
    /// row: a callout hugs its target, and a full-width row centres the chip across the card, far
    /// from the pointer and over the row above (B-2649).
    var info: String?
    var tooltipPreview: TallyTooltip.PreviewTarget?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        GroupSubRowFrame {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: SettingsType.rowSubtitle))
                    .foregroundStyle(tint ?? Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let info, !info.isEmpty { SettingsInfoGlyph() }
            }
            .tallyTooltipObstacle()
            .tallyTooltip(info ?? "", forced: tooltipPreview.map(TallyTooltip.previewForced) ?? false, beside: true)
        } accessory: {
            accessory.fixedSize().tallyTooltipObstacle()
        }
    }
}

extension SettingsSubRow where Accessory == EmptyView {
    init(title: String, tint: Color? = nil) {
        self.init(title: title, tint: tint) { EmptyView() }
    }
}

// MARK: - Status, notices

/// "● Installed", "● Needs attention": a 6pt dot and medium text, no fill and no frame.
struct SettingsStatusBadge: View {
    enum Tone { case good, goodMuted, attention, neutral }

    let text: String
    var tone: Tone = .good

    var body: some View {
        HStack(spacing: 5) {
            if tone != .neutral { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(text).font(.system(size: SettingsType.badge, weight: .medium)).foregroundStyle(ink)
        }
    }

    private var dot: Color { tone == .attention ? TallyColor.warning : TallyColor.normal }
    private var ink: Color {
        switch tone {
        case .good: return TallyColor.normal
        case .attention: return TallyColor.warningInk
        case .goodMuted: return .secondary
        case .neutral: return Color.primary.opacity(0.35)
        }
    }
}

/// A tinted strip above the page's sections: orange for a development build or an error, accent
/// for information. `trailing` holds borderless buttons (Undo, Dismiss).
struct SettingsNoticeBar<Trailing: View>: View {
    enum Kind { case dev, info, warning }

    let kind: Kind
    let title: String
    var message: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: SettingsType.noticeIcon)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: SettingsType.noticeTitle, weight: .medium))
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: SettingsType.noticeMessage))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .modifier(NoticeSurface(tint: tint))
    }

    private var tint: Color { kind == .info ? .accentColor : TallyColor.warning }
    private var symbol: String {
        switch kind {
        case .dev: return "hammer.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}

extension SettingsNoticeBar where Trailing == EmptyView {
    init(kind: Kind, title: String, message: String? = nil) {
        self.init(kind: kind, title: title, message: message) { EmptyView() }
    }
}

/// The development-build strip a page shows when it has a line of its own to say about it; nothing
/// in a shipped build.
struct SettingsDevBanner: View {
    let message: String

    var body: some View {
        if BuildVariant.isUnshipped {
            SettingsNoticeBar(kind: .dev, title: L("Development build"), message: message)
        }
    }
}
