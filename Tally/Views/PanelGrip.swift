import SwiftUI

/// The pinned panel's handle: six small dots along its top edge, and the whole strip moves the
/// panel. The Detailed panel has no title line of its own to take hold of, so it says where.
struct PanelGrip: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 6, id: \.self) { _ in
                Circle().fill(PanelStyle.text3).frame(width: 3, height: 3)
            }
        }
        .padding(.top, 5)
        .frame(maxWidth: .infinity)
        .frame(height: 11, alignment: .top)
        .contentShape(Rectangle())
        .windowDragSurface()
        .accessibilityHidden(true)
    }
}
