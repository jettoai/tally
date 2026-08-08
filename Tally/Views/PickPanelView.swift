import SwiftUI

// The list itself. One row is one whole decision, so there is no Accept: the click IS the submit,
// and the keyboard path is Enter on the row the arrow keys are resting on.
//
// THE RESTING ROW IS WHERE THE SESSION ALREADY IS (`PickRow.isCurrent`), not the top of the list.
// That is what makes the keyboard path short for the change people actually make: one arrow from
// "the model I am on at the depth I am on" is the same model one level deeper.

struct PickPanelView: View {
    let request: PickRequest
    /// nil is a cancellation. One closure for both, because the panel above treats them as one
    /// event: something happened and the panel is done.
    let choose: (PickRow?) -> Void

    @State private var selection: Int
    @FocusState private var focused: Bool

    init(request: PickRequest, choose: @escaping (PickRow?) -> Void) {
        self.request = request
        self.choose = choose
        _selection = State(initialValue: request.rows.firstIndex(where: { $0.isCurrent }) ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TallyMetrics.headerToCard) {
            Text(request.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(request.rows.enumerated()), id: \.offset) { index, row in
                            PickRowView(row: row, isSelected: index == selection)
                                .id(index)
                                .contentShape(Rectangle())
                                // ONE CLICK, no second confirmation. The cost of a mis-click is a
                                // pin to the wrong account, which the same panel undoes in one more
                                // click; the cost of an Accept key is one extra action on every
                                // correct pick, for ever.
                                .onTapGesture { choose(row) }
                                .onHover { if $0 { selection = index } }
                        }
                    }
                    .padding(.vertical, 2)
                }
                // Capped so the intrinsic height stays bounded whatever the fleet or the effort list
                // does: the panel is sized by this content and nothing else (PickPanelController).
                .frame(maxHeight: 360)
                .onChange(of: selection) { _, now in
                    withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(now, anchor: .center) }
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .padding(.horizontal, TallyMetrics.pagePaddingH)
        .padding(.vertical, TallyMetrics.pagePaddingV)
        .frame(width: 460)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.return) { commit() }
        .onKeyPress(.escape) {
            choose(nil)
            return .handled
        }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !request.rows.isEmpty else { return .handled }
        // Clamped rather than wrapped: a list that jumps from the last row to the first turns a held
        // arrow key into a lap of the fleet.
        selection = min(max(selection + step, 0), request.rows.count - 1)
        return .handled
    }

    private func commit() -> KeyPress.Result {
        guard request.rows.indices.contains(selection) else { return .handled }
        choose(request.rows[selection])
        return .handled
    }
}

/// One row: what it is, what it costs, and what it is to this session.
struct PickRowView: View {
    let row: PickRow
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.label)
                        .font(.body)
                        .fontWeight(row.isCurrent ? .semibold : .regular)
                    if let effort = row.effort {
                        Text(effort)
                            .font(.caption)
                            .foregroundStyle(TallyColor.ai)
                    }
                }
                if let detail = row.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            // The tags the CLI decided, drawn rather than restated: which account this session is on
            // and which one has the most headroom are one answer for every surface.
            ForEach(row.tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .foregroundStyle(tag == switchRecommendedTag ? TallyColor.normal : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: TallyMetrics.calloutRadius, style: .continuous)
                            .fill(.quaternary.opacity(isSelected ? 0.35 : 0.25)))
            }
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.selection.opacity(0.55))
                      : AnyShapeStyle(Color.clear)))
    }
}
