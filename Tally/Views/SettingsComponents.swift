import SwiftUI

// The Settings window's shared page vocabulary (B-2526), laid out like Jetto Voice's settings so the
// two apps read as one family: a page header (26 bold title, 13 subtitle, page-level actions on the
// right), section titles OUTSIDE their card, one card per section, and rows at two type sizes
// (15 medium title, 13 secondary description at most two lines). Every pane builds from these;
// nothing here knows about a particular pane.

/// A page: header first, then sections, 28pt apart.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.sectionGap) { content }
    }
}

// MARK: - Page header

/// 26 bold title over a 13 secondary subtitle (two lines at most, so a long CJK sentence still
/// says its point), with the page's own actions on the right.
struct SettingsPageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .bold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 2)
            Spacer(minLength: 12)
            HStack(spacing: 8) { trailing }
        }
    }
}

extension SettingsPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The face of a page-level action: 32 high, a card surface, 12 semibold icon and 13 medium title.
/// `destructive` turns icon and title red and the hover wash red. Public so a `Menu` can wear it.
struct PageActionLabel: View {
    let title: String
    let symbol: String
    var destructive = false
    var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            Text(title)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(destructive ? Color(nsColor: .systemRed) : Color.primary)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(shape.fill(destructive && hovered ? Color(nsColor: .systemRed).opacity(0.08) : .clear))
        .modifier(SettingsCardSurface(cornerRadius: 8, highlighted: hovered))
        .contentShape(shape)
    }
}

/// A page-level action button (Add account, Install all, Remove all).
struct PageActionButton: View {
    let title: String
    let symbol: String
    var destructive = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            PageActionLabel(title: title, symbol: symbol, destructive: destructive, hovered: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovered)
    }
}

// MARK: - Sections and cards

/// A section's title above its card: optional icon (18 wide), 15 semibold secondary, an optional
/// count, a hairline running to the trailing edge. Nothing sits to its right.
struct SettingsSectionTitle<Icon: View>: View {
    let title: String
    var count: Int?
    var icon: Icon?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: 8) {
            if let icon { icon.font(.system(size: 14)).frame(width: 18) }
            Text(title).font(.system(size: 15, weight: .semibold))
            if let count {
                Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.tertiary)
            }
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1 / displayScale).padding(.leading, 2)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
    }
}

/// A card: rounded 12, white on the page in light mode, rows' hover wash clipped to its corners.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .modifier(SettingsCardSurface())
    }
}

/// A titled group: title outside, one card below it (at most five rows by design; an account table
/// or a machine list is the exception). `icon` is any small view (an SF Symbol, a provider mark).
struct SettingsSection<Icon: View, Content: View>: View {
    let title: String
    var count: Int?
    var icon: Icon?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.headerToCard) {
            SettingsSectionTitle(title: title, count: count, icon: icon)
            SettingsCard { content }
        }
    }
}

extension SettingsSection where Icon == Image {
    init(_ title: String, symbol: String, count: Int? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, icon: Image(systemName: symbol), content: content)
    }
}

extension SettingsSection where Icon == EmptyView {
    init(_ title: String, count: Int? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, icon: nil, content: content)
    }
}

extension SettingsSection {
    /// Any icon view, e.g. `ProviderIconView`.
    init(_ title: String, count: Int? = nil, @ViewBuilder icon: () -> Icon, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, icon: icon(), content: content)
    }
}

// MARK: - Rows

/// The line between two rows: 1 physical pixel, from the text column (`inset` 56 with an icon, 20
/// without; `SettingsChrome.dividerInsetIcon` / `dividerInsetPlain`).
struct SettingsDivider: View {
    var inset: CGFloat = SettingsChrome.dividerInsetIcon
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1 / displayScale).padding(.leading, inset)
    }
}

/// The small `info.circle` after a row title; the hover text rides on the whole label
/// (`SettingsRowLabel`), this only says that there is one.
struct SettingsInfoGlyph: View {
    var body: some View {
        Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(.tertiary)
    }
}

/// A row's left side: optional 17pt line icon in a 24-wide slot, 15 medium title, 13 description
/// held to two lines. `info` is the long explanation: it moves into a hover and adds the glyph.
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String?
    var icon: String?
    var info: String?
    /// Holds the hover open for a design capture (`-TallyTooltipPreview <target>`).
    var tooltipPreview: TallyTooltip.PreviewTarget?

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    if let info, !info.isEmpty { SettingsInfoGlyph() }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .tallyTooltip(info ?? "", forced: tooltipPreview.map(TallyTooltip.previewForced) ?? false)
    }
}

/// One row of a card: label on the left, its control on the right at natural width. 20x10 insets,
/// at least 52 high, a 3% wash under the pointer.
struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var icon: String?
    var info: String?
    var tooltipPreview: TallyTooltip.PreviewTarget?
    @ViewBuilder var accessory: Accessory
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            SettingsRowLabel(title: title, subtitle: subtitle, icon: icon, info: info,
                             tooltipPreview: tooltipPreview)
            Spacer(minLength: 12)
            accessory.fixedSize()
        }
        .padding(.horizontal, SettingsChrome.rowInsetH)
        .padding(.vertical, SettingsChrome.rowInsetV)
        .frame(minHeight: SettingsChrome.rowMinHeight)
        .background(Color.primary.opacity(hovered ? 0.03 : 0))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovered)
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
/// the same card, text aligned under the parent's title, no icon, 13 secondary, 40 high.
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
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(tint ?? Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let info, !info.isEmpty { SettingsInfoGlyph() }
            }
            .tallyTooltip(info ?? "", forced: tooltipPreview.map(TallyTooltip.previewForced) ?? false)
            Spacer(minLength: 12)
            accessory.fixedSize()
        }
        .padding(.leading, SettingsChrome.dividerInsetIcon)
        .padding(.trailing, SettingsChrome.rowInsetH)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
    }
}

extension SettingsSubRow where Accessory == EmptyView {
    init(title: String, tint: Color? = nil) {
        self.init(title: title, tint: tint) { EmptyView() }
    }
}

// MARK: - Status, notices

/// "● Installed", "● Needs attention": a 6pt dot and 12 medium text, no fill and no frame.
struct SettingsStatusBadge: View {
    enum Tone { case good, goodMuted, attention, neutral }

    let text: String
    var tone: Tone = .good

    var body: some View {
        HStack(spacing: 5) {
            if tone != .neutral { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(ink)
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
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(tint.opacity(0.06)))
        .overlay(shape.strokeBorder(tint.opacity(0.2), lineWidth: 0.5))
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
