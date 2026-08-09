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
    /// What the rows actually laid out at, or zero before the first pass. Read through
    /// `pickRowsHeight`, which is where "zero is not a measurement" is decided.
    @State private var rowsHeight: CGFloat = 0

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
                    // EAGER, and that is a sizing decision rather than a performance one: what the
                    // list is told to be tall is what these rows MEASURE (`rowsHeightReporter`), and
                    // a lazy stack only measures the rows it has materialized. The lists here are a
                    // fleet or an effort table, tens of rows at the outside.
                    VStack(spacing: pickRowSpacing) {
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
                    .padding(.vertical, pickRowsPadding)
                    .background(rowsHeightReporter)
                }
                // TOLD, NOT ASKED. A ScrollView has no ideal height along its scroll axis, so a
                // panel sized by its content (`PickPanelController` leaves `sizingOptions` the only
                // size authority) used to get nothing back and come up as a message with no rows
                // under it. The height comes from the rows themselves now, measured or computed,
                // and `pickRowsHeight` is where both live.
                .frame(height: pickRowsHeight(measured: rowsHeight, rows: request.rows))
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

    /// The rows' own laid-out height, reported upward. Same shape as the surface the panel and the
    /// popover are sized by (`PopoverRootView.sizeReporter`), and for the same reason: a rendered
    /// size is a fact, while a size asked of a scrolling container is a preference it does not have.
    private var rowsHeightReporter: some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                rowsHeight = height
            }
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
