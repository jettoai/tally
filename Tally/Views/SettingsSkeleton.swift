import SwiftUI

// The settings window's skeleton (B-4474): a fixed page header over a scroll view of the page's own,
// three card types, and the numbers they are drawn with. Written to move into a shared package
// (Jetto Voice has the same shape, B-4473), so nothing here names an app type: the app's adapters
// (SettingsComponents.swift) turn its own strings, colours and tooltips into these.

/// The skeleton's numbers. Only the window and sidebar sizes vary between apps; every other value
/// is the design spec's.
struct PageSkeleton: Equatable {
    var windowWidth: CGFloat
    var windowHeight: CGFloat
    var sidebarWidth: CGFloat

    // Page frame: the header is 104 high, the first element of a page sits at y116.
    static let headerHeight: CGFloat = 104
    static let headerTop: CGFloat = 36
    static let horizontal: CGFloat = 40
    static let top: CGFloat = 12
    static let bottom: CGFloat = 32
    // Spacing scale (4, 8, 12, 16, 24, 32, 40 only).
    static let gutter: CGFloat = 12
    static let sectionGap: CGFloat = 24
    static let sectionTitleToCard: CGFloat = 10
    static let sectionTitleToNote: CGFloat = 6
    // Card A: grouped rows.
    static let cornerRadius: CGFloat = 12
    static let rowMinHeight: CGFloat = 52
    static let rowInsetH: CGFloat = 20
    static let rowInsetV: CGFloat = 10
    static let rowIconSlot: CGFloat = 24
    static let rowIconGap: CGFloat = 12
    static var dividerInsetIcon: CGFloat { rowInsetH + rowIconSlot + rowIconGap }
    static let subRowHeight: CGFloat = 36
    // Card B: tiles.
    static let tileHeight: CGFloat = 96
    // Card C: tables.
    static let tableHeaderHeight: CGFloat = 28
    static let tableRowHeight: CGFloat = 36
    // Controls.
    static let pageButtonHeight: CGFloat = 32
    static let inlineControlHeight: CGFloat = 26
    // Sidebar.
    static let brandTop: CGFloat = 46
    static let tagsTop: CGFloat = 80
    static let tagsHeight: CGFloat = 22
    static let navTop: CGFloat = 116
    static let navRowHeight: CGFloat = 34
    static let navRowSpacing: CGFloat = 2
    static let navInset: CGFloat = 10
    /// The `.id` at the top and foot of every page's scroll content.
    static let topAnchor = "settings.paneTop"
    static let bottomAnchor = "settings.paneBottom"

    /// The content column: the window less the sidebar less the page's two insets (700).
    var contentWidth: CGFloat { windowWidth - sidebarWidth - 2 * Self.horizontal }
    var tileWidth: CGFloat { (contentWidth - 3 * Self.gutter) / 4 }
}

/// The skeleton's type scale, in points.
enum PageType {
    static let pageTitle: CGFloat = 26, pageTitleLine: CGFloat = 32
    static let pageSubtitle: CGFloat = 13, pageSubtitleLine: CGFloat = 18, titleToSubtitle: CGFloat = 4
    static let sectionTitle: CGFloat = 15, sectionIcon: CGFloat = 15, count: CGFloat = 12, note: CGFloat = 12
    static let tableHeader: CGFloat = 11
    static let pageButton: CGFloat = 13, pageButtonIcon: CGFloat = 12, inlineButton: CGFloat = 12
    static let sidebar: CGFloat = 14, sidebarIcon: CGFloat = 17
}

// MARK: - Environment

private struct PageSkeletonKey: EnvironmentKey {
    static let defaultValue = PageSkeleton(windowWidth: 980, windowHeight: 700, sidebarWidth: 200)
}
private struct PageScrollTargetKey: EnvironmentKey { static let defaultValue: Binding<String?>? = nil }
private struct PageIsActiveKey: EnvironmentKey { static let defaultValue = true }
private struct PageIDKey: EnvironmentKey { static let defaultValue = "page" }
private struct PageStartsScrolledKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var pageSkeleton: PageSkeleton {
        get { self[PageSkeletonKey.self] } set { self[PageSkeletonKey.self] = newValue }
    }
    /// A request to scroll the page in front to the view tagged with this id; consumed on arrival.
    var pageScrollTarget: Binding<String?>? {
        get { self[PageScrollTargetKey.self] } set { self[PageScrollTargetKey.self] = newValue }
    }
    /// Whether this page is the one on screen: pages that wait keep their state and scroll back to the top.
    var pageIsActive: Bool {
        get { self[PageIsActiveKey.self] } set { self[PageIsActiveKey.self] = newValue }
    }
    /// Names the page in the geometry probes.
    var pageID: String { get { self[PageIDKey.self] } set { self[PageIDKey.self] = newValue } }
    /// A capture asks the page to open scrolled to its foot (header hairline shots).
    var pageStartsScrolled: Bool {
        get { self[PageStartsScrolledKey.self] } set { self[PageStartsScrolledKey.self] = newValue }
    }
}

// MARK: - Geometry probe

/// Global frames of the skeleton's landmarks, for the pane-switch bench. Debug only.
@MainActor
enum PageGeometryProbe {
    #if DEBUG
    static var frames: [String: CGRect] = [:]
    #else
    static var frames: [String: CGRect] { [:] }
    #endif
}

extension View {
    #if DEBUG
    func pageGeometryProbe(_ key: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, frame in
                PageGeometryProbe.frames[key] = frame
            }
        })
    }
    #else
    func pageGeometryProbe(_ key: String) -> some View { self }
    #endif
}

// MARK: - Page: fixed header, own scroll view

private let pageScrollSpace = "pageScroll"

private struct PageScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 104 high, title top at 36, the trailing slot 32 high on the title's line and ending at the
/// content column's right edge. A hairline shows once the page has scrolled under it.
struct MainPageHeader<Title: View, Subtitle: View, Trailing: View>: View {
    let title: Title
    let subtitle: Subtitle
    let trailing: Trailing
    var scrolled = false
    @Environment(\.pageID) private var pageID
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: PageType.titleToSubtitle) {
                title.font(.system(size: PageType.pageTitle, weight: .bold)).lineLimit(1)
                    .frame(height: PageType.pageTitleLine, alignment: .leading)
                subtitle.font(.system(size: PageType.pageSubtitle)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(height: PageType.pageSubtitleLine, alignment: .leading)
            }
            .padding(.top, PageSkeleton.headerTop)
            .padding(.horizontal, PageSkeleton.horizontal)
            HStack(spacing: 8) { trailing }
                .frame(height: PageSkeleton.pageButtonHeight)
                .padding(.top, PageSkeleton.headerTop)
                .padding(.trailing, PageSkeleton.horizontal)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: PageSkeleton.headerHeight, alignment: .top)
        .overlay(alignment: .bottom) {
            if scrolled { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1 / displayScale) }
        }
        .pageGeometryProbe("\(pageID).header")
    }
}

/// A page: the fixed header, then a scroll view of its own holding the content column. Reports no
/// size to the window.
struct MainPageScroll<Title: View, Subtitle: View, Trailing: View, Content: View>: View {
    let title: Title
    let subtitle: Subtitle
    let trailing: Trailing
    let content: Content
    @Environment(\.pageIsActive) private var isActive
    @Environment(\.pageScrollTarget) private var target
    @Environment(\.pageStartsScrolled) private var startsScrolled
    @State private var scrolled = false

    init(title: Title, subtitle: Subtitle, trailing: Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            MainPageHeader(title: title, subtitle: subtitle, trailing: trailing, scrolled: scrolled)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        // The zero-height probe whose position in the scroll view's space says how far it has scrolled.
                        Color.clear.frame(height: 0).id(PageSkeleton.topAnchor)
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: PageScrollOffsetKey.self,
                                                       value: geo.frame(in: .named(pageScrollSpace)).minY)
                            })
                        content.mainPageColumn()
                            .padding(.top, PageSkeleton.top)
                            .padding(.bottom, PageSkeleton.bottom)
                        Color.clear.frame(height: 0).id(PageSkeleton.bottomAnchor)
                    }
                }
                .coordinateSpace(name: pageScrollSpace)
                .onPreferenceChange(PageScrollOffsetKey.self) { scrolled = $0 < -0.5 }
                // A page that stops being the one in front goes back to its top while nobody can see it.
                .onChange(of: isActive) { _, active in
                    if !active { proxy.scrollTo(PageSkeleton.topAnchor, anchor: .top) }
                }
                // A request for a view of this page; one turn later, so a page that is only now
                // getting its height has laid the view out.
                .onChange(of: target?.wrappedValue) { _, id in
                    guard isActive, let id, let target else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(id, anchor: .top)
                        target.wrappedValue = nil
                    }
                }
                .onAppear {
                    guard startsScrolled, isActive else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        proxy.scrollTo(PageSkeleton.bottomAnchor, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct PageColumn: ViewModifier {
    @Environment(\.pageSkeleton) private var skeleton
    @Environment(\.pageID) private var pageID

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0).pageGeometryProbe("\(pageID).first")
            content
        }
        .frame(width: skeleton.contentWidth, alignment: .topLeading)
        .pageGeometryProbe("\(pageID).column")
        .padding(.leading, PageSkeleton.horizontal)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

extension View {
    /// The 700-wide content column, 40 in from the pane's left edge.
    func mainPageColumn() -> some View { modifier(PageColumn()) }
}

// MARK: - Sections

/// A section's title above its card: icon 15, title 15 semibold, count 12, a hairline to the edge.
/// The left edge is the column's, with no inset of its own.
struct PageSectionTitle<Icon: View>: View {
    let title: String
    var count: Int?
    var icon: Icon?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: 8) {
            if let icon { icon.font(.system(size: PageType.sectionIcon)).frame(width: 18) }
            Text(title).font(.system(size: PageType.sectionTitle, weight: .semibold))
            if let count {
                Text("\(count)").font(.system(size: PageType.count).monospacedDigit()).foregroundStyle(.tertiary)
            }
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1 / displayScale)
        }
        .foregroundStyle(.secondary)
        .frame(height: 20)
    }
}

/// A titled group: the title, an optional note under it, then the content in a card (or bare, for tiles).
struct PageSection<Icon: View, Content: View>: View {
    let title: String
    var count: Int?
    var icon: Icon?
    var note: Text?
    var card = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageSectionTitle(title: title, count: count, icon: icon)
            if let note {
                note.font(.system(size: PageType.note)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, PageSkeleton.sectionTitleToNote)
            }
            Group {
                if card { GroupCard { content } } else { content }
            }
            .padding(.top, PageSkeleton.sectionTitleToCard)
        }
    }
}

// MARK: - Card surface and the three card types

/// A card face: white on the page in light mode with a faint shadow, a 6% white wash in dark.
struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = PageSkeleton.cornerRadius
    /// A raised card under the pointer (a page-level action button), one step brighter.
    var highlighted = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = scheme == .dark
        content
            .background(shape.fill(dark ? Color.white.opacity(highlighted ? 0.09 : 0.06) : Color.white)
                .shadow(color: .black.opacity(dark ? 0 : (highlighted ? 0.09 : 0.05)),
                        radius: highlighted ? 5 : 3, y: 1))
            .overlay(shape.strokeBorder(Color.primary.opacity(dark ? 0.09 : 0.08), lineWidth: 0.5))
    }
}

/// Card A: grouped rows, the rows' hover wash clipped to the corners.
struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: PageSkeleton.cornerRadius, style: .continuous))
            .modifier(CardSurface())
    }
}

/// One row of card A: the label on the left, the accessory on the right at natural width. Insets
/// 20 x 10, at least 52 high, a 3% wash under the pointer.
struct GroupRowFrame<Label: View, Accessory: View>: View {
    @ViewBuilder var label: Label
    @ViewBuilder var accessory: Accessory
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            label
            Spacer(minLength: 12)
            accessory
        }
        .padding(.horizontal, PageSkeleton.rowInsetH)
        .padding(.vertical, PageSkeleton.rowInsetV)
        .frame(minHeight: PageSkeleton.rowMinHeight)
        .background(Color.primary.opacity(hovered ? 0.03 : 0))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovered)
    }
}

/// A row that belongs to the one above it: text under the parent's title column, 36 high.
struct GroupSubRowFrame<Label: View, Accessory: View>: View {
    @ViewBuilder var label: Label
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            label
            Spacer(minLength: 12)
            accessory
        }
        .padding(.leading, PageSkeleton.dividerInsetIcon)
        .padding(.trailing, PageSkeleton.rowInsetH)
        .padding(.vertical, 6)
        .frame(minHeight: PageSkeleton.subRowHeight)
    }
}

/// The line between two rows: 1 physical pixel, from the text column (or from the inset, with no icon).
struct GroupDivider: View {
    var inset: CGFloat = PageSkeleton.dividerInsetIcon
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1 / displayScale).padding(.leading, inset)
    }
}

/// Card B's row: tiles in four columns of `tileWidth`, 12 apart. One row per grid; stack grids for more.
struct TileGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: PageSkeleton.gutter) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Card B: a tile `span` columns wide, 96 high (taller if its content is), a 1.5 point accent frame when selected.
struct TileCard<Content: View>: View {
    var span = 1
    var selected = false
    @ViewBuilder var content: Content
    @Environment(\.pageSkeleton) private var skeleton

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PageSkeleton.cornerRadius, style: .continuous)
        content
            .frame(width: CGFloat(span) * skeleton.tileWidth + CGFloat(span - 1) * PageSkeleton.gutter,
                   alignment: .topLeading)
            .frame(minHeight: PageSkeleton.tileHeight)
            .modifier(CardSurface())
            .overlay(shape.strokeBorder(Color.accentColor, lineWidth: selected ? 1.5 : 0))
            .contentShape(shape)
    }
}

/// Card C's header row: 28 high, 11 point secondary text, the card's row inset on both sides.
struct TableHeaderFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.system(size: PageType.tableHeader)).foregroundStyle(.secondary)
            .padding(.horizontal, PageSkeleton.rowInsetH)
            .frame(height: PageSkeleton.tableHeaderHeight)
    }
}

/// Card C's body row: 36 high, the card's row inset on both sides.
struct TableRowFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, PageSkeleton.rowInsetH)
            .frame(minHeight: PageSkeleton.tableRowHeight)
    }
}

// MARK: - Notices and buttons

/// A tinted strip: radius 12, insets 12 x 16, 6% fill and a 20% frame in the tint.
struct NoticeSurface: ViewModifier {
    var tint: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PageSkeleton.cornerRadius, style: .continuous)
        content
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(tint.opacity(0.06)))
            .overlay(shape.strokeBorder(tint.opacity(0.2), lineWidth: 0.5))
    }
}

/// The face of a page-level button: 32 high, a card surface, 13 point medium. `symbol` may be left out.
/// Public so a `Menu` can wear it.
struct PageButtonLabel: View {
    let title: String
    var symbol: String?
    var destructive = false
    var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: PageType.pageButtonIcon, weight: .semibold)) }
            Text(title)
        }
        .font(.system(size: PageType.pageButton, weight: .medium))
        .foregroundStyle(destructive ? Color(nsColor: .systemRed) : Color.primary)
        .padding(.horizontal, 12)
        .frame(height: PageSkeleton.pageButtonHeight)
        .background(shape.fill(destructive && hovered ? Color(nsColor: .systemRed).opacity(0.08) : .clear))
        .modifier(CardSurface(cornerRadius: 8, highlighted: hovered))
        .contentShape(shape)
    }
}

/// A button inside a row (Remove, Apply): 26 high, radius 6, 12 points, dimmed while disabled.
struct InlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.4)
            .font(.system(size: PageType.inlineButton, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: PageSkeleton.inlineControlHeight)
            .modifier(CardSurface(cornerRadius: 6, highlighted: configuration.isPressed))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
