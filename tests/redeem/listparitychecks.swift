import Foundation

// The list row answers the same reset question the card does, at row scale: every ResetOffer
// state gets a mark, and what the card writes out in words the row keeps on hover or in the
// accessibility label rather than dropping. These are read from the source because the row is a
// SwiftUI view the suite cannot build; the helpers from main.swift dig out one body at a time.

/// The text inside the parentheses that open at `opener` (which must end in "("), balanced.
func balancedParens(_ source: String, after opener: String) -> String? {
    balancedBlock(source, after: opener, open: "(", close: ")")
}

func runListParityChecks(rowSource: String, offerSource: String) {
    // The population is every case ResetOffer declares, read from its own source so a new state
    // cannot be added without the row being asked about it. `case .x:` lines are switch arms.
    let enumBody = balancedBlock(offerSource, after: "enum ResetOffer: Equatable {") ?? ""
    let cases = enumBody.split(separator: "\n").compactMap { line -> String? in
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("case "), !text.hasPrefix("case .") else { return nil }
        let name = text.dropFirst(5).prefix { $0.isLetter || $0.isNumber }
        return name.isEmpty ? nil : String(name)
    }
    expect(!cases.isEmpty, "L0 the ResetOffer cases were read from its source")
    print("  ResetOffer cases: \(cases)")

    let marks = balancedBlock(rowSource, after: "private var usageMarks: some View {") ?? ""
    let missing = cases.filter { marks.range(of: "\\.\($0)\\b", options: .regularExpression) == nil }
    expect(!marks.isEmpty && missing.isEmpty,
           "L1 the list row's reset mark has a branch for every ResetOffer state")
    if !missing.isEmpty { print("  no branch for: \(missing)") }

    let limitMark = functionBody(rowSource, from: "private func sessionLimitMark(") ?? ""
    let limitHover = balancedParens(limitMark, after: ".tallyTooltipAroundControl(") ?? ""
    expect(limitHover.contains("limitResetLabel(") && limitHover.contains("limitResetHelp("),
           "L2 hovering the session-limit mark names its state, a used reset's return date included")
    expect(limitHover.contains("\"resetting…\""),
           "L3 hovering the session-limit spinner says the reset is running")

    // The redeem hover, wherever it is built: the tooltip's own arguments, plus the helper they
    // name when they name one.
    let redeemBody = functionBody(rowSource, from: "private func redeemButton(") ?? ""
    var redeemHover = balancedParens(redeemBody, after: ".tallyTooltipAroundControl(") ?? ""
    if redeemHover.contains("redeemHelp") {
        redeemHover += functionBody(rowSource, from: "private var redeemHelp: String {") ?? ""
    }
    // A signed-out login still holds its credits, so the expiry is not a branch of that question:
    // no line that reads the note may also be the dormant test or one arm of a ternary.
    let noteLines = redeemHover.split(separator: "\n").filter { $0.contains("resetExpiryNote(") }
    let noteGated = noteLines.contains { line in
        let text = line.trimmingCharacters(in: .whitespaces)
        return line.contains("isDormant") || text.hasPrefix(":") || text.hasPrefix("?")
    }
    expect(redeemHover.contains("Signed out: renew the login to spend a banked reset.")
           && !noteLines.isEmpty && !noteGated,
           "L4 a signed-out login's redeem hover still carries the expiry")
    expect(redeemHover.contains("\"redeeming…\""),
           "L5 hovering the redeem spinner says the redeem is running")

    let redeemLabel = balancedParens(redeemBody, after: ".accessibilityLabel(") ?? ""
    expect(redeemLabel.contains("\\(resets)") && redeemLabel.contains("resetExpiryNote("),
           "L6 the redeem control's accessibility label carries the count and the expiry")
}
