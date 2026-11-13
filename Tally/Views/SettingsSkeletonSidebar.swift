import SwiftUI

/// One sidebar entry.
struct PageSidebarItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let symbol: String
}

/// The settings sidebar (B-4474): a brand slot at y46, a tag slot at y80 (22 high), the navigation
/// from y116 (rows 34 high, 2 apart, 10 in from each side), and a footer slot pushed to the foot by
/// a spacer. The brand, tags and footer are the app's; the numbers are the skeleton's.
struct PageSidebar<ID: Hashable, Brand: View, Tags: View, Footer: View>: View {
    let items: [PageSidebarItem<ID>]
    let selection: ID
    let select: (ID) -> Void
    @ViewBuilder var brand: Brand
    @ViewBuilder var tags: Tags
    @ViewBuilder var footer: Footer
    @State private var hovered: ID?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .frame(height: 28, alignment: .leading)
                .pageGeometryProbe("sidebar.brand")
                .padding(.leading, 20)
                .padding(.top, PageSkeleton.brandTop)
            tags
                .frame(height: PageSkeleton.tagsHeight, alignment: .leading)
                .padding(.leading, 20)
                .padding(.top, PageSkeleton.tagsTop - PageSkeleton.brandTop - 28)
            nav
                .pageGeometryProbe("sidebar.nav")
                .padding(.horizontal, PageSkeleton.navInset)
                .padding(.top, PageSkeleton.navTop - PageSkeleton.tagsTop - PageSkeleton.tagsHeight)
            Spacer(minLength: 0)
            footer
        }
    }

    private var nav: some View {
        VStack(alignment: .leading, spacing: PageSkeleton.navRowSpacing) {
            ForEach(items) { item in
                let selected = item.id == selection
                Button { select(item.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.system(size: PageType.sidebarIcon))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .frame(width: 20)
                        Text(item.title).font(.system(size: PageType.sidebar, weight: selected ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: PageSkeleton.navRowHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill(selected, hovered: hovered == item.id)))
                    .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
                }
            }
        }
    }

    /// Selected: black 7% on light, white 9% on dark; a hover is a step under it.
    private func fill(_ selected: Bool, hovered: Bool) -> Color {
        let dark = scheme == .dark
        let base: Color = dark ? .white : .black
        if selected { return base.opacity(dark ? 0.09 : 0.07) }
        return base.opacity(hovered ? 0.05 : 0)
    }
}
