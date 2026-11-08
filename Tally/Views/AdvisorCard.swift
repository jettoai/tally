import SwiftUI

/// The advisor's conclusions as one card under the provider cards: a sparkle, then for each provider
/// with something to act on the provider's name and the full sentence the heading's tag only
/// abbreviates. Nothing to say, no card.
struct AdvisorCard: View {
    let lines: [(providerID: String, sentence: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.providerID) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\u{2726}").foregroundStyle(TallyColor.ai)
                    (Text(ProviderCatalog.displayName(for: line.providerID))
                        .font(PanelStyle.font(11.5, 600)).foregroundColor(PanelStyle.text)
                     + Text(verbatim: " \u{00B7} " + line.sentence)
                        .font(PanelStyle.font(11.5, 400)).foregroundColor(PanelStyle.text2))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(PanelStyle.font(11.5, 400))
        .padding(.horizontal, PanelStyle.rowPadH)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }
}
