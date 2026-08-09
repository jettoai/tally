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
        VStack(alignment: .leading, spacing: 0) {
            header
            // THREE SIZES, THREE JOBS: the header is the anchor, this is the situation it is
            // answering, and the rows are the answer. Everything was one weight of grey before, so
            // the panel read as two paragraphs with a list under them.
            Text(request.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, TallyMetrics.headerToCard + 4)
            ScrollViewReader { proxy in
                ScrollView {
                    // EAGER, and that is a sizing decision rather than a performance one: what the
                    // list is told to be tall is what these rows MEASURE (`rowsHeightReporter`), and
                    // a lazy stack only measures the rows it has materialized. The lists here are a
                    // fleet or an effort table, tens of rows at the outside.
                    //
                    // SPACED BY THE RULE RATHER THAN EVENLY (`pickRowGap`), which is why the stack
                    // itself has none: one model and its two depths belong together, and an even 2
                    // points made ten rows read as ten unrelated ones.
                    VStack(spacing: 0) {
                        ForEach(pickScrollingIndices(of: request.rows), id: \.self) { index in
                            separator(above: index)
                            row(at: index)
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
                    // Only what scrolls can be scrolled to: the pinned row is not in this region,
                    // and it does not need to be brought into view because it never leaves.
                    guard pickScrollingIndices(of: request.rows).contains(now) else { return }
                    withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(now, anchor: .center) }
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
            // PINNED UNDER THE LIST, not in it: the row that releases the pin is what a person
            // reaches for when the list is not what they wanted, and a long fleet used to scroll it
            // out of sight. Still the last member of `request.rows`, so the arrow keys walk onto it
            // from the last scrolling row and Enter takes it like any other (`pickScrollingIndices`).
            if let release = request.rows.indices.last,
               pickRowIsRelease(index: release, of: request.rows) {
                separator(above: release)
                row(at: release)
            }
        }
        // THE PANEL'S OWN CONTENT LINE, which is the popover's and the pinned panel's
        // (`PanelGeometry.contentPadding`): this surface used to keep a wider margin of its own, so
        // two windows of the same app started their text at two different x.
        .padding(.horizontal, PanelGeometry.contentPadding)
        .padding(.vertical, PanelGeometry.contentPadding)
        .frame(width: 460)
        // Borderless, like the pinned panel, so the surface is drawn rather than inherited: same
        // backdrop, same 12pt continuous corner (PinnedPanelController). The titled panel this
        // replaced spent 32 points on a titlebar it kept empty, which is the dead space at the top
        // Albert saw.
        .background(PanelBackdrop(settings: .shared))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    /// THE SAME HEADER THE REST OF THE APP HAS, which is the whole of this decision: the popover
    /// and the pinned panel open with the wordmark on the content line, so this one does too rather
    /// than inventing a third way to say the app's own name (`PopoverRootView.header`). Two attempts
    /// at something of its own were rejected on sight, and the reason is that they were something of
    /// its own.
    ///
    /// The wordmark is laid out by its INK rather than its frame (`PanelGeometry.brandLead`): the
    /// glyph draws wider than the box it is given, so a frame padded to the content line puts the
    /// mark left of everything under it. The lead is shared with the popover, not copied from it.
    private var header: some View {
        HStack(spacing: 6) {
            TallyWordmarkView(glyphHeight: 13)
                .padding(.leading, PanelGeometry.brandLead - PanelGeometry.contentPadding)
            Spacer(minLength: 8)
            // Which of the two lists this is, said once and quietly: the message below already says
            // what is being decided, so this only has to name the axis.
            Text(pickPanelKindName(request.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tally, \(pickPanelKindName(request.kind))")
    }

    /// One row, wherever it is drawn. Shared by the scrolling region and the pinned row so the two
    /// cannot grow different behaviour: the same click, the same hover, the same resting mark.
    private func row(at index: Int) -> some View {
        PickRowView(row: request.rows[index], isSelected: index == selection)
            .id(index)
            .contentShape(Rectangle())
            // ONE CLICK, no second confirmation. The cost of a mis-click is a pin to the wrong
            // account, which the same panel undoes in one more click; the cost of an Accept key is
            // one extra action on every correct pick, for ever.
            .onTapGesture { choose(request.rows[index]) }
            .onHover { if $0 { selection = index } }
    }

    /// What goes above row `index`: the rule that sets the way out apart from the choices, or plain
    /// space. Both are the height `pickRowGap` says they are, which is what keeps the drawing and the
    /// arithmetic the same thing.
    @ViewBuilder private func separator(above index: Int) -> some View {
        if index > 0 {
            if pickRowIsRelease(index: index, of: request.rows) {
                Divider()
                    .opacity(0.5)
                    .padding(.vertical, pickRowGroupSpacing)
            } else {
                Color.clear
                    .frame(height: pickRowGap(before: index, rows: request.rows))
            }
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
                    // The name only. The depth is the chip beside it and the aside is the line
                    // below, so a label carrying either has that part taken off rather than saying
                    // it twice (`pickPanelLabel`).
                    Text(pickPanelLabel(row))
                        .font(.body)
                        .fontWeight(row.isCurrent ? .semibold : .regular)
                    if let effort = row.effort {
                        Text(effort)
                            .font(.caption)
                            .foregroundStyle(TallyColor.ai)
                    }
                }
                if let detail = pickPanelDetail(row), !detail.isEmpty {
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
