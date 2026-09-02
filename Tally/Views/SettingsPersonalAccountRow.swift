import SwiftUI

/// THE PERSONAL ACCOUNT'S OWN TWO PIECES OF THE ACCOUNTS PANE, split out of SettingsAccountsView for
/// file size: the mark on the account's name line, and the water line under it.
///
/// What the marking means, and why one account gets it, is in Tally/Core/AccountReserve.swift. What
/// this file adds is the surface: the pane is where somebody comes to say "this one is the account I
/// use in my browser", so it is also where they say how much of it to leave alone.
extension SettingsAccountsView {
    /// The mark itself. In the app's own accent rather than a launch colour: this is not a launch
    /// mode (the panel's Smart purple and Pinned orange are), it is a fact about the account.
    var personalBadge: some View {
        Text(L("Personal"))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(TallyColor.ai)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(TallyColor.ai.opacity(0.15)))
            .fixedSize()   // a badge must never wrap
            // Tally's own callout, like every other hover on this row since 2026-08-24: the badge
            // sits on the account's name line, and one native box among the row's own chips is the
            // seam the owner spotted on the sign-in chip.
            .tallyTooltip(L("The account you are signed into on claude.ai. Tally publishes artifacts from it, and can keep part of its quota free for you."))
    }

    /// "Keep at least 30% of the week and the 5h window for web use", and the ten-cell strip that
    /// sets it.
    ///
    /// THE NUMBER IS IN THE SENTENCE rather than in a field beside it, because the sentence is what
    /// the setting means and a bare "30" next to "Reserve" is a number the reader has to translate
    /// every time. The strip is the only control, and it carries the same number a second way: the
    /// sentence says what the setting IS, the cells say where it sits on the scale and what is left
    /// (`ReserveCellBar` states why ten of them, `AccountRoles.reserveStep` what one is worth). A
    /// typed field would invite a precision this figure does not have.
    ///
    /// AND THE SENTENCE NAMES BOTH WINDOWS, because that is what the number does: the reserve is
    /// held back from the account's weekly window and its 5h one, the two its owner's browser draws
    /// on as well, and from no other (Tally/Core/AccountReserve.swift states why). A bare "quota"
    /// would promise a line on the flagship bar, which carries none.
    ///
    /// The second line is the part somebody will otherwise get wrong in the expensive direction: a
    /// reserve binds TALLY'S OWN choices and nothing else, so naming this account still launches on
    /// it. Without that sentence the control reads as a cap on the account, which is a thing people
    /// would rightly be afraid to set.
    func reserveRow(_ home: String, underBadge: Bool) -> some View {
        // A capture shows the fixture's figure, and its strip writes nothing (the marking itself
        // does not exist on a demo launch - PersonalAccount).
        let shown = DemoUsage.isActive ? DemoUsage.personalReserve
            : LaunchPolicyStore.shared.reserve(home: home)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: L("Keep at least %lld%% of the week and the 5h window for web use"), shown))
                    .font(.subheadline)
                Text(L("Tally leaves this much of the account's weekly and 5-hour quota alone when it picks or moves sessions by itself, because your browser shares both windows with it. Its per-model windows are untouched, and launching on it yourself always works."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            ReserveCellBar(value: shown) { LaunchPolicyStore.shared.setReserve(home, $0) }
                .disabled(DemoUsage.isActive)
                // CENTRED ON THE SENTENCE'S FIRST LINE. The strip is not text and has no baseline
                // of its own, so the row's baseline alignment would fall back to its bottom edge
                // and hang it low against the line it belongs to.
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // ALIGNED WITH THE ACCOUNT'S NAME, not merely indented past it: this row is a property of
        // the row above and the eye reads that from one shared left edge. The account row nests at
        // 18, and where the provider has siblings its number badge (22pt plus the 10pt gap) puts the
        // name another 32 along - a column that is simply absent on a provider with one account, so
        // a constant here would sit 32pt adrift on exactly those machines.
        .padding(.leading, underBadge ? 50 : 18)
    }
}
